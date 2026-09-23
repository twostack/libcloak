import 'dart:typed_data';

import 'package:tstokenlib/tstokenlib.dart';

import '../headers/merkle_membership.dart';
import '../refusal.dart';
import 'codec.dart';

/// A note's opening, as the payer hands it over.
///
/// It is the note itself, less the memo: the asset, the diversifier the
/// invoice named, the value, and the two pieces of randomness the commitment
/// was made from. With the payee's own `pk_d` it reproduces the commitment,
/// and nothing else in the world does.
///
/// It is not a secret of the payer's. The payer built this note for the payee
/// and already knows every field; what it must never carry is a key, a seed,
/// or the randomness of any other note.
class NoteOpening {
  final List<int> asset, d, rho, rcm;
  final int value;

  NoteOpening({required this.asset, required this.d, required this.value, required this.rho, required this.rcm}) {
    if (asset.length != PoolHash.assetLanes) throw ArgumentError('an asset is ${PoolHash.assetLanes} lanes');
    if (d.length != PoolHash.dLanes) throw ArgumentError('a diversifier is ${PoolHash.dLanes} lanes');
    if (rho.length != PoolHash.rhoLanes) throw ArgumentError('rho is ${PoolHash.rhoLanes} lanes');
    if (rcm.length != PoolHash.rcmLanes) throw ArgumentError('rcm is ${PoolHash.rcmLanes} lanes');
    if (value < 0 || value >= PoolHash.maxValue) throw ArgumentError('a value is 0 to ${PoolHash.maxValue}');
  }

  /// The opening of [note], the plaintext a payee decrypted or a payer built.
  factory NoteOpening.of(NotePlaintext note) =>
      NoteOpening(asset: note.asset, d: note.d, value: note.value, rho: note.rho, rcm: note.rcm);

  /// The plaintext form the pool's own checks take. The memo is not carried:
  /// it is not in the commitment, and a payee that wants one has the payer to
  /// ask.
  NotePlaintext get plaintext => NotePlaintext(asset: asset, d: d, value: value, rho: rho, rcm: rcm);

  /// Bytes: 4 + 3 + 3 + 4 lanes of four bytes, and the value.
  static const encodedSize = 4 * (PoolHash.assetLanes + PoolHash.dLanes + PoolHash.rhoLanes + PoolHash.rcmLanes) + 8;

  void writeTo(Writer w) {
    w
      ..lanes(asset)
      ..lanes(d)
      ..lanes(rho)
      ..lanes(rcm)
      ..u64(value);
  }

  static NoteOpening read(Reader r) {
    final asset = r.lanes('asset', PoolHash.assetLanes);
    final d = r.lanes('diversifier', PoolHash.dLanes);
    final rho = r.lanes('rho', PoolHash.rhoLanes);
    final rcm = r.lanes('rcm', PoolHash.rcmLanes);
    final value = r.u64('value');
    if (value >= PoolHash.maxValue) throw Refusal('value', '$value is outside the range a note can hold');
    return NoteOpening(asset: asset, d: d, value: value, rho: rho, rcm: rcm);
  }
}

/// Which of the two forms a proof is in.
enum ProofForm {
  /// Everything the payee needs and nothing it must look up.
  standing(1),

  /// The opening, the position and the path, for a payee that already follows
  /// the pool and holds its own commitment root for that round.
  short(2);

  final int number;
  const ProofForm(this.number);

  static ProofForm? of(int number) {
    for (final f in values) {
      if (f.number == number) return f;
    }
    return null;
  }
}

/// What a payer hands a payee so the payee can stop wondering.
///
/// The **standing** form carries the round transaction, the witness that
/// spends it, the witness's place in a block, and the note. Both transactions
/// are carried whole, because a txid is the hash of the whole serialisation
/// and the witness's txid is what its merkle branch commits to; so there is no
/// shorter form of it, and a standing proof is dominated by bytes the payee
/// hashes once and never reads — the PP1 unlock's STARK proof, which the payee
/// never verifies because the chain already did.
///
/// The **short** form carries the opening, the position and the path, and is
/// valid only against a round the payee has already folded and checked for
/// itself. It is about a kilobyte against three quarters of a megabyte, and it
/// is not a weaker proof: the payee applies exactly the same commitment and
/// path checks, against a commitment root of its own. What the short form must
/// never carry is that root — that is the one thing it has no evidence for.
class PaymentProof {
  /// Bumped when any field changes. An unknown version is refused, never
  /// guessed at.
  static const version = 1;

