import 'dart:io';
import 'dart:typed_data';

import 'package:tstokenlib/tstokenlib.dart';

import '../msg/codec.dart';
import '../refusal.dart';
import 'descriptor.dart';
import 'frontier.dart';
import 'note_path.dart';

/// The wallet's picture of the pool's commitment tree.
///
/// It holds the tree above the block level and one path per unspent note, and
/// that is all it holds. It is advanced by 32 bytes a round — the block root of
/// the round, the same bytes every wallet following this pool is given — and
/// what it folds is checked against the commitment root of a round the wallet
/// proved off the chain for itself. So the pool is a convenient place to get the
/// bytes from and never an authority about them: a wallet handed the same bytes
/// by a stranger reaches the same verdict, and a wallet that folded somebody's
/// wrong bytes finds out at the check and cannot spend until it does.
///
/// **It makes no requests.** There is no port here, no socket and no callback:
/// a view is pushed block roots by its host and asks nobody for anything. That
/// is the privacy property, and it is structural rather than a matter of care —
/// a class with nothing to call cannot leak which notes it holds by what it
/// asks for.
///
/// Two kinds of wallet come out of this. One holding no note joins at the head
/// from a [Checkpoint] — a fixed few hundred bytes, whatever the pool's age —
/// and never reads the rounds it missed. One holding a note pays 32 bytes a
/// round for as long as it holds it, because a note's upper siblings are made
/// of the blocks appended after its own and a checkpoint does not contain them.
class PoolView {
  /// Bumped when the stored state's fields change. An unknown version is
  /// refused, never guessed at.
  static const version = 1;
  static const kind = 1;

  /// Roots in the pool's ring: how many rounds a spend's anchor stays
  /// acceptable. The pool's own number, not this library's.
  static const ringEntries = PoolHeader.ringEntries;

  /// Notes one stored state carries. Well past what a wallet holds, and here
  /// so a declared count cannot make a reader allocate.
  static const maxNotes = 4096;

  /// What one note costs in a state file: its round, position, the round it
  /// is current at, whether it is being followed, its commitment and its path.
  static const noteSize = 4 + 4 + 4 + 1 + 32 + PoolShape.depth * 32;

  static const maxState =
      2 + 4 + 4 + 4 + 4 + 32 + 1 + PoolShape.depth * 32 + 1 + ringEntries * 32 + 4 + maxNotes * noteSize;

  final PoolShape shape;
  UpperFrontier _frontier;

  /// The first round this view folded. One from the genesis; the round after
  /// the checkpoint when it joined at one.
  int _foldedFrom;

  /// The last round whose root this view checked against a round it proved off
  /// the chain. Folding is arithmetic; this is the number that says how much of
  /// it is evidence.
  int _checkedTo;

  /// The block roots of the last [ringEntries] rounds, oldest first, so a path
  /// handed over a few rounds late can be brought forward. Beyond that there
  /// is no point keeping them: a note whose path is more than [ringEntries]
  /// rounds stale cannot be spent anyway, because its root has left the ring.
  final List<List<int>> _recent = [];

  final List<TrackedNote> _notes = [];
  final Map<int, TrackedNote> _atLeaf = {};

  PoolView._(this.shape, this._frontier, this._foldedFrom, this._checkedTo);

  /// A view at the pool's genesis, which folds every round from the first.
  factory PoolView.atGenesis(PoolShape shape) => PoolView._(shape, UpperFrontier.atGenesis(shape), 1, 0);

