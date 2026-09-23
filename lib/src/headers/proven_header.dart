import 'package:dartsv/dartsv.dart' show NetworkType;

import '../refusal.dart';
import 'header_source.dart';
import 'merkle_membership.dart';

/// A block header the wallet's own source vouches for, buried deep enough to
/// act on.
class ProvenHeader {
  final int height;

  /// Display order.
  final List<int> hash;

  /// The 80 bytes.
  final List<int> bytes;

  /// How many blocks deep it is, itself counting as one.
  final int confirmations;

  const ProvenHeader(this.height, this.hash, this.bytes, this.confirmations);

  /// The merkle root, display order.
  List<int> get merkleRoot => bytes.sublist(36, 68).reversed.toList();
}

/// Turns a block hash into a [ProvenHeader], or says why not.
///
/// A header counts as proven only when the source reports it on the chain the
/// source accepts, **and** the tip is far enough past it. A header the source
/// does not vouch for is absent, never provisional: there is no fallback to
/// asking somebody else, because asking somebody else about a block the wallet
/// cares about is the question this library does not ask.
class HeaderChecker {
  final HeaderSource source;

  /// Blocks deep before a payment counts as final; the block itself counts as
  /// one. One on regtest, where blocks are made to order, six elsewhere.
  final int confirmations;

  const HeaderChecker(this.source, {this.confirmations = 6});

  factory HeaderChecker.forNetwork(HeaderSource source, NetworkType network) =>
      HeaderChecker(source, confirmations: network == NetworkType.REGTEST ? 1 : 6);

  /// The proven header for [blockHash], or the check that refused it.
  ///
  /// Throws nothing: a source that fails comes back as a refusal naming the
  /// source's own reason, so a payee can tell "your proof is wrong" from "my
  /// node is down" and act differently.
  Future<(ProvenHeader?, Refusal?)> proven(List<int> blockHash) async {
    if (blockHash.length != 32) {
      return (null, Refusal('blockHash', 'a block hash is 32 bytes, ${blockHash.length} given'));
    }
    final int? height;
    final ChainTip tip;
    final List<int>? header;
    try {
      height = await source.heightOfBlock(blockHash);
      if (height == null) {
        return (
          null,
          Refusal('block', 'the header source does not have block ${shortHex(blockHash)} on the chain it accepts')
        );
      }
      header = await source.headerAtHeight(height);
      tip = await source.tip();
    } on HeaderSourceFailure catch (e) {
      return (null, Refusal('header source', e.reason));
    }
    if (header == null) {
      return (null, Refusal('block', 'the header source has no header at height $height'));
    }
    if (header.length != 80) {
      return (null, Refusal('header', 'the header at height $height is ${header.length} bytes, a header is 80'));
    }
    // the source is the wallet's own, and is still not taken at its word about
    // which header it handed back
    final got = MerkleMembership.hashOf(header);
    if (!_eq(got, blockHash)) {
      return (
        null,
        Refusal('header', 'the header at height $height hashes to ${shortHex(got)}, not ${shortHex(blockHash)}')
      );
    }
    final deep = tip.height - height + 1;
    if (deep < confirmations) {
      return (null, Refusal('confirmations', 'block $height has $deep of the $confirmations this wallet requires'));
    }
    return (ProvenHeader(height, blockHash, header, deep), null);
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
