import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dartsv/dartsv.dart';
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/testing.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'fakes.dart';
import 'support/node.dart';

/// **The gate.** Every payment proof this library will ever check rests on one
/// claim: that a mined witness spending a round's PP1 and PP2, with the pool's
/// tokenId in that PP1, places the round in the pool's own chain back to
/// genesis. If the claim is wrong, the payment proof is wrong and no amount of
/// careful encoding here helps.
///
/// The claim's strength is that PP1's round branch is the induction: it
/// rebuilds the round from its parent's raw bytes and refuses one the parent
/// did not produce, back to a create branch anchored to an outpoint that can
/// be spent once. A witness that was mined had that argument run over it by
/// the miners.
///
/// The claim's weakness is that a payee runs no script. It reads bytes. So the
/// attack is not against the covenant but against the reader: take a real
/// PP1's first 563 bytes — the owner, the tokenId, the verifier body hash, the
/// genesis header and a header of the forger's choosing — and put an ordinary
/// P2PKH body under them. Every field a reader looks up by offset is the
/// pool's. It spends on a signature, so it mines for the price of an ordinary
/// transaction, and the forger can then hand a payee a payment proof for a
/// pool state that never existed.
///
/// What must happen: the payee refuses, naming the step.
void main() {
  late PoolTestChain c;
  late PoolDescriptor pool;
  late PP1Fields identity;
  late FakeHeaderSource headers;
  late PaymentChecker checker;
  late ({NotePlaintext note, List<int> pkd, int position, MerklePath path}) paid;

  final forgerKey = SVPrivateKey.fromWIF('cRHYFwjjw2Xn2gjxdGw6RRgKJZqipZx7j8i64NdwzxcD6SezEZV5');
  final forgerAddr = Address.fromPublicKey(forgerKey.publicKey, NetworkType.TEST);

  /// The forgery: a real PP1's head over a body that spends on a signature.
  SVScript lookalike(SVScript real) => SVScript.fromByteArray([
        ...real.buffer.sublist(0, PP1SpScriptGen.scriptBodyStart),
        for (var i = 0; i < 5; i++) OpCodes.OP_DROP,
        ...P2PKHLockBuilder.fromAddress(forgerAddr).getScriptPubkey().buffer,
      ]);

  /// [tx] with output [vout]'s script replaced, every other byte the same.
  Transaction withOutputScript(Transaction tx, int vout, SVScript script) {
    final out = Transaction();
    for (final i in tx.inputs) {
      out.addInput(TransactionInput(i.prevTxnId, i.prevTxnOutputIndex, i.sequenceNumber,
          scriptBuilder: DefaultUnlockBuilder.fromScript(i.script ?? SVScript())));
    }
    for (int k = 0; k < tx.outputs.length; k++) {
      final o = tx.outputs[k];
      out.addOutput(TransactionOutput(o.satoshis, k == vout ? script : o.script));
    }
    return out;
  }

  /// A witness of the forger's own: funding, then the forged round's PP1 and
  /// PP2 where a real witness spends them.
  Transaction witnessFor(Transaction round) => Transaction()
    ..addInput(TransactionInput('11' * 32, 1, TransactionInput.MAX_SEQ_NUMBER))
    ..addInput(TransactionInput(round.id, PoolEvidence.pp1Vout, TransactionInput.MAX_SEQ_NUMBER))
    ..addInput(TransactionInput(round.id, PoolEvidence.pp2Vout, TransactionInput.MAX_SEQ_NUMBER))
    ..addOutputs([TransactionOutput(BigInt.one, P2PKHLockBuilder.fromAddress(forgerAddr).getScriptPubkey())]);

  /// A standing proof for [round] and [witness], with the witness placed in a
  /// block of [source] and the note [paid] describes.
  PaymentProof standingFor(Transaction round, Transaction witness, FakeHeaderSource source, {int? roundNumber}) {
    final block = source.blockOf(hex.decode(witness.id))!;
    final index = block.txids.indexWhere((t) => hex.encode(t) == witness.id);
    final (_, branch) = block.branchFor(index);
    return PaymentProof.standing(
        round: roundNumber ?? 1,
        roundTx: hex.decode(round.serialize()),
        witnessTx: hex.decode(witness.serialize()),
        blockHash: block.hash,
        txIndex: index,
        branch: branch,
        position: paid.position,
        path: paid.path.siblings,
        note: NoteOpening.of(paid.note));
  }

  setUpAll(() async {
    c = await PoolTestChain.build();
    pool = PoolDescriptor.forPool(
        network: NetworkType.TEST, issuance: c.r0, witness0: c.w0, slot0: c.y0.tx, plan: c.f.agg);
    identity = c.identity;

    // the wallet's note from round 1, and its path as the pool gave it
    final layout = ShieldedPoolLayout.forArities([2, 2], nullifierLevel: 1, receiptSlots: 2);
    final ledger = ShieldedLedger.open(layout, c.r0, c.w0, c.y0.tx, tokenId: c.tokenId, genesisHeader: c.genesisHeader);
    final round1 = ledger.apply(c.r1, c.w1, c.y1.tx);
    final scanner = ShieldedNoteScanner.forWallet(c.f.wallet, [c.f.walletD]);
    final found = await scanner.scan(round1);
    final note = found.first;
    final addr = await NoteAddress.derive(c.f.wallet.ivk, note.d);
    paid = (note: note.note, pkd: addr.pkd, position: note.position, path: ledger.tree.path(note.position));

    // the payee's own view of the chain: witness 1 in a block, buried
    headers = FakeHeaderSource.holding([
      crypto.sha256.convert([0]).bytes,
      hex.decode(c.w1.id),
      crypto.sha256.convert([1]).bytes,
    ], before: 3, after: 6);
    checker = PaymentChecker(pool: pool, headers: HeaderChecker(headers, confirmations: 6));
  });

  group('the control', () {
    test('a real payment on the fixture\'s chain is accepted, and reports the value', () async {
      final proof = standingFor(c.r1, c.w1, headers);
      final before = headers.calls.length;
      final (payment, why) = await checker.check(proof, pkd: paid.pkd);
      expect(why, isNull, reason: '$why');
      expect(payment!.value, paid.note.value);
      expect(payment.position, paid.position);
      expect(payment.round, 1);
      expect(payment.confirmations, greaterThanOrEqualTo(6));

      // and nothing was looked up but the block the proof itself named
      final asked = headers.calls.sublist(before);
      expect(asked.every((a) => a.startsWith('heightOfBlock') || a.startsWith('headerAtHeight') || a == 'tip'), isTrue,
          reason: 'the only calls are about blocks: $asked');
      final blockHash = hex.encode(proof.blockHash!);
      expect(asked.where((a) => a.startsWith('heightOfBlock')).every((a) => a.endsWith(blockHash)), isTrue,
          reason: 'and the only block asked about is the one inside the proof');
    });

    test('a note that is not the payee\'s fails at the commitment, not before', () async {
      final stranger = await NoteAddress.at(PoolWalletKeys(List.generate(5, (i) => i + 3)).ivk, 0);
      final (payment, why) = await checker.check(standingFor(c.r1, c.w1, headers), pkd: stranger.pkd);
      expect(payment, isNull);
      expect(why!.step, 'path', reason: 'a commitment under another key is simply not in the tree');
    });
  });

  group('ATTACK: a round with a forged lineage', () {
    late Transaction forgedRound, forgedWitness;
    late FakeHeaderSource forgedChain;

    setUpAll(() {
      forgedRound = withOutputScript(c.r1, PoolEvidence.pp1Vout, lookalike(c.r1.outputs[PoolEvidence.pp1Vout].script));
      forgedWitness = witnessFor(forgedRound);
      // the forger mines its own two transactions, so the payee's header
      // source really does vouch for the block: the attack is not about
      // headers
      forgedChain = FakeHeaderSource.holding([
        crypto.sha256.convert([7]).bytes,
        hex.decode(forgedWitness.id),
      ], before: 3, after: 6);
    });

    test('the forgery carries the pool\'s identity at every offset a reader looks at', () {
      final parsed = PP1SpLockBuilder.fromScript(forgedRound.outputs[PoolEvidence.pp1Vout].script);
      expect(parsed.tokenId, pool.tokenId, reason: 'the pool\'s own tokenId');
      expect(parsed.verifierBodyHash, identity.verifierBodyHash);
      expect(parsed.genesisHeader, pool.genesisHeader);
      expect(parsed.header!.encode(), c.f.h1.encode());
      // and it is 593 bytes where a real PP1 is 16,924
      expect(forgedRound.outputs[PoolEvidence.pp1Vout].script.buffer.length, lessThan(1000));
      expect(c.r1.outputs[PoolEvidence.pp1Vout].script.buffer.length, greaterThan(16000));
    });

    test('the payee refuses it, naming the step that caught it', () async {
      final forger = PaymentChecker(pool: pool, headers: HeaderChecker(forgedChain, confirmations: 6));
      final proof = standingFor(forgedRound, forgedWitness, forgedChain);

      // the block really is buried, and the witness really is in it
      final (header, whyHeader) = await HeaderChecker(forgedChain, confirmations: 6).proven(proof.blockHash!);
      expect(whyHeader, isNull);
      expect(header!.confirmations, greaterThanOrEqualTo(6));

      final (payment, why) = await forger.check(proof, pkd: paid.pkd);
      expect(payment, isNull, reason: 'a forged round must never be reported paid');
      expect(why!.step, 'PP1 is this pool\'s script');
      expect(why.reason, contains('not its body'));
      print('  the forgery is refused at: $why');
    });

    test('and the same forgery under a real witness fails one step earlier', () async {
      // swapping the PP1 changes the round's txid, so the pool's own witness
      // no longer spends it. The spend chain is a second, independent reason
      // this attack does not work; the body check is the one that has to hold
      // when the forger supplies both transactions.
      final proof = standingFor(forgedRound, c.w1, headers);
      final (payment, why) = await checker.check(proof, pkd: paid.pkd);
      expect(payment, isNull);
      expect(why!.step, 'witness spends PP1');
    });

    test('a forged round of a pool with another tokenId is refused at the tokenId', () async {
      // the other failure mode: not a forgery of this pool but a real pool of
      // somebody else's. The body check cannot catch that one and does not
      // have to; the tokenId does.
      final other = PoolDescriptor(
          network: NetworkType.TEST,
          issuance: pool.issuance,
          witness0: pool.witness0,
          slot0: pool.slot0,
          arities: pool.arities,
          nullifierLevel: pool.nullifierLevel,
          receiptSlots: pool.receiptSlots,
          spendP: pool.spendP,
          leavesPerRound: pool.leavesPerRound,
          tokenId: List<int>.generate(32, (i) => (i * 13 + 5) & 0xff),
          genesisHeader: pool.genesisHeader);
      final (payment, why) = await PaymentChecker(pool: other, headers: HeaderChecker(headers, confirmations: 6))
          .check(standingFor(c.r1, c.w1, headers), pkd: paid.pkd);
      expect(payment, isNull);
      expect(why!.step, 'tokenId');
    });
  });

  group('the proof itself', () {
    test('a standing proof round trips byte for byte, and two builds agree', () {
      final a = standingFor(c.r1, c.w1, headers), b = standingFor(c.r1, c.w1, headers);
      expect(a.encode(), b.encode(), reason: 'the same payment built twice is the same bytes');
      final back = PaymentProof.decode(a.encode());
      expect(back.form, ProofForm.standing);
      expect(back.encode(), a.encode());
      expect(back.position, a.position);
      expect(back.note.value, paid.note.value);
      print('  a standing proof at test parameters is ${a.encode().length} bytes');
      expect(a.encode().length, lessThan(1024 * 1024));
    });

    test('a short proof carries no commitment root, and is refused if one is appended', () {
      final short = PaymentProof.short(
          round: 1, position: paid.position, path: paid.path.siblings, note: NoteOpening.of(paid.note));
      final bytes = short.encode();
      expect(PaymentProof.decode(bytes).form, ProofForm.short);
      print('  a short proof is ${bytes.length} bytes');
      expect(bytes.length, lessThan(4096));
      expect(
          () => PaymentProof.decode([...bytes, ...List.filled(32, 7)]),
          throwsA(isA<Refusal>()
              .having((r) => r.step, 'step', 'cmRoot')
              .having((r) => r.reason, 'reason', contains('no evidence for'))));
    });

    test('a payee that does not follow the pool refuses a short proof and asks for the standing form', () async {
      final short = PaymentProof.short(
          round: 1, position: paid.position, path: paid.path.siblings, note: NoteOpening.of(paid.note));
      final (payment, why) = await checker.check(short, pkd: paid.pkd);
      expect(payment, isNull);
      expect(why!.step, 'short proof');
      expect(why.reason, contains('standing form'));

      // and a payee that folded round 1 accepts the same bytes
      final follower = PaymentChecker(
          pool: pool,
          headers: HeaderChecker(headers, confirmations: 6),
          foldedRoot: (n) => n == 1 ? c.f.h1.cmRoot : null,
          foldedTo: () => 1);
      final before = headers.calls.length;
      final (ok, whyOk) = await follower.check(short, pkd: paid.pkd);
      expect(whyOk, isNull, reason: '$whyOk');
      expect(ok!.value, paid.note.value);
      expect(headers.calls.length, before, reason: 'a short proof asks the header source nothing at all');

      // a round it has not folded is refused, naming both
      final later = PaymentProof.short(
          round: 2, position: paid.position, path: paid.path.siblings, note: NoteOpening.of(paid.note));
      final (none, whyLater) = await follower.check(later, pkd: paid.pkd);
      expect(none, isNull);
      expect(whyLater!.reason, contains('round 2'));
      expect(whyLater.reason, contains('round 1'));
    });

    test('an unknown version, an unknown form and a huge declared length are refused before allocation', () {
      final bytes = standingFor(c.r1, c.w1, headers).encode();
      expect(() => PaymentProof.decode([...bytes]..[0] = 9),
          throwsA(isA<Refusal>().having((r) => r.step, 'step', 'version')));
      expect(() => PaymentProof.decode([...bytes]..[1] = 9), throwsA(isA<Refusal>().having((r) => r.step, 'step', 'kind')));
      expect(() => PaymentProof.decode(bytes.sublist(0, 1)), throwsA(isA<Refusal>()));

      // the round's declared length, at the first byte after the path and the
      // opening, claimed as 4 GB
      final at = 2 + 4 + 4 + PoolSpendAir.depth * 32 + NoteOpening.encodedSize;
      final huge = [...bytes];
      huge[at] = 0xff;
      huge[at + 1] = 0xff;
      huge[at + 2] = 0xff;
      huge[at + 3] = 0x7f;
      expect(
          () => PaymentProof.decode(huge),
          throwsA(isA<Refusal>()
              .having((r) => r.step, 'step', 'roundTx')
              .having((r) => r.reason, 'reason', contains('${PaymentProof.maxTx}'))));

      // and a proof this side could not decode is one it refuses to build:
      // an encoder that can produce undecodable output is a bug, not a
      // feature of the far end
      final real = standingFor(c.r1, c.w1, headers);
      expect(
          () => PaymentProof.standing(
              round: 1,
              roundTx: List.filled(PaymentProof.maxProof ~/ 2 + 1024, 0),
              witnessTx: List.filled(PaymentProof.maxProof ~/ 2 + 1024, 0),
              blockHash: real.blockHash!,
              txIndex: real.txIndex,
              branch: real.branch,
              position: real.position,
              path: real.path,
              note: real.note),
          throwsA(isA<ArgumentError>()
              .having((e) => e.message.toString(), 'message', contains('${PaymentProof.maxProof}'))));
    });

    test('nothing secret is in a proof', () {
      final bytes = standingFor(c.r1, c.w1, headers).encode();
      for (final (secret, name) in [
        (c.f.wallet.ivk, 'the payee\'s incoming viewing key'),
        (c.f.wallet.nk, 'the payee\'s nullifier key'),
      ]) {
        expect(_contains(bytes, _lanesBytes(secret)), isFalse, reason: 'a proof carries $name');
      }
    });
  });

  group('untrusted input', () {
    test('10,000 mutated and truncated proofs: a named refusal or a refused check, never a crash', () async {
      final seed = standingFor(c.r1, c.w1, headers).encode();
      final rng = _Rng(2609);
      var refused = 0, decoded = 0, paidCount = 0;
      for (int i = 0; i < 10000; i++) {
        final bytes = [...seed];
        for (int h = 0; h < 1 + rng.next(3); h++) {
          bytes[rng.next(bytes.length)] = rng.next(256);
        }
        if (rng.next(2) == 0) bytes.length = 2 + rng.next(bytes.length - 2);
        PaymentProof proof;
        try {
          proof = PaymentProof.decode(bytes);
          decoded++;
        } on Refusal {
          refused++;
          continue;
        }
        final (payment, why) = await checker.check(proof, pkd: paid.pkd);
        if (payment == null) {
          expect(why!.step, isNotEmpty);
        } else {
          // a mutation that leaves the round, the witness, the note and the
          // path untouched is the same payment; anything else must not pass
          expect(payment.value, paid.note.value);
          paidCount++;
        }
      }
      expect(refused + decoded, 10000);
      print('  10,000 mutations: $refused refused at the encoding, $decoded decoded, $paidCount still paid');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  group('ATTACK on localnet', () {
    test('the forged round and its witness are mined, and the payee still refuses', () async {
      final net = LocalNode();
      await net.ready();

      // Fund the forger and build the two transactions for real. The point of
      // mining them is that it costs two ordinary transactions: nothing about
      // this attack is expensive or exotic, and what stops it is the payee's
      // reader, not the chain.
      final funding = await net.fund(forgerAddr, BigInt.from(200000));
      final vout = funding.outputs.indexWhere((o) => _paysTo(o, hex.decode(forgerAddr.pubkeyHash160)));
      expect(vout, isNonNegative, reason: 'the node funded the forger');
      final signer = DefaultTransactionSigner(PoolTestKeys.sigHashAll, forgerKey);
      final forgedPP1 = lookalike(c.r1.outputs[PoolEvidence.pp1Vout].script);

      final round = (TransactionBuilder()
            ..spendFromTxnWithSigner(
                signer, funding, vout, TransactionInput.MAX_SEQ_NUMBER, P2PKHUnlockBuilder(forgerKey.publicKey))
            ..spendToPKH(forgerAddr, BigInt.from(190000)) // 0: change, and the witness's funding
            ..spendToLockBuilder(DefaultLockBuilder.fromScript(forgedPP1), BigInt.one) // 1: "PP1"
            ..spendToPKH(forgerAddr, BigInt.one) // 2: "PP2"
            ..withFee(BigInt.from(2000)))
          .build(false);
      await net.submit('round', round);

      final witness = (TransactionBuilder()
            ..spendFromTxnWithSigner(
                signer, round, 0, TransactionInput.MAX_SEQ_NUMBER, P2PKHUnlockBuilder(forgerKey.publicKey))
            ..spendFromTxnWithSigner(signer, round, PoolEvidence.pp1Vout, TransactionInput.MAX_SEQ_NUMBER,
                P2PKHUnlockBuilder(forgerKey.publicKey))
            ..spendFromTxnWithSigner(signer, round, PoolEvidence.pp2Vout, TransactionInput.MAX_SEQ_NUMBER,
                P2PKHUnlockBuilder(forgerKey.publicKey))
            ..spendToPKH(forgerAddr, BigInt.from(188000))
            ..withFee(BigInt.from(2000)))
          .build(false);
      await net.submit('witness', witness);

      // Both are on the chain, and a reader that parses by offset sees a round
      // of this pool with a witness spending its PP1 and PP2.
      final parsed = PP1SpLockBuilder.fromScript(round.outputs[PoolEvidence.pp1Vout].script);
      expect(parsed.tokenId, pool.tokenId);
      expect(parsed.genesisHeader, pool.genesisHeader);

      // The payee is handed a payment proof built from those mined bytes, with
      // the merkle branch the node itself gives for the witness.
      final (proof, source) = await net.proofFor(round, witness,
          roundNumber: 1, note: paid.note, position: paid.position, path: paid.path.siblings);
      final (header, whyHeader) = await HeaderChecker(source, confirmations: 1).proven(proof.blockHash!);
      expect(whyHeader, isNull, reason: 'the block really is on the chain: $whyHeader');
      expect(header!.merkleRoot, isNotNull);

      final (payment, why) = await PaymentChecker(pool: pool, headers: HeaderChecker(source, confirmations: 1))
          .check(proof, pkd: paid.pkd);
      expect(payment, isNull, reason: 'mined is not the same as this pool\'s');
      expect(why!.step, 'PP1 is this pool\'s script');
      print('  localnet: forged round ${round.id} (${hex.decode(round.serialize()).length} B, PP1 '
          '${round.outputs[PoolEvidence.pp1Vout].script.buffer.length} B) and witness ${witness.id} '
          '(${hex.decode(witness.serialize()).length} B) mined and refused at "${why.step}"');
    }, timeout: const Timeout(Duration(minutes: 5)));
  }, skip: Platform.environment['POOL_LOCALNET'] == '1' ? false : 'set POOL_LOCALNET=1');
}

bool _paysTo(TransactionOutput o, List<int> pkh) {
  final s = o.script.buffer;
  return s.length == 25 && s[0] == 0x76 && s[1] == 0xa9 && hex.encode(s.sublist(3, 23)) == hex.encode(pkh);
}

/// A small deterministic generator, so a failing mutation can be reproduced.
class _Rng {
  int _s;
  _Rng(this._s);
  int next(int n) {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s % n;
  }
}

List<int> _lanesBytes(List<int> lanes) =>
    [for (final l in lanes) ...[l & 0xff, (l >> 8) & 0xff, (l >> 16) & 0xff, (l >> 24) & 0xff]];

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
