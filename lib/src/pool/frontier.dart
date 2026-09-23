import 'dart:typed_data';

import 'package:tstokenlib/tstokenlib.dart';

import '../msg/codec.dart';
import '../refusal.dart';
import 'descriptor.dart';

/// Everything a follower needs to join a pool at a round and fold forward
/// from there: the round, that round's block root, and the complete left
/// subtrees above the block level.
///
/// One node per level where the block index has a bit set, so at most
/// [PoolShape.upperLevels] of them — 23 nodes, 736 bytes, at production
/// parameters, whatever the pool's age. That fixed size is the whole point:
/// joining a pool that has run for a year costs the same as joining one mined
/// yesterday.
///
/// Nothing in here is trusted and nothing in here is signed. A checkpoint is
/// accepted because the root it computes is the commitment root of a round the
/// wallet proved off the chain for itself; a frontier of some other tree
/// reaches some other root, and there is no way to make it reach this one. So
/// the server that hands a checkpoint over needs no trust and needs no key.
class Checkpoint {
  /// Bumped when any field changes. An unknown version is refused, never
  /// guessed at.
  static const version = 1;
  static const kind = 1;

  /// The round this stands at. Round N's block is index N - 1.
  final int round;

  /// Round [round]'s block root, 32 bytes.
  final List<int> blockRoot;

  /// The complete left subtrees above the block level, in level order.
  final List<List<int>> left;

  Checkpoint({required this.round, required List<int> blockRoot, required List<List<int>> left})
      : blockRoot = List<int>.unmodifiable(blockRoot),
        left = List<List<int>>.unmodifiable([for (final n in left) List<int>.unmodifiable(n)]) {
    if (round < 1) throw ArgumentError('a checkpoint stands at round 1 or more, not $round');
    if (blockRoot.length != 32) throw ArgumentError('a block root is 32 bytes, ${blockRoot.length} given');
    if (left.any((n) => n.length != 32)) throw ArgumentError('a frontier node is 32 bytes');
  }

  /// The nodes a checkpoint at [round] must carry: one per set bit of the
  /// block index, and no others.
  static int nodesFor(int round, int upperLevels) {
    var n = 0;
    final m = round - 1;
    for (int l = 0; l < upperLevels; l++) {
      if ((m >> l) & 1 == 1) n++;
    }
    return n;
  }

  /// The checkpoint where [ledger] stands, as a pool's own reader gives it.
  factory Checkpoint.of(({int round, List<int> blockRoot, List<List<int>> left}) frontier) =>
      Checkpoint(round: frontier.round, blockRoot: frontier.blockRoot, left: frontier.left);

  /// Bytes on the wire, which is the fixed nodes plus eleven of framing.
  static int encodedSize(int nodes) => 2 + 4 + 32 + 1 + 32 * nodes;

  Uint8List encode() {
    final w = Writer(version, kind)
      ..u32(round)
      ..bytes(blockRoot)
      ..byte(left.length);
    for (final n in left) {
      w.bytes(n);
    }
    return w.done();
  }

  /// The checkpoint [bytes] hold, or a [Refusal] naming the field.
  ///
  /// [shape] is needed before a byte is read: it says how many nodes a
  /// checkpoint for a given round has, and a count that does not match is a
  /// checkpoint of a differently shaped pool, not a long one.
  static Checkpoint decode(List<int> bytes, {required PoolShape shape}) {
    final max = encodedSize(shape.upperLevels);
    final k = Reader.kindOf(bytes, version);
    if (k == null) {
      if (bytes.length < 2) throw const Refusal('size', 'a checkpoint is at least 2 bytes');
      throw Refusal('version', 'this library writes checkpoint version $version and does not read ${bytes[0]}');
    }
    if (k != kind) throw Refusal('kind', 'kind $k is not a checkpoint ($kind)');
    final r = Reader.open(bytes, version: version, kind: kind, max: max, what: 'checkpoint');
    return Reader.guard(() {
      final round = r.u32('round');
      if (round < 1) throw Refusal('round', 'a checkpoint stands at round 1 or more, not $round');
      if (round > shape.maxRounds) {
        throw Refusal('round', 'round $round is past the ${shape.maxRounds} this pool\'s tree holds');
      }
      final blockRoot = r.take('blockRoot', 32);
      final count = r.byte('left');
      final want = nodesFor(round, shape.upperLevels);
      if (count != want) {
        throw Refusal('left', 'a checkpoint at round $round carries $want nodes above the block level, $count given');
      }
      final left = [for (int i = 0; i < count; i++) r.take('left', 32)];
      r.end('end', '%n bytes after the last node');
      return Checkpoint(round: round, blockRoot: blockRoot, left: left);
    });
  }
}

