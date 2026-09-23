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

  /// The note as the payer opened it: the asset, the diversifier the invoice
  /// named, the value and the two pieces of randomness. It travels with the
  /// verdict because the note store needs exactly these fields and must not be
  /// handed them from anywhere a check did not reach.
  final NoteOpening note;

  const CheckedPayment._(
      {required this.value,
      required this.round,
      required this.position,
      required this.cmRoot,
      required this.confirmations,
      required this.note});
}

/// A round the wallet proved off the chain, with no note in it.
///
/// This is what a **head proof** amounts to: the same steps a standing payment
/// proof runs, stopping before the note. A wallet with no state cannot check a
/// frontier or a fold against anything until it holds one commitment root it
/// proved for itself, and this is where that root comes from.
///
/// The [round] number is **not** a number anybody claimed. It is the pool
/// header's own leaf count divided by the leaves a round appends, so a pool
/// that says "this is round 900" over a header holding two rounds of leaves is
/// caught here rather than believed.
class CheckedHead {
  /// The round, from the header's own size.
  final int round;

  /// That round's commitment root, from the header the round's PP1 carries.
  final List<int> cmRoot;

  /// How deep the witness is buried.
  final int confirmations;

  /// The whole header, for a caller that wants the ring or the balance.
  final PoolHeader header;

  const CheckedHead._(
      {required this.round, required this.cmRoot, required this.confirmations, required this.header});
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

  /// Checks a **head proof**: the tip round, its witness and the witness's
  /// place in a block, with no note.
  ///
  /// Steps 2 to 4 of the list above and nothing else, because there is nothing
  /// else — a head proof is a standing payment proof with the note taken out.
  /// It is what a wallet with no state starts from: the commitment root it
  /// gets here is the only thing a frontier or a thousand folded block roots
  /// can be checked against.
  Future<(CheckedHead?, Refusal?)> head({
    required List<int> roundTx,
    required List<int> witnessTx,
    required MerkleProof membership,
  }) async {
    final (proven, header, why) = await _provenRound(roundTx, witnessTx, membership);
    if (proven == null) return (null, why);

    // the round number is the header's own leaf count, not a claim
    final leaves = pool.leavesPerRound;
    final size = proven.header.size;
    if (size < leaves || size % leaves != 0) {
      return (
        null,
        Refusal('size',
            'this round\'s header holds $size leaves and the pool appends $leaves a round, so the header is not '
            'the header of a whole number of this pool\'s rounds')
      );
    }
    return (
      CheckedHead._(
          round: size ~/ leaves,
          cmRoot: proven.cmRoot,
          confirmations: header!.confirmations,
          header: proven.header),
      null
    );
  }

  /// Steps 2 to 4, shared by a standing payment proof and a head proof: the
  /// witness is in a block this wallet accepts, it spends the round's PP1 and
  /// PP2, and that PP1 is really this pool's.
  Future<(ProvenRound?, ProvenHeader?, Refusal?)> _provenRound(
      List<int> roundTx, List<int> witnessTx, MerkleProof membership) async {
    // 2. the witness is in a block this wallet accepts
    final (header, whyHeader) = await headers.proven(membership.blockHash);
    if (header == null) return (null, null, whyHeader);

    final whyBranch = MerkleMembership.confirm(
        merkleRoot: header.merkleRoot, blockHash: header.hash, txBytes: witnessTx, proof: membership);
    if (whyBranch != null) return (null, null, whyBranch);

    // 3 to 4. the round is this pool's, one hop back from the mined witness
    final Transaction round, witness;
    try {
      round = ShieldedLedger.parse(roundTx);
      witness = ShieldedLedger.parse(witnessTx);
    } on LedgerRefusal catch (e) {
      return (null, null, Refusal('transactions', e.reason));
    }
    final (proven, whyRound) = PoolEvidence.provenRound(
        round: round, witness: witness, tokenId: pool.tokenId, genesisHeader: pool.genesisHeader);
    if (proven == null) return (null, null, Refusal(whyRound!.step, whyRound.reason));
    return (proven, header, null);
  }

  Future<(CheckedPayment?, Refusal?)> _checkStanding(PaymentProof proof, List<int> pkd) async {
    final (proven, header, why) = await _provenRound(proof.roundTx!, proof.witnessTx!, proof.membership!);
    if (proven == null) return (null, why);

    // 5 to 6. the note is the payee's, and it is in that round's tree
    final (note, whyNote) = PoolEvidence.provenNote(
        round: proven, opening: proof.note.plaintext, pkd: pkd, position: proof.position, path: proof.path);
    if (note == null) return (null, Refusal(whyNote!.step, whyNote.reason));

    return (
      CheckedPayment._(
          value: note.value,
          round: proof.round,
          position: note.position,
          cmRoot: proven.cmRoot,
          confirmations: header!.confirmations,
          note: proof.note),
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
      CheckedPayment._(
          value: note.value,
          round: proof.round,
          position: note.position,
          cmRoot: root,
          confirmations: 0,
          note: proof.note),
      null
    );
  }
}
