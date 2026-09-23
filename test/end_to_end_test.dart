import 'dart:io';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dartsv/dartsv.dart' show NetworkType;
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/testing.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'fakes.dart';

/// One payment, from an invoice to an acknowledgement, through every piece of
/// the library in the order a person would use them.
///
/// The other suites each hold one part still and prod it. This one holds
/// nothing still: the invoice is encoded and decoded, the payer catches up
/// from a head proof it checked itself, chooses a note, builds a real spend
/// proof, submits it and is answered; the round is mined and folded; the proof
/// is encoded, handed over and decoded; the payee checks it against block
/// headers its own source vouches for, takes the note, acknowledges; and the
/// payer checks the acknowledgement against the invoice it kept. Both sides
/// write journals and both read as one thread.
///
/// **One seam, and it is named rather than papered over.** The round that gets
/// mined here is the fixture's round 2, and the transfer libcloak built is not
/// in it, because assembling a round means proving an aggregation and that is
/// the coordinator's job, not a wallet's. So the proof handed to the payee is
/// of the note round 2 really holds at the invoice's address, for the
/// invoice's amount. Task 11.2 is where the payer's own transfer goes into a
/// real coordinator's round and the proof comes out of that.
void main() {
  late PoolTestChain c;
  late PoolDescriptor pool;
  late PoolShape shape;
  late ShieldedLedger ledger;
  late ShieldedRound round1, round2;
  late List<int> br1, br2, cm1, cm2;
  late PoolAnnouncement ann1, ann2;

  // the pool's two wallets. At test parameters they are the same keys: the
  // fixture mints one wallet's notes and only that wallet has anything to
  // spend, so the payer and the payee are one person paying themselves for a
  // crate of oranges. Every check still runs against the other side's bytes.
  late PoolWalletKeys keys;
  late NoteAddress payeeAddr, changeAddr;
  late ScannedNote note1, note32;
  late List<List<int>> path1, path32;

  late FakeHeaderSource headers;
  late FakeBlock block2;
  late List<int> round2Bytes, witness2Bytes;
  late PoolCatchUpReply headReply, frontierReply;
  late DateTime now, expiry;
  late Directory root;

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('libcloak_e2e');
    c = await PoolTestChain.build();
    pool = PoolDescriptor.forPool(
        network: NetworkType.TEST, issuance: c.r0, witness0: c.w0, slot0: c.y0.tx, plan: c.f.agg);
    shape = PoolShape.forPool(pool).$1!;

    final layout = ShieldedPoolLayout.forArities([2, 2], nullifierLevel: 1, receiptSlots: 2);
    ledger = ShieldedLedger.open(layout, c.r0, c.w0, c.y0.tx, tokenId: c.tokenId, genesisHeader: c.genesisHeader);

    keys = c.f.wallet;
    payeeAddr = await NoteAddress.derive(keys.ivk, c.f.walletD);
    changeAddr = await NoteAddress.at(keys.ivk, 1);

    round1 = ledger.apply(c.r1, c.w1, c.y1.tx);
    br1 = List<int>.of(round1.blockRoot);
    cm1 = List<int>.of(ledger.header.cmRoot);
    final scanner = ShieldedNoteScanner.forWallet(keys, [c.f.walletD]);
    note1 = (await scanner.scan(round1)).single;
    path1 = [for (final x in ledger.tree.path(note1.position).siblings) List<int>.of(x)];

    round2 = ledger.apply(c.r2, c.w2, c.y2.tx);
    br2 = List<int>.of(round2.blockRoot);
    cm2 = List<int>.of(ledger.header.cmRoot);
    note32 = (await scanner.scan(round2)).single;
    path32 = [for (final x in ledger.tree.path(note32.position).siblings) List<int>.of(x)];

    ann1 = PoolAnnouncement.of(1, round1.header, c.r1, c.w1, c.y1.tx, blockRoot: br1);
    ann2 = PoolAnnouncement.of(2, round2.header, c.r2, c.w2, c.y2.tx, blockRoot: br2);

    headers = FakeHeaderSource.holding([
      crypto.sha256.convert([0]).bytes,
      hex.decode(c.w2.id),
    ], before: 3, after: 6);
    block2 = headers.blockOf(hex.decode(c.w2.id))!;
    round2Bytes = hex.decode(c.r2.serialize());
    witness2Bytes = hex.decode(c.w2.serialize());

    final f = ledger.frontier();
    frontierReply = PoolCatchUpReply.frontier(round: f.round, blockRoot: f.blockRoot, left: f.left);
    headReply = PoolCatchUpReply.head(
        round: 2,
        roundTx: round2Bytes,
        witnessTx: witness2Bytes,
        blockHash: block2.hash,
        txIndex: 1,
        branch: block2.branchFor(1).$2);

    now = DateTime.utc(2026, 9, 23, 12);
    expiry = now.add(const Duration(days: 1));
  });

  tearDownAll(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// The pool's side: a feed that grows a round at a time, and a coordinator
  /// that answers submissions and the three catch-up questions.
  FakeTransport poolAt(int rounds, {int acceptInto = 3}) {
    final t = FakeTransport(feed: [
      pool.encode(),
      if (rounds >= 1) ann1.encode(),
      if (rounds >= 2) ann2.encode(),
    ]);
    t.answer = (frame) {
      final msg = PoolMessage.decode(frame);
      if (msg is PoolSubmission) return PoolReply.accepted(msg.id, acceptInto).encode();
      if (msg is PoolCatchUpRequest) {
        return switch (msg.what) {
          CatchUpKind.head => headReply.encode(),
          CatchUpKind.frontier => frontierReply.encode(),
          CatchUpKind.blockRoots => PoolCatchUpReply.blockRoots(from: msg.from, roots: [
              for (int r = msg.from; r <= rounds && r - msg.from < msg.count; r++) r == 1 ? br1 : br2
            ]).encode(),
        };
      }
      throw StateError('the pool was asked ${msg.kind.name}');
    };
    return t;
  }

  Future<Journal> journalAt(String name) async {
    final (j, why) = await Journal.open('${root.path}${Platform.pathSeparator}$name');
    expect(why, isNull, reason: '$why');
    return j!;
  }

  test('A payment, end to end', () async {
    final payerJournal = await journalAt('payer');
    final payeeJournal = await journalAt('payee');
    final timings = <String, int>{};
    final whole = Stopwatch()..start();

    // ---- 1. the payee asks for money ----

    final issued = await Invoice.issue(
        tokenId: pool.tokenId,
        ivk: keys.ivk,
        address: payeeAddr,
        amount: 200,
        expiry: expiry,
        memo: 'a crate of oranges',
        rng: Random(41));
    await payeeJournal.add(JournalEntry.invoiceIssued(issued, at: now));
    final handedOver = issued.encode();

    // ---- 2. the payer reads it, checking it as bytes from a stranger ----

    final (invoice, whyInvoice) = await Invoice.read(handedOver, tokenId: pool.tokenId, now: now);
    expect(whyInvoice, isNull, reason: '$whyInvoice');
    expect(invoice!.amount, 200);
    expect(invoice.memo, 'a crate of oranges');
    await payerJournal.add(JournalEntry.invoiceReceived(invoice, at: now));

    // ---- 3. the payer joins the pool and becomes current ----

    final pool1 = poolAt(1);
    final (client, whyOpen) = await CoordinatorClient.open(pool1);
    expect(whyOpen, isNull, reason: '$whyOpen');
    final checker = PaymentChecker(pool: pool, headers: HeaderChecker(headers, confirmations: 6));

    // it has no state, so it takes the frontier and a head proof and checks
    // one against the other. Nothing here is believed; the head proof is a
    // mined witness against headers this wallet holds.
    final stale = List<int>.of(frontierReply.blockRoot!);
    frontierReply = PoolCatchUpReply.frontier(round: 1, blockRoot: br1, left: const []);
    final savedHead = headReply;
    headReply = PoolCatchUpReply.head(
        round: 1,
        roundTx: hex.decode(c.r1.serialize()),
        witnessTx: hex.decode(c.w1.serialize()),
        blockHash: block2.hash,
        txIndex: 1,
        branch: block2.branchFor(1).$2);
    // round 1's witness is not the one in this wallet's block, so the honest
    // answer here is a refusal, not a view: the payer instead folds the feed
    // from the genesis, which costs 32 bytes a round and names nobody
    final (byCheckpoint, whyCheckpoint) = await client!.current(checker);
    expect(byCheckpoint, isNull);
    expect(whyCheckpoint, isNotNull);
    headReply = savedHead;
    frontierReply = PoolCatchUpReply.frontier(round: 2, blockRoot: stale, left: ledger.frontier().left);

    final view = PoolView.atGenesis(shape);
    final store = NoteStore(shape);
    var progress = await client.follow(view);
    expect(progress.ok, isTrue, reason: '${progress.stopped}');
    expect(view.round, 1);

    // the note round 1 paid this wallet, delivered with its path rather than
    // found by scanning
    final (tracked, whyTrack) = view.track(
        round: 1, position: note1.position, leaf: BlockFold.lanesToBytes(note1.cm), path: path1);
    expect(whyTrack, isNull, reason: '$whyTrack');
    final (held, whyHold) =
        store.takeChange(opening: NoteOpening.of(note1.note), position: note1.position, round: note1.round);
    expect(whyHold, isNull, reason: '$whyHold');
    expect(tracked, isNotNull);
    expect(held!.value, 500);

    // and the fold becomes evidence, once
    expect(view.checkedTo, 0);
    expect(view.check(1, cm1), isNull);
    expect(view.checkedTo, 1);

    // ---- 4. the payer picks a note and builds ----

    final balance = store.balanceOf(held.asset, view: view, tip: 1);
    expect(balance.spendable, 500);
    final (choice, whyChoice) =
        store.choose(amount: invoice.amount, asset: held.asset, view: view, tip: 1);
    expect(whyChoice, isNull, reason: '$whyChoice');
    expect(choice!.note.position, note1.position);

    final build = Stopwatch()..start();
    final (payment, whyBuild) = await PaymentBuilder.build(
        invoice: invoice,
        keys: keys,
        changeAddress: changeAddr,
        note: choice.note,
        notes: store,
        view: view,
        spendP: c.f.agg.spendP,
        tokenId: pool.tokenId,
        tip: 1,
        now: now,
        rng: Random(42));
    build.stop();
    expect(whyBuild, isNull, reason: '$whyBuild');
    timings['build'] = build.elapsedMilliseconds;
    expect(payment!.paid.value, 200);
    expect(payment.change.value, 300);
    expect(payment.anchor, cm1);
    await payerJournal.add(JournalEntry.paymentBuilt(payment, at: now));

    // ---- 5. the payer submits, and is answered ----

    final send = Stopwatch()..start();
    final answer = await client.submit(payment, notes: store, rng: Random(43));
    send.stop();
    timings['submit'] = send.elapsedMilliseconds;
    expect(answer.outcome, Submitted.accepted);
    expect(choice.note.state, NoteState.reserved, reason: 'the note cannot be spent twice');
    await payerJournal.add(JournalEntry.paymentSubmitted(invoice, answer.id, at: now));
    await payerJournal.add(JournalEntry.paymentAnswered(invoice, answer, at: now));

    // ---- 6. the round is mined, announced and folded ----

    pool1.feed.add(ann2.encode());
    progress = await client.follow(view);
    expect(progress.ok, isTrue, reason: '${progress.stopped}');
    expect(progress.folded, 1);
    expect(view.round, 2);
    expect(view.cmRoot, cm2, reason: 'one 32-byte block root brought every path here');

    // and the payer checks the fold against a round it proves off the chain
    final (head, whyHead) = await client.headProof(checker);
    expect(whyHead, isNull, reason: '$whyHead');
    expect(head!.round, 2);
    expect(view.check(head.round, head.cmRoot), isNull);
    expect(view.checkedTo, 2);

    // the payer's own note is still current, and would still be spendable
    expect(view.canSpend(tracked!, tip: 2), isTrue);

    // ---- 7. the payer builds the proof and hands it over ----
    //
    // The note is the one round 2 holds at the invoice's address, for the
    // invoice's amount. See the seam named at the top of this file.

    final position = PaymentProofs.positionOf(round2, BlockFold.lanesToBytes(note32.cm));
    expect(position, note32.position, reason: 'the payer learns the leaf from the mined round, not from a server');

    final (proof, whyProof) = PaymentProofs.standing(
        note: NoteOpening.of(note32.note),
        round: 2,
        roundTx: round2Bytes,
        witnessTx: witness2Bytes,
        blockHash: block2.hash,
        txIndex: 1,
        branch: block2.branchFor(1).$2,
        position: position!,
        path: path32);
    expect(whyProof, isNull, reason: '$whyProof');
    await payerJournal.add(JournalEntry.proofBuilt(invoice, proof!, at: now));
    final delivered = proof.encode();
    timings['proof bytes'] = delivered.length;

    // ---- 8. the payee checks it against its own headers ----

    final decoded = PaymentProof.decode(delivered);
    final check = Stopwatch()..start();
    final (checked, whyCheck) = await checker.check(decoded, pkd: payeeAddr.pkd);
    check.stop();
    timings['check'] = check.elapsedMilliseconds;
    expect(whyCheck, isNull, reason: '$whyCheck');
    expect(checked!.value, 200);
    expect(checked.round, 2);
    expect(checked.confirmations, greaterThanOrEqualTo(6));
    await payeeJournal.add(JournalEntry.proofChecked(invoice, payment: checked, at: now));

    // the payee takes the note, and its balance says so
    final payeeStore = NoteStore(shape);
    final (taken, whyTaken) = payeeStore.take(checked);
    expect(whyTaken, isNull, reason: '$whyTaken');
    expect(taken!.value, 200);

    final payeeView = PoolView.atGenesis(shape);
    expect(payeeView.fold(1, br1), isNull);
    expect(payeeView.fold(2, br2, cmRoot: cm2), isNull);
    final (payeeTracked, whyPayeeTrack) = payeeView.track(
        round: 2, position: checked.position, leaf: BlockFold.lanesToBytes(note32.cm), path: path32);
    expect(whyPayeeTrack, isNull, reason: '$whyPayeeTrack');
    expect(payeeTracked, isNotNull);
    expect(payeeStore.balanceOf(taken.asset, view: payeeView, tip: 2).spendable, 200,
        reason: 'the payee can spend what it was paid');

    // ---- 9. the payee acknowledges, and the payer keeps it ----

    final (ack, whyAck) = await Acknowledgement.of(
        invoice: invoice, payment: checked, ivk: keys.ivk, minedAt: now);
    expect(whyAck, isNull, reason: '$whyAck');
    await payeeJournal.add(JournalEntry.acknowledgementSent(invoice, ack!, at: now));
    final ackBytes = ack.encode();
    timings['acknowledgement bytes'] = ackBytes.length;

    final back = Acknowledgement.decode(ackBytes);
    final whyBad = await back.check(invoice);
    expect(whyBad, isNull, reason: '$whyBad');
    await payerJournal.add(JournalEntry.acknowledgementReceived(invoice, back, at: now));
    whole.stop();
    timings['whole run'] = whole.elapsedMilliseconds;

    // ---- what the two journals say ----

    final payerThread = await payerJournal.thread(invoice.id);
    expect(payerThread.whole, isTrue, reason: '${payerThread.refused}');
    expect([for (final e in payerThread.entries) e.kind], [
      JournalKind.invoiceReceived,
      JournalKind.paymentBuilt,
      JournalKind.paymentSubmitted,
      JournalKind.paymentAnswered,
      JournalKind.proofBuilt,
      JournalKind.acknowledgementReceived,
    ]);
    final payeeThread = await payeeJournal.thread(invoice.id);
    expect(payeeThread.whole, isTrue, reason: '${payeeThread.refused}');
    expect([for (final e in payeeThread.entries) e.kind], [
      JournalKind.invoiceIssued,
      JournalKind.proofChecked,
      JournalKind.acknowledgementSent,
    ]);
    for (final e in [...payerThread.entries, ...payeeThread.entries]) {
      expect(e.invoiceId, invoice.id);
    }

    // ---- what was said to the pool, over the whole run ----

    for (final frame in pool1.sent) {
      final msg = PoolMessage.decode(frame);
      expect(msg is PoolSubmission || msg is PoolCatchUpRequest, isTrue,
          reason: 'a wallet sends a transfer it built, or a question from a published set, and nothing else');
      if (msg is PoolCatchUpRequest && msg.what == CatchUpKind.blockRoots) {
        expect(pool.publishesRange(msg.from, msg.count), isTrue);
      }
    }
    final secrets = <String, List<int>>{
      'the payee\'s address key': payeeAddr.pkd,
      'the change address\'s key': changeAddr.pkd,
      'the paid note\'s commitment': BlockFold.lanesToBytes(note32.cm),
      'the spent note\'s commitment': BlockFold.lanesToBytes(note1.cm),
      'the round transaction\'s txid': hex.decode(c.r2.id),
    };
    for (final frame in pool1.sent) {
      for (final s in secrets.entries) {
        expect(_holds(frame, s.value), isFalse, reason: 'a frame carried ${s.key}');
      }
    }
    // and the header source was asked about blocks, never about a wallet
    expect(headers.calls.every((call) => call.startsWith('tip') || call.startsWith('heightOfBlock') || call.startsWith('headerAtHeight')),
        isTrue);

    print('  end to end: ${timings.entries.map((e) => '${e.key} ${e.value}').join(', ')}');
    for (final e in payerThread.entries) {
      print('  payer $e');
    }
    for (final e in payeeThread.entries) {
      print('  payee $e');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('The payee can refuse, and the record says so', () async {
    // the same run, with a proof for a note that is not the payee's
    final other = await NoteAddress.at(keys.ivk, 9);
    final (proof, why) = PaymentProofs.standing(
        note: NoteOpening.of(note32.note),
        round: 2,
        roundTx: round2Bytes,
        witnessTx: witness2Bytes,
        blockHash: block2.hash,
        txIndex: 1,
        branch: block2.branchFor(1).$2,
        position: note32.position,
        path: path32);
    expect(why, isNull);

    final invoice = await Invoice.issue(
        tokenId: pool.tokenId,
        ivk: keys.ivk,
        address: other,
        amount: 200,
        expiry: expiry,
        rng: Random(44));
    final checker = PaymentChecker(pool: pool, headers: HeaderChecker(headers, confirmations: 6));
    final (checked, whyCheck) = await checker.check(proof!, pkd: other.pkd);
    expect(checked, isNull);
    expect(whyCheck, isNotNull);

    final j = await journalAt('refusing');
    await j.add(JournalEntry.invoiceIssued(invoice, at: now));
    final (stored, _) = await j.add(JournalEntry.proofChecked(invoice, refusal: whyCheck, at: now));
    expect(stored!.outcome, 'refused');
    expect(stored.reason, whyCheck!.step);
    final thread = (await j.thread(invoice.id)).entries;
    expect(thread.length, 2);
    expect(thread.any((e) => e.outcome == 'paid'), isFalse,
        reason: 'nothing in the record says this invoice was paid');
  });
}

bool _holds(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  outer:
  for (int i = 0; i + needle.length <= haystack.length; i++) {
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
