import 'dart:async';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dartsv/dartsv.dart' show NetworkType;
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/testing.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'fakes.dart';

/// The wallet's side of the pool's protocol, against a transport that is a
/// list in memory.
///
/// Two claims are under test here and they pull in opposite directions. The
/// first is that the client can be **told** things — the descriptor, the
/// announcements, the three catch-up answers — and act on them. The second is
/// that it believes none of them: every one of those answers is either
/// arithmetic the wallet can redo, or is checked against a round the wallet
/// proved off its own block headers, and a pool that lies is refused naming
/// the check rather than followed.
///
/// The third claim is quieter and is the reason for the recording transport:
/// across a full catch-up and a full payment, **nothing the wallet sends says
/// anything about the wallet**. Not an address, not a leaf, not a txid, and
/// not even a round of its own choosing.
void main() {
  late PoolTestChain c;
  late PoolDescriptor pool;
  late PoolShape shape;
  late ShieldedRound round1, round2;
  late List<int> br1, br2, cm1, cm2;
  late PoolAnnouncement ann1, ann2;
  late List<List<int>> feed;
  late ({int round, List<int> blockRoot, List<List<int>> left}) tipFrontier;

  late PoolWalletKeys wallet;
  late NoteAddress changeAddr;
  late ScannedNote note1;
  late List<List<int>> path1;

  late FakeHeaderSource headers;
  late PaymentChecker checker;
  late FakeBlock block2;
  late List<int> round2Bytes, witness2Bytes;
  late PoolCatchUpReply headReply, frontierReply;

  late Invoice invoice;
  late DateTime now;

  /// A transport carrying the fixture's feed, answering every request the way
  /// an honest pool would.
  FakeTransport honest({int acceptInto = 3}) {
    final t = FakeTransport(feed: [for (final f in feed) List<int>.of(f)]);
    t.answer = (frame) {
      final msg = PoolMessage.decode(frame);
      if (msg is PoolSubmission) return PoolReply.accepted(msg.id, acceptInto).encode();
      if (msg is PoolCatchUpRequest) {
        switch (msg.what) {
          case CatchUpKind.head:
            return headReply.encode();
          case CatchUpKind.frontier:
            return frontierReply.encode();
          case CatchUpKind.blockRoots:
            final roots = <List<int>>[];
            for (int r = msg.from; r <= 2 && r - msg.from < msg.count; r++) {
              roots.add(r == 1 ? br1 : br2);
            }
            return PoolCatchUpReply.blockRoots(from: msg.from, roots: roots).encode();
          case CatchUpKind.round:
            // this fixture serves no round by number. A pool that does not
            // serve a kind refuses it by name rather than going quiet, which
            // is what a wallet has to be able to tell apart.
            return PoolCatchUpReply.refused(msg.what, CatchUpRefusal.notServed,
                    'this fixture pool does not serve a round by number',
                    id: msg.id)
                .encode();
        }
      }
      throw StateError('the fixture pool was asked ${msg.kind.name}');
    };
    return t;
  }

  Future<CoordinatorClient> clientOn(Transport t, {Duration? timeout, int? attempts}) async {
    final (client, why) = await CoordinatorClient.open(t,
        timeout: timeout ?? const Duration(milliseconds: 500),
        sendAttempts: attempts ?? CoordinatorClient.defaultAttempts);
    expect(why, isNull, reason: '$why');
    return client!;
  }

  /// A view that has folded round 1 and is keeping the wallet's note.
  PoolView viewAtRound1() {
    final v = PoolView.atGenesis(shape);
    expect(v.fold(1, br1, cmRoot: cm1), isNull);
    expect(v.track(round: 1, position: note1.position, leaf: BlockFold.lanesToBytes(note1.cm), path: path1).$2,
        isNull);
    return v;
  }

  setUpAll(() async {
    c = await PoolTestChain.build();
    pool = PoolDescriptor.forPool(
        network: NetworkType.TEST, issuance: c.r0, witness0: c.w0, slot0: c.y0.tx, plan: c.f.agg);
    final (s, whyShape) = PoolShape.forPool(pool);
    expect(whyShape, isNull);
    shape = s!;

    final layout = ShieldedPoolLayout.forArities([2, 2], nullifierLevel: 1, receiptSlots: 2);
    final ledger =
        ShieldedLedger.open(layout, c.r0, c.w0, c.y0.tx, tokenId: c.tokenId, genesisHeader: c.genesisHeader);

    wallet = c.f.wallet;
    changeAddr = await NoteAddress.at(wallet.ivk, 1);

    round1 = ledger.apply(c.r1, c.w1, c.y1.tx);
    br1 = List<int>.of(round1.blockRoot);
    cm1 = List<int>.of(ledger.header.cmRoot);
    final scanner = ShieldedNoteScanner.forWallet(wallet, [c.f.walletD]);
    note1 = (await scanner.scan(round1)).single;
    path1 = [for (final x in ledger.tree.path(note1.position).siblings) List<int>.of(x)];

    round2 = ledger.apply(c.r2, c.w2, c.y2.tx);
    br2 = List<int>.of(round2.blockRoot);
    cm2 = List<int>.of(ledger.header.cmRoot);
    tipFrontier = ledger.frontier();

    ann1 = PoolAnnouncement.of(1, round1.header, c.r1, c.w1, c.y1.tx, blockRoot: br1);
    ann2 = PoolAnnouncement.of(2, round2.header, c.r2, c.w2, c.y2.tx, blockRoot: br2);
    feed = [pool.encode(), ann1.encode(), ann2.encode()];

    // the wallet's chain: the round-2 witness in a block, buried
    headers = FakeHeaderSource.holding([
      crypto.sha256.convert([0]).bytes,
      hex.decode(c.w2.id),
    ], before: 3, after: 6);
    block2 = headers.blockOf(hex.decode(c.w2.id))!;
    round2Bytes = hex.decode(c.r2.serialize());
    witness2Bytes = hex.decode(c.w2.serialize());
    checker = PaymentChecker(pool: pool, headers: HeaderChecker(headers, confirmations: 6));

    headReply = PoolCatchUpReply.head(
        round: 2,
        roundTx: round2Bytes,
        witnessTx: witness2Bytes,
        blockHash: block2.hash,
        txIndex: 1,
        branch: block2.branchFor(1).$2);
    frontierReply = PoolCatchUpReply.frontier(
        round: tipFrontier.round, blockRoot: tipFrontier.blockRoot, left: tipFrontier.left);

    now = DateTime.utc(2026, 9, 23, 12);
    invoice = await Invoice.issue(
        tokenId: pool.tokenId,
        ivk: wallet.ivk,
        address: await NoteAddress.at(wallet.ivk, 7),
        amount: 120,
        expiry: now.add(const Duration(days: 1)));
  });

  // ---- what the fixture actually says ----

  test('An announcement\'s two claims about a round are checkable against each other', () {
    // the client refuses an announcement whose block root does not fold to
    // the commitment root its own header carries, and that check is only
    // sound if an honest announcement passes it. Measured on the fixture
    // rather than assumed.
    expect(round1.header.cmRoot, cm1);
    expect(round2.header.cmRoot, cm2);
    expect(round1.number, 1);
    expect(round2.number, 2);
    expect(shape.leavesPerRound, 32);
    expect(pool.catchUpRange, 1024);
  });

  // ---- the descriptor comes first ----

  test('Descriptor first', () async {
    final t = honest();
    final client = await clientOn(t);
    expect(client.pool, pool);
    expect(client.shape.leavesPerRound, pool.leavesPerRound);
    expect(client.nextSequence, 1);
    // reading the descriptor sends nothing
    expect(t.sent, isEmpty);
    expect(t.reads, ['readFeed 0 1']);
  });

  test('A feed that does not start with a descriptor', () async {
    final t = FakeTransport(feed: [ann1.encode(), pool.encode()]);
    final (client, why) = await CoordinatorClient.open(t);
    expect(client, isNull);
    expect(why!.step, 'descriptor');
    expect(why.reason, contains('announcement'));
    expect(t.sent, isEmpty, reason: 'a client with no descriptor submits nothing');
  });

  test('A feed with nothing in it', () async {
    final (client, why) = await CoordinatorClient.open(FakeTransport());
    expect(client, isNull);
    expect(why!.step, 'descriptor');
    expect(why.reason, contains('empty'));
  });

  test('A feed whose first entry is not a message at all', () async {
    final t = FakeTransport(feed: [List<int>.filled(40, 0xab)]);
    final (client, why) = await CoordinatorClient.open(t);
    expect(client, isNull);
    expect(why!.step, 'version');
  });

  // ---- submissions and replies ----

  PoolSubmission fakeSubmission(int seed) =>
      PoolSubmission(List<int>.filled(16, seed), List<int>.filled(64, seed + 1));

  test('A reply matched by id', () async {
    final t = honest();
    final client = await clientOn(t);
    t.hold = true;

    final a = fakeSubmission(1), b = fakeSubmission(2);
    final fa = client.send(a);
    final fb = client.send(b);
    await pumpEventQueue();
    expect(t.held.length, 2, reason: 'both are in flight');
    expect(client.inFlight, 2);

    // the transport hands each call the *other* submission's reply, which is
    // what "their replies arrive out of order" means at this layer
    final replyA = PoolReply.accepted(a.id, 11).encode();
    final replyB = PoolReply.accepted(b.id, 12).encode();
    t.held[0].$2.complete(replyB);
    t.held[1].$2.complete(replyA);

    final oa = await fa, ob = await fb;
    expect(oa.outcome, Submitted.accepted);
    expect(oa.round, 11, reason: 'the call for a got a\'s reply, not the bytes it was handed');
    expect(ob.outcome, Submitted.accepted);
    expect(ob.round, 12);
    expect(client.inFlight, 0);
  });

  test('A reply for an unknown id', () async {
    final t = honest();
    final client = await clientOn(t);
    final sub = fakeSubmission(3);
    t.answer = (_) => PoolReply.accepted(List<int>.filled(16, 0x99), 4).encode();

    final outcome = await client.send(sub);
    expect(outcome.outcome, Submitted.unanswered);
    expect(outcome.refusal!.step, 'id');
    expect(outcome.refusal!.reason, contains(shortHex(List<int>.filled(16, 0x99))));
    expect(t.attempts, 1, reason: 'the same answer would come back, so it is not asked for again');
    expect(client.inFlight, 0);
  });

  test('No reply', () async {
    final t = honest();
    final client = await clientOn(t, timeout: const Duration(milliseconds: 120));
    t.hold = true;
    final outcome = await client.send(fakeSubmission(4));
    expect(outcome.outcome, Submitted.unanswered);
    expect(outcome.refusal!.step, 'reply');
    expect(outcome.refusal!.reason, contains('not a refusal'));
    expect(outcome.isSettled, isFalse, reason: 'it may still be in a round');
  });

  test('A pool that answers a submission with something else', () async {
    final t = honest();
    final client = await clientOn(t);
    t.answer = (_) => ann1.encode();
    final outcome = await client.send(fakeSubmission(5));
    expect(outcome.outcome, Submitted.unanswered);
    expect(outcome.refusal!.step, 'reply');
    expect(outcome.refusal!.reason, contains('announcement'));
  });

  // ---- announcements ----

  test('Announcements in order', () async {
    final t = honest();
    final client = await clientOn(t);
    final view = PoolView.atGenesis(shape);

    final p = await client.follow(view);
    expect(p.ok, isTrue, reason: '${p.stopped}');
    expect(p.entries, 2);
    expect(p.folded, 2);
    expect(view.round, 2);
    expect(view.cmRoot, cm2);
    expect(view.checkedTo, 0,
        reason: 'an announcement is a claim; only a round proved off the chain makes a fold evidence');
    expect(client.nextSequence, 3);

    // reading again folds nothing and refuses nothing
    final again = await client.follow(view);
    expect(again.ok, isTrue);
    expect(again.entries, 0);
  });

  test('A round out of order', () async {
    final skipped = PoolAnnouncement(
        round: 4,
        header: round2.header,
        roundTxId: hex.decode(c.r2.id),
        witnessTxId: hex.decode(c.w2.id),
        slotTxId: hex.decode(c.y2.tx.id),
        blockRoot: br2);
    final t = FakeTransport(feed: [pool.encode(), ann1.encode(), ann2.encode(), skipped.encode()]);
    final client = await clientOn(t);
    final view = PoolView.atGenesis(shape);

    final p = await client.follow(view);
    expect(p.ok, isFalse);
    expect(p.stopped!.step, 'round');
    expect(p.stopped!.reason, contains('round 3'));
    expect(p.stopped!.reason, contains('round 4'));
    expect(p.folded, 2);
    expect(view.round, 2, reason: 'nothing was folded');
    expect(view.cmRoot, cm2);
  });

  test('A disagreeing announcement', () async {
    final other = PoolHeader(
        cmRoot: round2.header.cmRoot,
        nfRoot: round2.header.nfRoot,
        ring: round2.header.ring,
        size: round2.header.size,
        balance: round2.header.balance + BigInt.one,
        outHash: round2.header.outHash);
    final restated = PoolAnnouncement.of(2, other, c.r2, c.w2, c.y2.tx, blockRoot: br2);
    final t = FakeTransport(feed: [pool.encode(), ann1.encode(), ann2.encode(), restated.encode()]);
    final client = await clientOn(t);
    final view = PoolView.atGenesis(shape);

    final p = await client.follow(view);
    expect(p.ok, isFalse);
    expect(p.disagreement, isNotNull);
    expect(p.disagreement!.round, 2);
    expect(p.disagreement!.what, contains('two different pool headers'));
    expect(p.folded, 2);
    expect(view.round, 2, reason: 'the view is unchanged by the second story');
    expect(view.cmRoot, cm2);
  });

  test('An announcement that contradicts itself', () async {
    // the block root and the pool header in one announcement are two claims
    // by the same party; a block root that does not fold to the root its own
    // header carries is caught before anything is folded
    final bent = List<int>.of(br1)..[3] ^= 0x40;
    final twisted = PoolAnnouncement.of(1, round1.header, c.r1, c.w1, c.y1.tx, blockRoot: bent);
    final t = FakeTransport(feed: [pool.encode(), twisted.encode()]);
    final client = await clientOn(t);
    final view = PoolView.atGenesis(shape);

    final p = await client.follow(view);
    expect(p.ok, isFalse);
    expect(p.disagreement!.round, 1);
    expect(p.disagreement!.what, contains('contradicted itself'));
    expect(p.folded, 0);
    expect(view.round, 0, reason: 'nothing was folded');
  });

  test('A feed that re-publishes a different descriptor', () async {
    final other = PoolDescriptor.forPool(
        network: NetworkType.TEST,
        issuance: c.r0,
        witness0: c.w0,
        slot0: c.y0.tx,
        plan: c.f.agg,
        catchUpRange: 512);
    final t = FakeTransport(feed: [pool.encode(), ann1.encode(), other.encode()]);
    final client = await clientOn(t);
    final view = PoolView.atGenesis(shape);
    final p = await client.follow(view);
    expect(p.ok, isFalse);
    expect(p.stopped!.step, 'descriptor');
    expect(p.folded, 1);
  });

  test('A feed read out of order is refused before it leaves a gap', () async {
    // the descriptor read is honest, so the client opens; every read after it
    // comes back numbered one higher than it was asked for
    final client = await clientOn(_ShiftedFeed(honest(), 1));
    final view = PoolView.atGenesis(shape);
    final p = await client.follow(view);
    expect(p.ok, isFalse);
    expect(p.stopped!.step, 'sequence');
    expect(view.round, 0);
  });

  // ---- catching up ----

  test('A wallet with no state becomes current', () async {
    final t = honest();
    final client = await clientOn(t);
    final (view, why) = await client.current(checker);
    expect(why, isNull, reason: '$why');
    expect(view!.round, 2);
    expect(view.checkedTo, 2, reason: 'the frontier was accepted because it computes a proven round\'s root');
    expect(view.cmRoot, cm2);
    expect(view.size, 64);
    expect(t.attempts, 2, reason: 'one head proof and one frontier, and nothing else');
  });

  test('A wallet that fell behind', () async {
    final t = honest();
    final client = await clientOn(t);
    final view = viewAtRound1();
    final note = view.trackedAt(note1.position)!;

    final why = await client.bringForward(view, checker);
    expect(why, isNull, reason: '$why');
    expect(view.round, 2);
    expect(view.checkedTo, 2);
    expect(view.cmRoot, cm2);

    final (path, whyPath) = view.spendPath(note, tip: 2);
    expect(whyPath, isNull, reason: '$whyPath');
    expect(path!.position, note1.position);
    expect(BlockFold.lanesToBytes(PoolHash.root(note1.cm, path.siblings, path.position)), cm2,
        reason: 'the note\'s path is current');
  });

  test('A wallet already at the tip only checks', () async {
    final t = honest();
    final client = await clientOn(t);
    final view = PoolView.atGenesis(shape);
    expect(view.fold(1, br1), isNull);
    expect(view.fold(2, br2), isNull);
    expect(view.checkedTo, 0);
    expect(await client.bringForward(view, checker), isNull);
    expect(view.checkedTo, 2);
    expect(t.attempts, 1, reason: 'a head proof and no block roots');
  });

  group('The pool lies', () {
    test('about its frontier', () async {
      final t = honest();
      final client = await clientOn(t);
      final bent = List<int>.of(tipFrontier.blockRoot)..[0] ^= 0x11;
      frontierReply =
          PoolCatchUpReply.frontier(round: tipFrontier.round, blockRoot: bent, left: tipFrontier.left);
      final (view, why) = await client.current(checker);
      frontierReply = PoolCatchUpReply.frontier(
          round: tipFrontier.round, blockRoot: tipFrontier.blockRoot, left: tipFrontier.left);
      expect(view, isNull);
      expect(why!.step, 'checkpoint');
      expect(why.reason, contains('some other tree'));
      expect(t.attempts, 2, reason: 'a refused answer is not asked for again');
    });

    test('about a block root', () async {
      final t = honest();
      final client = await clientOn(t);
      t.answer = (frame) {
        final msg = PoolMessage.decode(frame);
        if (msg is PoolCatchUpRequest && msg.what == CatchUpKind.head) return headReply.encode();
        if (msg is PoolCatchUpRequest && msg.what == CatchUpKind.blockRoots) {
          return PoolCatchUpReply.blockRoots(
              from: msg.from, roots: [br1, List<int>.of(br2)..[0] ^= 0x01]).encode();
        }
        throw StateError('unexpected');
      };
      final view = viewAtRound1();
      final why = await client.bringForward(view, checker);
      expect(why, isNotNull);
      expect(why!.step, 'cmRoot');
      expect(why.reason, contains('round 1'), reason: 'it names the rounds folded since the last check');
      expect(view.checkedTo, 1, reason: 'the state it had is kept');
      expect(t.attempts, 2);
    });

    test('about its head, with a round the witness does not spend', () async {
      final t = honest();
      final client = await clientOn(t);
      final saved = headReply;
      headReply = PoolCatchUpReply.head(
          round: 2,
          roundTx: hex.decode(c.r1.serialize()),
          witnessTx: witness2Bytes,
          blockHash: block2.hash,
          txIndex: 1,
          branch: block2.branchFor(1).$2);
      final (head, why) = await client.headProof(checker);
      headReply = saved;
      expect(head, isNull);
      expect(why, isNotNull);
      expect(t.attempts, 1);
    });

    test('about its head, with a block this wallet does not have', () async {
      final t = honest();
      final client = await clientOn(t);
      final saved = headReply;
      headReply = PoolCatchUpReply.head(
          round: 2,
          roundTx: round2Bytes,
          witnessTx: witness2Bytes,
          blockHash: List<int>.filled(32, 0x5a),
          txIndex: 1,
          branch: block2.branchFor(1).$2);
      final (head, why) = await client.headProof(checker);
      headReply = saved;
      expect(head, isNull);
      expect(why!.step, 'block');
    });

    test('about which round its head is', () async {
      final t = honest();
      final client = await clientOn(t);
      final saved = headReply;
      headReply = PoolCatchUpReply.head(
          round: 900,
          roundTx: round2Bytes,
          witnessTx: witness2Bytes,
          blockHash: block2.hash,
          txIndex: 1,
          branch: block2.branchFor(1).$2);
      final (head, why) = await client.headProof(checker);
      headReply = saved;
      expect(head, isNull);
      expect(why!.step, 'head');
      expect(why.reason, contains('900'));
      expect(why.reason, contains('round 2'));
    });

    test('about its frontier\'s round', () async {
      final t = honest();
      final client = await clientOn(t);
      final saved = frontierReply;
      frontierReply = PoolCatchUpReply.frontier(round: 1, blockRoot: br1, left: const []);
      final (view, why) = await client.current(checker);
      frontierReply = saved;
      expect(view, isNull);
      expect(why!.step, 'frontier');
      expect(why.reason, contains('round 1'));
      expect(why.reason, contains('round 2'));
    });

    test('and answers a frontier request with block roots', () async {
      final t = honest();
      final client = await clientOn(t);
      t.answer = (_) => PoolCatchUpReply.blockRoots(from: 1, roots: [br1]).encode();
      final (cp, why) = await client.frontier();
      expect(cp, isNull);
      expect(why!.step, 'catch-up');
      expect(t.attempts, 1);
    });
  });

  // ---- a catch-up request says nothing about the wallet ----

  test('Requests come from the published set', () async {
    final t = honest();
    final client = await clientOn(t);
    final view = viewAtRound1();
    expect(await client.bringForward(view, checker), isNull);
    final (_, why) = await client.current(checker);
    expect(why, isNull);

    var ranges = 0;
    for (final frame in t.sent) {
      final msg = PoolMessage.decode(frame);
      expect(msg, isA<PoolCatchUpRequest>());
      final r = msg as PoolCatchUpRequest;
      if (r.what != CatchUpKind.blockRoots) {
        expect(r.from, 0);
        expect(r.count, 0);
        continue;
      }
      ranges++;
      expect(pool.publishesRange(r.from, r.count), isTrue,
          reason: 'rounds ${r.from} to ${r.from + r.count - 1} are not a run this pool publishes');
    }
    expect(ranges, greaterThan(0));
  });

  test('A range is the published run the wanted round falls in, not the wanted round', () async {
    final small = PoolDescriptor.forPool(
        network: NetworkType.TEST,
        issuance: c.r0,
        witness0: c.w0,
        slot0: c.y0.tx,
        plan: c.f.agg,
        catchUpRange: 2);
    final t = FakeTransport(feed: [small.encode()]);
    t.answer = (frame) {
      final r = PoolMessage.decode(frame) as PoolCatchUpRequest;
      return PoolCatchUpReply.blockRoots(from: r.from, roots: [br1, br2]).encode();
    };
    final client = await clientOn(t);
    for (int want = 1; want <= 8; want++) {
      final (run, why) = await client.blockRootsFor(want);
      expect(why, isNull, reason: '$why');
      expect(run!.from, [1, 1, 3, 3, 5, 5, 7, 7][want - 1],
          reason: 'round $want falls in the published run from ${run.from}');
      expect(small.publishesRange(run.from, 2), isTrue);
    }
    for (final frame in t.sent) {
      final r = PoolMessage.decode(frame) as PoolCatchUpRequest;
      expect(r.from.isOdd, isTrue, reason: 'every run this pool publishes starts on an odd round');
    }
  });

  test('Nothing wallet-derived is sent', () async {
    final t = honest();
    final client = await clientOn(t);
    final view = viewAtRound1();
    expect(await client.bringForward(view, checker), isNull);
    final (fresh, why) = await client.current(checker);
    expect(why, isNull);
    expect(fresh, isNotNull);

    // the things a wallet must never put on the wire
    final secrets = <String, List<int>>{
      'the note\'s commitment': BlockFold.lanesToBytes(note1.cm),
      'the wallet\'s diversifier': c.f.walletD,
      'the change address\'s pk_d': changeAddr.pkd,
      'a round transaction\'s txid': hex.decode(c.r2.id),
      'the witness\'s txid': hex.decode(c.w2.id),
    };
    for (final frame in t.sent) {
      for (final e in secrets.entries) {
        expect(_holds(frame, e.value), isFalse, reason: 'a request carried ${e.key}');
      }
      // no leaf position, and no round the wallet chose: a request is a kind
      // and, for block roots, a published run
      final r = PoolMessage.decode(frame) as PoolCatchUpRequest;
      expect(r.from == 0 || pool.publishesRange(r.from, r.count), isTrue);
    }
  });

  // ---- privacy over a whole payment ----

  test('What is sent', () async {
    final t = honest();
    final client = await clientOn(t);
    final view = viewAtRound1();
    final store = NoteStore(shape);
    final (held, whyTake) =
        store.takeChange(opening: NoteOpening.of(note1.note), position: note1.position, round: note1.round);
    expect(whyTake, isNull);

    final (payment, whyBuild) = await PaymentBuilder.build(
        invoice: invoice,
        keys: wallet,
        changeAddress: changeAddr,
        note: held!,
        notes: store,
        view: view,
        spendP: c.f.agg.spendP,
        tokenId: pool.tokenId,
        tip: 1,
        now: now,
        rng: Random(7));
    expect(whyBuild, isNull, reason: '$whyBuild');

    final outcome = await client.submit(payment!, notes: store, rng: Random(8));
    expect(outcome.outcome, Submitted.accepted);

    final p = await client.follow(view);
    expect(p.ok, isTrue, reason: '${p.stopped}');

    // everything sent is a submission, and nothing else was asked
    expect(t.sent.length, 1);
    expect(PoolMessage.decode(t.sent.single), isA<PoolSubmission>());
    // and everything read is the feed every follower reads
    expect(t.reads.every((r) => r.startsWith('readFeed ')), isTrue);
    // the header source was never asked anything about the wallet either
    expect(headers.calls.every((call) => !call.startsWith('heightOfBlock') || call.length > 'heightOfBlock '.length),
        isTrue);
  });

  // ---- payments: the twelve refusals and acceptance ----

  group('Submitting a payment', () {
    late NoteStore store;
    late BuiltPayment payment;

    setUp(() async {
      store = NoteStore(shape);
      final (held, why) =
          store.takeChange(opening: NoteOpening.of(note1.note), position: note1.position, round: note1.round);
      expect(why, isNull);
      final view = viewAtRound1();
      final (built, whyBuild) = await PaymentBuilder.build(
          invoice: invoice,
          keys: wallet,
          changeAddress: changeAddr,
          note: held!,
          notes: store,
          view: view,
          spendP: c.f.agg.spendP,
          tokenId: pool.tokenId,
          tip: 1,
          now: now,
          rng: Random(11));
      expect(whyBuild, isNull, reason: '$whyBuild');
      payment = built!;
    });

    test('Each of the twelve refusals', () async {
      final t = honest();
      final client = await clientOn(t);
      expect(RefusalReason.values.length, 12);
      for (final reason in RefusalReason.values) {
        t.answer = (frame) {
          final sub = PoolMessage.decode(frame) as PoolSubmission;
          return PoolReply.refused(sub.id, reason, 'the coordinator said ${reason.name}').encode();
        };
        final outcome = await client.submit(payment, notes: store, rng: Random(reason.number));
        expect(outcome.outcome, Submitted.refused, reason: reason.name);
        expect(outcome.reason, reason);
        expect(outcome.refusal!.step, reason.name,
            reason: 'a journal records the protocol\'s own name, not a sentence of ours');
        expect(outcome.refusal!.reason, contains(reason.name));
        expect(payment.spent.state, NoteState.proven,
            reason: 'the payment is unpaid and the note is neither spent nor held');
        expect(store.balanceOf(payment.spent.asset, view: viewAtRound1(), tip: 1).spendable, 500);
      }
    });

    test('Accepted and awaiting', () async {
      final t = honest(acceptInto: 4);
      final client = await clientOn(t);
      final outcome = await client.submit(payment, notes: store, rng: Random(12));
      expect(outcome.outcome, Submitted.accepted);
      expect(outcome.round, 4);
      expect(outcome.isSettled, isFalse, reason: 'it is awaiting its round');
      expect(payment.spent.state, NoteState.reserved);

      // a second payment cannot spend it
      final again = await client.submit(payment, notes: store, rng: Random(13));
      expect(again.outcome, Submitted.unsent);
      expect(t.sent.length, 1, reason: 'the second one never left the machine');
    });

    test('Expired', () async {
      final t = honest();
      final client = await clientOn(t);
      t.answer = (frame) {
        final sub = PoolMessage.decode(frame) as PoolSubmission;
        return PoolReply.expired(sub.id, 'it sat here too long').encode();
      };
      final outcome = await client.submit(payment, notes: store, rng: Random(14));
      expect(outcome.outcome, Submitted.expired);
      expect(outcome.refusal!.step, 'expired');
      expect(payment.spent.state, NoteState.proven);
    });

    test('The transport is down', () async {
      final t = honest();
      final client = await clientOn(t, attempts: 3);
      t.fail = 'connection refused';
      final outcome = await client.submit(payment, notes: store, rng: Random(15));
      expect(outcome.outcome, Submitted.unsent);
      expect(outcome.refusal!.step, 'transport');
      expect(outcome.refusal!.reason, contains('connection refused'));
      expect(outcome.refusal!.reason, contains('3 of 3'));
      expect(t.attempts, 3, reason: 'three attempts, then it is an error');
      expect(payment.spent.state, NoteState.proven, reason: 'the note is released');
    });

    test('A send that fails and then succeeds', () async {
      final t = honest(acceptInto: 9);
      final client = await clientOn(t, attempts: 3);
      t.failFirst = 2;
      final outcome = await client.submit(payment, notes: store, rng: Random(16));
      expect(outcome.outcome, Submitted.accepted);
      expect(outcome.round, 9);
      expect(t.attempts, 3);
      final ids = {for (final frame in t.sent) hex.encode((PoolMessage.decode(frame) as PoolSubmission).id)};
      expect(ids.length, 1,
          reason: 'a resend is the same submission, so a coordinator that took the first copy knows it');
      expect(payment.spent.state, NoteState.reserved);
    });

    test('A timeout leaves the note reserved', () async {
      final t = honest();
      final client = await clientOn(t, timeout: const Duration(milliseconds: 120));
      t.hold = true;
      final outcome = await client.submit(payment, notes: store, rng: Random(17));
      expect(outcome.outcome, Submitted.unanswered);
      expect(payment.spent.state, NoteState.reserved,
          reason: 'it may be in a round, and releasing a note on a maybe is how a wallet double-spends itself');
    });
  });

  // ---- untrusted input ----

  test('Random frames', () async {
    final rng = Random(2026);
    final real = [pool.encode(), ann1.encode(), ann2.encode(), PoolReply.accepted(List<int>.filled(16, 1), 1).encode(), headReply.encode(), frontierReply.encode()];

    var refused = 0, accepted = 0, folded = 0;
    final steps = <String>{};
    for (int i = 0; i < 10000; i++) {
      final List<int> frame;
      if (i.isEven) {
        // random
        final n = rng.nextInt(600);
        frame = [for (int j = 0; j < n; j++) rng.nextInt(256)];
      } else {
        // a real frame with bytes bent in it
        final base = List<int>.of(real[rng.nextInt(real.length)]);
        final bends = 1 + rng.nextInt(3);
        for (int b = 0; b < bends; b++) {
          base[rng.nextInt(base.length)] ^= 1 << rng.nextInt(8);
        }
        frame = base;
      }
      final t = FakeTransport(feed: [pool.encode(), frame]);
      final (client, why) = await CoordinatorClient.open(t);
      expect(why, isNull);
      final view = PoolView.atGenesis(shape);
      final p = await client!.follow(view);
      if (p.ok) {
        // A bent frame that is still a well-formed round-1 announcement is a
        // pass, not a hole. The fields a bend can land in and leave it
        // foldable are the ones this client never acts on — the three txids,
        // the nullifier root, the balance, the out hash — and the two it does
        // act on have to agree with each other before anything moves. So the
        // claim is not "nothing got through", it is **nothing got folded
        // that was not round 1's own block root**, which is asserted here.
        accepted++;
        expect(p.folded, lessThanOrEqualTo(1));
        if (p.folded == 1) {
          folded++;
          expect(view.round, 1);
          expect(view.cmRoot, cm1);
        }
      } else {
        refused++;
        expect(p.stopped!.step, isNotEmpty);
        expect(p.stopped!.reason, isNotEmpty);
        steps.add(p.stopped!.step);
      }
    }
    expect(refused + accepted, 10000);
    print('random frames: $refused refused, $accepted taken, $folded folded, '
        'steps ${(steps.toList()..sort()).join(', ')}');

    // and the client is still usable afterwards
    final t = honest();
    final client = await clientOn(t);
    final view = PoolView.atGenesis(shape);
    final p = await client.follow(view);
    expect(p.ok, isTrue);
    expect(view.round, 2);
  });

  test('Random frames as replies', () async {
    final rng = Random(7);
    final sub = fakeSubmission(9);
    final real = PoolReply.accepted(sub.id, 3).encode();
    var unnamed = 0;
    final t = honest();
    final client = await clientOn(t);
    for (int i = 0; i < 2000; i++) {
      final List<int> frame;
      if (i.isEven) {
        final n = rng.nextInt(200);
        frame = [for (int j = 0; j < n; j++) rng.nextInt(256)];
      } else {
        frame = List<int>.of(real)..[rng.nextInt(real.length)] ^= 1 << rng.nextInt(8);
      }
      t.answer = (_) => frame;
      final outcome = await client.send(sub);
      if (outcome.outcome == Submitted.accepted) continue;
      if (outcome.refusal == null || outcome.refusal!.step.isEmpty) unnamed++;
    }
    expect(unnamed, 0);
    expect(client.inFlight, 0);
  });

  test('A frame past the protocol\'s own bound is refused before it is read', () async {
    final t = FakeTransport(feed: [pool.encode(), List<int>.filled(PoolMessage.maxOther + 1, 2)]);
    final client = await clientOn(t);
    final p = await client.follow(PoolView.atGenesis(shape));
    expect(p.ok, isFalse);
    expect(p.stopped!.step, 'size');
  });

  // ---- what following costs ----

  test('Following the feed is cheap', () async {
    final t = honest();
    final client = await clientOn(t);
    final view = PoolView.atGenesis(shape);
    final w = Stopwatch()..start();
    final p = await client.follow(view);
    w.stop();
    expect(p.folded, 2);
    print('follow: ${w.elapsedMicroseconds} us for 2 rounds, '
        '${(w.elapsedMicroseconds / 2).toStringAsFixed(0)} us a round');
    expect(w.elapsedMilliseconds, lessThan(100));
  });
}

/// Whether [frame] holds [needle] anywhere in it.
bool _holds(List<int> frame, List<int> needle) {
  if (needle.isEmpty || needle.length > frame.length) return false;
  outer:
  for (int i = 0; i + needle.length <= frame.length; i++) {
    for (int j = 0; j < needle.length; j++) {
      if (frame[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// A transport whose feed comes back numbered one higher than it was asked
/// for, once the descriptor is past.
class _ShiftedFeed implements Transport {
  final FakeTransport inner;
  final int shift;
  _ShiftedFeed(this.inner, this.shift);

  @override
  Future<List<int>> request(List<int> frame, {Duration timeout = const Duration(seconds: 30)}) =>
      inner.request(frame, timeout: timeout);

  @override
  Future<List<FeedEntry>> readFeed(int from, {int max = 100}) async {
    final got = await inner.readFeed(from, max: max);
    if (from == 0) return got;
    return [for (final e in got) FeedEntry(e.sequence + shift, e.bytes)];
  }
}