  /// A view joining the pool at [checkpoint], or the refusal that stopped it.
  ///
  /// [cmRoot] is the commitment root of that round's pool header, taken from a
  /// round the wallet proved off the chain. The checkpoint is accepted only
  /// when it computes that root, which it can only do by being the frontier of
  /// the tree that root commits to. Nothing is signed and nobody is trusted.
  static (PoolView?, Refusal?) atCheckpoint(PoolShape shape, Checkpoint checkpoint, {required List<int> cmRoot}) {
    final (frontier, why) = UpperFrontier.at(shape, checkpoint);
    if (frontier == null) return (null, why);
    if (cmRoot.length != 32) {
      return (null, Refusal('cmRoot', 'a commitment root is 32 bytes, ${cmRoot.length} given'));
    }
    if (!_eq(frontier.cmRoot, cmRoot)) {
      return (
        null,
        Refusal('checkpoint',
            'the frontier offered for round ${checkpoint.round} computes ${shortHex(frontier.cmRoot)} and round '
            '${checkpoint.round}\'s header commits to ${shortHex(cmRoot)}, so it is the frontier of some other tree')
      );
    }
    return (PoolView._(shape, frontier, checkpoint.round + 1, checkpoint.round), null);
  }

  /// The last round folded. Zero at the genesis.
  int get round => _frontier.round;

  /// The first round this view folded.
  int get foldedFrom => _foldedFrom;

  /// The pool's commitment root after the last round folded.
  List<int> get cmRoot => _frontier.cmRoot;

  /// Leaves the pool holds after the rounds folded.
  int get size => _frontier.size;

  /// Where this view would tell a new follower to join, or null at the
  /// genesis.
  Checkpoint? get checkpoint => _frontier.checkpoint;

  /// The notes being kept, in the order they were taken on.
  List<TrackedNote> get notes => List<TrackedNote>.unmodifiable(_notes);

  /// The note being kept at [position], or null. A wallet asks this for every
  /// note it holds each time it reads a balance, so it is a lookup and not a
  /// scan.
  TrackedNote? trackedAt(int position) => _atLeaf[position];

  /// Folds round [round]'s [blockRoot]: the 32 bytes, and nothing else about
  /// the round, that keep every path this view is keeping current.
  ///
  /// With [cmRoot] — the commitment root of that round's pool header, taken
  /// from a round the wallet proved off the chain — the fold is checked as it
  /// is made, and a root that does not match is refused naming the round with
  /// nothing changed.
  ///
  /// Without it the fold is arithmetic. That is not a hole and it is not a
  /// shortcut: a wrong block root anywhere in a run makes the root at the end
  /// of that run wrong too, so a wallet may fold a thousand rounds from
  /// anybody and [check] the root once at the end. What it may not do is
  /// **spend** from an unchecked fold, and [spendPath] is where that is
  /// enforced — a view says how far it has folded and how far it has checked,
  /// and those are two different numbers on purpose.
  Refusal? fold(int round, List<int> blockRoot, {List<int>? cmRoot}) {
    final why = _frontier.fold(round, blockRoot, cmRoot: cmRoot);
    if (why != null) return why;
    if (cmRoot != null) _checkedTo = round;
    _recent.add(List<int>.unmodifiable(blockRoot));
    if (_recent.length > ringEntries) _recent.removeRange(0, _recent.length - ringEntries);
    for (final n in _notes) {
      n.foldedTo(round);
    }
    return null;
  }

  /// Checks the root this view has folded to against [cmRoot], the commitment
  /// root of round [round]'s pool header from a round the wallet proved off the
  /// chain. Null when they agree, and then everything folded up to here is
  /// evidence rather than arithmetic.
  Refusal? check(int round, List<int> cmRoot) {
    if (round != _frontier.round) {
      return Refusal('round',
          'this view stands at round ${_frontier.round} and was offered round $round\'s commitment root; '
          'fold up to round $round before checking against it');
    }
    if (cmRoot.length != 32) {
      return Refusal('cmRoot', 'a commitment root is 32 bytes, ${cmRoot.length} given');
    }
    if (!_eq(_frontier.cmRoot, cmRoot)) {
      return Refusal('cmRoot',
          'this view folded to ${shortHex(_frontier.cmRoot)} and round $round\'s header commits to '
          '${shortHex(cmRoot)}; one of the block roots folded since round $_checkedTo was not this pool\'s');
    }
    _checkedTo = round;
    return null;
  }

  /// The last round whose root this view checked against a proven round.
  int get checkedTo => _checkedTo;