/// The tree above the block level, kept from one 32-byte root a round.
///
/// This is tstokenlib's [BlockFold] with libcloak's manners on it: every way
/// in takes bytes from somebody else, so every way out is a value or a
/// [Refusal] naming the step, and a refused fold leaves the frontier and every
/// path it is keeping exactly as they were.
class UpperFrontier {
  final PoolShape shape;
  BlockFold _block;

  UpperFrontier._(this.shape, this._block);

  /// A frontier at the pool's genesis, folding from round 1.
  factory UpperFrontier.atGenesis(PoolShape shape) => UpperFrontier._(shape, BlockFold(shape.leavesPerRound));

  /// A frontier standing where [checkpoint] says, or the refusal that stopped
  /// it. The root it reaches is not checked here — the caller checks it
  /// against a round it proved off the chain, which is the only check that
  /// means anything.
  static (UpperFrontier?, Refusal?) at(PoolShape shape, Checkpoint checkpoint) {
    if (checkpoint.round > shape.maxRounds) {
      return (
        null,
        Refusal('round', 'round ${checkpoint.round} is past the ${shape.maxRounds} this pool\'s tree holds')
      );
    }
    final want = Checkpoint.nodesFor(checkpoint.round, shape.upperLevels);
    if (checkpoint.left.length != want) {
      return (
        null,
        Refusal('left',
            'a checkpoint at round ${checkpoint.round} carries $want nodes above the block level, '
            '${checkpoint.left.length} given')
      );
    }
    try {
      return (
        UpperFrontier._(
            shape,
            BlockFold.at(
                leavesPerRound: shape.leavesPerRound,
                round: checkpoint.round,
                blockRoot: checkpoint.blockRoot,
                left: checkpoint.left)),
        null
      );
    } on ArgumentError catch (e) {
      return (null, Refusal('frontier', '${e.message}'));
    }
  }

  /// Rounds folded; the next block root expected is round `round + 1`'s.
  int get round => _block.rounds;

  /// The pool's commitment root after the last round folded, 32 bytes. The
  /// empty tree's root before anything has been folded.
  List<int> get cmRoot => _block.cmRoot;

  /// Leaves the pool holds after the rounds folded.
  int get size => _block.size;

  /// Where a new follower would be told to join, or null at the genesis.
  Checkpoint? get checkpoint => round == 0
      ? null
      : Checkpoint(round: round, blockRoot: _block.lastBlockRoot, left: _block.leftNodes);

  /// Folds round [round]'s [blockRoot], and with [cmRoot] checks the root it
  /// reaches against the one that round's pool header carries.
  ///
  /// Returns null when it folded. A refusal changes nothing: not the root, not
  /// the round, and not one sibling of one path being kept.
  ///
  /// Without [cmRoot] the fold is arithmetic and nothing more. That is a
  /// legitimate thing to do — a wrong block root anywhere in a run makes the
  /// root at the end of the run wrong, so a run can be checked once at its end
  /// instead of a round at a time — and it is [PoolView] that holds callers to
  /// checking it before a spend is built.
  Refusal? fold(int round, List<int> blockRoot, {List<int>? cmRoot}) {
    if (blockRoot.length != 32) {
      return Refusal('blockRoot', 'a block root is 32 bytes, ${blockRoot.length} given for round $round');
    }
    if (cmRoot != null && cmRoot.length != 32) {
      return Refusal('cmRoot', 'a commitment root is 32 bytes, ${cmRoot.length} given for round $round');
    }
    try {
      BlockFold.bytesToLanes(blockRoot);
    } on ArgumentError {
      return Refusal('blockRoot', 'the block root offered for round $round holds a lane outside the field');
    }
    if (round != _block.rounds + 1) {
      return Refusal('round',
          'this view stands at round ${_block.rounds}, so the next block root is round ${_block.rounds + 1}\'s and '
          'this one is for round $round; a round cannot be skipped, because the rounds between it and here hold '
          'the leaves this one sits on');
    }
    if (round > shape.maxRounds) {
      return Refusal('round', 'round $round is past the ${shape.maxRounds} this pool\'s tree holds');
    }
    try {
      _block.fold(round, blockRoot, cmRoot: cmRoot);
    } on FoldRefusal {
      return Refusal('cmRoot',
          'the block root offered for round $round does not fold to the commitment root round $round\'s header '
          'carries, so it is a root of some other tree and nothing was folded');
    }
    return null;
  }

  /// Keeps [path] current on every later fold, and returns the living copy.
  FoldedPath follow(MerklePath path) => _block.follow(path);

  /// The same for a path brought forward elsewhere.
  FoldedPath adopt(FoldedPath path) => _block.track(path);

  void forget(FoldedPath path) => _block.forget(path);

  /// A frontier of the same shape standing where this one does, following
  /// nothing. Used to bring one note's path forward without disturbing the
  /// paths this one is keeping.
  (UpperFrontier?, Refusal?) detachedAt(Checkpoint checkpoint) => at(shape, checkpoint);
}
