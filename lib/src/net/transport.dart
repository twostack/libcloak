/// How frames reach the pool, as a port.
///
/// libcloak speaks tstokenlib's wallet-to-coordinator protocol and nothing
/// else: what goes over this port is a `PoolMessage`'s bytes, and what comes
/// back is too. The transport is opaque to the library — ricochet, a socket, a
/// queue, a test double — because the properties the wallet needs are in the
/// messages, not in the pipe: every frame is bounded and decoded as hostile
/// input, and nothing the wallet sends names anything it holds.
library;

/// One entry of the pool's feed: its sequence number and its bytes.
///
/// The feed is the same broadcast for every follower — a descriptor, then an
/// announcement a round — so reading it says nothing about the reader. The
/// sequence number is the pool's, and a client keeps the last one it read.
class FeedEntry {
  final int sequence;
  final List<int> bytes;
  const FeedEntry(this.sequence, this.bytes);
}

/// Why a transport call could not be made, carrying the transport's own
/// reason. A failure leaves the wallet's stored state unchanged; whether to
/// retry is the client's decision, not the transport's.
class TransportFailure implements Exception {
  final String call;
  final String reason;
  const TransportFailure(this.call, this.reason);
  @override
  String toString() => 'the transport failed on $call: $reason';
}

/// Send a frame and read the feed. That is the whole surface.
abstract interface class Transport {
  /// Sends [frame] to the pool and waits for its reply, for at most
  /// [timeout]. Throws [TransportFailure] when it cannot be sent, and when no
  /// reply arrives in time — which is not the same as a refusal, because a
  /// submission that was accepted may still be in a round.
  Future<List<int>> request(List<int> frame, {Duration timeout});

  /// Reads up to [max] feed entries from sequence [from] onward, in order.
  /// An empty list means the reader is at the end of the feed.
  Future<List<FeedEntry>> readFeed(int from, {int max});
}
