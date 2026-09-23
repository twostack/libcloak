import 'package:tstokenlib/tstokenlib.dart';

import '../refusal.dart';
import 'descriptor.dart';
import 'frontier.dart';

/// One note's Merkle path, kept current.
///
/// A path splits in two at the block level, and the two halves have nothing in
/// common but the note they belong to.
///
/// The **lower** siblings — [PoolShape.blockLevel] of them — are the note's
/// company inside the block its own round appended. They were fixed the moment
/// that round was mined and they are never recomputed: no later round can
/// change a leaf inside a block that is already full.
///
/// The **upper** siblings follow the pool. A round appends one block, so at
/// most one of them changes a round, and which one is arithmetic on the block
/// index rather than anything the wallet has to be told.
///
/// The number that matters is [currentAt]: the round this path was last folded
/// through. A path that is not current is not a weaker path, it is a path to a
/// root that no longer exists, and the view refuses to spend it rather than
/// handing over something the pool will reject.
class TrackedNote {
  final PoolShape shape;

  /// The round that appended this note, which is [block] plus one. It is not
  /// a claim: a note's position decides its block, so a round that disagrees
  /// with the position is refused at [of].
  final int round;

  final int position;

  /// The note's commitment, in the 32 bytes a round's blob carries it in.
  final List<int> leaf;

  FoldedPath? _live;
  MerklePath? _stale;
  int _currentAt;

  TrackedNote._(this.shape, this.round, this.position, this.leaf, this._currentAt);

  /// A note the view can keep, or the refusal that stopped it. Every argument
  /// here came from outside — a payment proof, a stored file — so every one of
  /// them is checked before a hash is computed.
  static (TrackedNote?, Refusal?) of({
    required PoolShape shape,
    required int round,
    required int position,
    required List<int> leaf,
    required List<List<int>> path,
  }) {
    if (round < 1 || round > shape.maxRounds) {
      return (null, Refusal('round', 'a round is 1 to ${shape.maxRounds}, not $round'));
    }
    if (position < 0 || position >= (1 << PoolShape.depth)) {
      return (null, Refusal('position', '$position is not a leaf of a tree of depth ${PoolShape.depth}'));
    }
    if (shape.blockOf(position) != round - 1) {
      return (
        null,
        Refusal('position',
            'round $round appends leaves ${shape.firstLeafOf(round)} to ${shape.firstLeafOf(round + 1) - 1}, '
            'and leaf $position is in round ${shape.blockOf(position) + 1}\'s block')
      );
    }
    if (leaf.length != 32) return (null, Refusal('leaf', 'a commitment is 32 bytes, ${leaf.length} given'));
    try {
      BlockFold.bytesToLanes(leaf);
    } on ArgumentError {
      return (null, Refusal('leaf', 'the commitment holds a lane outside the field'));
    }
    if (path.length != PoolShape.depth) {
      return (null, Refusal('path', 'a path is ${PoolShape.depth} siblings, ${path.length} given'));
    }
    for (int i = 0; i < path.length; i++) {
      final s = path[i];
      if (s.length != PoolHash.digestLanes) {
        return (null, Refusal('path', 'sibling $i is ${s.length} lanes, a node is ${PoolHash.digestLanes}'));
      }
      for (final l in s) {
        if (l < 0 || l >= M31.p) return (null, Refusal('path', 'sibling $i holds a lane outside the field'));
      }
    }
    final note = TrackedNote._(shape, round, position, List<int>.unmodifiable(leaf), round);
    note._stale = MerklePath([for (final s in path) List<int>.unmodifiable(s)], position);
    return (note, null);
  }

  /// The block this note's leaf is in, which is [round] less one.
  int get block => shape.blockOf(position);

  /// The round this path was last folded through. A note is spendable only
  /// against the root of this round.
  int get currentAt => _currentAt;

  /// Whether the view is still folding rounds into this path.
  bool get maintained => _live != null;

  /// The path as it stands, leaf level first: the [PoolSpendAir.depth]
  /// siblings a spend proof consumes.
  MerklePath get path => _live?.path ?? _stale!;

  /// The siblings inside this note's own block, which never change.
  List<List<int>> get lower => path.siblings.sublist(0, shape.blockLevel);

  /// The siblings above the block level, which follow the pool.
  List<List<int>> get upper => path.siblings.sublist(shape.blockLevel);

  /// The commitment root this path reaches, 32 bytes. This is the whole of
  /// the note's evidence: a path that reaches a root the wallet proved off the
  /// chain is a path to a leaf that tree really holds, and no other path is.
  List<int> get reachedRoot =>
      BlockFold.lanesToBytes(PoolHash.root(BlockFold.bytesToLanes(leaf), path.siblings, position));

  /// The block root of this note's own round, computed from the note and the
  /// siblings inside its block.
  List<int> get blockRoot =>
      BlockFold.lanesToBytes(PoolHash.root(BlockFold.bytesToLanes(leaf), lower, position));

  /// The checkpoint this note's path is, as of [currentAt].
  ///
  /// A note's path already carries a frontier: its lower siblings give its
  /// block's root, and its upper siblings at the levels where the block index
  /// has a bit set are exactly the complete left subtrees a follower needs.
  /// So a wallet that is handed one verified path can fold from that round on
  /// without being given anything else — which is what makes a payment enough
  /// to resume on.
  Checkpoint get checkpoint {
    final m = block;
    final s = path.siblings;
    return Checkpoint(round: round, blockRoot: blockRoot, left: [
      for (int l = 0; l < shape.upperLevels; l++)
        if ((m >> l) & 1 == 1) BlockFold.lanesToBytes(s[shape.blockLevel + l])
    ]);
  }

  /// Hands this note to [frontier], which keeps it current from here on. The
  /// path must already be current at the frontier's round; the view checks
  /// that before it calls this.
  void attachTo(UpperFrontier frontier, {required int at}) {
    _live = frontier.follow(path);
    _stale = null;
    _currentAt = at;
  }

  /// The same for a path some other frontier brought forward.
  void adoptInto(UpperFrontier frontier, FoldedPath brought, {required int at}) {
    _live = frontier.adopt(brought);
    _stale = null;
    _currentAt = at;
  }

  /// Stops following: the path is frozen where it is, and stays readable, so
  /// the view can say what round it is current as of rather than losing it.
  void freeze(UpperFrontier frontier) {
    final live = _live;
    if (live == null) return;
    _stale = live.path;
    frontier.forget(live);
    _live = null;
  }

  /// Records that [frontier] has folded up to [round] into this path.
  void foldedTo(int round) {
    if (_live != null) _currentAt = round;
  }

  @override
  String toString() => 'TrackedNote(round $round, leaf $position, current at $_currentAt)';
}
