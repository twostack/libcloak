import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../msg/codec.dart';
import '../refusal.dart';

/// Binding a transaction to a block, from the transaction's own bytes.
///
/// The payee is handed a transaction and a branch and told which block it is
/// in. It computes the txid itself — the double SHA-256 of the whole
/// serialisation — rather than taking one it was given, walks the branch, and
/// compares the result with the merkle root of a header its own source
/// vouches for. That is the whole of the payee's trust in the payer: none.
class MerkleMembership {
  /// The deepest branch read. A block of 2^64 transactions is past anything
  /// the chain can hold; the bound exists so a declared length cannot make a
  /// payee allocate.
  static const maxBranch = 64;

  /// The txid of [txBytes], in the display order a node prints it.
  static List<int> txidOf(List<int> txBytes) => _dsha(txBytes).reversed.toList();

  /// The merkle root that [branch] gives for the transaction at [index], in
  /// display order, or the refusal that stopped it.
  ///
  /// The branch nodes are in display order too, as a node's `getmerkleproof`
  /// prints them, and each is flipped to internal order before hashing —
  /// which is the one step everybody gets wrong once.
  static (List<int>?, Refusal?) rootFor({
    required List<int> txid,
    required int index,
    required List<List<int>> branch,
  }) {
    if (txid.length != 32) return (null, Refusal('txid', 'a txid is 32 bytes, ${txid.length} given'));
    if (index < 0) return (null, Refusal('index', '$index is not a position in a block'));
    if (branch.length > maxBranch) {
      return (null, Refusal('branch', 'declares ${branch.length} levels, at most $maxBranch'));
    }
    // a 64-level branch covers every index a 64-bit int can hold, and
    // `1 << 64` wraps to zero, so the comparison is only meaningful below 63
    if (branch.length < 63 && index >= (1 << branch.length)) {
      return (
        null,
        Refusal('index',
            'position $index is outside a block of ${1 << branch.length} transaction${branch.isEmpty ? '' : 's'}')
      );
    }
    for (int i = 0; i < branch.length; i++) {
      if (branch[i].length != 32) {
        return (null, Refusal('branch', 'node $i is ${branch[i].length} bytes, a node is 32'));
      }
    }
    var cur = txid.reversed.toList();
    var at = index;
    for (final sib in branch) {
      final other = sib.reversed.toList();
      cur = _dsha(at.isEven ? [...cur, ...other] : [...other, ...cur]);
      at >>= 1;
    }
    return (cur.reversed.toList(), null);
  }

  /// The merkle root [header] commits to, in display order.
  static (List<int>?, Refusal?) merkleRootOf(List<int> header) {
    if (header.length != 80) return (null, Refusal('header', 'a block header is 80 bytes, ${header.length} given'));
    return (header.sublist(36, 68).reversed.toList(), null);
  }

  /// The hash of [header], display order.
  static List<int> hashOf(List<int> header) => _dsha(header).reversed.toList();

  /// Whether [txBytes] really is the transaction [proof] places in a block
  /// whose header commits to [merkleRoot]. Null when it is.
  ///
  /// The txid is computed from [txBytes] and compared with the one [proof]
  /// declares, rather than taken from it. A proof that names one transaction
  /// and travels with another is refused **naming both**, which is the
  /// failure a person can actually act on: it says the bytes and the proof do
  /// not go together, not merely that a root did not match.
  static Refusal? confirm({
    required List<int> merkleRoot,
    required List<int> txBytes,
    required MerkleProof proof,
    List<int>? blockHash,
  }) {
    if (txBytes.isEmpty) return const Refusal('transaction', 'a transaction is at least one byte');
    if (blockHash != null && !_eq(blockHash, proof.blockHash)) {
      return Refusal('blockHash',
          'the proof is for block ${shortHex(proof.blockHash)} and the root given is block '
          '${shortHex(blockHash)}');
    }
    final computed = txidOf(txBytes);
    if (!_eq(computed, proof.txid)) {
      return Refusal('txid',
          'the transaction given hashes to ${shortHex(computed)} and the proof is for ${shortHex(proof.txid)}');
    }
    final (root, why) = rootFor(txid: computed, index: proof.txIndex, branch: proof.branch);
    if (root == null) return why;
    if (!_eq(root, merkleRoot)) {
      return Refusal('merkle proof',
          'transaction ${shortHex(computed)} at index ${proof.txIndex} reaches ${shortHex(root)}, '
          'and the block commits to ${shortHex(merkleRoot)}');
    }
    return null;
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static List<int> _dsha(List<int> b) => crypto.sha256.convert(crypto.sha256.convert(b).bytes).bytes;
}

/// A transaction's place in a block, written down.
///
/// A payment proof carries these fields inline, because it also carries the
/// transaction and the two travel as one message. This is the standalone,
/// versioned form — what a coordinator hands over on its own, and what a host
/// stores — and it exists so the merkle check has one implementation rather
/// than one per caller.
///
/// The [txid] is a **claim**, not evidence. [MerkleMembership.confirm] hashes
/// the transaction it was given and refuses if the two disagree, so a proof
/// cannot smuggle in a txid the bytes do not have.
class MerkleProof {
  /// Bumped when any field changes. An unknown version is refused, never
  /// guessed at.
  static const version = 1;
  static const kind = 1;