  /// The largest proof read, above the production estimate of about 3 MB.
  static const maxProof = 8 * 1024 * 1024;

  /// The largest transaction inside one: the chain's own per-transaction
  /// limit, since a larger one cannot be mined and so cannot be in a proof.
  static const maxTx = 10 * 1024 * 1024;

  final ProofForm form;

  /// The round the payer says the note is in. A claim, not evidence: a pool
  /// header carries no round number. The standing form's checks do not use
  /// it; the short form does, to pick which of the payee's own folded roots
  /// to check against, and a wrong number simply fails that check.
  final int round;

  final int position;

  /// [PoolSpendAir.depth] siblings, leaf level first.
  final List<List<int>> path;
  final NoteOpening note;

  /// Standing only: the round and witness transactions, whole.
  final Uint8List? roundTx, witnessTx;

  /// Standing only: the block the witness is in, its index there, and the
  /// merkle branch.
  final Uint8List? blockHash;
  final int txIndex;
  final List<List<int>> branch;

  PaymentProof._(this.form,
      {required this.round,
      required this.position,
      required this.path,
      required this.note,
      this.roundTx,
      this.witnessTx,
      this.blockHash,
      this.txIndex = 0,
      this.branch = const []});

  /// A standing proof: everything, nothing to look up.
  factory PaymentProof.standing({
    required int round,
    required List<int> roundTx,
    required List<int> witnessTx,
    required List<int> blockHash,
    required int txIndex,
    required List<List<int>> branch,
    required int position,
    required List<List<int>> path,
    required NoteOpening note,
  }) {
    _checkRound(round);
    _checkPath(position, path);
    for (final (b, name) in [(roundTx, 'the round'), (witnessTx, 'the witness')]) {
      if (b.isEmpty || b.length > maxTx) throw ArgumentError('$name is 1 to $maxTx bytes');
    }
    if (blockHash.length != 32) throw ArgumentError('a block hash is 32 bytes');
    if (txIndex < 0 || txIndex > 0xffffffff) throw ArgumentError('a transaction index fits 32 bits');
    if (branch.length > MerkleMembership.maxBranch) {
      throw ArgumentError('a branch is at most ${MerkleMembership.maxBranch} deep');
    }
    if (branch.any((x) => x.length != 32)) throw ArgumentError('a branch node is 32 bytes');
    if (branch.length < 63 && txIndex >= (1 << branch.length)) {
      throw ArgumentError('index $txIndex is outside a block of ${1 << branch.length}');
    }
    // a proof this side cannot decode is a proof this side must not build:
    // the reader refuses the whole thing at maxProof before it reads a byte
    final size = _fixedSize + 4 + roundTx.length + 4 + witnessTx.length + 32 + 4 + 1 + 32 * branch.length;
    if (size > maxProof) {
      throw ArgumentError('a payment proof of $size bytes is over the $maxProof a reader accepts; '
          'the round is ${roundTx.length} bytes and the witness ${witnessTx.length}');
    }
    return PaymentProof._(ProofForm.standing,
        round: round,
        position: position,
        path: _copyPath(path),
        note: note,
        roundTx: Uint8List.fromList(roundTx),
        witnessTx: Uint8List.fromList(witnessTx),
        blockHash: Uint8List.fromList(blockHash),
        txIndex: txIndex,
        branch: [for (final x in branch) List<int>.unmodifiable(x)]);
  }

  /// A short proof, for a payee that has folded [round] already.
  factory PaymentProof.short({
    required int round,
    required int position,
    required List<List<int>> path,
    required NoteOpening note,
  }) {
    _checkRound(round);
    _checkPath(position, path);
    return PaymentProof._(ProofForm.short, round: round, position: position, path: _copyPath(path), note: note);
  }

  /// Where the witness sits in its block, as a [MerkleProof] on its own.
  /// Null for the short form, which carries no block.
  ///
  /// The txid is computed from the witness the proof already carries, so
  /// inside a payment proof it is not a separate claim and cannot disagree —
  /// which is why the payment proof's wire format does not carry one.
  MerkleProof? get membership => form == ProofForm.standing
      ? MerkleProof.of(witnessTx!, blockHash: blockHash!, txIndex: txIndex, branch: branch)
      : null;

