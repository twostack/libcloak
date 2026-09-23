import 'dart:async';
import 'dart:typed_data';

import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:libcloak/libcloak.dart';
import 'package:pool_coordinator/pool_coordinator.dart' as co;

/// libcloak's [Transport] over a real ricochet client: the wallet's side of
/// the pipe the coordinator's side already speaks.
///
/// It is thirty lines because there is nothing in the port that needs more.
/// A frame goes to the coordinator's submissions folder; replies come back
/// from this identity's own replies folder; the feed is read by sequence
/// under the coordinator's peer id. Nothing here knows what a frame means —
/// the client decodes every one of them as hostile input, and matches a
/// reply to a submission **by id**, which is why this may hand back whichever
/// reply arrived.
class RicochetWalletTransport implements Transport {
  final co.RicochetTransport client;

  /// The coordinator's peer id, as its descriptor was published under.
  final String coordinator;

  /// Replies drained from the folder that were not the one a call was
  /// waiting for. The folder marks what it hands over as delivered, so a
  /// reply that is not kept here is a reply nobody will see again.
  final List<Uint8List> _spare = [];

  RicochetWalletTransport(this.client, this.coordinator);

  late final PeerId _owner = PeerId.fromString(coordinator);

  @override
  Future<List<int>> request(List<int> frame, {Duration timeout = const Duration(seconds: 30)}) async {
    try {
      await client.submit(coordinator, Uint8List.fromList(frame));
    } on co.TransportFailure catch (e) {
      throw TransportFailure('request', e.reason);
    }
    final deadline = DateTime.now().add(timeout);
    while (true) {
      if (_spare.isNotEmpty) return _spare.removeAt(0);
      final List<co.InboxMessage> got;
      try {
        got = await client.readReplies();
      } on co.TransportFailure catch (e) {
        throw TransportFailure('request', e.reason);
      }
      _spare.addAll([for (final m in got) m.payload]);
      if (_spare.isNotEmpty) continue;
      if (DateTime.now().isAfter(deadline)) {
        throw const TransportFailure('request', 'no reply arrived before the deadline');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  @override
  Future<List<FeedEntry>> readFeed(int from, {int max = 100}) async {
    try {
      // ricochet numbers a feed from 1 and libcloak asks from where it left
      // off, which is 0 before it has read anything
      final got = await client.feedOf(_owner, from < 1 ? 1 : from, limit: max);
      return [for (final e in got) FeedEntry(e.sequence, e.content)];
    } on co.TransportFailure catch (e) {
      throw TransportFailure('readFeed', e.reason);
    }
  }

  Future<void> close() => client.close();
}