  /// Takes on a note whose path was verified against a round this view has
  /// already folded, and keeps it current from here on.
  ///
  /// The path is checked against a root this view computed itself: either the
  /// one it stands at, or — for a path a few rounds stale — the one it reaches
  /// after the retained block roots are folded into it. A path that does not
  /// reach it is refused and nothing is taken on.
  (TrackedNote?, Refusal?) track({
    required int round,
    required int position,
    required List<int> leaf,
    required List<List<int>> path,
  }) {
    final (note, why) = TrackedNote.of(shape: shape, round: round, position: position, leaf: leaf, path: path);
    if (note == null) return (null, why);
    if (round > _frontier.round) {
      return (
        null,
        Refusal('round',
            'this view stands at round ${_frontier.round} and the note is from round $round, which it has not '
            'folded; fold the rounds between, or resume from this payment if the view is keeping no other note')
      );
    }
    if (round == _frontier.round) {
      if (!_eq(note.reachedRoot, _frontier.cmRoot)) {
        return (null, _pathRefusal(note.reachedRoot, _frontier.cmRoot, round));
      }
      note.attachTo(_frontier, at: round);
      _keep(note);
      return (note, null);
    }
    // the path is current at an earlier round, so bring it forward through the
    // block roots this view kept, and check where it lands
    final behind = _frontier.round - round;
    if (behind > _recent.length) {
      final kept = _recent.isEmpty
          ? 'and has kept none'
          : 'and has kept rounds ${_frontier.round - _recent.length + 1} to ${_frontier.round}';
      return (
        null,
        Refusal('rounds',
            'bringing a path current at round $round forward needs the block roots of rounds ${round + 1} to '
            '${_frontier.round}; this view stands at round ${_frontier.round} $kept')
      );
    }
    final (detached, whyDetached) = _frontier.detachedAt(note.checkpoint);
    if (detached == null) return (null, whyDetached);
    final brought = detached.follow(note.path);
    for (int i = _recent.length - behind; i < _recent.length; i++) {
      final at = _frontier.round - _recent.length + 1 + i;
      final whyFold = detached.fold(at, _recent[i]);
      if (whyFold != null) return (null, whyFold);
    }
    if (!_eq(detached.cmRoot, _frontier.cmRoot)) {
      return (null, _pathRefusal(detached.cmRoot, _frontier.cmRoot, _frontier.round));
    }
    note.adoptInto(_frontier, brought, at: _frontier.round);
    _keep(note);
    return (note, null);
  }

  /// Resumes a view that stopped folding, from the path delivered with a
  /// payment, rather than from the rounds it skipped.
  ///
  /// A wallet holding no note has nothing whose freshness matters, so it is
  /// allowed to stop. When money arrives it arrives with a path, and a
  /// verified path is a frontier: it carries its block's root and the complete
  /// left subtrees above it. So the view restarts at that round for nothing.
  ///
  /// [cmRoot] is that round's commitment root from a round the wallet proved
  /// off the chain. A view keeping notes cannot do this, because a frontier
  /// says nothing about the rounds those notes' paths missed.
  (TrackedNote?, Refusal?) resume({
    required int round,
    required int position,
    required List<int> leaf,
    required List<List<int>> path,
    required List<int> cmRoot,
  }) {
    if (_notes.isNotEmpty) {
      return (
        null,
        Refusal('notes',
            'this view is keeping ${_notes.length} note${_notes.length == 1 ? '' : 's'}, and resuming at another '
            'round would leave ${_notes.length == 1 ? 'its' : 'their'} path stale; fold the rounds between instead')
      );
    }
    if (cmRoot.length != 32) {
      return (null, Refusal('cmRoot', 'a commitment root is 32 bytes, ${cmRoot.length} given'));
    }
    if (round < _frontier.round) {
      return (
        null,
        Refusal('round', 'this view stands at round ${_frontier.round}; resuming at round $round would go backwards')
      );
    }
    final (note, why) = TrackedNote.of(shape: shape, round: round, position: position, leaf: leaf, path: path);
    if (note == null) return (null, why);
    if (!_eq(note.reachedRoot, cmRoot)) return (null, _pathRefusal(note.reachedRoot, cmRoot, round));
    final (frontier, whyFrontier) = UpperFrontier.at(shape, note.checkpoint);
    if (frontier == null) return (null, whyFrontier);
    if (!_eq(frontier.cmRoot, cmRoot)) {
      return (
        null,
        Refusal('checkpoint',
            'the frontier this path carries computes ${shortHex(frontier.cmRoot)} and round $round\'s header '
            'commits to ${shortHex(cmRoot)}')
      );
    }
    _frontier = frontier;
    _foldedFrom = round + 1;
    _checkedTo = round;
    _recent.clear();
    note.attachTo(_frontier, at: round);
    _keep(note);
    return (note, null);
  }

