import 'package:tstokenlib/tstokenlib.dart';

import '../refusal.dart';
import 'balance.dart';
import 'note.dart';

/// The note a payment will spend, and what comes back as change.
class NoteChoice {
  final HeldNote note;
  final int amount;

  const NoteChoice(this.note, this.amount);

  /// What the payer pays itself back. Zero when the note is exact.
  int get change => note.value - amount;

  @override
  String toString() => 'NoteChoice(leaf ${note.position}, ${note.value} for $amount, change $change)';
}

/// Which note a payment spends.
///
/// The rule is **the smallest spendable note that covers the amount, and the
/// lowest leaf position among equals**. Stated, so a person can predict it;
/// deterministic, so the same wallet asked twice makes no second reservation
/// against a different note; smallest-that-covers, so the wallet's large notes
/// stay whole for the large payments they are for.
///
/// There is no gathering. A TSL1_SP transfer has two inputs and two outputs,
/// and a payment needs one of each pair for its change, so a payment is one
/// note or it is nothing. That is why the refusal names the **largest**
/// spendable value rather than the total: the total is the wrong number to
/// show somebody who cannot pay, because it is not what they can pay. A wallet
/// whose money is in pieces too small has to put them together first, and
/// doing that is a payment to itself like any other, not a rule hidden inside
/// selection.
class NoteSelection {
  /// The note to spend for [amount] out of [balance], or the refusal.
  static (NoteChoice?, Refusal?) choose({required int amount, required Balance balance}) {
    if (amount <= 0) {
      return (null, Refusal('amount', 'a payment is one unit or more, not $amount'));
    }
    if (amount >= PoolHash.maxValue) {
      return (null, Refusal('amount', '$amount is outside the range a note can hold'));
    }
    final covering = [for (final n in balance.spendableNotes) if (n.value >= amount) n]
      ..sort((a, b) => a.value != b.value ? a.value - b.value : a.position - b.position);
    if (covering.isEmpty) {
      final largest = balance.largestSpendable;
      final behind = balance.staleNotes.isEmpty
          ? ''
          : '; ${balance.stale} more is held in ${balance.staleNotes.length} note'
              '${balance.staleNotes.length == 1 ? '' : 's'} the view is ${balance.behind} rounds too far behind to '
              'anchor';
      return (
        null,
        Refusal('amount',
            'no single note covers $amount; the largest spendable is $largest, and a transfer spends one note'
            '$behind')
      );
    }
    return (NoteChoice(covering.first, amount), null);
  }
}