  static void _checkRound(int round) {
    if (round < 1 || round > 0xffffffff) throw ArgumentError('a round number is 1 or more');
  }

  static void _checkPath(int position, List<List<int>> path) {
    if (position < 0 || position >= (1 << PoolSpendAir.depth)) {
      throw ArgumentError('a position is inside a tree of depth ${PoolSpendAir.depth}');
    }
    if (path.length != PoolSpendAir.depth) throw ArgumentError('a path is ${PoolSpendAir.depth} siblings');
    if (path.any((s) => s.length != PoolHash.digestLanes)) {
      throw ArgumentError('a sibling is ${PoolHash.digestLanes} lanes');
    }
  }

  static List<List<int>> _copyPath(List<List<int>> path) => [for (final s in path) List<int>.unmodifiable(s)];

  /// What every proof carries: the version and kind, the round, the position,
  /// the path and the opening.
  static const _fixedSize = 2 + 4 + 4 + PoolSpendAir.depth * 4 * PoolHash.digestLanes + NoteOpening.encodedSize;

  // ---- wire format ----
  //
  //   version, kind (form)     1 + 1
  //   round                    4
  //   position                 4
  //   path                     32 siblings of 8 lanes, 4 bytes each
  //   opening                  asset 16, d 12, rho 12, rcm 16, value 8
  //   standing only:
  //     round length 4, round
  //     witness length 4, witness
  //     block hash 32
  //     index 4
  //     branch count 1, nodes 32 each

  Uint8List encode() {
    final w = Writer(version, form.number)
      ..u32(round)
      ..u32(position);
    for (final s in path) {
      w.lanes(s);
    }
    note.writeTo(w);
    if (form == ProofForm.standing) {
      w
        ..sized(roundTx!)
        ..sized(witnessTx!)
        ..bytes(blockHash!)
        ..u32(txIndex)
        ..byte(branch.length);
      for (final n in branch) {
        w.bytes(n);
      }
    }
    return w.done();
  }

  /// The proof [bytes] hold, or a [Refusal] naming the field that stopped it.
  static PaymentProof decode(List<int> bytes) {
    final kind = Reader.kindOf(bytes, version);
    if (kind == null) {
      if (bytes.length < 2) throw Refusal('size', 'a payment proof is at least 2 bytes');
      throw Refusal('version', 'this library writes payment proof version $version and does not read ${bytes[0]}');
    }
    final form = ProofForm.of(kind);
    if (form == null) throw Refusal('kind', 'unknown payment proof form $kind');
    final r = Reader.open(bytes, version: version, kind: kind, max: maxProof, what: 'payment proof');
    return Reader.guard(() {
      final round = r.u32('round');
      if (round < 1) throw Refusal('round', 'a round number is 1 or more, not $round');
      final position = r.u32('position');
      final path = [for (int i = 0; i < PoolSpendAir.depth; i++) r.lanes('path', PoolHash.digestLanes)];
      final note = NoteOpening.read(r);
      if (form == ProofForm.short) {
        r.end('cmRoot',
            'a short proof carries %n bytes after the note; it carries no commitment root, because that root is '
            'the one thing it has no evidence for, and the payee uses the one its own fold produced');
        return PaymentProof.short(round: round, position: position, path: path, note: note);
      }
      final roundTx = r.sized('roundTx', maxTx);
      final witnessTx = r.sized('witnessTx', maxTx);
      final blockHash = r.take('blockHash', 32);
      final txIndex = r.u32('txIndex');
      final levels = r.byte('branch');
      if (levels > MerkleMembership.maxBranch) {
        throw Refusal('branch', 'declares $levels levels, at most ${MerkleMembership.maxBranch}');
      }
      final branch = [for (int i = 0; i < levels; i++) r.take('branch', 32)];
      r.end('end', '%n bytes after the last field');
      if (levels < 63 && txIndex >= (1 << levels)) {
        throw Refusal('txIndex', 'position $txIndex is outside a block of ${1 << levels}');
      }
      return PaymentProof.standing(
          round: round,
          roundTx: roundTx,
          witnessTx: witnessTx,
          blockHash: blockHash,
          txIndex: txIndex,
          branch: branch,
          position: position,
          path: path,
          note: note);
    });
  }
}