  void _keep(TrackedNote note) {
    _notes.add(note);
    _atLeaf[note.position] = note;
  }

  /// Moves this view to [checkpoint], verified against [cmRoot].
  ///
  /// Every note the view was keeping is **frozen** where it stood, not brought
  /// forward: a checkpoint is a frontier, and a frontier does not contain the
  /// block roots a note's upper siblings are made of. A frozen note is kept and
  /// readable, and [spendPath] refuses it naming the first round that was never
  /// folded into it, which is the honest answer — the alternative is handing
  /// over a path to a root the pool no longer holds.
  Refusal? restoreTo(Checkpoint checkpoint, {required List<int> cmRoot}) {
    final (view, why) = atCheckpoint(shape, checkpoint, cmRoot: cmRoot);
    if (view == null) return why;
    for (final n in _notes) {
      n.freeze(_frontier);
    }
    _frontier = view._frontier;
    _foldedFrom = checkpoint.round + 1;
    _checkedTo = checkpoint.round;
    _recent.clear();
    return null;
  }

  /// Stops keeping [note] — it was spent, or it was never this wallet's.
  void forget(TrackedNote note) {
    note.freeze(_frontier);
    _notes.remove(note);
    if (identical(_atLeaf[note.position], note)) _atLeaf.remove(note.position);
  }

  /// How many more rounds may be mined before [note]'s anchor leaves the
  /// pool's ring, given the pool's [tip]. Zero or less means a spend built now
  /// would be refused by the pool.
  int roundsLeft(TrackedNote note, {required int tip}) => ringEntries - (tip - note.currentAt);

  /// Whether [spendPath] would yield a path for [note] at [tip].
  ///
  /// The same conditions, with no sentence built for the failing case. A
  /// wallet asks this once per note every time somebody looks at a balance, and
  /// a refusal nobody reads is a string nobody should have paid for.
  bool canSpend(TrackedNote note, {required int tip}) =>
      identical(_atLeaf[note.position], note) &&
      note.maintained &&
      note.currentAt == _frontier.round &&
      _checkedTo == _frontier.round &&
      tip >= _frontier.round &&
      tip - _frontier.round < ringEntries;

  /// The path a spend proof takes for [note], or the refusal that stopped it.
  ///
  /// Being behind is a reason to catch up, never a reason to build a proof the
  /// pool will refuse, so this says how far behind the view is and which rounds
  /// it needs rather than handing over a stale path.
  (MerklePath?, Refusal?) spendPath(TrackedNote note, {required int tip}) {
    if (!identical(_atLeaf[note.position], note)) {
      return (null, const Refusal('note', 'this view is not keeping that note'));
    }
    if (!note.maintained || note.currentAt != _frontier.round) {
      return (
        null,
        Refusal('rounds',
            'this note\'s path is current as of round ${note.currentAt} and this view stands at round '
            '${_frontier.round}; round ${note.currentAt + 1} was never folded into it, so the path it would yield '
            'reaches a root that is not this pool\'s')
      );
    }
    if (_checkedTo != _frontier.round) {
      return (
        null,
        Refusal('unchecked',
            'this view has folded to round ${_frontier.round} and last checked its root against a proven round at '
            'round $_checkedTo; a spend built on an unchecked fold is only as right as whoever sent the block '
            'roots, so prove round ${_frontier.round} and check it first')
      );
    }
    if (tip < _frontier.round) {
      return (
        null,
        Refusal('tip', 'this view stands at round ${_frontier.round} and was given a tip of round $tip, behind it')
      );
    }
    final behind = tip - _frontier.round;
    if (behind >= ringEntries) {
      return (
        null,
        Refusal('behind',
            'this view stands at round ${_frontier.round} and the pool\'s tip is round $tip, $behind rounds ahead; '
            'a spend anchors to one of the $ringEntries roots in the pool\'s ring, so fold the block roots for '
            'rounds ${_frontier.round + 1} to $tip first')
      );
    }
    return (note.path, null);
  }

