import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart'
    show
        Address,
        DefaultTransactionSigner,
        NetworkType,
        P2PKHLockBuilder,
        SVPublicKey,
        Transaction,
        TransactionInput,
        TransactionOutput,
        TransactionSigner;
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/testing.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'fakes.dart';

/// Money into the pool and back out, built the way a payment is built.
///
/// A deposit is two dummy inputs, BSV brought in and the depositor's note as
/// output 1, proved first and then backed by the covenant transaction the host
/// built from its commitment. A withdrawal is one real note in, BSV out to a
/// pubkey hash, and change back to the wallet. Both are checked against
/// tstokenlib's own rule for a transfer, and both are then put through
/// tstokenlib's own coordinator intake, opened at the fixture's round 1, to show
/// the pool would take what this library builds.
void main() {
  late PoolTestChain c;
  late PoolDescriptor pool;
  late PoolShape shape;
  late ShieldedRound round1;
  late List<int> br1, cm1;

  late PoolWalletKeys wallet;
  late NoteAddress walletAddr, depositAddr, changeAddr, strangerAddr;
  late ScannedNote note1;
  late List<List<int>> path1;
  final payTo = List<int>.generate(20, (i) => 0x40 + i);

  late ProvedDeposit proved;
  late Transaction covenant;
  late BuiltDeposit deposit;
  late BuiltWithdrawal withdrawal;
  late NoteStore withdrawalStore;

  // every refusal the builders produced, for the search for secrets at the end
  final refusals = <Refusal>[];
  Refusal seen(Refusal? r) {
    expect(r, isNotNull);
    refusals.add(r!);
    return r;
  }

  StarkParams spendP() => c.f.agg.spendP;

  NoteStore storeWith(ScannedNote n) {
    final s = NoteStore(shape);
    final (held, why) = s.takeChange(opening: NoteOpening.of(n.note), position: n.position, round: n.round);
    expect(why, isNull, reason: '$why');
    expect(held, isNotNull);
    return s;
  }

  PoolView viewAtRound1() {
    final v = PoolView.atGenesis(shape);
    expect(v.fold(1, br1, cmRoot: cm1), isNull);
    expect(v.track(round: 1, position: note1.position, leaf: BlockFold.lanesToBytes(note1.cm), path: path1).$2,
        isNull);
    return v;
  }

  /// A covenant transaction locking [satoshis] behind [commitment], against
  /// round 1's PP3, funded and signed by the fixture's published stranger key:
  /// what a host's transparent wallet builds with tstokenlib.
  Transaction covenantFor(List<int> commitment, int satoshis) {
    final depositor = PoolTestKeys.stranger.publicKey.toAddress(NetworkType.TEST);
    final coins = Transaction()
      ..addInputs([TransactionInput(hex.encode(List.filled(32, 0x31)), 0, 0xffffffff)])
      ..addOutputs([TransactionOutput(BigInt.from(10000), P2PKHLockBuilder.fromAddress(depositor).getScriptPubkey())]);
    return c.svc.createDepositTxn(
        fundingTx: coins,
        fundingVout: 0,
        fundingSigner: DefaultTransactionSigner(0x41, PoolTestKeys.stranger),
        fundingPubKey: PoolTestKeys.stranger.publicKey,
        changeAddress: depositor,
        commitment: commitment,
        satoshis: BigInt.from(satoshis),
        pp3Outpoint: c.svc.getOutpoint(c.r1.hash, outputIndex: 3),
        refundPKH: hex.decode(depositor.pubkeyHash160),
        refundAfter: 1000);
  }

  Future<(BuiltWithdrawal?, Refusal?)> withdraw(int amount,
      {NoteStore? store, List<int>? to, NoteAddress? change, PoolView? view, int tip = 1, int seed = 21}) {
    final notes = store ?? storeWith(note1);
    return WithdrawalBuilder.build(
        keys: wallet,
        note: notes.at(note1.position)!,
        notes: notes,
        amount: amount,
        payTo: to ?? payTo,
        changeAddress: change ?? changeAddr,
        view: view ?? viewAtRound1(),
        spendP: spendP(),
        tip: tip,
        rng: Random(seed));
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
    round1 = ledger.apply(c.r1, c.w1, c.y1.tx);
    br1 = List<int>.of(round1.blockRoot);
    cm1 = List<int>.of(ledger.header.cmRoot);

    wallet = c.f.wallet;
    walletAddr = await NoteAddress.derive(wallet.ivk, c.f.walletD);
    changeAddr = await NoteAddress.at(wallet.ivk, 1);
    depositAddr = await NoteAddress.at(wallet.ivk, 2);
    strangerAddr = await NoteAddress.at(PoolWalletKeys(List.filled(5, 7)).ivk, 0);
    final scanner = ShieldedNoteScanner.forWallet(wallet, [c.f.walletD]);
    note1 = (await scanner.scan(round1)).single;
    path1 = [for (final x in ledger.tree.path(note1.position).siblings) List<int>.of(x)];
    expect(note1.value, 500);

    final (p, whyProve) =
        await DepositBuilder.prove(keys: wallet, address: depositAddr, amount: 400, spendP: spendP(), rng: Random(20));
    expect(whyProve, isNull, reason: '$whyProve');
    proved = p!;
    covenant = covenantFor(proved.commitment, 400);
    final (d, whyBack) = proved.backedBy(covenant);
    expect(whyBack, isNull, reason: '$whyBack');
    deposit = d!;

    withdrawalStore = storeWith(note1);
    final (w, whyW) = await withdraw(300, store: withdrawalStore);
    expect(whyW, isNull, reason: '$whyW');
    withdrawal = w!;
  });

  group('building a deposit', () {
    test('A deposit on the fixture\'s pool', () async {
      final t = deposit.transfer;
      expect(t.refusal(), isNull, reason: 'the transfer is well formed on its own');
      expect(t.verifyProof(spendP()), isNull, reason: 'and its spend proof verifies');
      expect(t.publics.real1, isFalse);
      expect(t.publics.real2, isFalse);
      expect(t.publics.publicOut, -400, reason: 'money comes in');
      expect(t.isBsv, isTrue);

      // output 1 is the depositor's note, and it is what the covenant locks
      expect(BlockFold.lanesToBytes(t.publics.cmOut1), deposit.commitment);
      expect(t.receipt!.commitment, deposit.commitment);
      expect(t.receipt!.satoshis, BigInt.from(400));
      expect(deposit.outpoint, c.svc.getOutpoint(covenant.hash, outputIndex: ShieldedPoolTool.depositVout));
      expect(deposit.commitment, proved.commitment, reason: 'backing a proof does not change the note');

      // the depositor can read back its own note from the outgoing copy
      final mine = await NoteEncryption.decryptOutgoing(t.notes[0], wallet.ovk);
      expect(mine!.$1.value, 400);
      expect(mine.$2, depositAddr.pkd);
      final zero = await NoteEncryption.decryptOutgoing(t.notes[1], wallet.ovk);
      expect(zero!.$1.value, 0, reason: 'output 2 is a zero-value note');

      // the opening is what the store will take once the round is mined
      expect(deposit.note.value, 400);
      expect(BlockFold.lanesToBytes(deposit.note.plaintext.cmUnder(depositAddr.pkd)), deposit.commitment);

      print('    built a deposit: own work ${proved.ownWork.inMilliseconds} ms, '
          'spend proof ${proved.proving.inMilliseconds} ms, '
          'transfer ${t.encode(spendP()).length} bytes, covenant ${covenant.serialize().length ~/ 2} bytes');
      expect(proved.ownWork.inMilliseconds, lessThan(200), reason: 'everything but the STARK');
    });

    test('The transfer\'s shape is checked before it is sent', () {
      expect(DepositBuilder.check(deposit.transfer), isNull,
          reason: 'both inputs dummy, the asset BSV, money coming in');

      // a real input beside a deposit: the withdrawal's transfer, naming a covenant
      final w = withdrawal.transfer;
      final beside = ShieldedTransfer(w.publics, w.proof, w.bundle,
          withdrawal: w.withdrawal, depositOutpoint: deposit.outpoint);
      final why = seen(DepositBuilder.check(beside));
      expect(why.step, 'deposit');
      expect(why.reason, contains('real note beside a deposit'));

      // and a transfer that names no covenant is not a deposit
      final d = deposit.transfer;
      expect(seen(DepositBuilder.check(ShieldedTransfer(d.publics, d.proof, d.bundle))).step, 'deposit');
    });

    test('A covenant that is not this deposit\'s', () {
      final other = seen(proved.backedBy(covenantFor(List<int>.filled(32, 5), 400)).$2);
      expect(other.step, 'covenant');
      expect(other.reason, contains('commitment'));

      final more = seen(proved.backedBy(covenantFor(proved.commitment, 401)).$2);
      expect(more.step, 'covenant');
      expect(more.reason, contains('401'));
      expect(more.reason, contains('400'));

      final change = seen(proved.backedBy(covenant, vout: 0).$2);
      expect(change.reason, contains('not a deposit covenant'));
      final past = seen(proved.backedBy(covenant, vout: 5).$2);
      expect(past.reason, contains('has none at 5'));
    });

    test('The depositor finds its note in the mined round', () {
      // the fixture's own deposit, of 500 into the wallet's note, is what a
      // mined round with a receipt looks like; the flow for a built deposit
      // is the same with deposit.commitment and deposit.note
      final opening = NoteOpening.of(note1.note);
      final commitment = BlockFold.lanesToBytes(opening.plaintext.cmUnder(walletAddr.pkd));
      expect(commitment, c.f.receipt.commitment, reason: 'the receipt names the note\'s commitment');
      final at = PaymentProofs.positionOf(round1, commitment);
      expect(at, 0);
      final store = NoteStore(shape);
      final (held, why) = store.takeChange(opening: opening, position: at!, round: 1);
      expect(why, isNull);
      expect(held!.value, 500);
      expect(PaymentProofs.positionOf(round1, deposit.commitment), isNull, reason: 'ours is in no mined round');
    });

    test('A deposit\'s own refusals cost nothing', () async {
      final sw = Stopwatch()..start();
      for (final (amount, address, step) in [
        (0, depositAddr, 'amount'),
        (PoolHash.maxValue, depositAddr, 'amount'),
        (10, strangerAddr, 'address'),
      ]) {
        final (p, why) =
            await DepositBuilder.prove(keys: wallet, address: address, amount: amount, spendP: spendP());
        expect(p, isNull);
        expect(seen(why).step, step);
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(100), reason: 'no proof was computed');
    });
  });

  group('building a withdrawal', () {
    test('A withdrawal on the fixture\'s chain', () async {
      final t = withdrawal.transfer;
      expect(t.refusal(), isNull, reason: 'the transfer is well formed on its own');
      expect(t.verifyProof(spendP()), isNull, reason: 'and its spend proof verifies');
      expect(t.publics.publicOut, 300);
      expect(t.withdrawal!.satoshis, BigInt.from(300));
      expect(t.withdrawal!.pubkeyHash, payTo);
      expect(t.publics.outHash, PoolOutHash.transferLanes(t.bundleHash, withdrawal: t.withdrawal),
          reason: 'outHash commits to the withdrawal record');
      expect(withdrawal.anchor, cm1);
      expect(withdrawal.anchorRound, 1);
      expect(withdrawal.change.value, 200, reason: '500 spent, 300 out');

      final mine = await NoteEncryption.decryptOutgoing(t.notes[0], wallet.ovk);
      expect(mine!.$1.value, 200, reason: 'the change note is recoverable by the wallet');
      expect(mine.$2, changeAddr.pkd);
      expect(BlockFold.lanesToBytes(t.publics.cmOut1), withdrawal.changeCommitment);

      print('    built a withdrawal: own work ${withdrawal.ownWork.inMilliseconds} ms, '
          'spend proof ${withdrawal.proving.inMilliseconds} ms, '
          'transfer ${t.encode(spendP()).length} bytes');
      expect(withdrawal.ownWork.inMilliseconds, lessThan(200), reason: 'everything but the STARK');
    });

    test('The withdrawal and the public amount agree', () {
      expect(WithdrawalBuilder.check(withdrawal.transfer), isNull);
      final t = withdrawal.transfer;
      final swapped = ShieldedTransfer(t.publics, t.proof, t.bundle, withdrawal: PoolWithdrawal(payTo, BigInt.from(250)));
      final why = seen(WithdrawalBuilder.check(swapped));
      expect(why.step, 'withdrawal');
      expect(why.reason, contains('300'));
      expect(why.reason, contains('250'));
      expect(swapped.refusal()!.field, 'outHash',
          reason: 'tstokenlib\'s own check stops at outHash first, which is why libcloak compares the amounts');

      final none = seen(WithdrawalBuilder.check(ShieldedTransfer(t.publics, t.proof, t.bundle)));
      expect(none.step, 'withdrawal');
    });

    test('Withdrawing more than the note holds', () async {
      final sw = Stopwatch()..start();
      final (built, why) = await withdraw(600);
      sw.stop();
      expect(built, isNull);
      expect(seen(why).step, 'amount');
      expect(why!.reason, contains('600'));
      expect(why.reason, contains('500'));
      expect(sw.elapsedMilliseconds, lessThan(100), reason: 'no proof was computed');
    });

    test('A note already in flight', () async {
      final store = storeWith(note1);
      expect(store.reserve(store.at(note1.position)!), isNull);
      final sw = Stopwatch()..start();
      final (built, why) = await withdraw(300, store: store);
      sw.stop();
      expect(built, isNull);
      expect(seen(why).step, 'note');
      expect(why!.reason, contains('reserved'));
      expect(sw.elapsedMilliseconds, lessThan(100));
    });

    test('The request is checked first', () async {
      final sw = Stopwatch()..start();
      expect(seen((await withdraw(300, to: List.filled(19, 1))).$2).step, 'payTo');
      expect(seen((await withdraw(0)).$2).step, 'amount');
      expect(seen((await withdraw(300, change: strangerAddr)).$2).step, 'address');
      final behind = seen((await withdraw(300, tip: 9)).$2);
      expect(behind.step, 'behind');
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(4 * 100), reason: 'four refusals, no proof');
    });
  });

  group('submitting', () {
    late NoteStore store;
    late BuiltWithdrawal w;

    Future<CoordinatorClient> clientOn(FakeTransport t, {Duration? timeout}) async {
      final (client, why) =
          await CoordinatorClient.open(t, timeout: timeout ?? const Duration(milliseconds: 500));
      expect(why, isNull, reason: '$why');
      return client!;
    }

    setUp(() async {
      store = storeWith(note1);
      final (built, why) = await withdraw(300, store: store, seed: 31);
      expect(why, isNull);
      w = built!;
    });

    test('A withdrawal refused, and one accepted', () async {
      final t = FakeTransport(feed: [pool.encode()]);
      final client = await clientOn(t);
      t.answer = (frame) {
        final sub = PoolMessage.decode(frame) as PoolSubmission;
        return PoolReply.refused(sub.id, RefusalReason.balance, 'the pool is short').encode();
      };
      final refused = await client.submitWithdrawal(w, notes: store, rng: Random(1));
      expect(refused.outcome, Submitted.refused);
      expect(refused.refusal!.step, 'balance');
      expect(w.spent.state, NoteState.proven, reason: 'refused, so the note is released');

      t.answer = (frame) => PoolReply.accepted((PoolMessage.decode(frame) as PoolSubmission).id, 2).encode();
      final accepted = await client.submitWithdrawal(w, notes: store, rng: Random(2));
      expect(accepted.outcome, Submitted.accepted);
      expect(w.spent.state, NoteState.reserved);

      final again = await client.submitWithdrawal(w, notes: store, rng: Random(3));
      expect(again.outcome, Submitted.unsent);
      expect(t.sent.length, 2, reason: 'the third one never left the machine');
    });

    test('A withdrawal unanswered', () async {
      final t = FakeTransport(feed: [pool.encode()])..hold = true;
      final client = await clientOn(t, timeout: const Duration(milliseconds: 120));
      final outcome = await client.submitWithdrawal(w, notes: store, rng: Random(4));
      expect(outcome.outcome, Submitted.unanswered);
      expect(w.spent.state, NoteState.reserved,
          reason: 'it may be in a round, and releasing a note on a maybe is how a wallet double-spends itself');
    });

    test('A deposit goes with its covenant', () async {
      // the transport hands every frame to tstokenlib's own coordinator,
      // opened at the fixture's round 1
      final co = _coordinatorAtRound1(c);
      final t = FakeTransport(feed: [pool.encode()]);
      t.answer = (frame) => co.submitBytes(frame)!.encode();
      final client = await clientOn(t, timeout: const Duration(seconds: 10));

      final d = await client.submitDeposit(deposit, rng: Random(5));
      expect(d.outcome, Submitted.accepted, reason: '$d');
      expect(d.round, 2);
      final sent = PoolMessage.decode(t.sent.single) as PoolSubmission;
      expect(sent.depositTransaction()!.id, covenant.id, reason: 'the covenant went with the transfer');

      final x = await client.submitWithdrawal(w, notes: store, rng: Random(6));
      expect(x.outcome, Submitted.accepted, reason: '$x');
      expect(w.spent.state, NoteState.reserved);

      // and the coordinator refuses a second transfer backing the same covenant
      final twice = await client.submitDeposit(deposit, rng: Random(7));
      expect(twice.outcome, Submitted.refused);
      expect(twice.reason, RefusalReason.depositPending);
    });
  });

  group('the journal', () {
    test('A deposit and a withdrawal, each one thread', () async {
      // one accepted and one refused, as a coordinator answers them
      final t = FakeTransport(feed: [pool.encode()]);
      t.answer = (frame) {
        final sub = PoolMessage.decode(frame) as PoolSubmission;
        return sub.depositTx != null
            ? PoolReply.accepted(sub.id, 2).encode()
            : PoolReply.refused(sub.id, RefusalReason.nullifierSpent, 'the note is already spent').encode();
      };
      final (client, _) = await CoordinatorClient.open(t);
      final ok = (
        await client!.submitDeposit(deposit, rng: Random(8)),
        await client.submitWithdrawal(withdrawal, notes: withdrawalStore, rng: Random(9))
      );
      expect(ok.$1.outcome, Submitted.accepted);
      expect(ok.$2.outcome, Submitted.refused);
      expect(withdrawal.spent.state, NoteState.proven);
      final entries = [
        JournalEntry.depositBuilt(deposit),
        JournalEntry.depositAnswered(deposit, ok.$1),
        JournalEntry.withdrawalBuilt(withdrawal),
        JournalEntry.withdrawalAnswered(withdrawal, ok.$2),
      ];
      final read = [for (final e in entries) JournalEntry.decode(e.encode())];
      expect([for (final e in read) e.kind.number], [10, 11, 12, 13]);
      expect(read[0].invoiceId, deposit.threadId);
      expect(read[1].invoiceId, deposit.threadId);
      expect(read[2].invoiceId, withdrawal.threadId);
      expect(read[3].invoiceId, withdrawal.threadId);
      expect(deposit.threadId, isNot(withdrawal.threadId));
      expect(read[0].amount, 400);
      expect(read[0].reference, deposit.covenantTxid);
      expect(read[2].position, note1.position);
      expect(read[3].reason, 'nullifierSpent');
      expect(read[3].outcome, 'refused');

      final bytes = [for (final e in entries) ...e.encode()];
      for (final (name, secret) in [('sk', wallet.sk), ('ivk', wallet.ivk), ('ovk', wallet.ovk), ('nk', wallet.nk)]) {
        expect(_contains(bytes, _lanesLE(secret)), isFalse, reason: 'the journal carries no $name');
      }
    });

    test('Old entries still read', () {
      for (int n = 1; n <= 9; n++) {
        expect(JournalKind.of(n)!.number, n, reason: 'the nine kinds keep their numbers');
      }
      expect(JournalEntry.version, 1, reason: 'no field changed, so the version did not');
    });
  });

  group('untrusted input and secrets', () {
    test('Mutated covenant transactions', () {
      final rng = Random(2026);
      final real = hex.decode(covenant.serialize());
      final original = covenant.outputs[ShieldedPoolTool.depositVout];
      var backed = 0, refused = 0, unparsed = 0, otherTerms = 0;
      final steps = <String>{};
      for (int i = 0; i < 1000; i++) {
        final bytes = List<int>.of(real);
        final List<int> mutated;
        if (i % 4 == 3) {
          mutated = bytes.sublist(0, rng.nextInt(bytes.length));
        } else {
          for (int k = 0; k <= i % 3; k++) {
            final at = rng.nextInt(bytes.length);
            bytes[at] ^= 1 + rng.nextInt(255);
          }
          mutated = bytes;
        }
        final Transaction tx;
        try {
          tx = Transaction.fromHex(hex.encode(mutated));
        } catch (_) {
          unparsed++; // the host's parser said no, before this library saw anything
          continue;
        }
        final (d, why) = proved.backedBy(tx);
        if (d != null) {
          backed++;
          final out = tx.outputs[ShieldedPoolTool.depositVout];
          expect(out.satoshis, original.satoshis, reason: 'only a covenant locking this value backs the deposit');
          // the PP3, refund key and refund height are the host's choice and
          // the coordinator's to refuse; what the deposit rests on is the note
          expect(out.script.buffer.sublist(1, 33), proved.commitment,
              reason: 'only a covenant locking this note backs the deposit');
          if (!_contains(out.script.buffer, original.script.buffer)) otherTerms++;
        } else {
          refused++;
          expect(why!.step, isNotEmpty);
          steps.add(why.step);
        }
      }
      print('    1,000 mutated covenants: $backed backed ($otherTerms with other PP3 or refund terms), $refused refused '
          '($steps), $unparsed not transactions');
      expect(backed + refused + unparsed, 1000);
    });

    test('Nothing secret in a refusal', () {
      expect(refusals, isNotEmpty);
      final secrets = <(String, List<int>)>[
        ('sk', wallet.sk),
        ('ivk', wallet.ivk),
        ('ovk', wallet.ovk),
        ('nk', wallet.nk),
        ('rho', deposit.note.rho),
        ('rcm', deposit.note.rcm),
        ('rho', withdrawal.change.rho),
        ('rcm', withdrawal.change.rcm),
        ('rho', note1.note.rho),
        ('rcm', note1.note.rcm),
      ];
      for (final r in refusals) {
        final text = '$r';
        for (final (name, lanes) in secrets) {
          for (final l in lanes) {
            if (l < 1000) continue; // a small number is not a secret's fingerprint
            expect(text.contains('$l'), isFalse, reason: 'a refusal names a $name lane: $text');
            expect(text.contains(l.toRadixString(16).padLeft(8, '0')), isFalse, reason: 'a refusal names a $name lane');
          }
        }
      }
      print('    ${refusals.length} refusals searched for keys and note randomness');
    });
  });
}

