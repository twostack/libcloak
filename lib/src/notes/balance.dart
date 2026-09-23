import 'package:tstokenlib/tstokenlib.dart';

import '../pool/pool_view.dart';
import '../refusal.dart';
import 'note.dart';

/// What the wallet holds of one asset, in the three lines a person can act on.
///
/// A single total would be a lie of omission. The two things that stop a
/// payment being made are money that is already in flight and money whose path
/// the wallet can no longer anchor, and a total hides both behind a number that
/// looks spendable. So there are three lines and they are never added up here:
/// **spendable** is what a payment can be built from right now, **reserved** is
/// what is in flight, and **stale** is what needs the view to catch up first,
/// with how far behind it is.
///
/// Stale is not lost. It is the balance saying "fold some block roots", which
/// is a thing the wallet can do on its own for 32 bytes a round.
class Balance {
  /// The asset these lines are about, in lanes. Lines are never added across
  /// assets, because a hundred of one and a hundred of another is not two
  /// hundred of anything.
  final List<int> asset;

  final List<HeldNote> spendableNotes, reservedNotes, staleNotes;

  /// How far behind the pool's tip the view is, which is why anything is
  /// stale.
  final int behind;

  /// Why the stale notes are stale, as the view put it. Null when none are.
  final Refusal? whyStale;

  /// The three lines, each summed once when the balance is made rather than
  /// on every read.
  final int spendable, reserved, stale;

  /// The largest single note a payment could be built from, or zero. This is
  /// the number a person needs when a payment is refused, because the pool's
  /// transfer spends one note and not a handful of them.
  final int largestSpendable;

  Balance._(List<int> asset, this.spendableNotes, this.reservedNotes, this.staleNotes, this.behind, this.whyStale)
      : asset = List<int>.unmodifiable(asset),
        spendable = _sum(spendableNotes),
        reserved = _sum(reservedNotes),
        stale = _sum(staleNotes),
        largestSpendable = spendableNotes.fold(0, (a, n) => n.value > a ? n.value : a);

  /// No notes of [asset] at all, which is a balance and not an absence: a
  /// person asking what they hold of something they hold none of gets three
  /// zeroes, not an error.
  factory Balance.empty(List<int> asset, {required int behind}) =>
      Balance._(asset, const [], const [], const [], behind, null);

  bool get isBsv => PoolHash.isBsv(asset);

  static int _sum(List<HeldNote> notes) => notes.fold(0, (a, n) => a + n.value);

  /// The lines for every asset in [notes], one [Balance] each, ordered by
  /// asset so two wallets holding the same notes report them the same way.
  ///
  /// A proven note counts as spendable only when [view] will actually yield a
  /// spend path for it at [tip] — the view is the half of this that knows
  /// about rounds, and asking it is the only way to be right about what can be
  /// paid now.
  static List<Balance> forNotes(Iterable<HeldNote> notes, {required PoolView view, required int tip}) {
    final behind = tip - view.round;
    // a wallet holds a handful of assets and a great many notes, so the notes
    // are dealt into the assets by comparing four lanes rather than by making
    // a key out of them — ten thousand throwaway strings is what reading a
    // balance used to cost
    final byAsset = <List<HeldNote>>[];
    for (final n in notes) {
      var placed = false;
      for (final group in byAsset) {
        if (PoolHash.sameAsset(group.first.asset, n.asset)) {
          group.add(n);
          placed = true;
          break;
        }
      }
      if (!placed) byAsset.add([n]);
    }
    byAsset.sort((a, b) => _order(a.first.asset, b.first.asset));
    return [
      for (final held in byAsset)
        () {
          final spendable = <HeldNote>[], reserved = <HeldNote>[], stale = <HeldNote>[];
          Refusal? why;
          for (final n in held) {
            switch (n.state) {
              case NoteState.reserved:
                reserved.add(n);
              case NoteState.spent:
                break;
              case NoteState.proven:
                final tracked = view.trackedAt(n.position);
                if (tracked != null && view.canSpend(tracked, tip: tip)) {
                  spendable.add(n);
                } else {
                  stale.add(n);
                  // the sentence is built once, for the first one, because a
                  // wallet with ten thousand stale notes is stale for one
                  // reason and reading a balance should not pay for ten
                  // thousand copies of it
                  why ??= anchorable(n, view: view, tip: tip).$2;
                }
            }
          }
          return Balance._(held.first.asset, spendable, reserved, stale, behind, why);
        }()
    ];
  }

  /// Whether [view] will yield a spend path for [note] at [tip], and the
  /// refusal when it will not.
  static (bool, Refusal?) anchorable(HeldNote note, {required PoolView view, required int tip}) {
    final tracked = view.trackedAt(note.position);
    if (tracked == null) {
      return (
        false,
        Refusal('view',
            'the pool view is keeping no path for the note at leaf ${note.position}, so there is nothing to anchor '
            'a spend of it to')
      );
    }
    final (path, why) = view.spendPath(tracked, tip: tip);
    return (path != null, why);
  }

  /// Assets in a fixed order, so two wallets holding the same notes list their
  /// lines the same way.
  static int _order(List<int> a, List<int> b) {
    for (int i = 0; i < PoolHash.assetLanes; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return 0;
  }

  @override
  String toString() => 'spendable $spendable (${spendableNotes.length}), '
      'reserved $reserved (${reservedNotes.length}), '
      'stale $stale (${staleNotes.length})${staleNotes.isEmpty ? '' : ', $behind rounds behind'}';
}
