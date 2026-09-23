import 'dart:math';

import 'package:tstokenlib/tstokenlib.dart';

import '../msg/invoice.dart';
import '../msg/payment_proof.dart';
import '../notes/note.dart';
import '../notes/note_store.dart';
import '../pool/pool_view.dart';
import '../refusal.dart';

/// A payment a payer has built and not yet submitted.
///
/// It holds the transfer the coordinator will be given, the note it spends,
/// and the two openings that come out of it: the payee's, which becomes the
/// payment proof once the round is mined, and the payer's own change.
class BuiltPayment {
  final Invoice invoice;
  final ShieldedTransfer transfer;

  /// The note this spends, as the store holds it.
  final HeldNote spent;

  /// The note the payee gets, and the address it was written to.
  final NoteOpening paid;
  final NoteAddress paidTo;

  /// The payer's change, and the address it went to. Value zero when the note
  /// covered the invoice exactly.
  final NoteOpening change;
  final NoteAddress changeTo;

  /// The commitment root the spend proof anchors to, and the round the payer's
  /// view stood at when it was built. The pool accepts an anchor while it is
  /// in the ring, which is why a payment is built and submitted rather than
  /// built and kept.
  final List<int> anchor;
  final int anchorRound;

  /// How long the wallet's own work took, and how long the spend proof took.
  /// They are kept apart because only the second is a STARK.
  final Duration ownWork, proving;

  const BuiltPayment._(
      {required this.invoice,
      required this.transfer,
      required this.spent,
      required this.paid,
      required this.paidTo,
      required this.change,
      required this.changeTo,
      required this.anchor,
      required this.anchorRound,
      required this.ownWork,
      required this.proving});

  /// The payee's note commitment, in the 32 bytes a round's blob carries it
  /// in: what the payer looks for in the mined round to learn its leaf.
  List<int> get paidCommitment => BlockFold.lanesToBytes(paid.plaintext.cmUnder(paidTo.pkd));

  /// The payer's own, likewise.
  List<int> get changeCommitment => BlockFold.lanesToBytes(change.plaintext.cmUnder(changeTo.pkd));

  int get amount => paid.value;
}

