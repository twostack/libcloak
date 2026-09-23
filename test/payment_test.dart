import 'dart:math';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dartsv/dartsv.dart' show NetworkType;
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/testing.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'fakes.dart';

/// A payment from one person to another, and the proof that it happened.
///
/// This is the capability the library exists for, and the claim under test is
/// that **nobody has to look anything up and nobody has to be believed**. The
/// payer builds against an invoice it checked and a path its own view
/// vouches for; the payee checks the proof against headers its own source
/// vouches for and acknowledges; and neither side asks anyone a question that
/// names a note, an address or a wallet.
///
/// Two payments run here. One libcloak builds itself — a real spend proof
/// against the fixture's round-1 note — which is what the build path is tested
/// on. One the fixture already mined — round 2 pays the wallet 200 at leaf 32
/// — which is what the check path is tested on, because checking needs a round
/// that a chain really carried.
void main() {
  late PoolTestChain c;
  late PoolDescriptor pool;
  late PoolShape shape;
  late ShieldedRound round1, round2;
  late List<int> br1, br2, cm1, cm2;

  // the fixture wallet: the payer in the build tests, the payee in the check
  // tests, because it is the wallet whose notes the fixture's chain carries
  late PoolWalletKeys fixtureWallet;
  late NoteAddress walletAddr, changeAddr;
  late ScannedNote note1, note32;
  late List<List<int>> path1, path32;

  late FakeHeaderSource headers;
  late PaymentChecker payeeChecker;
  late FakeBlock block2;
  late int index2;
  late List<int> round2Bytes, witness2Bytes;
  late Invoice paidInvoice;
  late PaymentProof standing;
  late DateTime now, soon;

  NoteStore storeWith(ScannedNote n) {
    final s = NoteStore(shape);
    final (held, why) = s.takeChange(opening: NoteOpening.of(n.note), position: n.position, round: n.round);
    expect(why, isNull, reason: '$why');
    expect(held, isNotNull);
    return s;
  }

  PoolView viewAt(int round) {
    final v = PoolView.atGenesis(shape);
    expect(v.fold(1, br1, cmRoot: cm1), isNull);
    expect(v.track(round: 1, position: note1.position, leaf: BlockFold.lanesToBytes(note1.cm), path: path1).$2,
        isNull);
    if (round >= 2) {
      expect(v.fold(2, br2, cmRoot: cm2), isNull);
      expect(
          v.track(round: 2, position: note32.position, leaf: BlockFold.lanesToBytes(note32.cm), path: path32).$2,
          isNull);
    }
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
    final ledger = ShieldedLedger.open(layout, c.r0, c.w0, c.y0.tx, tokenId: c.tokenId, genesisHeader: c.genesisHeader);

    fixtureWallet = c.f.wallet;
    walletAddr = await NoteAddress.derive(fixtureWallet.ivk, c.f.walletD);
    changeAddr = await NoteAddress.at(fixtureWallet.ivk, 1);

    round1 = ledger.apply(c.r1, c.w1, c.y1.tx);
    br1 = List<int>.of(round1.blockRoot);
    cm1 = List<int>.of(ledger.header.cmRoot);
    final scanner = ShieldedNoteScanner.forWallet(fixtureWallet, [c.f.walletD]);
    note1 = (await scanner.scan(round1)).single;
    path1 = [for (final x in ledger.tree.path(note1.position).siblings) List<int>.of(x)];

    round2 = ledger.apply(c.r2, c.w2, c.y2.tx);
    br2 = List<int>.of(round2.blockRoot);
    cm2 = List<int>.of(ledger.header.cmRoot);
    note32 = (await scanner.scan(round2)).single;
    path32 = [for (final x in ledger.tree.path(note32.position).siblings) List<int>.of(x)];

    expect(note1.position, 0);
    expect(note1.value, 500);
    expect(note32.position, 32);
    expect(note32.value, 200);

    // the payee's chain: w2 in a block, buried
    headers = FakeHeaderSource.holding([
      crypto.sha256.convert([0]).bytes,
      hex.decode(c.w2.id),
    ], before: 3, after: 6);
    block2 = headers.blockOf(hex.decode(c.w2.id))!;
    index2 = 1;
    round2Bytes = hex.decode(c.r2.serialize());
    witness2Bytes = hex.decode(c.w2.serialize());
    payeeChecker = PaymentChecker(pool: pool, headers: HeaderChecker(headers, confirmations: 6));

    now = DateTime.utc(2026, 9, 23, 12);
    soon = now.add(const Duration(days: 1));
    // the fixture wallet asked for the 200 it was paid, at its own address
    paidInvoice = await Invoice.issue(
        tokenId: pool.tokenId,
        ivk: fixtureWallet.ivk,
        address: walletAddr,
        amount: 200,
        expiry: soon,
        memo: 'a crate of oranges',
        id: List<int>.generate(Invoice.idLength, (i) => i),
        rng: Random(11));

    final (_, branch) = block2.branchFor(index2);
    final (p, whyProof) = PaymentProofs.standing(
        note: NoteOpening.of(note32.note),
        round: 2,
        roundTx: round2Bytes,
        witnessTx: witness2Bytes,
        blockHash: block2.hash,
        txIndex: index2,
        branch: branch,
        position: note32.position,
        path: path32);
    expect(whyProof, isNull, reason: '$whyProof');
    standing = p!;
    headers.calls.clear();
  });

  setUp(() {
    headers.calls.clear();
    headers.fail = null;
  });

  late WalletKeys lastPayee;

  Future<(BuiltPayment?, Refusal?)> buildPaying(int amount,
      {DateTime? at, DateTime? expiry, NoteStore? store, PoolView? view, int tip = 1}) async {
    final payee = WalletKeys(
        seed: WalletSeed.fromHex('f0e1d2c3b4a5968778695a4b3c2d1e0ff0e1d2c3b4a5968778695a4b3c2d1e0f'), birthday: 1);
    lastPayee = payee;
    final invoice = await Invoice.issueFor(
        tokenId: pool.tokenId,
        keys: payee,
        amount: amount,
        expiry: expiry ?? soon,
        memo: 'two crates',
        id: List<int>.generate(Invoice.idLength, (i) => 100 + i),
        rng: Random(12));
    final notes = store ?? storeWith(note1);
    return PaymentBuilder.build(
        invoice: invoice,
        keys: fixtureWallet,
        changeAddress: changeAddr,
        note: notes.at(note1.position)!,
        notes: notes,
        view: view ?? viewAt(1),
        spendP: c.f.agg.spendP,
        tokenId: pool.tokenId,
        tip: tip,
        now: at ?? now,
        rng: Random(13));
  }

  group('building a payment', () {
    test('A payment on the fixture\'s chain', () async {
      final (built, why) = await buildPaying(300);
      expect(why, isNull, reason: '$why');
      final p = built!;

      expect(p.transfer.refusal(), isNull, reason: 'the transfer is well formed on its own');
      expect(p.transfer.verifyProof(c.f.agg.spendP), isNull, reason: 'and its spend proof verifies');
      expect(p.paid.value, 300);
      expect(p.change.value, 200, reason: '500 spent, 300 paid');
      expect(p.anchorRound, 1);
      expect(p.anchor, cm1, reason: 'anchored to the round the view stands at');

      // the payer can read back both notes it sent, from its own outgoing copy
      final bundles = p.transfer.notes;
      expect(bundles.length, 2);
      final mine = await NoteEncryption.decryptOutgoing(bundles[1], fixtureWallet.ovk);
      expect(mine, isNotNull, reason: 'the change note is recoverable by the payer');
      expect(mine!.$1.value, 200);
      expect(mine.$2, changeAddr.pkd);

      // and so can the payee, with its own incoming key and the diversifier
      // its own invoice named
      final theirs = await NoteEncryption.decryptIncoming(bundles[0], lastPayee.ivk, p.paidTo.d);
      expect(theirs, isNotNull, reason: 'the payee opens the note it was paid');
      expect(theirs!.value, 300);
      final notMine = await NoteEncryption.decryptIncoming(bundles[1], lastPayee.ivk, p.paidTo.d);
      expect(notMine, isNull, reason: 'and not the payer\'s change');

      print('    built a payment: own work ${p.ownWork.inMilliseconds} ms, '
          'spend proof ${p.proving.inMilliseconds} ms, '
          'transfer ${p.transfer.encode(c.f.agg.spendP).length} bytes');
      expect(p.ownWork.inMilliseconds, lessThan(200), reason: 'everything but the STARK');
    });

    test('Not enough in the note', () async {
      final sw = Stopwatch()..start();
      final (built, why) = await buildPaying(600);
      sw.stop();
      expect(built, isNull);
      expect(why!.step, 'amount');
      expect(why.reason, contains('600'));
      expect(why.reason, contains('500'));
      expect(sw.elapsedMilliseconds, lessThan(100), reason: 'no proof was computed');
    });

    test('An expired invoice', () async {
      final sw = Stopwatch()..start();
      final (built, why) = await buildPaying(300, expiry: now.subtract(const Duration(minutes: 1)));
      sw.stop();
      expect(built, isNull);
      expect(why!.step, 'expiry');
      expect(sw.elapsedMilliseconds, lessThan(100), reason: 'before any proof is computed');
    });

    test('Too far behind to spend', () async {
      final (built, why) = await buildPaying(300, tip: 9);
      expect(built, isNull);
      expect(why!.step, 'behind');
      expect(why.reason, contains('8 rounds ahead'));
    });

    test('A note already in flight', () async {
      final store = storeWith(note1);
      expect(store.reserve(store.at(note1.position)!), isNull);
      final (built, why) = await buildPaying(300, store: store);
      expect(built, isNull);
      expect(why!.step, 'note');
      expect(why.reason, contains('reserved'));
    });

    test('An invoice for another pool', () async {
      final payee = WalletKeys(seed: WalletSeed.fromHex('11' * 32), birthday: 1);
      final invoice = await Invoice.issueFor(
          tokenId: List<int>.filled(32, 9), keys: payee, amount: 10, expiry: soon, rng: Random(1));
      final notes = storeWith(note1);
      final (built, why) = await PaymentBuilder.build(
          invoice: invoice,
          keys: fixtureWallet,
          changeAddress: changeAddr,
          note: notes.at(note1.position)!,
          notes: notes,
          view: viewAt(1),
          spendP: c.f.agg.spendP,
          tokenId: pool.tokenId,
          tip: 1,
          now: now);
      expect(built, isNull);
      expect(why!.step, 'pool');
    });
  });

  group('a standing payment proof is self-contained', () {
    test('Nothing to look up', () async {
      final (paid, why) = await payeeChecker.check(standing, pkd: walletAddr.pkd);
      expect(why, isNull, reason: '$why');
      expect(paid!.value, 200);

      expect(headers.calls, [
        'heightOfBlock ${hex.encode(block2.hash)}',
        'headerAtHeight ${block2.height}',
        'tip',
      ], reason: 'a block hash the proof itself carries, its height, and the tip');
    });

    test('Size at test parameters', () {
      final bytes = standing.encode();
      print('    standing proof at test parameters: ${bytes.length} bytes '
          '(round ${round2Bytes.length}, witness ${witness2Bytes.length})');
      expect(bytes.length, lessThan(1024 * 1024));
      expect(PaymentProof.decode(bytes).encode(), bytes);
    });

    test('Two builds agree', () {
      List<int> build() {
        final (_, branch) = block2.branchFor(index2);
        final (p, why) = PaymentProofs.standing(
            note: NoteOpening.of(note32.note),
            round: 2,
            roundTx: round2Bytes,
            witnessTx: witness2Bytes,
            blockHash: block2.hash,
            txIndex: index2,
            branch: branch,
            position: note32.position,
            path: path32);
        expect(why, isNull);
        return p!.encode();
      }

      expect(build(), build());
    });

    test('The payer finds its own leaf', () {
      final at = PaymentProofs.positionOf(round2, BlockFold.lanesToBytes(note32.cm));
      expect(at, note32.position, reason: 'which is the one thing the round tells the payer');
      expect(PaymentProofs.positionOf(round2, List<int>.filled(32, 0)), isNull);
    });
  });

  group('what a payee checks', () {
    test('A good payment is accepted', () async {
      final (paid, why) = await payeeChecker.check(standing, pkd: walletAddr.pkd);
      expect(why, isNull);
      expect(paid!.value, paidInvoice.amount);
      expect(paid.round, 2);
      expect(paid.position, note32.position);
      expect(paid.cmRoot, cm2);
      expect(paid.confirmations, greaterThanOrEqualTo(6));
    });

    test('A note that is not the payee\'s', () async {
      final stranger = await NoteAddress.at(PoolWalletKeys(List<int>.generate(5, (i) => 7 + i)).ivk, 0);
      final (paid, why) = await payeeChecker.check(standing, pkd: stranger.pkd);
      expect(paid, isNull, reason: 'nothing is reported paid');
      expect(why, isNotNull);

      // The spec names a separate "commitment step" here, and there is not
      // one to name: an opening carries no commitment, so the commitment is
      // *computed* from the opening and the payee's own pk_d, and the only
      // thing that can then fail is the walk to the round's root. Under
      // another key the commitment is a different value, so the walk lands
      // somewhere else and the refusal says exactly that, naming both roots.
      // The clause that does carry weight is the second one, and it holds:
      // the witness being mined and the round being this pool's are not
      // reported as proof of anything.
      expect(why!.step, 'path');
      expect(why.reason, contains('${note32.position}'));
      expect(why.reason, contains(_short(cm2)), reason: 'the round\'s own root');

      // the step that can fail on its own is an opening that is not a note at
      // all, and that one is named 'commitment'
      final (nonsense, whyNonsense) = PoolEvidence.noteUnderRoot(
          cmRoot: cm2,
          opening: NoteOpening.of(note32.note).plaintext,
          pkd: const <int>[],
          position: note32.position,
          path: path32);
      expect(nonsense, isNull);
      expect(whyNonsense!.step, anyOf('pk_d', 'commitment'));
    });

    test('A path to another round', () async {
      final (bent, whyBent) = PaymentProofs.standing(
          note: NoteOpening.of(note32.note),
          round: 2,
          roundTx: round2Bytes,
          witnessTx: witness2Bytes,
          blockHash: block2.hash,
          txIndex: index2,
          branch: block2.branchFor(index2).$2,
          position: note32.position,
          path: path1);
      expect(whyBent, isNull);
      final (paid, why) = await payeeChecker.check(bent!, pkd: walletAddr.pkd);
      expect(paid, isNull);
      expect(why, isNotNull);
      expect(why!.step, 'path');
      expect(why.reason, contains(_short(cm2)), reason: 'the round\'s root');
      expect(why.reason, contains('reaches'), reason: 'and the one the path reached');
    });

    test('Checking is cheap', () async {
      // The bound is per core, and `dart test` runs files beside each other,
      // so a single wall-clock reading here measures the machine's load as
      // much as the check. The minimum of several runs is the honest estimate
      // of what one core does: interference can only make a reading longer.
      final runs = <int>[];
      for (int i = 0; i < 7; i++) {
        final sw = Stopwatch()..start();
        final (paid, why) = await payeeChecker.check(standing, pkd: walletAddr.pkd);
        sw.stop();
        expect(why, isNull);
        expect(paid, isNotNull);
        runs.add(sw.elapsedMicroseconds);
      }
      runs.sort();
      final best = runs.first / 1000, worst = runs.last / 1000;
      print('    checking a standing proof at test parameters: '
          '${best.toStringAsFixed(1)} ms best of ${runs.length}, ${worst.toStringAsFixed(1)} ms worst '
          '(${standing.encode().length} bytes, no STARK verified)');
      expect(best, lessThan(100));
    });

  });

  group('a short payment proof', () {
    PaymentChecker checkerFollowing(PoolView view) => PaymentChecker(
        pool: pool,
        headers: HeaderChecker(headers, confirmations: 6),
        foldedRoot: (r) => r == view.round ? view.cmRoot : null,
        foldedTo: () => view.round);

    (PaymentProof, int) shortProof() {
      final (p, why) = PaymentProofs.short(
          note: NoteOpening.of(note32.note), round: 2, position: note32.position, path: path32);
      expect(why, isNull);
      return (p!, p.encode().length);
    }

    test('A short proof into a folded round', () async {
      final view = viewAt(2);
      final (proof, size) = shortProof();
      final (paid, why) = await checkerFollowing(view).check(proof, pkd: walletAddr.pkd);
      expect(why, isNull, reason: '$why');
      expect(paid!.value, 200);
      expect(paid.cmRoot, cm2, reason: 'the payee\'s own fold, not one inside the proof');
      expect(headers.calls, isEmpty, reason: 'it asked its header source nothing at all');
      print('    short proof: $size bytes against ${standing.encode().length} standing');
    });

    test('Size of the short form', () {
      final (_, size) = shortProof();
      expect(size, lessThan(4 * 1024));
    });

    test('A short proof for a round not folded', () async {
      final view = viewAt(1);
      final (proof, _) = shortProof();
      final (paid, why) = await checkerFollowing(view).check(proof, pkd: walletAddr.pkd);
      expect(paid, isNull);
      expect(why!.step, 'short proof');
      expect(why.reason, contains('round 2'));
      expect(why.reason, contains('round 1'));
    });

    test('The payer falls back', () async {
      final view = viewAt(1);
      final checker = checkerFollowing(view);
      final (proof, _) = shortProof();
      final (none, why) = await checker.check(proof, pkd: walletAddr.pkd);
      expect(none, isNull);
      expect(why!.step, 'short proof');

      // the payer hears that and sends the standing form for the same payment
      final (paid, whyStanding) = await checker.check(standing, pkd: walletAddr.pkd);
      expect(whyStanding, isNull);
      expect(paid!.value, 200);
    });

    test('A short proof naming its own root', () {
      final (proof, _) = shortProof();
      final bent = [...proof.encode(), ...cm2];
      final why = _refusalFrom(() => PaymentProof.decode(bent));
      expect(why.step, 'cmRoot');
      expect(why.reason, contains('commitment root'));
    });

    test('A payee that does not follow the pool', () async {
      final (proof, _) = shortProof();
      final (paid, why) = await payeeChecker.check(proof, pkd: walletAddr.pkd);
      expect(paid, isNull);
      expect(why!.step, 'short proof');
      expect(why.reason, contains('standing'));
    });
  });

  group('acknowledgement', () {
    Future<(Acknowledgement?, Refusal?)> ack({Invoice? invoice, DateTime? minedAt}) async {
      final (paid, why) = await payeeChecker.check(standing, pkd: walletAddr.pkd);
      expect(why, isNull);
      final (header, _) = await payeeChecker.headers.proven(block2.hash);
      return Acknowledgement.of(
          invoice: invoice ?? paidInvoice,
          payment: paid!,
          ivk: fixtureWallet.ivk,
          minedAt: minedAt ?? header!.time);
    }

    test('An acknowledgement checks against its invoice', () async {
      final (a, why) = await ack();
      expect(why, isNull, reason: '$why');
      expect(a!.round, 2);
      expect(a.value, 200);
      expect(a.invoiceId, paidInvoice.id);

      // the payer holds only the invoice it issued, and that is enough
      expect(await a.check(paidInvoice), isNull);
      final bytes = a.encode();
      expect(bytes.length, Acknowledgement.encodedSize);
      expect(await Acknowledgement.decode(bytes).check(paidInvoice), isNull);
      expect(Acknowledgement.decode(bytes).encode(), bytes);
      print('    acknowledgement: ${bytes.length} bytes');
    });

    test('An acknowledgement for another invoice', () async {
      final other = await Invoice.issue(
          tokenId: pool.tokenId,
          ivk: fixtureWallet.ivk,
          address: walletAddr,
          amount: 200,
          expiry: soon,
          id: List<int>.generate(Invoice.idLength, (i) => 200 - i),
          rng: Random(3));
      final (a, _) = await ack();
      final why = await a!.check(other);
      expect(why, isNotNull);
      expect(why!.step, 'invoice');
      expect(why.reason, contains(shortHex(paidInvoice.id)));
      expect(why.reason, contains(shortHex(other.id)));
    });

    test('An acknowledgement somebody else wrote', () async {
      final (a, _) = await ack();
      final bytes = List<int>.of(a!.encode());
      bytes[bytes.length - 1] ^= 1;
      final why = await Acknowledgement.decode(bytes).check(paidInvoice);
      expect(why!.step, 'signature');
    });

    test('An invoice that had expired when the round was mined', () async {
      final expired = await Invoice.issue(
          tokenId: pool.tokenId,
          ivk: fixtureWallet.ivk,
          address: walletAddr,
          amount: 200,
          expiry: DateTime.utc(2020),
          id: List<int>.generate(Invoice.idLength, (i) => i),
          rng: Random(4));
      final (a, why) = await ack(invoice: expired);
      expect(a, isNull);
      expect(why!.step, 'expiry');
      expect(why.reason, contains('2020'));
    });

    test('Unknown acknowledgement version', () async {
      final (a, _) = await ack();
      final bytes = List<int>.of(a!.encode());
      bytes[0] = 6;
      final why = _refusalFrom(() => Acknowledgement.decode(bytes));
      expect(why.step, 'version');
      expect(why.reason, contains('6'));
    });
  });

  group('untrusted input, secrets and failure behaviour', () {
    test('A proof that claims a huge length', () {
      // the round's declared length, four bytes after the fixed head
      final bytes = List<int>.of(standing.encode());
      final at = 2 + 4 + 4 + PoolSpendAir.depth * 4 * PoolHash.digestLanes + NoteOpening.encodedSize;
      for (int i = 0; i < 4; i++) {
        bytes[at + i] = 0xff;
      }
      final why = _refusalFrom(() => PaymentProof.decode(bytes));
      expect(why.step, 'roundTx');
      expect(why.reason, contains('${PaymentProof.maxTx}'));
    });

    test('Nothing secret in a proof', () {
      final bytes = standing.encode();
      final secrets = <String, List<int>>{
        'the payee\'s sk': lanesToBytes(fixtureWallet.sk),
        'the payee\'s ivk': lanesToBytes(fixtureWallet.ivk),
        'the payee\'s nk': lanesToBytes(fixtureWallet.nk),
        'the payee\'s ovk': lanesToBytes(fixtureWallet.ovk),
      };
      secrets.forEach((name, secret) {
        expect(_indexOf(bytes, secret), -1, reason: '$name is in the proof');
      });
    });

    test('Nothing secret in a refusal', () async {
      final refusals = <Refusal>[];
      void keep(Refusal? r) {
        if (r != null) refusals.add(r);
      }

      keep((await buildPaying(600)).$2);
      keep((await buildPaying(300, expiry: now.subtract(const Duration(days: 1)))).$2);
      keep((await buildPaying(300, tip: 9)).$2);
      keep((await payeeChecker.check(standing, pkd: List<int>.filled(8, 3))).$2);
      final (proof, _) = PaymentProofs.short(
          note: NoteOpening.of(note32.note), round: 2, position: note32.position, path: path32);
      keep((await payeeChecker.check(proof!, pkd: walletAddr.pkd)).$2);
      keep(_refusalFrom(() => PaymentProof.decode(List<int>.filled(50, 9))));
      final (a, _) = await Acknowledgement.of(
          invoice: paidInvoice,
          payment: (await payeeChecker.check(standing, pkd: walletAddr.pkd)).$1!,
          ivk: fixtureWallet.ivk,
          minedAt: now);
      keep(await a!.check(await Invoice.issue(
          tokenId: pool.tokenId,
          ivk: fixtureWallet.ivk,
          address: walletAddr,
          amount: 1,
          expiry: soon,
          rng: Random(5))));

      expect(refusals.length, greaterThanOrEqualTo(6));
      final secrets = <String, List<int>>{
        'sk': lanesToBytes(fixtureWallet.sk),
        'ivk': lanesToBytes(fixtureWallet.ivk),
        'nk': lanesToBytes(fixtureWallet.nk),
        'ovk': lanesToBytes(fixtureWallet.ovk),
        'the note\'s rho': lanesToBytes(note32.note.rho),
        'the note\'s rcm': lanesToBytes(note32.note.rcm),
      };
      for (final r in refusals) {
        final text = r.toString();
        expect(text, isNotEmpty);
        secrets.forEach((name, secret) {
          expect(text, isNot(contains(hex.encode(secret))), reason: '$name in "$text"');
          expect(text, isNot(contains(shortHex(secret))), reason: '$name in "$text"');
        });
      }
      print('    ${refusals.length} refusals collected, none naming a key, a seed or a note\'s randomness');
    });

    test('State after a failed check', () async {
      final store = NoteStore(shape);
      final view = viewAt(2);
      final before = (notes: store.encode(), view: view.encode());

      for (final (what, proof, pkd) in <(String, PaymentProof, List<int>)>[
        ('another payee', standing, List<int>.filled(PoolHash.digestLanes, 5)),
        ('a bent path', _bendPath(standing), walletAddr.pkd),
      ]) {
        final (paid, why) = await payeeChecker.check(proof, pkd: pkd);
        expect(paid, isNull, reason: what);
        expect(why, isNotNull, reason: what);
        expect(store.length, 0, reason: 'the note is not added: $what');
      }
      expect(store.encode(), before.notes);
      expect(view.encode(), before.view);

      // and the same proof is still good for the payee it was for, so a retry
      // needs nothing repaired
      expect((await payeeChecker.check(standing, pkd: walletAddr.pkd)).$2, isNull);
    });
  });
}

PaymentProof _bendPath(PaymentProof p) {
  final bytes = List<int>.of(p.encode());
  bytes[2 + 4 + 4 + 8] ^= 1;
  return PaymentProof.decode(bytes);
}

int _indexOf(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return -1;
  for (int i = 0; i + needle.length <= haystack.length; i++) {
    var same = true;
    for (int k = 0; k < needle.length; k++) {
      if (haystack[i + k] != needle[k]) {
        same = false;
        break;
      }
    }
    if (same) return i;
  }
  return -1;
}

String _short(List<int> b) {
  const d = '0123456789abcdef';
  final s = StringBuffer();
  for (final x in b.take(8)) {
    s.write(d[(x >> 4) & 15]);
    s.write(d[x & 15]);
  }
  return '$s';
}

Refusal _refusalFrom(void Function() f) {
  try {
    f();
  } on Refusal catch (e) {
    return e;
  }
  fail('expected a refusal');
}
