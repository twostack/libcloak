/// Where block headers come from, as a port.
///
/// libcloak does not sync headers, check difficulty or open a socket. It is
/// handed something that answers three questions about blocks, and it asks
/// nothing else of the chain for the whole life of a wallet.
///
/// The narrowness is the privacy property, not a simplification. A port with
/// no method taking an address, an outpoint or a txid cannot be asked about
/// one, so a source — however curious, however logged — cannot learn what the
/// wallet holds from the questions it is asked. Every call names a height, a
/// block hash, or nothing at all, and a block hash the wallet asks about is one
/// that arrived inside a payment proof somebody handed it.
library;

/// Where the chain the source accepts currently ends.
class ChainTip {
  final int height;

  /// The block hash, in the display order a node prints it.
  final List<int> hash;
  const ChainTip(this.height, this.hash);

  @override
  String toString() => 'tip $height';
}

/// Why a header source could not answer. The [reason] is the source's own, and
/// is carried rather than replaced so a host can tell a timeout from a refusal.
class HeaderSourceFailure implements Exception {
  final String call;
  final String reason;
  const HeaderSourceFailure(this.call, this.reason);
  @override
  String toString() => 'the header source failed on $call: $reason';
}

/// The three questions libcloak asks about blocks.
///
/// An implementation answers from headers it holds and validated itself.
/// Returning null means "not on the chain I accept", which libcloak treats as
/// absent — never as provisional, and never as a reason to ask somebody else.
abstract interface class HeaderSource {
  /// Where the accepted chain ends. Used to turn a height into a number of
  /// confirmations.
  Future<ChainTip> tip();

  /// The height of [blockHash] on the accepted chain, or null when the source
  /// does not have it there. [blockHash] is in display order.
  Future<int?> heightOfBlock(List<int> blockHash);

  /// The 80-byte header at [height] on the accepted chain, or null when the
  /// source does not have it.
  Future<List<int>?> headerAtHeight(int height);
}