List<int> _lanesLE(List<int> lanes) {
  final out = BytesBuilder();
  for (final l in lanes) {
    out.add([l & 0xff, (l >> 8) & 0xff, (l >> 16) & 0xff, (l >> 24) & 0xff]);
  }
  return out.toBytes();
}

bool _contains(List<int> hay, List<int> needle) {
  outer:
  for (int i = 0; i + needle.length <= hay.length; i++) {
    for (int j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// tstokenlib's own coordinator, opened at the fixture's round 1, so what the
/// builders make can be put through the pool's real intake: the transfer's own
/// rules, the ring, the nullifiers, the covenant, the balance and the proof.
ShieldedCoordinator _coordinatorAtRound1(PoolTestChain c) {
  final ledger = ShieldedLedger.open(ShieldedPoolLayout.of(c.f.agg.tree), c.r0, c.w0, c.y0.tx,
      tokenId: c.tokenId, genesisHeader: c.genesisHeader);
  ledger.apply(c.r1, c.w1, c.y1.tx);
  final signer = DefaultTransactionSigner(PoolTestKeys.sigHashAll, PoolTestKeys.op);
  final opPub = PoolTestKeys.op.publicKey;
  return ShieldedCoordinator(
      config: CoordinatorConfig(plan: c.f.agg),
      tool: ShieldedPoolTool(),
      ledger: ledger,
      funding: _Funding(signer, opPub, Address.fromPublicKey(opPub, NetworkType.TEST)),
      store: _Store(),
      publish: (_) async {},
      owner: signer,
      ownerPub: opPub,
      clock: FakeClock());
}

class _Funding implements CoordinatorFunding {
  final TransactionSigner signer;
  final SVPublicKey pubKey;
  final Address to;
  _Funding(this.signer, this.pubKey, this.to);

  @override
  Future<FundingOutput?> output(BigInt minValue) async => null;
}

class _Store implements CoordinatorStore {
  @override
  Future<void> roundBuilt(int number, Transaction y, Transaction round, Transaction witness, List<int> snapshot) async {}
}
