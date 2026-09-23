import 'package:dartsv/dartsv.dart' show Transaction;
import 'package:tstokenlib/tstokenlib.dart';

import '../headers/merkle_membership.dart';
import '../headers/proven_header.dart';
import '../msg/payment_proof.dart';
import '../refusal.dart';

/// A payment the payee has checked and can act on.
class CheckedPayment {
  /// The value of the note, in the pool's smallest unit.
  final int value;

  /// The round the payer named. Believed only as far as the checks go: for a
  /// standing proof nothing rests on it, and for a short proof it picks which
  /// of the payee's own folded roots the path had to reach.
  final int round;

  final int position;

  /// The commitment root the note was found under: for a standing proof the
  /// one the round's own PP1 carries, for a short proof the one the payee's
  /// fold produced.
  final List<int> cmRoot;

  /// How deep the witness is buried, for a standing proof.
  final int confirmations;

  const CheckedPayment(
      {required this.value,
      required this.round,
      required this.position,
      required this.cmRoot,
      required this.confirmations});
}

/// The payee's side of a payment: check what you were handed, against headers
/// you hold yourself, and nothing else.
///
/// The order the checks run in is part of the contract, because a refusal
/// names the step and a person acts on that name. It is, stopping at the first
/// failure:
///
/// 1. the encoding and its bounds (done when the proof was decoded);
/// 2. the witness is in a block this wallet's own source vouches for, by its
///    merkle branch, buried deep enough;
/// 3. the witness spends the round's PP1 and PP2;
/// 4. the PP1 is a real PP1_SP script carrying the descriptor's tokenId and
///    genesis header, and its pool header parses;
/// 5. the opening commits under the payee's own `pk_d`;
/// 6. the path takes that commitment to the round's commitment root at the
///    stated position.
///
/// Steps 3 to 6 are tstokenlib's `PoolEvidence`, on purpose: they are rules
/// about the pool, so they live beside the pool where the coordinator and the
/// wallet cannot drift apart. Step 4 is the one the lineage attack is about —
/// a script carrying the pool's fields at the right offsets over a body that
/// enforces nothing reads as genuine to anything that parses by offset.
///
/// Nothing here verifies a STARK. The round was mined, which means the chain
/// ran the pool's verifier over it; the payee's evidence is that the witness is
/// buried in a block it accepts.
class PaymentChecker {
  final PoolDescriptor pool;
  final HeaderChecker headers;

  /// The commitment root this payee folded for a round, for the short form,
  /// or null when it has not folded that round. A payee that does not follow
  /// the pool leaves it out and accepts standing proofs only.
  final List<int>? Function(int round)? foldedRoot;

  /// The last round this payee has folded, for the refusal's sentence.
  final int Function()? foldedTo;

  const PaymentChecker({required this.pool, required this.headers, this.foldedRoot, this.foldedTo});

  /// Checks [proof] for a note paid to [pkd], the payee's own address key for
  /// the diversifier its invoice named. Returns the payment, or the first
  /// check that failed.
  Future<(CheckedPayment?, Refusal?)> check(PaymentProof proof, {required List<int> pkd}) async {
    switch (proof.form) {
      case ProofForm.short:
        return _checkShort(proof, pkd);
      case ProofForm.standing:
        return _checkStanding(proof, pkd);
    }
  }

  Future<(CheckedPayment?, Refusal?)> _checkStanding(PaymentProof proof, List<int> pkd) async {
    // 2. the witness is in a block this wallet accepts
    final (header, whyHeader) = await headers.proven(proof.blockHash!);
    if (header == null) return (null, whyHeader);

    final whyBranch = MerkleMembership.confirm(
        merkleRoot: header.merkleRoot,
        blockHash: header.hash,
        txBytes: proof.witnessTx!,
        proof: proof.membership!);
    if (whyBranch != null) return (null, whyBranch);

    // 3 to 4. the round is this pool's, one hop back from the mined witness
    final Transaction round, witness;
    try {
      round = ShieldedLedger.parse(proof.roundTx!);
      witness = ShieldedLedger.parse(proof.witnessTx!);
    } on LedgerRefusal catch (e) {
      return (null, Refusal('transactions', e.reason));
    }
    final (proven, whyRound) = PoolEvidence.provenRound(
        round: round, witness: witness, tokenId: pool.tokenId, genesisHeader: pool.genesisHeader);
    if (proven == null) return (null, Refusal(whyRound!.step, whyRound.reason));

    // 5 to 6. the note is the payee's, and it is in that round's tree
    final (note, whyNote) = PoolEvidence.provenNote(
        round: proven, opening: proof.note.plaintext, pkd: pkd, position: proof.position, path: proof.path);
    if (note == null) return (null, Refusal(whyNote!.step, whyNote.reason));

    return (
      CheckedPayment(
          value: note.value,
          round: proof.round,
          position: note.position,
          cmRoot: proven.cmRoot,
          confirmations: header.confirmations),
      null
    );
  }

  Future<(CheckedPayment?, Refusal?)> _checkShort(PaymentProof proof, List<int> pkd) async {
    final known = foldedRoot;
    if (known == null) {
      return (
        null,
        Refusal('short proof', 'this payee does not follow the pool, so it holds no commitment root of its own; '
            'send the standing form')
      );
    }
    final root = known(proof.round);
    if (root == null) {
      final at = foldedTo?.call();
      return (
        null,
        Refusal('short proof',
            'this payee has not folded round ${proof.round}${at == null ? '' : '; it holds up to round $at'}; '
            'send the standing form')
      );
    }
    // The same commitment and path checks as the standing form, against a root
    // this payee folded and checked for itself. The proof supplied no root and
    // could not have: that is the whole difference between the two forms.
    final (note, whyNote) = PoolEvidence.noteUnderRoot(
        cmRoot: root, opening: proof.note.plaintext, pkd: pkd, position: proof.position, path: proof.path);
    if (note == null) return (null, Refusal(whyNote!.step, whyNote.reason));
    return (
      CheckedPayment(value: note.value, round: proof.round, position: note.position, cmRoot: root, confirmations: 0),
      null
    );
  }
}
