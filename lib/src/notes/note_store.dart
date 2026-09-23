import 'dart:io';
import 'dart:typed_data';

import 'package:tstokenlib/tstokenlib.dart';

import '../msg/codec.dart';
import '../msg/payment_proof.dart';
import '../pay/checker.dart';
import '../pool/descriptor.dart';
import '../pool/pool_view.dart';
import '../refusal.dart';
import 'balance.dart';
import 'note.dart';
import 'selection.dart';

/// The notes the wallet holds.
///
/// Nothing in here was found by looking. Every note arrived with a payment
/// proof that checked out, or was the wallet's own change out of a round it
/// had already seen, and the store has no way to take one any other way: the
/// only door a payment comes through is [take], and the only thing it accepts
/// is a [CheckedPayment], which nothing outside the payments check can build.
///
/// It holds no key. The nullifier that would link a note to its spend is never
/// written down and never held — it is computed from `nk` at the moment it is
/// needed and dropped again, which is what [settle] does and why `nk` is an
/// argument there rather than a field here.
class NoteStore {
  /// Bumped when the stored fields change. An unknown version is refused,
  /// never guessed at.
  static const version = 1;
  static const kind = 1;

  /// Notes one store carries. Far past a wallet and here so a declared count
  /// cannot make a reader allocate.
  static const maxNotes = 100000;

  /// What one note costs: its state, position, round, value and opening.
  static const noteSize = 1 + 4 + 4 + NoteOpening.encodedSize;

  static const maxState = 2 + 4 + 4 + maxNotes * noteSize;

  /// The pool's shape, so a note's round can be checked against its leaf
  /// rather than believed, and so a store built under another block size is
  /// refused rather than silently misread.
  final PoolShape shape;

  final List<HeldNote> _notes = [];
  final Map<int, HeldNote> _at = {};

  NoteStore(this.shape);

  /// The notes held, in the order they were taken on — which is the order they
  /// are written in, so two stores that took the same notes agree byte for
  /// byte.
  List<HeldNote> get notes => List<HeldNote>.unmodifiable(_notes);

  /// The note at [position], or null.
  HeldNote? at(int position) => _at[position];

  int get length => _notes.length;

  /// Takes on the note a checked payment delivered.
  ///
  /// [payment] can only have come out of [PaymentChecker.check], which is the
  /// whole of the "unless the proof checked out" rule: there is no path into
  /// this store for a proof nobody verified, because the argument type does
  /// not exist until one was.
  (HeldNote?, Refusal?) take(CheckedPayment payment) =>
      _add(opening: payment.note, position: payment.position, round: payment.round);

  /// Takes on the wallet's own change from a round it has seen.
  ///
  /// This is the other way a note becomes proven, and it is not weaker: the
  /// payer built the note itself and watched the round that carries it, so
  /// there is nobody to have lied. It is still checked against the pool's
  /// shape, because a wrong round here makes a note the view cannot anchor.
  (HeldNote?, Refusal?) takeChange(
          {required NoteOpening opening, required int position, required int round}) =>
      _add(opening: opening, position: position, round: round);

  (HeldNote?, Refusal?) _add({required NoteOpening opening, required int position, required int round}) {
    if (_notes.length >= maxNotes) {
      return (null, Refusal('notes', 'this store already holds $maxNotes notes'));
    }
    if (round < 1 || round > shape.maxRounds) {
      return (null, Refusal('round', 'a round is 1 to ${shape.maxRounds}, not $round'));
    }
    if (position < 0 || position >= (1 << PoolShape.depth)) {
      return (null, Refusal('position', '$position is not a leaf of a tree of depth ${PoolShape.depth}'));
    }
    // a round number in a proof is a claim; the leaf decides which block it is
    // in, and a note recorded under the wrong round is one the view will never
    // be able to anchor
    if (shape.blockOf(position) != round - 1) {
      return (
        null,
        Refusal('position',
            'round $round appends leaves ${shape.firstLeafOf(round)} to ${shape.firstLeafOf(round + 1) - 1}, '
            'and leaf $position is in round ${shape.blockOf(position) + 1}\'s block')
      );
    }
    final already = _at[position];
    if (already != null) {
      return (
        null,
        Refusal('note', 'this store already holds the note at leaf $position, which is ${already.state.name}')
      );
    }
    final note = HeldNote(opening: opening, position: position, round: round);
    _notes.add(note);
    _at[position] = note;
    return (note, null);
  }

  /// Marks [note] as spent by a submission the pool accepted.
  ///
  /// This is what stops two payments being built against one note: a note is
  /// reserved before a proof is computed, so the second attempt is refused
  /// naming the leaf and the state, and nothing expensive happens.
  Refusal? reserve(HeldNote note) => _held(note) ?? note.reserve();

  /// Gives a reserved note back, because the submission spending it was
  /// refused.
  Refusal? release(HeldNote note) => _held(note) ?? note.release();

  /// Records that [note] is spent.
  Refusal? markSpent(HeldNote note) => _held(note) ?? note.markSpent();

  Refusal? _held(HeldNote note) => identical(_at[note.position], note)
      ? null
      : Refusal('note', 'this store is not holding the note at leaf ${note.position}');

