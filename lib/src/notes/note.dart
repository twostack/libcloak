import 'package:tstokenlib/tstokenlib.dart';

import '../msg/payment_proof.dart';
import '../refusal.dart';

/// Where a note is in its one-way life.
///
/// The order matters and the store enforces it: a note that has been spent is
/// never anything else again, because the thing that made it spent is a
/// nullifier in a mined round and no wallet gets to disagree with that. The one
/// move that looks backwards — reserved to proven — is not the wallet changing
/// its mind about the chain, it is a submission the pool refused, which means
/// the note was never spent at all.
enum NoteState {
  /// A payment proof checked out, or it is the wallet's own change from a
  /// round it has seen. Spendable, if the view can still anchor its path.
  proven(1),

  /// A submission spending it was accepted and its round is not yet mined.
  reserved(2),

  /// Its nullifier is in a round the wallet has seen.
  spent(3);

  final int number;
  const NoteState(this.number);

  static NoteState? of(int number) {
    for (final s in values) {
      if (s.number == number) return s;
    }
    return null;
  }
}

/// A note the wallet holds.
///
/// It carries what the spend circuit will need and nothing it can derive: the
/// asset, the diversifier the invoice named, the value, `rho` and `rcm`, the
/// leaf position and the round that created it. The commitment is not stored
/// because it is a function of those and the wallet's own `pk_d`, and the
/// **nullifier is not stored** because it is a function of `nk`, which is a
/// secret the store does not hold and does not want to.
///
/// That last one is a rule and not an optimisation. A nullifier is the one
/// value that links a note to the spend that destroys it; a store that wrote
/// them down would hand anybody who read the file the wallet's whole spending
/// history in advance. So it is computed, used, and dropped — see
/// [nullifierWith].
class HeldNote {
  /// The asset, diversifier, value, `rho` and `rcm`: what the payer built the
  /// note from, and what reproduces the commitment.
  final NoteOpening opening;

  /// The leaf this note is at, which is what makes a note unique in a store.
  final int position;

  /// The round that appended it, which is [position]'s block plus one.
  final int round;

  NoteState _state;

  HeldNote({required this.opening, required this.position, required this.round, NoteState state = NoteState.proven})
      : _state = state {
    if (position < 0 || position >= (1 << PoolSpendAir.depth)) {
      throw ArgumentError('a position is inside a tree of depth ${PoolSpendAir.depth}');
    }
    if (round < 1) throw ArgumentError('a round number is 1 or more');
  }

  int get value => opening.value;
  List<int> get asset => opening.asset;
  List<int> get d => opening.d;
  NoteState get state => _state;

  /// Whether this note is in a state a payment could spend from. Whether it
  /// *can* be spent also needs the pool view, which is the other half of the
  /// balance.
  bool get isProven => _state == NoteState.proven;

  /// The commitment this note has under [pkd], in the 32 bytes a round's blob
  /// carries it in. The wallet's own `pk_d` for the diversifier the invoice
  /// named — a note's commitment is not a property of the note alone.
  List<int> commitmentFor(List<int> pkd) {
    final (_, cm) = PoolHash.commit(pkd, value, opening.rho, opening.rcm, asset: opening.asset);
    return BlockFold.lanesToBytes(cm);
  }

  /// The nullifier `H(nk, rho)` this note has under the wallet's [nk].
  ///
  /// Computed here and returned to the caller; nothing keeps it. The two
  /// places it is wanted are recognising this note among the nullifiers a
  /// round the wallet already holds inserted, and building a transfer's own
  /// statement. Anywhere else is a leak.
  List<int> nullifierWith(List<int> nk) {
    if (nk.length != PoolHash.digestLanes) {
      throw ArgumentError('nk is ${PoolHash.digestLanes} lanes, ${nk.length} given');
    }
    return PoolHash.nullifierFromNk(nk, opening.rho);
  }

  /// Marks this note as spent by a submission the pool accepted. Null when it
  /// moved.
  Refusal? reserve() => _to(NoteState.reserved);

  /// Gives a reserved note back, because the submission spending it was
  /// refused and so it was never spent.
  Refusal? release() => _to(NoteState.proven);

  /// Records that this note's nullifier turned up in a round the wallet has
  /// seen. There is no way back from here.
  Refusal? markSpent() => _to(NoteState.spent);

  Refusal? _to(NoteState next) {
    if (_state == next) {
      return Refusal('note', 'the note at leaf $position is already ${next.name}');
    }
    final allowed = switch (_state) {
      NoteState.proven => next == NoteState.reserved || next == NoteState.spent,
      NoteState.reserved => next == NoteState.proven || next == NoteState.spent,
      NoteState.spent => false,
    };
    if (!allowed) {
      return Refusal('note',
          'the note at leaf $position is ${_state.name} and cannot become ${next.name}; a note whose nullifier is '
          'in a mined round stays spent');
    }
    _state = next;
    return null;
  }

  @override
  String toString() => 'HeldNote(leaf $position, round $round, $value, ${_state.name})';
}