  // ---- stored state ----
  //
  //   version, kind        1 + 1
  //   leaves a round       4
  //   round                4
  //   folded from          4
  //   checked to           4
  //   if round > 0:  block root 32, left count 1, nodes 32 each
  //   recent count 1, roots 32 each
  //   notes 4, then each: round 4, position 4, current at 4, followed 1,
  //                       commitment 32, path 32 siblings of 8 lanes

  Uint8List encode() {
    final w = Writer(version, kind)
      ..u32(shape.leavesPerRound)
      ..u32(_frontier.round)
      ..u32(_foldedFrom)
      ..u32(_checkedTo);
    final c = _frontier.checkpoint;
    if (c != null) {
      w
        ..bytes(c.blockRoot)
        ..byte(c.left.length);
      for (final n in c.left) {
        w.bytes(n);
      }
    }
    w.byte(_recent.length);
    for (final r in _recent) {
      w.bytes(r);
    }
    w.u32(_notes.length);
    for (final n in _notes) {
      w
        ..u32(n.round)
        ..u32(n.position)
        ..u32(n.currentAt)
        ..byte(n.maintained ? 1 : 0)
        ..bytes(n.leaf);
      for (final s in n.path.siblings) {
        w.lanes(s);
      }
    }
    return w.done();
  }

  /// The view [bytes] hold, or a [Refusal] naming the field that stopped it.
  static PoolView decode(List<int> bytes, {required PoolShape shape}) {
    final k = Reader.kindOf(bytes, version);
    if (k == null) {
      if (bytes.length < 2) throw const Refusal('size', 'a pool view state is at least 2 bytes');
      throw Refusal('version', 'this library writes pool view state version $version and does not read ${bytes[0]}');
    }
    if (k != kind) throw Refusal('kind', 'kind $k is not a pool view state ($kind)');
    final r = Reader.open(bytes, version: version, kind: kind, max: maxState, what: 'pool view state');
    return Reader.guard(() {
      final leaves = r.u32('leavesPerRound');
      final mismatch = shape.sameSizeAs(leaves);
      if (mismatch != null) throw mismatch;
      final round = r.u32('round');
      if (round > shape.maxRounds) {
        throw Refusal('round', 'round $round is past the ${shape.maxRounds} this pool\'s tree holds');
      }
      final foldedFrom = r.u32('foldedFrom');
      if (foldedFrom < 1 || (round > 0 && foldedFrom > round + 1)) {
        throw Refusal('foldedFrom', 'a view at round $round cannot have started folding at round $foldedFrom');
      }
      final checkedTo = r.u32('checkedTo');
      if (checkedTo > round) {
        throw Refusal('checkedTo', 'a view at round $round cannot have checked its root at round $checkedTo');
      }
      UpperFrontier frontier;
      if (round == 0) {
        frontier = UpperFrontier.atGenesis(shape);
      } else {
        final blockRoot = r.take('blockRoot', 32);
        final count = r.byte('left');
        final want = Checkpoint.nodesFor(round, shape.upperLevels);
        if (count != want) {
          throw Refusal('left', 'a view at round $round holds $want nodes above the block level, $count given');
        }
        final left = [for (int i = 0; i < count; i++) r.take('left', 32)];
        final (f, why) = UpperFrontier.at(shape, Checkpoint(round: round, blockRoot: blockRoot, left: left));
        if (f == null) throw why!;
        frontier = f;
      }
      final recentCount = r.byte('recent');
      if (recentCount > ringEntries || recentCount > round) {
        throw Refusal('recent', 'a view at round $round keeps at most ${round < ringEntries ? round : ringEntries} '
            'block roots, $recentCount given');
      }
      final recent = [for (int i = 0; i < recentCount; i++) r.take('recent', 32)];
      final noteCount = r.u32('notes');
      if (noteCount > maxNotes) throw Refusal('notes', 'declares $noteCount notes, at most $maxNotes');
      final view = PoolView._(shape, frontier, foldedFrom, checkedTo);
      view._recent.addAll([for (final x in recent) List<int>.unmodifiable(x)]);
      for (int i = 0; i < noteCount; i++) {
        final noteRound = r.u32('note round');
        final position = r.u32('note position');
        final currentAt = r.u32('note currentAt');
        final followed = r.byte('note followed');
        if (followed > 1) throw Refusal('note followed', 'is $followed, which is neither 0 nor 1');
        final leaf = r.take('note commitment', 32);
        final path = [for (int l = 0; l < PoolShape.depth; l++) r.lanes('note path', PoolHash.digestLanes)];
        final (note, why) =
            TrackedNote.of(shape: shape, round: noteRound, position: position, leaf: leaf, path: path);
        if (note == null) throw why!;
        if (currentAt < noteRound || currentAt > round) {
          throw Refusal('note currentAt',
              'a note from round $noteRound in a view at round $round cannot be current as of round $currentAt');
        }
        if (followed == 1) {
          if (currentAt != round) {
            throw Refusal('note currentAt',
                'a note this view is still following is current as of round $round, not $currentAt');
          }
          note.attachTo(frontier, at: round);
        }
        view._keep(note);
      }
      r.end('end', '%n bytes after the last note');
      return view;
    });
  }

