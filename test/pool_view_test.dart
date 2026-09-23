import 'dart:io';
import 'dart:math';

import 'package:dartsv/dartsv.dart' show NetworkType;
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/testing.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'fakes.dart';

/// The wallet's picture of the pool, and what it costs to keep.
///
/// Three claims are under test. The first is arithmetic: a path kept from one
/// 32-byte root a round is the same path a party that built the whole tree
/// would hand out — checked against a tree of 512,000 leaves built directly,
/// not against another fold. The second is that the fold is evidence and not
/// hearsay: a root that does not reach the commitment root of a round the
/// wallet proved off the chain changes nothing, and a view that has not
/// checked will not yield a spend path. The third is the privacy one, and it
/// is structural: a [PoolView] has no port, so there is nothing for it to ask.
///
/// The numbers the pool fixes — 32 leaves a round here, 4 roots in the ring —
/// come from tstokenlib and are read, never restated.
void main() {
  // ---- the fixture pool: two real rounds, mined, with a real note in them ----
  late PoolTestChain c;
  late PoolDescriptor pool;
  late PoolShape shape;
  late List<int> br1, br2, cm1, cm2;
  late Checkpoint cp1, cp2;
  late int notePos;
  late List<int> noteLeaf;
  late List<List<int>> notePath1, notePath2;

  // ---- a pool at production shape, driven synthetically ----
  const bigBlocks = 1000, bigPer = 512;
  late PoolShape big;
  late NoteCommitmentTree bigTree;
  late List<List<int>> bigRoots, bigCms;

  List<int> leafAt(int i) => [for (int k = 0; k < 8; k++) ((i * 2654435761 + k * 40503) & 0x7ffffffe)];

  /// The pool's tree as it stood after [blocks] rounds, built from its leaves
  /// rather than folded, for the scenarios that compare the two.
  NoteCommitmentTree bigTreeAfter(int blocks) =>
      NoteCommitmentTree.fromLeaves([for (int i = 0; i < blocks * bigPer; i++) leafAt(i)]);

  setUpAll(() async {
    c = await PoolTestChain.build();
    pool = PoolDescriptor.forPool(
        network: NetworkType.TEST, issuance: c.r0, witness0: c.w0, slot0: c.y0.tx, plan: c.f.agg);
    final (s, whyShape) = PoolShape.forPool(pool);
    expect(whyShape, isNull);
    shape = s!;

    final layout = ShieldedPoolLayout.forArities([2, 2], nullifierLevel: 1, receiptSlots: 2);
    final ledger = ShieldedLedger.open(layout, c.r0, c.w0, c.y0.tx, tokenId: c.tokenId, genesisHeader: c.genesisHeader);

    final round1 = ledger.apply(c.r1, c.w1, c.y1.tx);
    br1 = List<int>.of(round1.blockRoot);
    cm1 = List<int>.of(ledger.header.cmRoot);
    cp1 = Checkpoint.of(ledger.frontier());
    final scanner = ShieldedNoteScanner.forWallet(c.f.wallet, [c.f.walletD]);
    final scanned = (await scanner.scan(round1)).first;
    notePos = scanned.position;
    noteLeaf = BlockFold.lanesToBytes(scanned.cm);
    notePath1 = [for (final x in ledger.tree.path(notePos).siblings) List<int>.of(x)];

    final round2 = ledger.apply(c.r2, c.w2, c.y2.tx);
    br2 = List<int>.of(round2.blockRoot);
    cm2 = List<int>.of(ledger.header.cmRoot);
    cp2 = Checkpoint.of(ledger.frontier());
    notePath2 = [for (final x in ledger.tree.path(notePos).siblings) List<int>.of(x)];

    final (b, whyBig) = PoolShape.of(bigPer);
    expect(whyBig, isNull);
    big = b!;
    bigTree = bigTreeAfter(bigBlocks);
    bigRoots = [for (int i = 0; i < bigBlocks; i++) BlockFold.lanesToBytes(bigTree.nodeAt(big.blockLevel, i))];
    final ref = _RefUpper(big.blockLevel);
    bigCms = [
      for (int i = 0; i < bigBlocks; i++)
        () {
          ref.set(i, bigTree.nodeAt(big.blockLevel, i));
          return BlockFold.lanesToBytes(ref.root);
        }()
    ];
    // the long-hand tree and the one built from leaves agree, so the roots the
    // synthetic rounds are checked against are not this library's own opinion
    expect(bigCms.last, BlockFold.lanesToBytes(bigTree.root));
  });

  /// A view on the big pool folded to [round], with [notes] notes from round 1
  /// taken on, checked at every step.
  (PoolView, List<TrackedNote>) bigViewAt(int round, {int notes = 0}) {
    final view = PoolView.atGenesis(big);
    expect(view.fold(1, bigRoots[0], cmRoot: bigCms[0]), isNull);
    final held = <TrackedNote>[];
    if (notes > 0) {
      final first = bigTreeAfter(1);
      for (int i = 0; i < notes; i++) {
        final (n, why) = view.track(
            round: 1,
            position: i,
            leaf: BlockFold.lanesToBytes(leafAt(i)),
            path: first.path(i).siblings);
        expect(why, isNull, reason: 'note $i: $why');
        held.add(n!);
      }
    }
    for (int r = 2; r <= round; r++) {
      expect(view.fold(r, bigRoots[r - 1], cmRoot: bigCms[r - 1]), isNull);
    }
    return (view, held);
  }

  group('the pool\'s shape comes from its descriptor', () {
    test('The test pool\'s descriptor', () {
      expect(pool.transfers, 4);
      expect(c.f.agg.tree.subtrees, 1);
      expect(shape.leavesPerRound, 32);
      expect(shape.blockLevel, 5);
      expect(shape.upperLevels, 27);

      final view = PoolView.atGenesis(shape);
      expect(view.round, 0);
      expect(view.fold(1, br1, cmRoot: cm1), isNull, reason: 'the view is ready to fold');
      expect(view.round, 1);
    });

    test('A leaf count that is not a power of two', () {
      final (s, why) = PoolShape.of(608);
      expect(s, isNull, reason: 'no shape, so no view, so nothing is written');
      expect(why!.step, 'leavesPerRound');
      expect(why.reason, contains('608'));

      // the pool's own descriptor refuses it too, for the same reason: 304
      // transfers append 608 leaves, and at 608 a round owns no node
      expect(
          () => PoolDescriptor(
              network: NetworkType.TEST,
              issuance: PoolMessage.txidOf(c.r0),
              witness0: PoolMessage.txidOf(c.w0),
              slot0: PoolMessage.txidOf(c.y0.tx),
              arities: const [16, 19],
              nullifierLevel: 1,
              receiptSlots: 2,
              spendP: c.f.agg.spendP,
              leavesPerRound: 608,
              tokenId: c.tokenId,
              genesisHeader: c.genesisHeader),
          throwsArgumentError);
    });

    test('A pool that changed its block size', () {
      final view = PoolView.atGenesis(shape);
      expect(view.fold(1, br1, cmRoot: cm1), isNull);
      final stored = view.encode();

      final (other, _) = PoolShape.of(64);
      final why = _refusalFrom(() => PoolView.decode(stored, shape: other!));
      expect(why.step, 'leavesPerRound');
      expect(why.reason, contains('32'));
      expect(why.reason, contains('64'));
    });
  });

  group('following costs one block root a round', () {
    test('Thirty-two bytes a round', () {
      final (view, held) = bigViewAt(5, notes: 8);
      expect(held.length, 8);
      final before = [for (final n in held) n.currentAt];
      expect(before, everyElement(5));

      var consumed = 0;
      final root = bigRoots[5];
      consumed += root.length;
      expect(view.fold(6, root), isNull);

      expect(consumed, 32, reason: 'the whole of what round 6 had to publish for this wallet');
      expect([for (final n in held) n.currentAt], everyElement(6));
    });

    test('Notes do not multiply the feed', () {
      var one = 0, hundred = 0;
      final (viewA, _) = bigViewAt(5, notes: 1);
      final (viewB, _) = bigViewAt(5, notes: 100);
      for (int r = 6; r <= 15; r++) {
        one += bigRoots[r - 1].length;
        hundred += bigRoots[r - 1].length;
        expect(viewA.fold(r, bigRoots[r - 1]), isNull);
        expect(viewB.fold(r, bigRoots[r - 1]), isNull);
      }
      expect(one, 320);
      expect(hundred, 320);
      expect(viewA.round, 15);
      expect(viewB.round, 15);
    });
  });

  group('a fold is checked, never trusted', () {
    test('A wrong block root', () {
      final view = PoolView.atGenesis(shape);
      expect(view.fold(1, br1, cmRoot: cm1), isNull);
      final (note, whyTrack) = view.track(round: 1, position: notePos, leaf: noteLeaf, path: notePath1);
      expect(whyTrack, isNull);
      final before = [for (final s in note!.path.siblings) List<int>.of(s)];

      final wrong = List<int>.of(br2);
      wrong[7] ^= 1;
      final why = view.fold(2, wrong, cmRoot: cm2);
      expect(why, isNotNull);
      expect(why!.step, 'cmRoot');
      expect(why.reason, contains('round 2'));

      expect(view.round, 1, reason: 'the view did not move');
      expect(note.path.siblings, before, reason: 'and neither did the path it was keeping');
      expect(view.cmRoot, cm1);
    });

    test('The fixture\'s two rounds', () {
      final view = PoolView.atGenesis(shape);
      expect(view.fold(1, br1, cmRoot: cm1), isNull);
      expect(view.cmRoot, cm1);
      final (note, why) = view.track(round: 1, position: notePos, leaf: noteLeaf, path: notePath1);
      expect(why, isNull);
      expect(view.fold(2, br2, cmRoot: cm2), isNull);
      expect(view.cmRoot, cm2);
      expect(view.checkedTo, 2);

      expect(note!.path.siblings, notePath2, reason: 'the maintained path is the ledger\'s own');
      expect(note.path.position, notePos);
      expect(BlockFold.lanesToBytes(note.path.rootFor(BlockFold.bytesToLanes(noteLeaf))), cm2);
    });

    test('An unchecked fold is not a spend', () {
      final (view, held) = bigViewAt(5, notes: 1);
      expect(view.fold(6, bigRoots[5]), isNull);
      final (path, why) = view.spendPath(held.first, tip: 6);
      expect(path, isNull);
      expect(why!.step, 'unchecked');
      expect(why.reason, contains('round 6'));
      expect(why.reason, contains('round 5'));

      expect(view.check(6, bigCms[5]), isNull);
      final (ok, whyOk) = view.spendPath(held.first, tip: 6);
      expect(whyOk, isNull);
      expect(ok, isNotNull);
    });
  });

  group('rounds arrive in order, with no gaps', () {
    test('A skipped round', () {
      final (view, held) = bigViewAt(7, notes: 1);
      final before = [for (final s in held.first.path.siblings) List<int>.of(s)];

      final why = view.fold(9, bigRoots[8], cmRoot: bigCms[8]);
      expect(why, isNotNull);
      expect(why!.step, 'round');
      expect(why.reason, contains('round 8'));
      expect(why.reason, contains('round 9'));
      expect(view.round, 7);
      expect(held.first.path.siblings, before);
    });

    test('Catching up', () {
      final (view, held) = bigViewAt(7, notes: 3);
      for (int r = 8; r <= 10; r++) {
        expect(view.fold(r, bigRoots[r - 1], cmRoot: bigCms[r - 1]), isNull);
      }
      expect(view.round, 10);
      expect(view.checkedTo, 10);

      // against a tree of ten blocks built straight from its leaves
      final ten = bigTreeAfter(10);
      for (final n in held) {
        expect(n.currentAt, 10);
        expect(n.path.siblings, ten.path(n.position).siblings);
      }
    });
  });

  group('what a note keeps', () {
    test('The lower siblings never change', () {
      final view = PoolView.atGenesis(shape);
      expect(view.fold(1, br1, cmRoot: cm1), isNull);
      final (note, _) = view.track(round: 1, position: notePos, leaf: noteLeaf, path: notePath1);
      final lower = [for (final s in note!.lower) List<int>.of(s)];
      expect(lower.length, shape.blockLevel);

      expect(view.fold(2, br2, cmRoot: cm2), isNull);
      expect(note.lower, lower, reason: 'a full block is never rewritten');
      expect(note.upper.length, shape.upperLevels);
      expect(note.upper, isNot(equals(notePath1.sublist(shape.blockLevel))),
          reason: 'and the siblings above it did move');
    });

    test('A maintained path against a built tree', () {
      const block = 3;
      final position = block * bigPer + 7;
      final view = PoolView.atGenesis(big);
      for (int r = 1; r <= block + 1; r++) {
        expect(view.fold(r, bigRoots[r - 1], cmRoot: bigCms[r - 1]), isNull);
      }
      final four = bigTreeAfter(block + 1);
      final (note, why) = view.track(
          round: block + 1,
          position: position,
          leaf: BlockFold.lanesToBytes(leafAt(position)),
          path: four.path(position).siblings);
      expect(why, isNull);

      for (int r = block + 2; r <= bigBlocks; r++) {
        expect(view.fold(r, bigRoots[r - 1], cmRoot: bigCms[r - 1]), isNull);
      }
      expect(view.round, bigBlocks);
      expect(note!.path.siblings, bigTree.path(position).siblings,
          reason: '$bigBlocks blocks of $bigPer leaves, folded 32 bytes at a time');
      expect(note.path.position, position);
    });
  });

  group('spending needs a root the pool still accepts', () {
    test('Four rounds of slack', () {
      final view = PoolView.atGenesis(shape);
      expect(view.fold(1, br1, cmRoot: cm1), isNull);
      final (note, _) = view.track(round: 1, position: notePos, leaf: noteLeaf, path: notePath1);
      expect(view.fold(2, br2, cmRoot: cm2), isNull);

      expect(PoolView.ringEntries, 4);
      expect(view.roundsLeft(note!, tip: 2), 4);
      final (path, why) = view.spendPath(note, tip: 2);
      expect(why, isNull);
      expect(path!.siblings.length, PoolSpendAir.depth);
    });

    test('Too far behind to spend', () {
      final (view, held) = bigViewAt(10, notes: 1);
      expect(view.roundsLeft(held.first, tip: 15), -1);
      final (path, why) = view.spendPath(held.first, tip: 15);
      expect(path, isNull);
      expect(why!.step, 'behind');
      expect(why.reason, contains('5 rounds ahead'));
      expect(why.reason, contains('rounds 11 to 15'), reason: 'what it needs to catch up');

      // and one round sooner it is still spendable
      expect(view.roundsLeft(held.first, tip: 13), 1);
      expect(view.spendPath(held.first, tip: 13).$2, isNull);
    });
  });

  group('nothing is asked that names the wallet', () {
    test('Advancing makes no requests', () {
      final headers = FakeHeaderSource.holding([List<int>.filled(32, 7)]);
      final transport = FakeTransport();
      headers.calls.clear();

      final (view, held) = bigViewAt(1, notes: 4);
      for (int r = 2; r <= 11; r++) {
        expect(view.fold(r, bigRoots[r - 1]), isNull);
      }
      expect(view.check(11, bigCms[10]), isNull);
      expect(view.spendPath(held.first, tip: 11).$2, isNull);

      expect(headers.calls, isEmpty);
      expect(transport.sent, isEmpty);
      expect(transport.reads, isEmpty);
    });
  });

  group('idle when there is nothing to keep fresh', () {
    test('Resuming from a payment', () {
      final view = PoolView.atGenesis(big);
      for (int r = 1; r <= 4; r++) {
        expect(view.fold(r, bigRoots[r - 1], cmRoot: bigCms[r - 1]), isNull);
      }
      expect(view.notes, isEmpty);

      // rounds 5 to 8 go by and the wallet, holding nothing, folds none of them
      const position = 8 * bigPer + 3;
      final nine = bigTreeAfter(9);
      final (note, why) = view.resume(
          round: 9,
          position: position,
          leaf: BlockFold.lanesToBytes(leafAt(position)),
          path: nine.path(position).siblings,
          cmRoot: bigCms[8]);
      expect(why, isNull);
      expect(view.round, 9);
      expect(view.foldedFrom, 10);
      expect(view.checkedTo, 9);
      expect(view.cmRoot, bigCms[8]);

      // and from there it follows normally
      expect(view.fold(10, bigRoots[9], cmRoot: bigCms[9]), isNull);
      final ten = bigTreeAfter(10);
      expect(note!.path.siblings, ten.path(position).siblings);
    });
  });

  group('joining a pool from a checkpoint', () {
    test('A wallet joins at the head', () {
      final (view, why) = PoolView.atCheckpoint(shape, cp2, cmRoot: cm2);
      expect(why, isNull);
      expect(view!.round, 2);
      expect(view.cmRoot, cm2);
      expect(view.checkedTo, 2);
      expect(view.foldedFrom, 3, reason: 'it folds from round 3 on and reads no round before it');
      expect(view.notes, isEmpty);

      // everything it was given: the frontier and that round's own root
      expect(cp2.encode().length, Checkpoint.encodedSize(cp2.left.length));
      final joined = cp2.encode().length + cm2.length;
      expect(joined, lessThan(1024));
      // and at round 1, where the block index is zero and carries no nodes
      expect(cp1.left, isEmpty);
      final (one, whyOne) = PoolView.atCheckpoint(shape, cp1, cmRoot: cm1);
      expect(whyOne, isNull);
      expect(one!.round, 1);
      expect(one.fold(2, br2, cmRoot: cm2), isNull);
      expect(one.cmRoot, cm2);

      print('    joined at round 2 for $joined bytes '
          '(${cp2.left.length} frontier nodes; at production ${big.upperLevels} nodes, '
          '${big.upperLevels * 32} bytes)');
    });

    test('A frontier that does not reproduce the root', () {
      final left = [for (final n in cp2.left) List<int>.of(n)];
      left[0][5] ^= 1;
      final bent = Checkpoint(round: cp2.round, blockRoot: cp2.blockRoot, left: left);
      final (view, why) = PoolView.atCheckpoint(shape, bent, cmRoot: cm2);
      expect(view, isNull, reason: 'the view stays empty');
      expect(why!.step, 'checkpoint');
      expect(why.reason, contains('round 2'));
    });
  });

  group('what a checkpoint does and does not replace', () {
    test('A note across a checkpoint', () {
      final view = PoolView.atGenesis(shape);
      expect(view.fold(1, br1, cmRoot: cm1), isNull);
      final (note, _) = view.track(round: 1, position: notePos, leaf: noteLeaf, path: notePath1);

      expect(view.restoreTo(cp2, cmRoot: cm2), isNull);
      expect(view.round, 2);
      expect(note!.currentAt, 1, reason: 'the checkpoint did not bring it forward');
      expect(note.maintained, isFalse);

      final (path, why) = view.spendPath(note, tip: 2);
      expect(path, isNull);
      expect(why!.step, 'rounds');
      expect(why.reason, contains('round 2'), reason: 'the first round it never folded');
      expect(why.reason, contains('round 1'));
    });

    test('A wallet with no notes rejoins cheaply', () {
      final view = PoolView.atGenesis(shape);
      expect(view.fold(1, br1, cmRoot: cm1), isNull);
      expect(view.notes, isEmpty);

      final consumed = cp2.encode().length + cm2.length;
      expect(view.restoreTo(cp2, cmRoot: cm2), isNull);
      expect(view.round, 2);
      expect(view.cmRoot, cm2);
      expect(view.checkedTo, 2);
      expect(consumed, lessThan(1024));
      expect(big.upperLevels * 32, 736, reason: 'the production frontier, whatever the pool\'s age');
    });
  });

  group('untrusted input', () {
    test('Roots, paths and positions that are not', () {
      final view = PoolView.atGenesis(shape);
      expect(view.fold(1, br1.sublist(0, 31), cmRoot: cm1)!.step, 'blockRoot');
      expect(view.fold(1, List<int>.filled(32, 0xff), cmRoot: cm1)!.step, 'blockRoot');
      expect(view.fold(1, br1, cmRoot: cm1.sublist(0, 20))!.step, 'cmRoot');
      expect(view.fold(1, br1, cmRoot: cm1), isNull);

      expect(view.track(round: 1, position: notePos, leaf: noteLeaf, path: notePath1.sublist(0, 31)).$2!.step, 'path');
      expect(
          view
              .track(round: 1, position: notePos, leaf: noteLeaf.sublist(0, 16), path: notePath1)
              .$2!
              .step,
          'leaf');
      expect(view.track(round: 1, position: 1 << 20, leaf: noteLeaf, path: notePath1).$2!.step, 'position');
      expect(view.track(round: 0, position: notePos, leaf: noteLeaf, path: notePath1).$2!.step, 'round');
      // a round and a position that disagree: the position decides the block,
      // so the round number in a proof is checked and not believed
      final disagree = view.track(round: 2, position: notePos, leaf: noteLeaf, path: notePath1).$2!;
      expect(disagree.step, 'position');
      expect(disagree.reason, contains('round 1'));
      expect(view.notes, isEmpty);
    });

    test('Mutated input', () {
      final rng = Random(9051);
      final counts = <String, int>{};
      var accepted = 0, unnamed = 0;
      const runs = 10000;

      for (int i = 0; i < runs; i++) {
        final view = PoolView.atGenesis(shape);
        expect(view.fold(1, br1, cmRoot: cm1), isNull);
        final root = view.cmRoot;
        Refusal? why;
        try {
          switch (i % 3) {
            case 0:
              final bent = List<int>.of(br2);
              bent[rng.nextInt(bent.length)] ^= 1 << rng.nextInt(8);
              why = view.fold(2, bent, cmRoot: cm2);
            case 1:
              final bent = [for (final s in notePath1) List<int>.of(s)];
              final l = rng.nextInt(bent.length);
              bent[l][rng.nextInt(8)] ^= 1 << rng.nextInt(31);
              why = view.track(round: 1, position: notePos, leaf: noteLeaf, path: bent).$2;
            default:
              final bent = notePos ^ (1 << rng.nextInt(24));
              why = view.track(round: 1, position: bent, leaf: noteLeaf, path: notePath1).$2;
          }
        } on Refusal catch (e) {
          unnamed++;
          fail('a refusal escaped instead of being returned: $e');
        } catch (e) {
          unnamed++;
          continue;
        }
        if (why == null) {
          accepted++;
          // whatever was accepted left the view consistent
          expect(view.round, inInclusiveRange(1, 2));
          expect(view.cmRoot.length, 32);
          if (view.round == 1) expect(view.cmRoot, root);
        } else {
          counts[why.step] = (counts[why.step] ?? 0) + 1;
          expect(why.reason, isNotEmpty);
          expect(view.round, 1, reason: 'a refusal left the view where it was');
          expect(view.cmRoot, root);
        }
      }

      expect(unnamed, 0);
      expect(counts.values.fold(0, (a, b) => a + b) + accepted, runs);
      print('    $runs mutations: $accepted accepted, '
          '${[for (final e in counts.entries) '${e.value} ${e.key}'].join(', ')}, $unnamed unnamed');
    });
  });

  group('determinism and compatibility', () {
    test('Two views agree', () {
      List<int> drive() {
        final v = PoolView.atGenesis(shape);
        expect(v.fold(1, br1, cmRoot: cm1), isNull);
        expect(v.track(round: 1, position: notePos, leaf: noteLeaf, path: notePath1).$2, isNull);
        expect(v.fold(2, br2, cmRoot: cm2), isNull);
        return v.encode();
      }

      final a = drive(), b = drive();
      expect(a, b);

      // and a view restored from those bytes folds on identically
      final restored = PoolView.decode(a, shape: shape);
      expect(restored.round, 2);
      expect(restored.cmRoot, cm2);
      expect(restored.notes.single.path.siblings, notePath2);
      expect(restored.encode(), a);
    });

    test('Unknown state version', () {
      final view = PoolView.atGenesis(shape);
      expect(view.fold(1, br1, cmRoot: cm1), isNull);
      final stored = List<int>.of(view.encode());
      stored[0] = 9;
      final why = _refusalFrom(() => PoolView.decode(stored, shape: shape));
      expect(why.step, 'version');
      expect(why.reason, contains('9'));
    });
  });

  group('resources and failure behaviour', () {
    test('Catch-up cost', () {
      final first = bigTreeAfter(1);
      final view = PoolView.atGenesis(big);
      final held = <TrackedNote>[];

      final sw = Stopwatch()..start();
      expect(view.fold(1, bigRoots[0], cmRoot: bigCms[0]), isNull);
      sw.stop();
      for (int i = 0; i < 8; i++) {
        final (n, why) =
            view.track(round: 1, position: i, leaf: BlockFold.lanesToBytes(leafAt(i)), path: first.path(i).siblings);
        expect(why, isNull);
        held.add(n!);
      }
      sw.start();
      for (int r = 2; r <= bigBlocks; r++) {
        expect(view.fold(r, bigRoots[r - 1]), isNull);
      }
      expect(view.check(bigBlocks, bigCms[bigBlocks - 1]), isNull);
      sw.stop();

      expect(view.round, bigBlocks);
      for (final n in held) {
        expect(n.currentAt, bigBlocks);
        expect(n.path.siblings, bigTree.path(n.position).siblings);
      }
      print('    $bigBlocks rounds holding ${held.length} notes: ${sw.elapsedMilliseconds} ms');
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });

    test('State size', () {
      final (view, held) = bigViewAt(4, notes: 100);
      expect(held.length, 100);
      final stored = view.encode();
      print('    100 notes at round 4: ${stored.length} bytes '
          '(${PoolView.noteSize} a note)');
      expect(stored.length, lessThan(200 * 1024));

      final back = PoolView.decode(stored, shape: big);
      expect(back.notes.length, 100);
      expect(back.encode(), stored);
    });

    test('A state file cut short', () async {
      final dir = await Directory.systemTemp.createTemp('libcloak-view-');
      final path = '${dir.path}/view.state';
      try {
        final view = PoolView.atGenesis(shape);
        expect(view.fold(1, br1, cmRoot: cm1), isNull);
        expect(view.track(round: 1, position: notePos, leaf: noteLeaf, path: notePath1).$2, isNull);
        await PoolViewFile.save(path, view);

        final whole = await File(path).readAsBytes();
        final back = await PoolViewFile.open(path, shape: shape);
        expect(back.encode(), whole);
        expect(File(path).statSync().mode & 0x1ff, 0x180, reason: 'owner only');
        expect(File(PoolViewFile.temporaryFor(path)).existsSync(), isFalse);

        await File(path).writeAsBytes(whole.sublist(0, whole.length - 40));
        final why = await _refusalFromAsync(() => PoolViewFile.open(path, shape: shape));
        expect(why.reason, contains(path), reason: 'the file is named');
        expect(why.step, isNotEmpty);

        // nothing was folded: the caller still has the view it had
        expect(view.round, 1);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('A view whose notes claim more than the state holds', () {
      final view = PoolView.atGenesis(shape);
      expect(view.fold(1, br1, cmRoot: cm1), isNull);
      expect(view.track(round: 1, position: notePos, leaf: noteLeaf, path: notePath1).$2, isNull);
      final stored = List<int>.of(view.encode());

      // the note count, four bytes after the recent roots, made huge
      final at = stored.length - PoolView.noteSize - 4;
      stored[at] = 0xff;
      stored[at + 1] = 0xff;
      final why = _refusalFrom(() => PoolView.decode(stored, shape: shape));
      expect(why.step, 'notes');
      expect(why.reason, contains('${PoolView.maxNotes}'));
    });
  });
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

/// The pool's tree above the block level, written out the long way: every
/// node kept, nothing pruned, the root read off the top.
///
/// [BlockFold] does the same arithmetic with a frontier, forgetting what it
/// can no longer need and rewriting the paths it is keeping as it goes. Two
/// implementations of the same tree agree only if both are right, and this one
/// is anchored to the fixture's real rounds — the commitment roots a
/// [ShieldedLedger] rebuilt from the mined transactions — so it is not two
/// opinions checking each other.
class _RefUpper {
  final int blockLevel;
  final List<Map<int, List<int>>> nodes;

  _RefUpper(this.blockLevel)
      : nodes = List.generate(NoteCommitmentTree.depth - blockLevel + 1, (_) => <int, List<int>>{});

  List<int> at(int level, int index) => nodes[level][index] ?? MerkleFrontier.emptyRoots[blockLevel + level];

  void set(int block, List<int> lanes) {
    nodes[0][block] = lanes;
    var idx = block;
    for (int l = 0; l < NoteCommitmentTree.depth - blockLevel; l++) {
      final left = idx & ~1;
      nodes[l + 1][idx >> 1] = PoolHash.node(at(l, left), at(l, left | 1));
      idx >>= 1;
    }
  }

  List<int> get root => at(NoteCommitmentTree.depth - blockLevel, 0);
}