  /// Recognises this wallet's notes among the [nullifiers] a round it already
  /// holds inserted, and marks them spent. Returns the ones that moved.
  ///
  /// [nk] is an argument and not a field because that is the whole point: the
  /// store computes `H(nk, rho)` here, compares it, and keeps neither the key
  /// nor the answer. A store that cached nullifiers would be a file that says
  /// which spends were this wallet's.
  List<HeldNote> settle(List<List<int>> nullifiers, {required List<int> nk}) {
    if (nullifiers.isEmpty) return const [];
    final seen = {for (final x in nullifiers) _lanes(x)};
    final moved = <HeldNote>[];
    for (final n in _notes) {
      if (n.state == NoteState.spent) continue;
      if (seen.contains(_lanes(n.nullifierWith(nk)))) {
        if (n.markSpent() == null) moved.add(n);
      }
    }
    return moved;
  }

  /// The balance lines, one per asset held.
  List<Balance> balances({required PoolView view, required int tip}) =>
      Balance.forNotes(_notes, view: view, tip: tip);

  /// The lines for [asset] alone, three zeroes when the wallet holds none.
  Balance balanceOf(List<int> asset, {required PoolView view, required int tip}) {
    for (final b in balances(view: view, tip: tip)) {
      if (PoolHash.sameAsset(b.asset, asset)) return b;
    }
    return Balance.empty(asset, behind: tip - view.round);
  }

  /// The note a payment for [amount] of [asset] spends, or the refusal.
  (NoteChoice?, Refusal?) choose(
          {required int amount, required List<int> asset, required PoolView view, required int tip}) =>
      NoteSelection.choose(amount: amount, balance: balanceOf(asset, view: view, tip: tip));

  // ---- stored form ----
  //
  //   version, kind        1 + 1
  //   leaves a round       4
  //   notes                4, then each: state 1, position 4, round 4,
  //                        asset 16, d 12, rho 12, rcm 16, value 8

  Uint8List encode() {
    final w = Writer(version, kind)
      ..u32(shape.leavesPerRound)
      ..u32(_notes.length);
    for (final n in _notes) {
      w
        ..byte(n.state.number)
        ..u32(n.position)
        ..u32(n.round);
      n.opening.writeTo(w);
    }
    return w.done();
  }

  /// The store [bytes] hold, or a [Refusal] naming the field that stopped it.
  static NoteStore decode(List<int> bytes, {required PoolShape shape}) {
    final k = Reader.kindOf(bytes, version);
    if (k == null) {
      if (bytes.length < 2) throw const Refusal('size', 'a note store is at least 2 bytes');
      throw Refusal('version', 'this library writes note store version $version and does not read ${bytes[0]}');
    }
    if (k != kind) throw Refusal('kind', 'kind $k is not a note store ($kind)');
    final r = Reader.open(bytes, version: version, kind: kind, max: maxState, what: 'note store');
    return Reader.guard(() {
      final leaves = r.u32('leavesPerRound');
      final mismatch = shape.sameSizeAs(leaves);
      if (mismatch != null) throw mismatch;
      final count = r.u32('notes');
      if (count > maxNotes) throw Refusal('notes', 'declares $count notes, at most $maxNotes');
      final store = NoteStore(shape);
      for (int i = 0; i < count; i++) {
        final s = r.byte('note state');
        final state = NoteState.of(s);
        if (state == null) throw Refusal('note state', 'is $s, which is not a state a note has');
        final position = r.u32('note position');
        final round = r.u32('note round');
        final opening = NoteOpening.read(r);
        final (note, why) = store._add(opening: opening, position: position, round: round);
        if (note == null) throw why!;
        if (state != NoteState.proven) {
          final moved = state == NoteState.reserved ? note.reserve() : note.markSpent();
          if (moved != null) throw moved;
        }
      }
      r.end('end', '%n bytes after the last note');
      return store;
    });
  }

  static String _lanes(List<int> x) => [for (final l in x) l.toRadixString(16).padLeft(8, '0')].join();
}

/// The store on disk.
///
/// A write goes to a temporary name and is renamed over the real one, so a
/// crash leaves either the old store or the new one and never half of either,
/// and the file is owner-only.
///
/// The bytes are the ones [NoteStore.encode] produced, unchanged: the stored
/// form is required to be deterministic — two wallets that took the same notes
/// in the same order hold the same file — and a sealed file with a fresh nonce
/// is not. What that costs is written down in the design record, because it is
/// a decision and not an oversight: the file holds each note's `rho` and `rcm`,
/// which are the note's own secrets, and it is the seed's file next door that
/// is encrypted.
class NoteStoreFile {
  static String temporaryFor(String path) => '$path.tmp';

  static Future<void> save(String path, NoteStore store) async {
    final tmp = File(temporaryFor(path));
    await tmp.writeAsBytes(const <int>[], flush: true);
    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', ['600', tmp.path]);
      if (chmod.exitCode != 0) {
        await tmp.delete();
        throw Refusal('permissions', 'could not make ${tmp.path} owner-only, so the notes were not written');
      }
    }
    await tmp.writeAsBytes(store.encode(), flush: true);
    await tmp.rename(path);
  }

  /// The store at [path], or a [Refusal] naming the file.
  static Future<NoteStore> open(String path, {required PoolShape shape}) async {
    final f = File(path);
    if (!await f.exists()) throw Refusal('file', 'there is no note store at $path');
    final length = await f.length();
    if (length > NoteStore.maxState) {
      throw Refusal('size', 'a note store is at most ${NoteStore.maxState} bytes, $length at $path');
    }
    final bytes = await f.readAsBytes();
    try {
      return NoteStore.decode(bytes, shape: shape);
    } on Refusal catch (e) {
      throw Refusal(e.step, '${e.reason} (reading $path)');
    }
  }
}