  /// A txid, a block hash, an index, a count, and at most
  /// [MerkleMembership.maxBranch] nodes.
  static const maxProof = 2 + 32 + 32 + 4 + 1 + MerkleMembership.maxBranch * 32;

  /// The transaction this is a proof for, display order. A claim.
  final List<int> txid;

  /// The block it says the transaction is in, display order.
  final List<int> blockHash;

  final int txIndex;

  /// The siblings, leaf level first, display order.
  final List<List<int>> branch;

  MerkleProof({
    required List<int> txid,
    required List<int> blockHash,
    required this.txIndex,
    required List<List<int>> branch,
  })  : txid = List<int>.unmodifiable(txid),
        blockHash = List<int>.unmodifiable(blockHash),
        branch = [for (final n in branch) List<int>.unmodifiable(n)] {
    if (txid.length != 32) throw ArgumentError('a txid is 32 bytes, ${txid.length} given');
    if (blockHash.length != 32) throw ArgumentError('a block hash is 32 bytes, ${blockHash.length} given');
    if (txIndex < 0 || txIndex > 0xffffffff) throw ArgumentError('a transaction index fits 32 bits');
    if (branch.length > MerkleMembership.maxBranch) {
      throw ArgumentError('a branch is at most ${MerkleMembership.maxBranch} deep, ${branch.length} given');
    }
    if (branch.any((n) => n.length != 32)) throw ArgumentError('a branch node is 32 bytes');
    if (branch.length < 63 && txIndex >= (1 << branch.length)) {
      throw ArgumentError('position $txIndex is outside a block of ${1 << branch.length}');
    }
  }

  /// The proof of the transaction whose bytes are [txBytes]: the txid is
  /// computed here rather than passed in, so this constructor cannot make a
  /// proof that names the wrong transaction.
  factory MerkleProof.of(List<int> txBytes,
          {required List<int> blockHash, required int txIndex, required List<List<int>> branch}) =>
      MerkleProof(
          txid: MerkleMembership.txidOf(txBytes), blockHash: blockHash, txIndex: txIndex, branch: branch);

  Uint8List encode() {
    final w = Writer(version, kind)
      ..bytes(txid)
      ..bytes(blockHash)
      ..u32(txIndex)
      ..byte(branch.length);
    for (final n in branch) {
      w.bytes(n);
    }
    return w.done();
  }

  /// The proof [bytes] hold, or a [Refusal] naming the field that stopped it.
  static MerkleProof decode(List<int> bytes) {
    final k = Reader.kindOf(bytes, version);
    if (k == null) {
      if (bytes.length < 2) throw const Refusal('size', 'a merkle proof is at least 2 bytes');
      throw Refusal('version', 'this library writes merkle proof version $version and does not read ${bytes[0]}');
    }
    if (k != kind) throw Refusal('kind', 'kind $k is not a merkle proof ($kind)');
    final r = Reader.open(bytes, version: version, kind: kind, max: maxProof, what: 'merkle proof');
    return Reader.guard(() {
      final txid = r.take('txid', 32);
      final blockHash = r.take('blockHash', 32);
      final txIndex = r.u32('txIndex');
      final levels = r.byte('branch');
      if (levels > MerkleMembership.maxBranch) {
        throw Refusal('branch', 'declares $levels levels, at most ${MerkleMembership.maxBranch}');
      }
      final branch = [for (int i = 0; i < levels; i++) r.take('branch', 32)];
      r.end('end', '%n bytes after the last field');
      if (levels < 63 && txIndex >= (1 << levels)) {
        throw Refusal('txIndex', 'position $txIndex is outside a block of ${1 << levels}');
      }
      return MerkleProof(txid: txid, blockHash: blockHash, txIndex: txIndex, branch: branch);
    });
  }
}