  Refusal _pathRefusal(List<int> reached, List<int> want, int round) => Refusal('path',
      'this path reaches ${shortHex(reached)} and round $round\'s commitment root is ${shortHex(want)}, '
      'so the leaf it is a path for is not in that tree at that position');

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The view's stored state on disk.
///
/// The file holds no key and no seed: commitments, positions and paths are all
/// public. What it does say is **which** of them are this wallet's, so it is
/// written owner-only, the same as the wallet file, and for the same reason —
/// the thing worth protecting here is the link, not the bytes.
///
/// A write goes to a temporary name and is renamed over the real one, so a
/// crash leaves either the old state or the new one and never half of either.
class PoolViewFile {
  static String temporaryFor(String path) => '$path.tmp';

  static Future<void> save(String path, PoolView view) async {
    final tmp = File(temporaryFor(path));
    await tmp.writeAsBytes(const <int>[], flush: true);
    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', ['600', tmp.path]);
      if (chmod.exitCode != 0) {
        await tmp.delete();
        throw Refusal('permissions', 'could not make ${tmp.path} owner-only, so the view was not written');
      }
    }
    await tmp.writeAsBytes(view.encode(), flush: true);
    await tmp.rename(path);
  }

  /// The view stored at [path], or a [Refusal] naming the file.
  ///
  /// A file cut short is refused here rather than read: a truncated frontier
  /// decodes into a tree that is not the pool's, and a view that folded onto it
  /// would refuse every round afterwards for the wrong reason.
  static Future<PoolView> open(String path, {required PoolShape shape}) async {
    final f = File(path);
    if (!await f.exists()) throw Refusal('file', 'there is no pool view state at $path');
    final length = await f.length();
    if (length > PoolView.maxState) {
      throw Refusal('size', 'a pool view state is at most ${PoolView.maxState} bytes, $length at $path');
    }
    final bytes = await f.readAsBytes();
    try {
      return PoolView.decode(bytes, shape: shape);
    } on Refusal catch (e) {
      throw Refusal(e.step, '${e.reason} (reading $path)');
    }
  }
}
