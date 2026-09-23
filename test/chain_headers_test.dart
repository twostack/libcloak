import 'dart:math';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dartsv/dartsv.dart' show NetworkType;
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/testing.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'fakes.dart';

/// The only place libcloak takes evidence from the chain.
///
/// Two claims are under test. The first is arithmetic: a transaction is bound
/// to a block by a branch the payee walks itself, from a txid the payee
/// computed itself, against a merkle root in a header the payee's own source
/// vouches for. The second is the privacy one, and it is the reason the port
/// has three methods: every question the wallet asks names a height or a block
/// hash, and the block hash is one that arrived inside a proof somebody handed
/// it. A source that logged every call would learn nothing it did not already
/// give away.
void main() {
  late PoolTestChain c;
  late PoolDescriptor pool;
  late FakeHeaderSource headers;
  late PaymentChecker checker;
  late PaymentProof good;
  late List<int> paidPkd;
  late FakeBlock witnessBlock;
  late int witnessIndex;

  /// A transaction that is in the witness's block but is not the witness.
  late List<int> neighbourTxid;

  setUpAll(() async {
    c = await PoolTestChain.build();
    pool = PoolDescriptor.forPool(
        network: NetworkType.TEST, issuance: c.r0, witness0: c.w0, slot0: c.y0.tx, plan: c.f.agg);

    final layout = ShieldedPoolLayout.forArities([2, 2], nullifierLevel: 1, receiptSlots: 2);
    final ledger = ShieldedLedger.open(layout, c.r0, c.w0, c.y0.tx, tokenId: c.tokenId, genesisHeader: c.genesisHeader);
    final round1 = ledger.apply(c.r1, c.w1, c.y1.tx);
    final scanner = ShieldedNoteScanner.forWallet(c.f.wallet, [c.f.walletD]);
    final note = (await scanner.scan(round1)).first;
    paidPkd = (await NoteAddress.derive(c.f.wallet.ivk, note.d)).pkd;

    neighbourTxid = crypto.sha256.convert([0]).bytes;
    headers = FakeHeaderSource.holding([
      neighbourTxid,
      hex.decode(c.w1.id),
      crypto.sha256.convert([1]).bytes,
    ], before: 3, after: 6);
    witnessBlock = headers.blockOf(hex.decode(c.w1.id))!;
    witnessIndex = 1;
    checker = PaymentChecker(pool: pool, headers: HeaderChecker(headers, confirmations: 6));

    final (_, branch) = witnessBlock.branchFor(witnessIndex);
    good = PaymentProof.standing(
        round: 1,
        roundTx: hex.decode(c.r1.serialize()),
        witnessTx: hex.decode(c.w1.serialize()),
        blockHash: witnessBlock.hash,
        txIndex: witnessIndex,
        branch: branch,
        position: note.position,
        path: ledger.tree.path(note.position).siblings,
        note: NoteOpening.of(note.note));
    headers.calls.clear();
  });

  setUp(() {
    headers.calls.clear();
    headers.fail = null;
  });

  List<int> witnessBytes() => hex.decode(c.w1.serialize());

  MerkleProof proofFor(int index) {
    final (_, branch) = witnessBlock.branchFor(index);
    return MerkleProof.of(
        index == witnessIndex ? witnessBytes() : List<int>.filled(4, index + 1),
        blockHash: witnessBlock.hash,
        txIndex: index,
        branch: branch);
  }

  group('a transaction is bound to a header by its merkle proof', () {
    test('The fixture\'s witness', () async {
      final (header, why) = await checker.headers.proven(witnessBlock.hash);
      expect(why, isNull);
      expect(header!.height, witnessBlock.height);
      expect(header.confirmations, 7, reason: 'six blocks after it, and itself');

      final proof = MerkleProof.of(witnessBytes(),
          blockHash: witnessBlock.hash, txIndex: witnessIndex, branch: witnessBlock.branchFor(witnessIndex).$2);
      expect(MerkleMembership.confirm(merkleRoot: header.merkleRoot, txBytes: witnessBytes(), proof: proof), isNull);
      expect(hex.encode(proof.txid), c.w1.id, reason: 'the txid is computed from the bytes, not taken from anyone');
      expect(header.merkleRoot, witnessBlock.merkleRoot);
    });

    test('the txid is computed from the bytes, so a proof cannot claim another one', () {
      final honest = MerkleProof.of(witnessBytes(),
          blockHash: witnessBlock.hash, txIndex: witnessIndex, branch: witnessBlock.branchFor(witnessIndex).$2);
      // the same branch, the same index, and a txid that is somebody else's
      final lying = MerkleProof(
          txid: neighbourTxid, blockHash: honest.blockHash, txIndex: honest.txIndex, branch: honest.branch);
      final why = MerkleMembership.confirm(
          merkleRoot: witnessBlock.merkleRoot, txBytes: witnessBytes(), proof: lying);
      expect(why, isNotNull);
      expect(why!.step, 'txid');
      expect(why.reason, contains(shortHex(MerkleMembership.txidOf(witnessBytes()))));
      expect(why.reason, contains(shortHex(neighbourTxid)));
    });

    test('A proof for another transaction', () async {
      // the neighbour's own proof, honest in every field, travelling with the
      // witness's bytes: both txids are named
      final neighbour = proofFor(0);
      final why = MerkleMembership.confirm(
          merkleRoot: witnessBlock.merkleRoot, txBytes: witnessBytes(), proof: neighbour);
      expect(why!.step, 'txid');
      expect(why.reason, contains(shortHex(MerkleMembership.txidOf(witnessBytes()))));
      expect(why.reason, contains(shortHex(neighbour.txid)));

      // and inside a payment proof, where the txid cannot disagree because the
      // transaction is carried, the same substitution shows up at the root
      final swapped = PaymentProof.standing(
          round: good.round,
          roundTx: good.roundTx!,
          witnessTx: good.witnessTx!,
          blockHash: good.blockHash!,
          txIndex: 0,
          branch: witnessBlock.branchFor(0).$2,
          position: good.position,
          path: good.path,
          note: good.note);
      final (paid, refusal) = await checker.check(swapped, pkd: paidPkd);
      expect(paid, isNull);
      expect(refusal!.step, 'merkle proof');
      expect(refusal.reason, contains(shortHex(witnessBlock.merkleRoot)));
    });

    test('an empty block, a single transaction block, and an index outside one', () {
      final only = FakeBlock(0, [neighbourTxid], List.filled(32, 0));
      final (_, branch) = only.branchFor(0);
      expect(branch, isEmpty);
      expect(MerkleMembership.rootFor(txid: neighbourTxid, index: 0, branch: branch).$1, only.merkleRoot);
      // a single-transaction block has exactly one position, and it is 0
      expect(MerkleMembership.rootFor(txid: neighbourTxid, index: 1, branch: branch).$2!.step, 'index');
      expect(MerkleMembership.rootFor(txid: neighbourTxid, index: 4, branch: [List.filled(32, 1)]).$2!.step, 'index');
    });
  });

  group('a proven header is one the wallet accepts', () {
    test('Not yet buried', () async {
      final shallow = FakeHeaderSource.holding([hex.decode(c.w1.id)], before: 2, after: 2);
      final strict = PaymentChecker(pool: pool, headers: HeaderChecker(shallow, confirmations: 6));
      final block = shallow.blockOf(hex.decode(c.w1.id))!;
      final (_, branch) = block.branchFor(0);
      final proof = PaymentProof.standing(
          round: good.round,
          roundTx: good.roundTx!,
          witnessTx: good.witnessTx!,
          blockHash: block.hash,
          txIndex: 0,
          branch: branch,
          position: good.position,
          path: good.path,
          note: good.note);
      final (paid, refusal) = await strict.check(proof, pkd: paidPkd);
      expect(paid, isNull);
      expect(refusal!.step, 'confirmations');
      expect(refusal.reason, contains('3'), reason: 'names what it has');
      expect(refusal.reason, contains('6'), reason: 'and what is required');

      // the same block, the same proof, under a rule that asks for three
      final lenient = PaymentChecker(pool: pool, headers: HeaderChecker(shallow, confirmations: 3));
      expect((await lenient.check(proof, pkd: paidPkd)).$2, isNull);
    });

    test('regtest asks for one confirmation, everything else for six', () {
      expect(HeaderChecker.forNetwork(headers, NetworkType.REGTEST).confirmations, 1);
      for (final n in [NetworkType.TEST, NetworkType.MAIN]) {
        expect(HeaderChecker.forNetwork(headers, n).confirmations, 6);
      }
    });

    test('A header the source does not know', () async {
      final absent = List.generate(32, (i) => i);
      final proof = PaymentProof.standing(
          round: good.round,
          roundTx: good.roundTx!,
          witnessTx: good.witnessTx!,
          blockHash: absent,
          txIndex: good.txIndex,
          branch: good.branch,
          position: good.position,
          path: good.path,
          note: good.note);
      final (paid, refusal) = await checker.check(proof, pkd: paidPkd);
      expect(paid, isNull);
      expect(refusal!.step, 'block');
      expect(refusal.reason, contains(shortHex(absent)), reason: 'names the block hash');

      // and it stops there. No second source, no retry, no asking anybody
      // else about a block this wallet cares about
      expect(headers.calls, ['heightOfBlock ${_hex(absent)}']);
    });

    test('a header the source hands back that does not hash to what was asked for', () async {
      // a source that answers heightOfBlock and then returns another height's
      // header: the wallet re-hashes what it is given, including its own
      final liar = _WrongHeaderSource(headers);
      final strict = HeaderChecker(liar, confirmations: 1);
      final (header, why) = await strict.proven(witnessBlock.hash);
      expect(header, isNull);
      expect(why!.step, 'header');
      expect(why.reason, contains('hashes to'));
    });
  });

  group('nothing is asked that names the wallet', () {
    test('Checking a payment asks only about blocks', () async {
      final (paid, refusal) = await checker.check(good, pkd: paidPkd);
      expect(refusal, isNull, reason: '$refusal');
      expect(paid, isNotNull);

      expect(headers.calls, isNotEmpty);
      final blockHashHex = _hex(good.blockHash!);
      for (final call in headers.calls) {
        expect(call, anyOf(equals('tip'), startsWith('heightOfBlock '), startsWith('headerAtHeight ')),
            reason: 'the port was asked something that is not about a block: $call');
        if (call.startsWith('heightOfBlock ')) {
          expect(call.substring('heightOfBlock '.length), blockHashHex,
              reason: 'the only block hash asked about is the one that arrived inside the proof');
        }
        if (call.startsWith('headerAtHeight ')) {
          expect(int.parse(call.substring('headerAtHeight '.length)), isA<int>());
        }
      }

      // nothing the wallet holds is mentioned anywhere in what was asked
      final secrets = <String, List<int>>{
        'the round txid': hex.decode(c.r1.id),
        'the witness txid': hex.decode(c.w1.id),
        'the payee pk_d': lanesToBytes(paidPkd),
        'the payee ivk': lanesToBytes(c.f.wallet.ivk),
      };
      final asked = headers.calls.join(' ');
      for (final entry in secrets.entries) {
        expect(asked, isNot(contains(_hex(entry.value))), reason: '${entry.key} was in a call');
      }
      expect(headers.calls.where((c) => c.startsWith('heightOfBlock ')), hasLength(1),
          reason: 'one block hash, asked about once');
    });

    test('a short proof asks the port nothing at all', () async {
      final folded = PaymentChecker(
          pool: pool,
          headers: HeaderChecker(headers, confirmations: 6),
          foldedRoot: (r) => null,
          foldedTo: () => 0);
      final short = PaymentProof.short(
          round: good.round, position: good.position, path: good.path, note: good.note);
      final (paid, refusal) = await folded.check(short, pkd: paidPkd);
      expect(paid, isNull);
      expect(refusal!.step, 'short proof');
      expect(headers.calls, isEmpty, reason: 'a short proof is checked against a root the payee already folded');
    });
  });

  group('untrusted input', () {
    test('Unknown proof version', () {
      final bytes = MerkleProof.of(witnessBytes(),
              blockHash: witnessBlock.hash, txIndex: witnessIndex, branch: witnessBlock.branchFor(witnessIndex).$2)
          .encode();
      expect(MerkleProof.decode(bytes).txIndex, witnessIndex);

      final wrong = bytes.toList()..[0] = 99;
      expect(
          () => MerkleProof.decode(wrong),
          throwsA(isA<Refusal>()
              .having((r) => r.step, 'step', 'version')
              .having((r) => r.reason, 'names the version', contains('99'))));

      final wrongKind = bytes.toList()..[1] = 42;
      expect(() => MerkleProof.decode(wrongKind),
          throwsA(isA<Refusal>().having((r) => r.step, 'step', 'kind')));
      expect(() => MerkleProof.decode(const [1]), throwsA(isA<Refusal>().having((r) => r.step, 'step', 'size')));
    });

    test('a header is refused unless it is 80 bytes', () {
      for (final n in [0, 79, 81, 160]) {
        final (root, why) = MerkleMembership.merkleRootOf(List.filled(n, 0));
        expect(root, isNull);
        expect(why!.step, 'header');
        expect(why.reason, contains('$n'));
      }
      expect(MerkleMembership.merkleRootOf(witnessBlock.header).$1, witnessBlock.merkleRoot);
    });

    test('a branch deeper than the bound is refused before it is walked', () {
      final deep = [for (int i = 0; i < MerkleMembership.maxBranch + 1; i++) List.filled(32, i)];
      expect(MerkleMembership.rootFor(txid: neighbourTxid, index: 0, branch: deep).$2!.step, 'branch');
      final declared = [1, 1, ...List.filled(32, 0), ...List.filled(32, 0), 0, 0, 0, 0, 200];
      expect(() => MerkleProof.decode(declared),
          throwsA(isA<Refusal>().having((r) => r.step, 'step', 'branch')));
    });

    test('Mutated proofs', () {
      final honest = MerkleProof.of(witnessBytes(),
          blockHash: witnessBlock.hash, txIndex: witnessIndex, branch: witnessBlock.branchFor(witnessIndex).$2);
      final encoded = honest.encode();
      final tx = witnessBytes();
      final root = witnessBlock.merkleRoot;
      final rng = Random(20260923);

      var refusedAtEncoding = 0, decoded = 0, admitted = 0, badHeaders = 0;
      for (int i = 0; i < 10000; i++) {
        // half the run mutates a serialized proof, half mutates the header
        // the root would have come from
        if (i.isEven) {
          final b = encoded.toList();
          switch (rng.nextInt(4)) {
            case 0:
              b[rng.nextInt(b.length)] ^= 1 << rng.nextInt(8);
            case 1:
              b[rng.nextInt(b.length)] = rng.nextInt(256);
            case 2:
              b.removeRange(rng.nextInt(b.length), b.length);
            case 3:
              b.addAll(List.generate(1 + rng.nextInt(8), (_) => rng.nextInt(256)));
          }
          MerkleProof read;
          try {
            read = MerkleProof.decode(b);
          } on Refusal catch (r) {
            expect(r.step, isNotEmpty);
            expect(r.reason, isNotEmpty);
            refusedAtEncoding++;
            continue;
          }
          decoded++;
          final why = MerkleMembership.confirm(
              merkleRoot: root, blockHash: witnessBlock.hash, txBytes: tx, proof: read);
          if (why == null) {
            // only an untouched proof may pass
            expect(read.encode(), encoded);
            admitted++;
          } else {
            expect(why.step, isNotEmpty);
            expect(why.reason, isNotEmpty);
          }
        } else {
          final h = witnessBlock.header.toList();
          switch (rng.nextInt(3)) {
            case 0:
              h[rng.nextInt(h.length)] ^= 1 << rng.nextInt(8);
            case 1:
              h.removeRange(rng.nextInt(h.length), h.length);
            case 2:
              h.addAll(List.generate(1 + rng.nextInt(4), (_) => rng.nextInt(256)));
          }
          final (mutated, why) = MerkleMembership.merkleRootOf(h);
          if (mutated == null) {
            expect(why!.step, 'header');
            badHeaders++;
            continue;
          }
          final stopped = MerkleMembership.confirm(merkleRoot: mutated, txBytes: tx, proof: honest);
          if (stopped == null) {
            // the only 80-byte mutation that can still hold the right root is
            // one that did not touch bytes 36..68
            expect(mutated, root);
          } else {
            expect(stopped.step, isNotEmpty);
            expect(stopped.reason, isNotEmpty);
          }
        }
      }
      expect(refusedAtEncoding + decoded, 5000);
      expect(refusedAtEncoding, greaterThan(0));
      expect(decoded, greaterThan(0));
      expect(badHeaders, greaterThan(0));
      print('  10,000 mutations: $refusedAtEncoding refused at the encoding, $decoded decoded '
          '($admitted unchanged and still confirmed), $badHeaders headers refused by length');
    });
  });

  group('resources and failure behaviour', () {
    test('Check cost', () {
      final txid = MerkleMembership.txidOf(witnessBytes());
      final branch = [for (int i = 0; i < 64; i++) crypto.sha256.convert([i]).bytes];
      final index = 0x5a5a5a5a5a5a5a5;
      expect(branch, hasLength(MerkleMembership.maxBranch));

      final proof = MerkleProof(txid: txid, blockHash: witnessBlock.hash, txIndex: 7, branch: branch.sublist(0, 32));
      expect(proof.branch, hasLength(32));

      // the walk itself, at the full 64 levels
      final (root, why) = MerkleMembership.rootFor(txid: txid, index: index, branch: branch);
      expect(why, isNull);
      expect(root, isNotNull);

      const runs = 200;
      final sw = Stopwatch()..start();
      for (int i = 0; i < runs; i++) {
        MerkleMembership.rootFor(txid: txid, index: index, branch: branch);
      }
      final each = sw.elapsedMicroseconds / runs / 1000;
      print('  a 64-level membership check: ${each.toStringAsFixed(3)} ms');
      expect(each, lessThan(5.0), reason: 'a 64-level check took $each ms');
    });

    test('The source is unavailable', () async {
      // the same proof that passes, against a port that is down
      headers.fail = 'the node refused the connection';
      final (paid, refusal) = await checker.check(good, pkd: paidPkd);
      expect(paid, isNull);
      expect(refusal!.step, 'header source');
      expect(refusal.reason, 'the node refused the connection',
          reason: 'the port\'s own reason is carried, so a payee can tell a bad proof from a down node');

      // nothing was kept: the checker holds no state, and the same proof is
      // accepted the moment the source answers again
      headers.fail = null;
      final (again, why) = await checker.check(good, pkd: paidPkd);
      expect(why, isNull);
      expect(again!.value, greaterThan(0));
    });
  });
}

/// A source that answers `heightOfBlock` honestly and then hands back the
/// wrong header, to show the wallet re-hashes what its own source gives it.
class _WrongHeaderSource implements HeaderSource {
  final FakeHeaderSource inner;
  _WrongHeaderSource(this.inner);

  @override
  Future<ChainTip> tip() => inner.tip();

  @override
  Future<int?> heightOfBlock(List<int> blockHash) => inner.heightOfBlock(blockHash);

  @override
  Future<List<int>?> headerAtHeight(int height) => inner.headerAtHeight(height + 1);
}

String _hex(List<int> b) {
  const d = '0123456789abcdef';
  final s = StringBuffer();
  for (final x in b) {
    s.write(d[(x >> 4) & 15]);
    s.write(d[x & 15]);
  }
  return '$s';
}
