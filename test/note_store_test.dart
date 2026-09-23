import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dartsv/dartsv.dart' show NetworkType;
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/testing.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'fakes.dart';

/// The wallet's own bookkeeping: what it holds, what state each note is in,
/// what a person reads, and which note a payment spends.
///
/// The fixture is the real thing and not a mock of it. Its round 1 pays the
/// wallet 500 at leaf 0; its round 2 spends that note — the nullifier the
/// scanner computes for it is the one round 2 inserted — and pays the wallet
/// 200 back at leaf 32. So a note goes through all three of its states here
/// because a mined pool put it through them, not because a test said so.
void main() {
  late PoolTestChain c;
  late PoolShape shape;
  late ShieldedRound round1, round2;
  late List<int> nk, paidPkd, walletD, bsv;

  // the fixture's own note, and the change it came back as
  late CheckedPayment paid;
  late PaymentProof goodProof;
  late PaymentChecker checker;
  late FakeHeaderSource headers;
  late NoteOpening changeOpening;

  late List<int> br1, br2, cm1, cm2;
  late List<List<int>> path1, path32;

  /// A view at round 1 or 2 with the fixture's notes tracked.
  PoolView viewAt(int round, {bool track = true}) {
    final v = PoolView.atGenesis(shape);
    expect(v.fold(1, br1, cmRoot: cm1), isNull);
    if (track) {
      expect(v.track(round: 1, position: 0, leaf: _cm(paid.note, paidPkd), path: path1).$2, isNull);
    }
    if (round >= 2) {
      expect(v.fold(2, br2, cmRoot: cm2), isNull);
      if (track) {
        expect(v.track(round: 2, position: 32, leaf: _cm(changeOpening, paidPkd), path: path32).$2, isNull);
      }
    }
    return v;
  }

  setUpAll(() async {
    c = await PoolTestChain.build();
    final pool = PoolDescriptor.forPool(
        network: NetworkType.TEST, issuance: c.r0, witness0: c.w0, slot0: c.y0.tx, plan: c.f.agg);
    final (s, whyShape) = PoolShape.forPool(pool);
    expect(whyShape, isNull);
    shape = s!;

    final layout = ShieldedPoolLayout.forArities([2, 2], nullifierLevel: 1, receiptSlots: 2);
    final ledger = ShieldedLedger.open(layout, c.r0, c.w0, c.y0.tx, tokenId: c.tokenId, genesisHeader: c.genesisHeader);

    round1 = ledger.apply(c.r1, c.w1, c.y1.tx);
    br1 = List<int>.of(round1.blockRoot);
    cm1 = List<int>.of(ledger.header.cmRoot);
    final scanner = ShieldedNoteScanner.forWallet(c.f.wallet, [c.f.walletD]);
    final scanned = (await scanner.scan(round1)).single;
    walletD = scanned.d;
    bsv = scanned.note.asset;
    paidPkd = (await NoteAddress.derive(c.f.wallet.ivk, scanned.d)).pkd;
    path1 = [for (final x in ledger.tree.path(scanned.position).siblings) List<int>.of(x)];
    nk = c.f.wallet.nk;

    round2 = ledger.apply(c.r2, c.w2, c.y2.tx);
    br2 = List<int>.of(round2.blockRoot);
    cm2 = List<int>.of(ledger.header.cmRoot);
    final change = (await scanner.scan(round2)).single;
    changeOpening = NoteOpening.of(change.note);
    path32 = [for (final x in ledger.tree.path(change.position).siblings) List<int>.of(x)];

    expect(scanned.position, 0);
    expect(change.position, 32);
    expect(round2.nullifiers.single, scanned.nullifier, reason: 'round 2 really does spend the round 1 note');

    // the standing proof for the round 1 note, checked the way a payee checks
    headers = FakeHeaderSource.holding([
      crypto.sha256.convert([0]).bytes,
      hex.decode(c.w1.id),
    ], before: 3, after: 6);
    final witnessBlock = headers.blockOf(hex.decode(c.w1.id))!;
    final (_, branch) = witnessBlock.branchFor(1);
    goodProof = PaymentProof.standing(
        round: 1,
        roundTx: hex.decode(c.r1.serialize()),
        witnessTx: hex.decode(c.w1.serialize()),
        blockHash: witnessBlock.hash,
        txIndex: 1,
        branch: branch,
        position: scanned.position,
        path: path1,
        note: NoteOpening.of(scanned.note));
    checker = PaymentChecker(pool: pool, headers: HeaderChecker(headers, confirmations: 6));
    final (payment, whyPaid) = await checker.check(goodProof, pkd: paidPkd);
    expect(whyPaid, isNull, reason: '$whyPaid');
    paid = payment!;
    expect(paid.value, 500);
  });

  // ---- a synthetic pool at production shape, for the many-note scenarios ----
  late _SynPool syn;
  late PoolShape bigShape;

  setUpAll(() {
    final (b, _) = PoolShape.of(512);
    bigShape = b!;
    syn = _SynPool(bigShape, paidPkd, asset: bsv, d: walletD, rounds: 20);
  });

  group('a note\'s states', () {
    test('A note through its states', () {
      final store = NoteStore(shape);
      final (note, why) = store.take(paid);
      expect(why, isNull);
      expect(note!.state, NoteState.proven);
      expect(note.value, 500);
      expect(note.round, 1);
      expect(note.position, 0);

      expect(store.reserve(note), isNull);
      expect(note.state, NoteState.reserved);

      // round 2's own nullifiers, as the ledger read them off the mined round
      final moved = store.settle(round2.nullifiers, nk: nk);
      expect(moved, [note]);
      expect(note.state, NoteState.spent);

      // and there is no way back
      for (final (step, refusal) in [
        ('release', store.release(note)),
        ('reserve', store.reserve(note)),
      ]) {
        expect(refusal, isNotNull, reason: step);
        expect(refusal!.reason, contains('spent'));
        expect(note.state, NoteState.spent);
      }
      expect(store.settle(round2.nullifiers, nk: nk), isEmpty, reason: 'seeing the round twice changes nothing');
    });

    test('A refused submission releases the note', () {
      final store = NoteStore(shape);
      final (note, _) = store.take(paid);
      expect(store.reserve(note!), isNull);

      final view = viewAt(1);
      expect(store.balanceOf(bsv, view: view, tip: 1).spendable, 0);
      expect(store.balanceOf(bsv, view: view, tip: 1).reserved, 500);

      expect(store.release(note), isNull);
      expect(note.state, NoteState.proven);
      expect(store.balanceOf(bsv, view: view, tip: 1).spendable, 500);
      final (chosen, why) = store.choose(amount: 500, asset: bsv, view: view, tip: 1);
      expect(why, isNull);
      expect(chosen!.note, note, reason: 'spendable again');
    });

    test('A round that spends nothing of ours', () {
      final store = NoteStore(shape);
      final (note, _) = store.take(paid);
      expect(store.settle(round1.nullifiers, nk: nk), isEmpty);
      expect(note!.state, NoteState.proven);
    });
  });

  group('one note, one payment at a time', () {
    test('A second payment on the same note', () {
      final store = NoteStore(shape);
      final (note, _) = store.take(paid);
      final view = viewAt(1);

      final (first, whyFirst) = store.choose(amount: 100, asset: bsv, view: view, tip: 1);
      expect(whyFirst, isNull);
      expect(store.reserve(first!.note), isNull);

      final again = store.reserve(note!);
      expect(again, isNotNull);
      expect(again!.step, 'note');
      expect(again.reason, contains('leaf 0'), reason: 'the position');
      expect(again.reason, contains('reserved'), reason: 'and the state');

      // and nothing offers it a second time either, so no proof is computed
      final (second, whySecond) = store.choose(amount: 100, asset: bsv, view: view, tip: 1);
      expect(second, isNull);
      expect(whySecond!.step, 'amount');
    });

    test('A note this store is not holding', () {
      final mine = NoteStore(shape), other = NoteStore(shape);
      final (note, _) = mine.take(paid);
      final why = other.reserve(note!);
      expect(why!.reason, contains('leaf 0'));
      expect(note.state, NoteState.proven);
    });
  });

  group('balance lines a person can read', () {
    test('A stale line', () {
      final store = NoteStore(shape);
      store.take(paid);
      final view = viewAt(1);

      final b = store.balanceOf(bsv, view: view, tip: 6);
      expect(b.spendable, 0);
      expect(b.stale, 500);
      expect(b.staleNotes.single.position, 0);
      expect(b.behind, 5);
      expect(b.whyStale!.reason, contains('5 rounds ahead'));
      expect(b.toString(), contains('5 rounds behind'));

      // catching up two rounds is not enough and one more is
      expect(store.balanceOf(bsv, view: view, tip: 4).spendable, 500);
      expect(store.balanceOf(bsv, view: view, tip: 5).spendable, 0);
    });

    test('Three lines, never one number', () {
      final store = NoteStore(shape);
      final view = viewAt(2);
      final (a, _) = store.take(paid);
      final (b, _) = store.takeChange(opening: changeOpening, position: 32, round: 2);
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(store.reserve(b!), isNull);

      final line = store.balanceOf(bsv, view: view, tip: 2);
      expect(line.spendable, 500, reason: 'the round 1 note, still anchorable at round 2');
      expect(line.reserved, 200);
      expect(line.stale, 0);
      expect(line.largestSpendable, 500);

      // a note the wallet holds but the view is not keeping is stale, not
      // spendable: there is nothing to anchor it to
      final blind = viewAt(2, track: false);
      final dark = store.balanceOf(bsv, view: blind, tip: 2);
      expect(dark.spendable, 0);
      expect(dark.stale, 500);
      expect(dark.whyStale!.step, 'view');
    });

    test('An asset the wallet holds none of', () {
      final store = NoteStore(shape);
      store.take(paid);
      final view = viewAt(1);
      final other = [9, 9, 9, 9];
      final b = store.balanceOf(other, view: view, tip: 1);
      expect(b.spendable, 0);
      expect(b.reserved, 0);
      expect(b.stale, 0);
      expect(b.asset, other);
      expect(store.balances(view: view, tip: 1).length, 1, reason: 'only the asset it does hold is listed');
    });
  });

  group('choosing what to spend', () {
    const values = [100, 50, 300, 50, 700, 25, 1000, 400, 75, 200];

    (NoteStore, PoolView) loaded() {
      final store = NoteStore(bigShape);
      final view = syn.viewAt(1);
      for (int i = 0; i < values.length; i++) {
        final (n, why) = store.takeChange(opening: syn.openingAt(i), position: i, round: 1);
        expect(why, isNull, reason: 'note $i: $why');
        expect(n!.value, values[i]);
        final (t, whyT) = view.track(round: 1, position: i, leaf: syn.leafAt(i), path: syn.path(i, 1).siblings);
        expect(whyT, isNull, reason: 'note $i: $whyT');
        expect(t, isNotNull);
      }
      return (store, view);
    }

    test('The same choice twice', () {
      final (store, view) = loaded();
      final (a, whyA) = store.choose(amount: 60, asset: bsv, view: view, tip: 1);
      final (b, whyB) = store.choose(amount: 60, asset: bsv, view: view, tip: 1);
      expect(whyA, isNull);
      expect(whyB, isNull);
      expect(a!.note, b!.note);
      expect(a.note.value, 75, reason: 'the smallest note that covers it');
      expect(a.change, 15);
    });

    test('The lowest leaf breaks a tie', () {
      final (store, view) = loaded();
      final (chosen, why) = store.choose(amount: 50, asset: bsv, view: view, tip: 1);
      expect(why, isNull);
      expect(chosen!.note.value, 50);
      expect(chosen.note.position, 1, reason: 'leaf 1 and leaf 3 both hold 50');
      expect(chosen.change, 0);
    });

    test('No note covers it', () {
      final (store, view) = loaded();
      final (chosen, why) = store.choose(amount: 2000, asset: bsv, view: view, tip: 1);
      expect(chosen, isNull);
      expect(why!.step, 'amount');
      expect(why.reason, contains('1000'), reason: 'the largest spendable, not the total');
      expect(why.reason, isNot(contains('2900')), reason: 'and never the total, which nobody can pay');

      for (final bad in [0, -1]) {
        expect(store.choose(amount: bad, asset: bsv, view: view, tip: 1).$2!.step, 'amount');
      }
    });

    test('Behind, not broke', () {
      final (store, view) = loaded();
      final (chosen, why) = store.choose(amount: 60, asset: bsv, view: view, tip: 9);
      expect(chosen, isNull);
      expect(why!.reason, contains('the largest spendable is 0'));
      expect(why.reason, contains('8 rounds too far behind'), reason: 'it says catching up is the fix');
    });
  });

  group('nullifiers stay inside', () {
    test('Nullifiers are not published', () async {
      final transport = FakeTransport();
      final store = NoteStore(shape);
      final (note, _) = store.take(paid);
      store.takeChange(opening: changeOpening, position: 32, round: 2);
      final view = viewAt(2);
      headers.calls.clear();

      store.balances(view: view, tip: 2);
      store.choose(amount: 100, asset: bsv, view: view, tip: 2);
      store.settle(round2.nullifiers, nk: nk);

      final dir = await Directory.systemTemp.createTemp('libcloak-notes-');
      try {
        final path = '${dir.path}/notes';
        await NoteStoreFile.save(path, store);
        final onDisk = await File(path).readAsBytes();

        // the note's nullifier, in every shape it could have been written in
        final nf = note!.nullifierWith(nk);
        expect(_contains(onDisk, BlockFold.lanesToBytes(nf)), isFalse);
        for (final lane in nf) {
          expect(_contains(onDisk, [lane & 0xff, (lane >> 8) & 0xff, (lane >> 16) & 0xff, (lane >> 24) & 0xff]),
              isFalse,
              reason: 'lane $lane of the nullifier is on disk');
        }
        // nor is nk itself
        expect(_contains(onDisk, BlockFold.lanesToBytes(nk)), isFalse);
      } finally {
        await dir.delete(recursive: true);
      }

      // and nothing was sent or asked, because the store has no port
      expect(transport.sent, isEmpty);
      expect(transport.reads, isEmpty);
      expect(headers.calls, isEmpty);
    });
  });

  group('untrusted input, determinism and compatibility', () {
    test('A note without a checked proof', () async {
      final store = NoteStore(shape);

      // the same proof against somebody else's address: the check refuses, so
      // there is no CheckedPayment and nothing to offer the store
      final stranger = [for (final l in paidPkd) l ^ 1];
      final (payment, why) = await checker.check(goodProof, pkd: stranger);
      expect(payment, isNull);
      expect(why, isNotNull);
      expect(store.notes, isEmpty);
      expect(store.encode(), NoteStore(shape).encode(), reason: 'the store is unchanged');

      // and the other door is not a way round it: a note whose round and leaf
      // disagree is refused, because the round would decide what anchors it
      final (bad, whyBad) = store.takeChange(opening: paid.note, position: 0, round: 2);
      expect(bad, isNull);
      expect(whyBad!.step, 'position');
      expect(whyBad.reason, contains('round 1'));
      expect(store.notes, isEmpty);
    });

    test('Two stores agree', () {
      List<int> drive() {
        final s = NoteStore(shape);
        expect(s.take(paid).$2, isNull);
        expect(s.takeChange(opening: changeOpening, position: 32, round: 2).$2, isNull);
        expect(s.reserve(s.at(32)!), isNull);
        return s.encode();
      }

      final a = drive(), b = drive();
      expect(a, b);

      final back = NoteStore.decode(a, shape: shape);
      expect(back.length, 2);
      expect(back.at(0)!.state, NoteState.proven);
      expect(back.at(0)!.value, 500);
      expect(back.at(32)!.state, NoteState.reserved);
      expect(back.encode(), a);
    });

    test('A duplicate note', () {
      final store = NoteStore(shape);
      expect(store.take(paid).$2, isNull);
      final (again, why) = store.take(paid);
      expect(again, isNull);
      expect(why!.reason, contains('leaf 0'));
      expect(store.length, 1);
    });

    test('Unknown store version', () {
      final store = NoteStore(shape);
      store.take(paid);
      final bytes = List<int>.of(store.encode());
      bytes[0] = 7;
      final why = _refusalFrom(() => NoteStore.decode(bytes, shape: shape));
      expect(why.step, 'version');
      expect(why.reason, contains('7'));
    });

    test('A store built under another block size', () {
      final store = NoteStore(shape);
      store.take(paid);
      final why = _refusalFrom(() => NoteStore.decode(store.encode(), shape: bigShape));
      expect(why.step, 'leavesPerRound');
      expect(why.reason, contains('32'));
      expect(why.reason, contains('512'));
    });

    test('A state that names a state no note has', () {
      final store = NoteStore(shape);
      store.take(paid);
      final bytes = List<int>.of(store.encode());
      bytes[10] = 9; // the first note's state byte
      final why = _refusalFrom(() => NoteStore.decode(bytes, shape: shape));
      expect(why.step, 'note state');
      expect(why.reason, contains('9'));
    });
  });

  group('resources and failure behaviour', () {
    test('A truncated store', () async {
      final dir = await Directory.systemTemp.createTemp('libcloak-notes-');
      final path = '${dir.path}/notes';
      try {
        final store = NoteStore(shape);
        store.take(paid);
        store.takeChange(opening: changeOpening, position: 32, round: 2);
        await NoteStoreFile.save(path, store);

        final whole = await File(path).readAsBytes();
        final back = await NoteStoreFile.open(path, shape: shape);
        expect(back.encode(), whole);
        expect(File(path).statSync().mode & 0x1ff, 0x180, reason: 'owner only');
        expect(File(NoteStoreFile.temporaryFor(path)).existsSync(), isFalse);

        await File(path).writeAsBytes(whole.sublist(0, whole.length - 30));
        final why = await _refusalFromAsync(() => NoteStoreFile.open(path, shape: shape));
        expect(why.reason, contains(path), reason: 'the file is named');

        // the previous state is what the caller still holds
        expect(store.length, 2);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('Ten thousand notes', () {
      const held = 10000;
      final store = NoteStore(bigShape);
      final view = syn.viewAt(1);

      // one round's worth is tracked and spendable, the next is reserved, and
      // the rest the view is not keeping, so all three lines are exercised
      for (int i = 0; i < held; i++) {
        final (n, why) = store.takeChange(
            opening: syn.openingAt(i), position: i, round: syn.roundOf(i));
        expect(why, isNull, reason: 'note $i: $why');
        if (i < 512) {
          expect(view.track(round: 1, position: i, leaf: syn.leafAt(i), path: syn.path(i, 1).siblings).$2, isNull);
        } else if (i < 1024) {
          expect(store.reserve(n!), isNull);
        }
      }
      expect(store.length, held);

      final sw = Stopwatch()..start();
      final lines = store.balanceOf(bsv, view: view, tip: 1);
      sw.stop();

      // recognising a spend costs one hash a note, which is the price of not
      // writing nullifiers down
      final one = store.at(7)!.nullifierWith(nk);
      final settling = Stopwatch()..start();
      final moved = store.settle([one], nk: nk);
      settling.stop();
      expect(moved.single.position, 7);

      final encoding = Stopwatch()..start();
      final bytes = store.encode();
      encoding.stop();
      print('    $held notes: ${bytes.length} bytes (${NoteStore.noteSize} a note), '
          'balance in ${sw.elapsedMicroseconds} us, '
          'settle in ${settling.elapsedMilliseconds} ms, '
          'encode in ${encoding.elapsedMilliseconds} ms');
      print('    $lines');
      expect(bytes.length, lessThan(4 * 1024 * 1024));
      expect(sw.elapsedMilliseconds, lessThan(10));
      expect(lines.spendableNotes.length, 512);
      expect(lines.reservedNotes.length, 512);
      expect(lines.staleNotes.length, held - 1024);

      final back = NoteStore.decode(bytes, shape: bigShape);
      expect(back.length, held);
      expect(back.encode(), bytes);
    });
  });
}

List<int> _cm(NoteOpening o, List<int> pkd) =>
    HeldNote(opening: o, position: 0, round: 1).commitmentFor(pkd);

bool _contains(List<int> haystack, List<int> needle) {
  for (int i = 0; i + needle.length <= haystack.length; i++) {
    var same = true;
    for (int k = 0; k < needle.length; k++) {
      if (haystack[i + k] != needle[k]) {
        same = false;
        break;
      }
    }
    if (same) return true;
  }
  return false;
}

Refusal _refusalFrom(void Function() f) {
  try {
    f();
  } on Refusal catch (e) {
    return e;
  }
  fail('expected a refusal');
}

Future<Refusal> _refusalFromAsync(Future<void> Function() f) async {
  try {
    await f();
  } on Refusal catch (e) {
    return e;
  }
  fail('expected a refusal');
}

/// A pool at production shape whose leaves are this wallet's own notes.
///
/// Each round's commitment root comes from a tree built straight from the
/// leaves that round had, so the roots a view is checked against here were not
/// produced by folding anything.
class _SynPool {
  final PoolShape shape;
  final List<int> pkd, asset, d;
  final List<NoteOpening> openings = [];
  final List<NoteCommitmentTree> _trees = [];

  static const values = [100, 50, 300, 50, 700, 25, 1000, 400, 75, 200];

  _SynPool(this.shape, this.pkd, {required this.asset, required this.d, required int rounds}) {
    final n = rounds * shape.leavesPerRound;
    final leaves = <List<int>>[];
    for (int i = 0; i < n; i++) {
      final o = NoteOpening(
          asset: asset,
          d: d,
          value: i < values.length ? values[i] : 1 + (i % 997),
          rho: [for (int k = 0; k < PoolHash.rhoLanes; k++) (i * 7919 + k * 104729 + 1) & 0x7ffffffe],
          rcm: [for (int k = 0; k < PoolHash.rcmLanes; k++) (i * 65537 + k * 31337 + 3) & 0x7ffffffe]);
      openings.add(o);
      leaves.add(BlockFold.bytesToLanes(HeldNote(opening: o, position: i, round: 1).commitmentFor(pkd)));
    }
    for (int r = 1; r <= rounds; r++) {
      _trees.add(NoteCommitmentTree.fromLeaves(leaves.sublist(0, r * shape.leavesPerRound)));
    }
  }

  int get rounds => _trees.length;
  int roundOf(int leaf) => shape.blockOf(leaf) + 1;
  NoteOpening openingAt(int leaf) => openings[leaf];
  List<int> leafAt(int leaf) => HeldNote(opening: openings[leaf], position: leaf, round: roundOf(leaf)).commitmentFor(pkd);
  MerklePath path(int leaf, int asOf) => _trees[asOf - 1].path(leaf);
  List<int> blockRoot(int round) => BlockFold.lanesToBytes(_trees.last.nodeAt(shape.blockLevel, round - 1));
  List<int> cmRoot(int round) => BlockFold.lanesToBytes(_trees[round - 1].root);

  /// A view folded to [round], checked at every step.
  PoolView viewAt(int round) {
    final v = PoolView.atGenesis(shape);
    for (int r = 1; r <= round; r++) {
      final why = v.fold(r, blockRoot(r), cmRoot: cmRoot(r));
      if (why != null) throw StateError('round $r: $why');
    }
    return v;
  }
}
