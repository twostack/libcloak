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

/// The wallet's record of what it promised, paid, proved and acknowledged.
///
/// The claim is that a person can answer "did I pay that?" and "was I paid?"
/// out of this directory and nothing else. So the tests are about a payment's
/// whole life reading as one thread, about a record that cannot quietly lose
/// or quietly change a line, and about what is *not* in it — no seed, no
/// spending key, no viewing key, and none of a note's randomness.
void main() {
  late PoolTestChain c;
  late PoolDescriptor pool;
  late PoolShape shape;
  late ShieldedRound round1, round2;
  late List<int> br1, br2, cm1, cm2;

  late PoolWalletKeys wallet;
  late NoteAddress walletAddr, changeAddr;
  late ScannedNote note1, note32;
  late List<List<int>> path1, path32;

  late FakeHeaderSource headers;
  late PaymentChecker checker;
  late FakeBlock block2;
  late List<int> round2Bytes, witness2Bytes;

  late Invoice invoice;
  late PaymentProof standing;
  late DateTime now, soon;

  late Directory root;

  Future<Journal> freshJournal([String name = 'j']) async {
    final path = '${root.path}${Platform.pathSeparator}$name${_unique++}';
    final (j, why) = await Journal.open(path);
    expect(why, isNull, reason: '$why');
    return j!;
  }

  NoteStore storeWith(ScannedNote n) {
    final s = NoteStore(shape);
    final (_, why) = s.takeChange(opening: NoteOpening.of(n.note), position: n.position, round: n.round);
    expect(why, isNull, reason: '$why');
    return s;
  }

  PoolView viewAt(int round) {
    final v = PoolView.atGenesis(shape);
    expect(v.fold(1, br1, cmRoot: cm1), isNull);
    expect(v.track(round: 1, position: note1.position, leaf: BlockFold.lanesToBytes(note1.cm), path: path1).$2,
        isNull);
    if (round >= 2) {
      expect(v.fold(2, br2, cmRoot: cm2), isNull);
      expect(v.track(round: 2, position: note32.position, leaf: BlockFold.lanesToBytes(note32.cm), path: path32).$2,
          isNull);
    }
    return v;
  }

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('libcloak_journal');
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
    walletAddr = await NoteAddress.derive(wallet.ivk, c.f.walletD);
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
    note32 = (await scanner.scan(round2)).single;
    path32 = [for (final x in ledger.tree.path(note32.position).siblings) List<int>.of(x)];

    headers = FakeHeaderSource.holding([
      crypto.sha256.convert([0]).bytes,
      hex.decode(c.w2.id),
    ], before: 3, after: 6);
    block2 = headers.blockOf(hex.decode(c.w2.id))!;
    round2Bytes = hex.decode(c.r2.serialize());
    witness2Bytes = hex.decode(c.w2.serialize());
    checker = PaymentChecker(pool: pool, headers: HeaderChecker(headers, confirmations: 6));

    now = DateTime.utc(2026, 9, 23, 12);
    soon = now.add(const Duration(days: 1));

    // the wallet asked for the 200 the fixture's round 2 paid it, at its own
    // address, and libcloak built a payment against the same invoice out of
    // the note round 1 left it. Both halves are real; they are two payments
    // at test parameters because the fixture mines two rounds and only one of
    // them can be the one libcloak built.
    invoice = await Invoice.issue(
        tokenId: pool.tokenId,
        ivk: wallet.ivk,
        address: walletAddr,
        amount: 200,
        expiry: soon,
        memo: 'a crate of oranges',
        id: List<int>.generate(Invoice.idLength, (i) => i),
        rng: Random(11));

    final (_, branch) = block2.branchFor(1);
    final (p, whyProof) = PaymentProofs.standing(
        note: NoteOpening.of(note32.note),
        round: 2,
        roundTx: round2Bytes,
        witnessTx: witness2Bytes,
        blockHash: block2.hash,
        txIndex: 1,
        branch: branch,
        position: note32.position,
        path: path32);
    expect(whyProof, isNull, reason: '$whyProof');
    standing = p!;
  });

  tearDownAll(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// A payment libcloak really built, with the store holding the note it
  /// spends: the two travel together because a submission reserves the note in
  /// the store it was built against, and no other.
  Future<(BuiltPayment, NoteStore)> buildIt() async {
    final store = storeWith(note1);
    final (built, why) = await PaymentBuilder.build(
        invoice: invoice,
        keys: wallet,
        changeAddress: changeAddr,
        note: store.at(note1.position)!,
        notes: store,
        view: viewAt(1),
        spendP: c.f.agg.spendP,
        tokenId: pool.tokenId,
        tip: 1,
        now: now,
        rng: Random(23));
    expect(why, isNull, reason: '$why');
    return (built!, store);
  }

  // ---- what is recorded ----

  test('One payment, one thread', () async {
    final payer = await freshJournal('payer');
    final payee = await freshJournal('payee');

    // 1. the payee asks
    await payee.add(JournalEntry.invoiceIssued(invoice, at: now));
    // 2. the payer is handed the invoice and builds against it
    await payer.add(JournalEntry.invoiceReceived(invoice, at: now));
    final (payment, store) = await buildIt();
    await payer.add(JournalEntry.paymentBuilt(payment, at: now));

    // 3. the payer submits, and the coordinator takes it
    final t = FakeTransport(feed: [pool.encode()]);
    t.answer = (frame) {
      final sub = PoolMessage.decode(frame) as PoolSubmission;
      return PoolReply.accepted(sub.id, 3).encode();
    };
    final (client, whyOpen) = await CoordinatorClient.open(t);
    expect(whyOpen, isNull);
    final answer = await client!.submit(payment, notes: store, rng: Random(24));
    expect(answer.outcome, Submitted.accepted);
    await payer.add(JournalEntry.paymentSubmitted(invoice, answer.id, at: now));
    await payer.add(JournalEntry.paymentAnswered(invoice, answer, at: now));

    // 4. the payer builds the proof and hands it over
    await payer.add(JournalEntry.proofBuilt(invoice, standing, at: now));

    // 5. the payee checks it and acknowledges
    final (checked, whyCheck) = await checker.check(standing, pkd: walletAddr.pkd);
    expect(whyCheck, isNull, reason: '$whyCheck');
    await payee.add(JournalEntry.proofChecked(invoice, payment: checked, at: now));
    final (ack, whyAck) = await Acknowledgement.of(
        invoice: invoice, payment: checked!, ivk: wallet.ivk, minedAt: now);
    expect(whyAck, isNull, reason: '$whyAck');
    await payee.add(JournalEntry.acknowledgementSent(invoice, ack!, at: now));

    // 6. the payer checks the acknowledgement and keeps it
    expect(await ack.check(invoice), isNull);
    await payer.add(JournalEntry.acknowledgementReceived(invoice, ack, at: now));

    final payerThread = await payer.thread(invoice.id);
    expect(payerThread.whole, isTrue, reason: '${payerThread.refused}');
    expect([for (final e in payerThread.entries) e.kind], [
      JournalKind.invoiceReceived,
      JournalKind.paymentBuilt,
      JournalKind.paymentSubmitted,
      JournalKind.paymentAnswered,
      JournalKind.proofBuilt,
      JournalKind.acknowledgementReceived,
    ]);
    expect([for (final e in payerThread.entries) e.sequence], [1, 2, 3, 4, 5, 6]);
    for (final e in payerThread.entries) {
      expect(e.invoiceId, invoice.id, reason: 'every entry names the invoice, which is what makes a thread');
    }

    final payeeThread = await payee.thread(invoice.id);
    expect([for (final e in payeeThread.entries) e.kind], [
      JournalKind.invoiceIssued,
      JournalKind.proofChecked,
      JournalKind.acknowledgementSent,
    ]);

    // and it reads as the story it is
    final answered = payerThread.entries[3];
    expect(answered.outcome, 'accepted');
    expect(answered.round, 3);
    final proved = payeeThread.entries[1];
    expect(proved.outcome, 'paid');
    expect(proved.amount, 200);
    expect(proved.position, note32.position);
    expect(proved.round, 2);
    for (final e in payerThread.entries) {
      print('payer $e');
    }
    for (final e in payeeThread.entries) {
      print('payee $e');
    }
  });

  test('A refusal is kept', () async {
    final j = await freshJournal('refused');
    final (payment, store) = await buildIt();
    await j.add(JournalEntry.invoiceReceived(invoice, at: now));
    await j.add(JournalEntry.paymentBuilt(payment, at: now));

    final t = FakeTransport(feed: [pool.encode()]);
    t.answer = (frame) {
      final sub = PoolMessage.decode(frame) as PoolSubmission;
      return PoolReply.refused(sub.id, RefusalReason.anchor, 'the anchor has left the ring').encode();
    };
    final (client, _) = await CoordinatorClient.open(t);
    final answer = await client!.submit(payment, notes: store, rng: Random(25));
    expect(answer.outcome, Submitted.refused);
    await j.add(JournalEntry.paymentSubmitted(invoice, answer.id, at: now));
    await j.add(JournalEntry.paymentAnswered(invoice, answer, at: now));

    final thread = (await j.thread(invoice.id)).entries;
    final answered = thread.last;
    expect(answered.kind, JournalKind.paymentAnswered);
    expect(answered.outcome, 'refused');
    expect(answered.reason, 'anchor',
        reason: 'the protocol\'s own name, in a field of its own, so the twelve can be counted');
    expect(answered.note, contains('left the ring'));

    // and the payment stays readable as unpaid: nothing in the thread says it
    // was paid, proved or acknowledged
    expect(thread.any((e) => e.outcome == 'accepted'), isFalse);
    expect(thread.any((e) => e.kind == JournalKind.proofBuilt), isFalse);
    expect(thread.any((e) => e.kind == JournalKind.acknowledgementReceived), isFalse);
  });

  test('Every one of the twelve refusals is recorded under its own name', () async {
    final j = await freshJournal('twelve');
    final (payment, store) = await buildIt();
    final t = FakeTransport(feed: [pool.encode()]);
    final (client, _) = await CoordinatorClient.open(t);

    for (final reason in RefusalReason.values) {
      t.answer = (frame) {
        final sub = PoolMessage.decode(frame) as PoolSubmission;
        return PoolReply.refused(sub.id, reason, 'the coordinator said ${reason.name}').encode();
      };
      final answer = await client!.submit(payment, notes: store, rng: Random(reason.number));
      expect(answer.outcome, Submitted.refused, reason: reason.name);
      final (stored, why) = await j.add(JournalEntry.paymentAnswered(invoice, answer, at: now));
      expect(why, isNull, reason: '$why');
      expect(stored!.reason, reason.name);
      expect(stored.outcome, 'refused');
    }
    final read = await j.read();
    expect(read.whole, isTrue);
    expect(read.entries.length, 12);
    expect({for (final e in read.entries) e.reason}, {for (final r in RefusalReason.values) r.name});
  });

  // ---- files, written whole ----

  test('An entry cut short', () async {
    final j = await freshJournal('cut');
    for (int i = 0; i < 5; i++) {
      await j.add(JournalEntry.invoiceIssued(invoice, at: now));
    }
    final victim = File(j.pathFor(3));
    final whole = victim.readAsBytesSync();
    victim.writeAsBytesSync(whole.sublist(0, whole.length - 9));

    final read = await j.read();
    expect(read.whole, isFalse);
    expect(read.refused.length, 1);
    expect(read.refused.single.reason, contains(victim.path), reason: 'it names the file');
    expect(read.entries.length, 4, reason: 'the other entries still read');
    expect([for (final e in read.entries) e.sequence], [1, 2, 4, 5]);
  });

  test('A leftover temporary file is not an entry and is not a fault', () async {
    final j = await freshJournal('tmp');
    await j.add(JournalEntry.invoiceIssued(invoice, at: now));
    File('${j.pathFor(2)}.tmp').writeAsBytesSync([1, 2, 3]);
    final read = await j.read();
    expect(read.whole, isTrue, reason: '${read.refused}');
    expect(read.entries.length, 1);
  });

  test('An entry removed from outside is reported', () async {
    final j = await freshJournal('gap');
    for (int i = 0; i < 4; i++) {
      await j.add(JournalEntry.invoiceIssued(invoice, at: now));
    }
    File(j.pathFor(2)).deleteSync();
    final read = await j.read();
    expect(read.whole, isFalse);
    expect(read.refused.single.step, 'missing');
    expect(read.refused.single.reason, contains('entry 2'));
    expect(read.entries.length, 3);
  });

  test('An entry in a file the name disagrees with', () async {
    final j = await freshJournal('renamed');
    await j.add(JournalEntry.invoiceIssued(invoice, at: now));
    await j.add(JournalEntry.invoiceIssued(invoice, at: now));
    File(j.pathFor(1)).renameSync(j.pathFor(3));
    final read = await j.read();
    expect(read.refused.any((r) => r.step == 'sequence'), isTrue);
    expect(read.refused.any((r) => r.step == 'missing'), isTrue, reason: 'entry 1 is gone too');
  });

  // ---- append only in effect ----

  test('A correction', () async {
    final j = await freshJournal('correction');
    await j.add(JournalEntry.invoiceIssued(invoice, at: now));

    // checked against a chain that has not got the block yet
    headers.fail = 'this wallet has no headers that far back';
    final (no, whyNo) = await checker.check(standing, pkd: walletAddr.pkd);
    headers.fail = null;
    expect(no, isNull);
    final (unproven, _) = await j.add(JournalEntry.proofChecked(invoice, refusal: whyNo, at: now));
    expect(unproven!.outcome, 'refused');

    // and again once the headers are there
    final (yes, whyYes) = await checker.check(standing, pkd: walletAddr.pkd);
    expect(whyYes, isNull, reason: '$whyYes');
    final (proved, _) =
        await j.add(JournalEntry.proofChecked(invoice, payment: yes, at: now).correcting(unproven));
    expect(proved!.outcome, 'paid');

    final thread = (await j.thread(invoice.id)).entries;
    expect(thread.length, 3, reason: 'both are present; nothing was rewritten');
    expect(thread[1].outcome, 'refused');
    expect(thread[1].corrects, 0);
    expect(thread[2].outcome, 'paid');
    expect(thread[2].corrects, thread[1].sequence, reason: 'the later names the earlier');
    expect(thread[2].isCorrection, isTrue);

    // what was believed at the time survives
    final onDisk = JournalEntry.decode(File(j.pathFor(thread[1].sequence)).readAsBytesSync());
    expect(onDisk.outcome, 'refused');
    expect(onDisk.reason, thread[1].reason);
  });

  test('A journal never rewrites an entry it has written', () async {
    final j = await freshJournal('noreplace');
    final (first, _) = await j.add(JournalEntry.invoiceIssued(invoice, at: now));
    final before = File(j.pathFor(1)).readAsBytesSync();
    for (int i = 0; i < 5; i++) {
      await j.add(JournalEntry.invoiceReceived(invoice, at: now));
    }
    expect(File(j.pathFor(1)).readAsBytesSync(), before);
    expect(first!.sequence, 1);
    expect(j.nextSequence, 7);
  });

  test('A journal reopened carries on where it stopped', () async {
    final j = await freshJournal('reopen');
    await j.add(JournalEntry.invoiceIssued(invoice, at: now));
    await j.add(JournalEntry.invoiceIssued(invoice, at: now));
    final (again, why) = await Journal.open(j.directory);
    expect(why, isNull);
    expect(again!.nextSequence, 3);
    final (stored, _) = await again.add(JournalEntry.invoiceIssued(invoice, at: now));
    expect(stored!.sequence, 3);
    expect((await again.read()).entries.length, 3);
  });

  // ---- secrets stay out ----

  test('Nothing secret in the journal', () async {
    final j = await freshJournal('secrets');
    final (payment, _) = await buildIt();
    await j.add(JournalEntry.invoiceIssued(invoice, at: now));
    await j.add(JournalEntry.invoiceReceived(invoice, at: now));
    await j.add(JournalEntry.paymentBuilt(payment, at: now));
    await j.add(JournalEntry.paymentSubmitted(invoice, List<int>.filled(16, 3), at: now));
    await j.add(JournalEntry.proofBuilt(invoice, standing, at: now));
    final (checked, _) = await checker.check(standing, pkd: walletAddr.pkd);
    await j.add(JournalEntry.proofChecked(invoice, payment: checked, at: now));
    final (ack, _) =
        await Acknowledgement.of(invoice: invoice, payment: checked!, ivk: wallet.ivk, minedAt: now);
    await j.add(JournalEntry.acknowledgementSent(invoice, ack!, at: now));

    final all = <int>[];
    for (final e in (await j.read()).entries) {
      all.addAll(e.encode());
    }
    expect(all.length, greaterThan(0));

    final secrets = <String, List<int>>{
      'the spending key': BlockFold.lanesToBytes(wallet.sk),
      'the incoming viewing key': BlockFold.lanesToBytes(wallet.ivk),
      'the outgoing viewing key': BlockFold.lanesToBytes(wallet.ovk),
      'the nullifier key': BlockFold.lanesToBytes(wallet.nk),
      'the spent note\'s rho': BlockFold.lanesToBytes(note1.note.rho),
      'the spent note\'s rcm': BlockFold.lanesToBytes(note1.note.rcm),
      'the paid note\'s rho': BlockFold.lanesToBytes(note32.note.rho),
      'the paid note\'s rcm': BlockFold.lanesToBytes(note32.note.rcm),
      'the change note\'s rho': BlockFold.lanesToBytes(payment.change.rho),
      'the change note\'s rcm': BlockFold.lanesToBytes(payment.change.rcm),
    };
    for (final e in secrets.entries) {
      expect(_holds(all, e.value), isFalse, reason: 'the journal holds ${e.key}');
    }

    // and a seeded wallet's seed, which is the one that unlocks everything
    final keys = WalletKeys(
        seed: WalletSeed.fromHex('f0e1d2c3b4a5968778695a4b3c2d1e0ff0e1d2c3b4a5968778695a4b3c2d1e0f'),
        birthday: 1);
    expect(_holds(all, keys.seed.bytes), isFalse);
    expect(_holds(all, BlockFold.lanesToBytes(keys.ivk)), isFalse);
  });

  test('The journal directory is the wallet\'s own', () async {
    final j = await freshJournal('mode');
    await j.add(JournalEntry.invoiceIssued(invoice, at: now));
    final mode = Directory(j.directory).statSync().mode & 0x1ff;
    expect(mode, 0x1c0, reason: 'owner-only (0700), so nobody else can even list the entries');
  });

  // ---- untrusted input and compatibility ----

  test('Mutated journal files', () async {
    final j = await freshJournal('mutate');
    final (payment, _) = await buildIt();
    final (checked, _) = await checker.check(standing, pkd: walletAddr.pkd);
    final samples = <JournalEntry>[
      JournalEntry.invoiceIssued(invoice, at: now),
      JournalEntry.paymentBuilt(payment, at: now),
      JournalEntry.paymentSubmitted(invoice, List<int>.filled(16, 9), at: now),
      JournalEntry.proofBuilt(invoice, standing, at: now),
      JournalEntry.proofChecked(invoice, payment: checked, at: now),
    ];
    for (final s in samples) {
      await j.add(s);
    }
    final originals = [for (int i = 1; i <= samples.length; i++) File(j.pathFor(i)).readAsBytesSync()];

    final rng = Random(31);
    var read = 0, refusedCount = 0, unnamed = 0;
    final steps = <String>{};
    for (int i = 0; i < 1000; i++) {
      final base = List<int>.of(originals[rng.nextInt(originals.length)]);
      final bent = switch (rng.nextInt(3)) {
        0 => base..[rng.nextInt(base.length)] ^= 1 << rng.nextInt(8),
        1 => base.sublist(0, rng.nextInt(base.length)),
        _ => [...base, for (int k = 0; k < 1 + rng.nextInt(40); k++) rng.nextInt(256)],
      };
      try {
        JournalEntry.decode(bent);
        read++;
      } on Refusal catch (e) {
        refusedCount++;
        if (e.step.isEmpty || e.reason.isEmpty) unnamed++;
        steps.add(e.step);
      } catch (e) {
        unnamed++;
        fail('an unnamed failure reading a mutated entry: $e');
      }
    }
    expect(unnamed, 0);
    expect(read + refusedCount, 1000);
    print('1,000 mutated entries: $read read, $refusedCount refused, '
        'steps ${(steps.toList()..sort()).join(', ')}');

    // and a directory of mutated files still reads the ones that are whole
    final dir = await freshJournal('mutatedir');
    for (int i = 0; i < originals.length; i++) {
      File(dir.pathFor(i + 1)).writeAsBytesSync(i == 2 ? originals[i].sublist(0, 12) : originals[i]);
    }
    final got = await dir.read();
    expect(got.refused.length, 1);
    expect(got.entries.length, originals.length - 1);
  });

  test('Unknown entry version', () async {
    final j = await freshJournal('version');
    await j.add(JournalEntry.invoiceIssued(invoice, at: now));
    final f = File(j.pathFor(1));
    final bytes = f.readAsBytesSync();
    bytes[0] = 9;
    f.writeAsBytesSync(bytes);

    final read = await j.read();
    expect(read.entries, isEmpty);
    expect(read.refused.single.step, 'version');
    expect(read.refused.single.reason, contains('9'), reason: 'it names the version');
    expect(read.refused.single.reason, contains(f.path), reason: 'and the file');
  });

  test('An unknown entry kind', () async {
    final j = await freshJournal('kind');
    await j.add(JournalEntry.invoiceIssued(invoice, at: now));
    final f = File(j.pathFor(1));
    final bytes = f.readAsBytesSync();
    bytes[1] = 77;
    f.writeAsBytesSync(bytes);
    final read = await j.read();
    expect(read.refused.single.step, 'kind');
    expect(read.refused.single.reason, contains('77'));
  });

  test('An entry past the bound is refused before it is read', () async {
    final j = await freshJournal('big');
    await j.add(JournalEntry.invoiceIssued(invoice, at: now));
    File(j.pathFor(1)).writeAsBytesSync(List<int>.filled(JournalEntry.maxEntry + 1, 1));
    final read = await j.read();
    expect(read.refused.single.step, 'size');
  });

  test('An entry round-trips, and a long memo is cut on a rune boundary', () async {
    final long = await Invoice.issue(
        tokenId: pool.tokenId,
        ivk: wallet.ivk,
        address: walletAddr,
        amount: 7,
        expiry: soon,
        memo: 'é' * 250,
        id: List<int>.generate(Invoice.idLength, (i) => 200 + i),
        rng: Random(33));
    final e = JournalEntry.invoiceIssued(long, at: now);
    final back = JournalEntry.decode(e.encode());
    expect(back.encode(), e.encode());
    expect(back.note, e.note);
    expect(back.at, e.at, reason: 'a time survives its own codec, in UTC');
    expect(back.note.endsWith('...'), isTrue);
    expect(back.note.contains('�'), isFalse, reason: 'never cut through a character');
  });

  test('A time written in local time comes back as the same instant', () async {
    final local = DateTime(2026, 9, 23, 14, 30);
    final e = JournalEntry.invoiceIssued(invoice, at: local);
    final back = JournalEntry.decode(e.encode());
    expect(back.at.isUtc, isTrue);
    expect(back.at, local.toUtc());
  });

  // ---- determinism, resources and failure ----

  test('Two wallets doing the same things write the same bytes', () async {
    final (payment, _) = await buildIt();
    final a = await freshJournal('detA');
    final b = await freshJournal('detB');
    final actions = <JournalEntry Function(DateTime)>[
      (t) => JournalEntry.invoiceReceived(invoice, at: t),
      (t) => JournalEntry.paymentBuilt(payment, at: t),
      (t) => JournalEntry.paymentSubmitted(invoice, List<int>.filled(16, 5), at: t),
      (t) => JournalEntry.proofBuilt(invoice, standing, at: t),
    ];
    for (final make in actions) {
      await a.add(make(now));
      await b.add(make(now.add(const Duration(hours: 3))));
    }
    final ea = (await a.read()).entries, eb = (await b.read()).entries;
    expect(ea.length, eb.length);
    for (int i = 0; i < ea.length; i++) {
      expect(ea[i].at, isNot(eb[i].at), reason: 'the timestamps differ, which is the one field allowed to');
      expect(_withoutTime(ea[i]), _withoutTime(eb[i]),
          reason: 'entry ${i + 1} differs in something other than its timestamp');
    }
  });

  test('Ten thousand entries', () async {
    final j = await freshJournal('tenk');
    final write = Stopwatch()..start();
    for (int i = 0; i < 10000; i++) {
      final (stored, why) = await j.add(JournalEntry.invoiceIssued(invoice, at: now));
      expect(why, isNull, reason: '$why');
      expect(stored!.sequence, i + 1);
    }
    write.stop();

    // The bound is on one core and `dart test` runs files in parallel, so this
    // is the best of fifteen: interference can only make a reading longer,
    // never shorter, so the minimum is the honest estimate of one core's cost.
    // Fifteen and not five because the first readings are contended by this
    // test's own writeback — ten thousand fsynced files ahead of them — and
    // the run has to be long enough for that to drain.
    var best = 0, worst = 0;
    JournalRead? read;
    for (int run = 0; run < 15; run++) {
      final w = Stopwatch()..start();
      read = await j.read();
      w.stop();
      final ms = w.elapsedMilliseconds;
      if (best == 0 || ms < best) best = ms;
      if (ms > worst) worst = ms;
    }
    expect(read!.whole, isTrue, reason: '${read.refused.take(3)}');
    expect(read.entries.length, 10000);
    expect(read.entries.first.sequence, 1);
    expect(read.entries.last.sequence, 10000);
    final size = read.entries.first.encode().length;
    print('10,000 entries: written in ${write.elapsedMilliseconds} ms, '
        'read in $best ms (best of 15, worst $worst), $size bytes an entry');
    expect(best, lessThan(1000));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('A write that fails', () async {
    final j = await freshJournal('readonly');
    for (int i = 0; i < 3; i++) {
      await j.add(JournalEntry.invoiceIssued(invoice, at: now));
    }
    final locked = await Process.run('chmod', ['500', j.directory]);
    expect(locked.exitCode, 0);
    try {
      final (stored, why) = await j.add(JournalEntry.paymentSubmitted(invoice, List<int>.filled(16, 1), at: now));
      expect(stored, isNull);
      expect(why!.step, 'write');
      expect(why.reason, contains('entry 4'), reason: 'the error names the entry');
      expect(why.reason, contains('paymentSubmitted'));
      expect(why.reason, contains(shortHex(invoice.id)));

      final read = await j.read();
      expect(read.whole, isTrue, reason: 'every earlier entry still reads');
      expect(read.entries.length, 3);
      expect(j.nextSequence, 4, reason: 'the sequence was not spent on an entry that was never written');
    } finally {
      await Process.run('chmod', ['700', j.directory]);
    }
  });

  test('A journal directory that cannot be read', () async {
    final j = await freshJournal('unreadable');
    await j.add(JournalEntry.invoiceIssued(invoice, at: now));
    await Process.run('chmod', ['000', j.directory]);
    try {
      final read = await j.read();
      expect(read.whole, isFalse);
      expect(read.refused.single.step, 'directory');
    } finally {
      await Process.run('chmod', ['700', j.directory]);
    }
  });
}

int _unique = 0;

/// Everything about an entry except when it was written.
List<int> _withoutTime(JournalEntry e) {
  final b = List<int>.of(e.encode());
  for (int i = 7; i < 15; i++) {
    b[i] = 0;
  }
  return b;
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
