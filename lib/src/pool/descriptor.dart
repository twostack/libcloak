import 'package:tstokenlib/tstokenlib.dart';

import '../refusal.dart';

/// The pool's shape, which is the one number every path a wallet keeps rests
/// on: how many leaves a round appends.
///
/// Round N appends a fixed block of leaves and nothing else, so the block it
/// appends is the aligned subtree at level `log2(leaves)`, index N - 1. That
/// sentence is true only while the count is a power of two: at any other count
/// a round's leaves straddle two subtrees, a round owns no node, and following
/// the pool by one root a round is not a thing that can be done. So the refusal
/// below is not a tidiness check — it is the difference between the view
/// working and the view being nonsense.
///
/// The count comes from the pool's descriptor, which a wallet is given out of
/// band. A wallet checks the pool it is talking to still has the shape its
/// stored state was built under, rather than discovering the change at the
/// round where a path stops reaching the root.
class PoolShape {
  /// The commitment tree's depth, which is the pool's and not this library's:
  /// a spend proof walks exactly this many siblings.
  static const depth = PoolSpendAir.depth;

  /// A round has to leave at least one level of tree above its block, or
  /// there is nothing to follow.
  static const maxLeavesPerRound = 1 << (depth - 1);

  final int leavesPerRound;

  const PoolShape._(this.leavesPerRound);

  /// The shape of a pool that appends [leavesPerRound] leaves a round, or the
  /// refusal that stopped it.
  static (PoolShape?, Refusal?) of(int leavesPerRound) {
    if (leavesPerRound < 1 || leavesPerRound > maxLeavesPerRound) {
      return (
        null,
        Refusal('leavesPerRound', 'a round appends 1 to $maxLeavesPerRound leaves, not $leavesPerRound')
      );
    }
    if (leavesPerRound & (leavesPerRound - 1) != 0) {
      return (
        null,
        Refusal('leavesPerRound',
            'a round appends a power of two leaves, not $leavesPerRound: round N owns the aligned subtree at the '
            'block level only while that count is a power of two, and at $leavesPerRound a round owns no node at all')
      );
    }
    return (PoolShape._(leavesPerRound), null);
  }

  /// The shape [pool] publishes.
  static (PoolShape?, Refusal?) forPool(PoolDescriptor pool) => of(pool.leavesPerRound);

  /// log2 of [leavesPerRound]: the tree level whose nodes are whole rounds.
  /// Round N owns the node at this level, index N - 1.
  int get blockLevel => leavesPerRound.bitLength - 1;

  /// Levels of tree above the block level: what a follower folds through, and
  /// how many siblings of a note's path move after its own round is mined.
  int get upperLevels => depth - blockLevel;

  /// Rounds the pool can hold before its tree is full.
  int get maxRounds => 1 << upperLevels;

  /// The block a leaf at [position] is in, which is its round less one.
  int blockOf(int position) => position >> blockLevel;

  /// The first leaf of round [round]'s block.
  int firstLeafOf(int round) => (round - 1) << blockLevel;

  /// Why stored state built under [stored] leaves a round cannot be folded
  /// under this shape, naming both counts. Null when they agree.
  Refusal? sameSizeAs(int stored) {
    if (stored == leavesPerRound) return null;
    return Refusal('leavesPerRound',
        'this state was built under a pool appending $stored leaves a round and the pool now says $leavesPerRound; '
        'every path in it is aligned to the old block size and none of them would reach the new root');
  }

  @override
  String toString() => 'PoolShape($leavesPerRound leaves a round, block level $blockLevel, $upperLevels above)';
}