/// Building a payment: an invoice and a note in, a transfer out.
///
/// The order the checks run in is the contract, because everything past the
/// last of them costs a STARK. It is, stopping at the first failure:
///
/// 1. the invoice — the pool it names, its expiry, its signature;
/// 2. the note — that this store holds it, that it is not already spent or in
///    flight, and that it covers the amount;
/// 3. the path — that the pool view will yield a spend path at the pool's tip,
///    which is where "too far behind" is caught;
/// 4. the anchor — that the path really reaches the root the view holds.
///
/// Only then are the output notes made, the bundle sealed and the proof
/// proved. An expired invoice, a note that is too small and a view that has
/// fallen behind all cost nothing.
class PaymentBuilder {
  /// Builds the payment [invoice] asks for, spending [note].
  ///
  /// [keys] are the payer's pool keys: `sk` to spend with and `ovk` to seal
  /// its own copy of both output notes, so the payer can read back what it
  /// sent. [changeAddress] is an address of the payer's own — a fresh one,
  /// for the same reason invoices use fresh ones.
  ///
  /// The note is **not** reserved here. Reserving it is what an accepted
  /// submission does, because until a coordinator has taken the transfer
  /// nothing has been spent; a note already reserved or spent is refused at
  /// step 2 instead.
  static Future<(BuiltPayment?, Refusal?)> build({
    required Invoice invoice,
    required PoolWalletKeys keys,
    required NoteAddress changeAddress,
    required HeldNote note,
    required NoteStore notes,
    required PoolView view,
    required StarkParams spendP,
    required List<int> tokenId,
    required int tip,
    required DateTime now,
    Random? rng,
  }) async {
    // 1. the invoice
    final whyInvoice = await invoice.check(tokenId: tokenId, now: now);
    if (whyInvoice != null) return (null, whyInvoice);

    // 2. the note
    if (!identical(notes.at(note.position), note)) {
      return (null, Refusal('note', 'this wallet is not holding the note at leaf ${note.position}'));
    }
    if (!note.isProven) {
      return (
        null,
        Refusal('note',
            'the note at leaf ${note.position} is ${note.state.name}, so a payment cannot be built against it')
      );
    }
    if (!PoolHash.isBsv(note.asset)) {
      return (
        null,
        Refusal('asset',
            'an invoice asks for satoshis and the note at leaf ${note.position} holds another asset')
      );
    }
    if (note.value < invoice.amount) {
      return (
        null,
        Refusal('amount',
            'this invoice asks for ${invoice.amount} and the note at leaf ${note.position} holds ${note.value}; '
            'a transfer spends one note, so no proof was computed')
      );
    }

    // 3. the path
    final tracked = view.trackedAt(note.position);
    if (tracked == null) {
      return (
        null,
        Refusal('view', 'the pool view is keeping no path for the note at leaf ${note.position}')
      );
    }
    final (path, whyPath) = view.spendPath(tracked, tip: tip);
    if (path == null) return (null, whyPath);

    // 4. the anchor
    final anchor = view.cmRoot;
    final leaf = BlockFold.bytesToLanes(note.commitmentFor(PoolHash.pkdFromIvk(keys.ivk, note.d)));
    final reached = BlockFold.lanesToBytes(PoolHash.root(leaf, path.siblings, path.position));
    if (!_eq(reached, anchor)) {
      return (
        null,
        Refusal('anchor',
            'the path the view holds for leaf ${note.position} reaches ${shortHex(reached)} and the view stands at '
            '${shortHex(anchor)}')
      );
    }

    // everything past here costs work
    final r = rng ?? Random.secure();
    final own = Stopwatch()..start();
    List<int> lanes(int n) => List.generate(n, (_) => r.nextInt(M31.p));

    final paidPlain = NotePlaintext(
        asset: note.asset, d: invoice.address.d, value: invoice.amount, rho: lanes(PoolHash.rhoLanes), rcm: lanes(PoolHash.rcmLanes));
    final changePlain = NotePlaintext(
        asset: note.asset,
        d: changeAddress.d,
        value: note.value - invoice.amount,
        rho: lanes(PoolHash.rhoLanes),
        rcm: lanes(PoolHash.rcmLanes));

    final bundle = [
      ...(await NoteEncryption.encrypt(paidPlain, invoice.address, keys.ovk, rng: r)).bytes,
      ...(await NoteEncryption.encrypt(changePlain, changeAddress, keys.ovk, rng: r)).bytes,
    ];

    final spend = SpendNote(
        sk: keys.sk,
        d: note.d,
        value: note.value,
        rho: note.opening.rho,
        rcm: note.opening.rcm,
        asset: note.asset,
        siblings: path.siblings,
        position: path.position);

    final PoolSpendWitness w;
    try {
      w = PoolSpendAir.witness(
          spend,
          SpendNote.dummy(sk: lanes(PoolHash.skLanes), rho: lanes(PoolHash.rhoLanes), asset: note.asset),
          paidPlain.toOutputNote(invoice.address.pkd),
          changePlain.toOutputNote(changeAddress.pkd),
          0,
          outHash: PoolOutHash.transferLanes(PoolOutHash.bundleHash(bundle)));
    } on ArgumentError catch (e) {
      return (null, Refusal('transfer', '${e.message}'));
    }
    own.stop();

    final proving = Stopwatch()..start();
    final proof = StarkProver.prove(spendP, PoolSpendAir.air(w.publics), w.rows,
        rng: r, hash: const Poseidon2ProofHash());
    proving.stop();

    final transfer = ShieldedTransfer(w.publics, proof, bundle);
    final whyTransfer = transfer.refusal();
    if (whyTransfer != null) return (null, Refusal('transfer', whyTransfer.reason));

    return (
      BuiltPayment._(
          invoice: invoice,
          transfer: transfer,
          spent: note,
          paid: NoteOpening.of(paidPlain),
          paidTo: invoice.address,
          change: NoteOpening.of(changePlain),
          changeTo: changeAddress,
          anchor: anchor,
          anchorRound: view.round,
          ownWork: own.elapsed,
          proving: proving.elapsed),
      null
    );
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Turning a mined round into the proof a payee checks.
///
/// The payer knows the note it wrote; what the round tells it is **where the
/// leaf landed**, which is the one thing a payment proof needs that the payer
/// could not have known in advance.
class PaymentProofs {
  /// The leaf [commitment] landed at in [round], or null when the round does
  /// not hold it.
  static int? positionOf(ShieldedRound round, List<int> commitment) {
    final want = BlockFold.bytesToLanes(commitment);
    for (int t = 0; t < round.transfers.length; t++) {
      final p = round.transfers[t];
      if (_sameLanes(p.cmOut1, want)) return round.positions[t].$1;
      if (_sameLanes(p.cmOut2, want)) return round.positions[t].$2;
    }
    return null;
  }

  /// The standing proof for [note]: everything, nothing to look up.
  ///
  /// The constructors this wraps throw for a badly shaped argument; here they
  /// come back as a named refusal, because a payer builds one of these out of
  /// bytes a node handed it.
  static (PaymentProof?, Refusal?) standing({
    required NoteOpening note,
    required int round,
    required List<int> roundTx,
    required List<int> witnessTx,
    required List<int> blockHash,
    required int txIndex,
    required List<List<int>> branch,
    required int position,
    required List<List<int>> path,
  }) =>
      _guard(() => PaymentProof.standing(
          round: round,
          roundTx: roundTx,
          witnessTx: witnessTx,
          blockHash: blockHash,
          txIndex: txIndex,
          branch: branch,
          position: position,
          path: path,
          note: note));

  /// The short proof for [note], for a payee that has folded [round] already.
  /// It carries no commitment root, and must not: that root is the one thing
  /// the short form has no evidence for.
  static (PaymentProof?, Refusal?) short({
    required NoteOpening note,
    required int round,
    required int position,
    required List<List<int>> path,
  }) =>
      _guard(() => PaymentProof.short(round: round, position: position, path: path, note: note));

  /// The standing proof for what [payment] paid.
  static (PaymentProof?, Refusal?) standingFor(
    BuiltPayment payment, {
    required int round,
    required List<int> roundTx,
    required List<int> witnessTx,
    required List<int> blockHash,
    required int txIndex,
    required List<List<int>> branch,
    required int position,
    required List<List<int>> path,
  }) =>
      standing(
          note: payment.paid,
          round: round,
          roundTx: roundTx,
          witnessTx: witnessTx,
          blockHash: blockHash,
          txIndex: txIndex,
          branch: branch,
          position: position,
          path: path);

  /// The short proof for what [payment] paid.
  static (PaymentProof?, Refusal?) shortFor(BuiltPayment payment,
          {required int round, required int position, required List<List<int>> path}) =>
      short(note: payment.paid, round: round, position: position, path: path);

  static (PaymentProof?, Refusal?) _guard(PaymentProof Function() f) {
    try {
      return (f(), null);
    } on Refusal catch (e) {
      return (null, e);
    } on ArgumentError catch (e) {
      return (null, Refusal('proof', '${e.message}'));
    }
  }

  static bool _sameLanes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
