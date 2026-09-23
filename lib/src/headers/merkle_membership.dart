import 'package:crypto/crypto.dart' as crypto;

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
    if (index >= (1 << branch.length)) {
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

  static List<int> _dsha(List<int> b) => crypto.sha256.convert(crypto.sha256.convert(b).bytes).bytes;
}
