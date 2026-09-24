import 'dart:math';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dartsv/dartsv.dart' show Transaction;
import 'package:tstokenlib/tstokenlib.dart';

import '../msg/payment_proof.dart';
import '../notes/note.dart';
import '../notes/note_store.dart';
import '../pool/pool_view.dart';
import '../refusal.dart';

// Money in and money out: the two transfers that touch the transparent side
// of the pool.
//
// Both are public by nature. A deposit names an amount and a covenant on the
// chain, and a withdrawal names an amount and a pubkey hash, so neither is
// private the way a payment is; what stays private is which notes they turn
// into or come out of. The builders here keep the same contract as
// [PaymentBuilder]: everything cheap is checked before the STARK, nothing
// throws on bad input, and a note moves only with a coordinator's answer.

/// The 16 bytes a deposit's or withdrawal's journal thread is filed under.
///
/// Neither answers an invoice, so neither has an invoice id to thread by. The
/// transfer's bundle hash is public (it is in the round's `outHash` preimage)
/// and unique to the transfer, so a tagged hash of it is an id known the
/// moment the transfer is built that says nothing a round does not.
List<int> _threadOf(ShieldedTransfer t) =>
    crypto.sha256.convert([...'tsl1-libcloak/onramp/1'.codeUnits, ...t.bundleHash]).bytes.sublist(0, 16);

/// Whether [address] is one of the addresses [keys] can open, which is what a
/// wallet must know before it writes its own money to one.
bool _ownsAddress(PoolWalletKeys keys, NoteAddress address) =>
    _eq(PoolHash.pkdFromIvk(keys.ivk, address.d), address.pkd);

/// A deposit whose proof is computed and whose covenant does not exist yet.
///
/// This is the first of two steps, and the order is forced: the covenant
/// transaction that carries the money needs the note's [commitment], and the
/// transfer needs the covenant's outpoint. The outpoint is not in the proof or
/// in `outHash`, so the expensive part can come first and the outpoint be
/// attached afterwards with [backedBy], which costs nothing.
class ProvedDeposit {
  /// The depositor's note, output 1, and the address it was written to. This
  /// is what [NoteStore.takeChange] takes once the round carrying the receipt
  /// is mined and [PaymentProofs.positionOf] has found [commitment] in it.
  final NoteOpening note;
  final NoteAddress to;

  /// How long the wallet's own work took, and how long the spend proof took.
  final Duration ownWork, proving;

  /// The proved transfer, not yet naming the covenant it backs.
  final ShieldedTransfer _unbacked;

  const ProvedDeposit._(this.note, this.to, this._unbacked, {required this.ownWork, required this.proving});

  int get amount => note.value;

  /// The note's commitment in the 32 bytes a covenant and a round's receipt
  /// carry it in: what `ShieldedPoolTool.createDepositTxn` takes as
  /// `commitment`, and what the depositor looks for in the mined round.
  List<int> get commitment => BlockFold.lanesToBytes(note.plaintext.cmUnder(to.pkd));

  /// The deposit backed by the covenant at output [vout] of [covenant].
  ///
  /// The covenant is checked against this deposit before a transfer is made:
  /// that the output is a deposit covenant at all, that it locks this note's
  /// commitment and exactly [amount], and that the transaction fits in a
  /// submission. A covenant that locks another value would otherwise be
  /// refused by the coordinator after a round trip, as `depositCovenant`; here
  /// it is refused before anything leaves. Which PP3 the covenant names is not
  /// checked: the host chose the round it deposits into, and a coordinator
  /// refuses a stale one by name.
  (BuiltDeposit?, Refusal?) backedBy(Transaction covenant, {int vout = ShieldedPoolTool.depositVout}) {
    try {
      final int size = covenant.serialize().length ~/ 2;
      if (size > PoolMessage.maxDepositTx) {
        return (
          null,
          Refusal('covenant',
              'the covenant transaction is $size bytes and a submission carries at most ${PoolMessage.maxDepositTx}')
        );
      }
      if (vout < 0 || vout >= covenant.outputs.length) {
        return (
          null,
          Refusal('covenant', 'the covenant transaction has ${covenant.outputs.length} outputs and has none at $vout')
        );
      }
      final script = covenant.outputs[vout].script.buffer;
      // findDeposits parses the covenant in full and asks which PP3 to look
      // for; the PP3 is read from the output's own push, so everything else
      // is what it matches on, and a script that is not a covenant is still
      // refused. See design D5.
      final receipts = script.length < 70
          ? const <PoolReceipt>[]
          : [
              for (final d in ShieldedPoolTool.findDeposits([covenant], script.sublist(34, 70), minRefundAfter: 0))
                if (d.vout == vout) d.receipt
            ];
      if (receipts.isEmpty) {
        return (null, Refusal('covenant', 'output $vout of the covenant transaction is not a deposit covenant'));
      }
      final receipt = receipts.single;
      if (!_eq(receipt.commitment, commitment)) {
        return (
          null,
          Refusal('covenant',
              'the covenant locks commitment ${shortHex(receipt.commitment)} and this deposit\'s note is '
              '${shortHex(commitment)}')
        );
      }
      if (receipt.satoshis != BigInt.from(amount)) {
        return (
          null,
          Refusal('covenant', 'the covenant locks ${receipt.satoshis} satoshis and this deposit brings in $amount')
        );
      }
      final outpoint = ShieldedPoolTool().getOutpoint(covenant.hash, outputIndex: vout);
      final transfer = ShieldedTransfer(_unbacked.publics, _unbacked.proof, _unbacked.bundle, depositOutpoint: outpoint);
      final why = DepositBuilder.check(transfer);
      if (why != null) return (null, why);
      return (
        BuiltDeposit._(
            transfer: transfer,
            covenant: covenant,
            note: note,
            to: to,
            ownWork: ownWork,
            proving: proving),
        null
      );
    } catch (e) {
      // the covenant is a transaction this library did not build, and a
      // wallet that threw on one would be a wallet its host's bytes can stop
      return (null, Refusal('covenant', 'the covenant transaction could not be read ($e)'));
    }
  }
}

/// A deposit ready to submit: the transfer, naming its covenant's outpoint,
/// and the covenant transaction the coordinator needs beside it.
class BuiltDeposit {
  final ShieldedTransfer transfer;

  /// The covenant transaction, which goes to the coordinator with the transfer
  /// and is public on the chain in any case.
  final Transaction covenant;

  /// The depositor's note and its address, as in [ProvedDeposit].
  final NoteOpening note;
  final NoteAddress to;

  final Duration ownWork, proving;

  const BuiltDeposit._(
      {required this.transfer,
      required this.covenant,
      required this.note,
      required this.to,
      required this.ownWork,
      required this.proving});

  int get amount => note.value;

  /// The note's 32-byte commitment, which is also the covenant's and the
  /// round's receipt's.
  List<int> get commitment => BlockFold.lanesToBytes(note.plaintext.cmUnder(to.pkd));

  /// The covenant outpoint the transfer names: txid, then the output index as
  /// four bytes little endian.
  List<int> get outpoint => List<int>.unmodifiable(transfer.depositOutpoint!);

  /// The covenant's txid in display order, which is public: the journal's
  /// reference for a deposit.
  List<int> get covenantTxid => hex.decode(covenant.id);

  /// The id this deposit's journal entries are threaded under.
  List<int> get threadId => _threadOf(transfer);
}

/// Building a deposit: an amount and an address of the depositor's own in, a
/// transfer with no real input out.
///
/// A deposit spends two dummy notes, so there is no note to hold, no path and
/// no anchor to check, and the builder takes no pool view. What it can refuse
/// before the proof is the request itself.
class DepositBuilder {
  /// Proves a deposit of [amount] satoshis into a note at [address].
  ///
  /// [keys] are the depositor's pool keys: `ivk` to confirm [address] is its
  /// own, since a deposit written to someone else's address is money gone,
  /// and `ovk` to seal its own copy of both output notes. Output 2 is a
  /// zero-value note to the same address, because a bundle must carry two
  /// real notes and the padding note is at an address nobody can encrypt to.
  ///
  /// The anchor is all zeros: nothing real is spent, so the pool checks no
  /// ring, and the padding every round carries is proved against the same
  /// zeros. A root from the wallet's view would say when the deposit was built
  /// and buy nothing.
  static Future<(ProvedDeposit?, Refusal?)> prove({
    required PoolWalletKeys keys,
    required NoteAddress address,
    required int amount,
    required StarkParams spendP,
    Random? rng,
  }) async {
    // the request
    if (amount < 1 || amount >= PoolHash.maxValue) {
      return (null, Refusal('amount', 'a deposit brings in 1 to ${PoolHash.maxValue - 1} satoshis, not $amount'));
    }
    if (!_ownsAddress(keys, address)) {
      return (
        null,
        const Refusal('address',
            'the deposit address is not one of this wallet\'s, so the note it creates could not be spent by it')
      );
    }

    // everything past here costs work
    final r = rng ?? Random.secure();
    final own = Stopwatch()..start();
    List<int> lanes(int n) => List.generate(n, (_) => r.nextInt(M31.p));
    NotePlaintext plain(int value) => NotePlaintext(
        asset: PoolHash.bsvAsset, d: address.d, value: value, rho: lanes(PoolHash.rhoLanes), rcm: lanes(PoolHash.rcmLanes));
    final notePlain = plain(amount), zeroPlain = plain(0);

    final bundle = [
      ...(await NoteEncryption.encrypt(notePlain, address, keys.ovk, rng: r)).bytes,
      ...(await NoteEncryption.encrypt(zeroPlain, address, keys.ovk, rng: r)).bytes,
    ];

    final PoolSpendWitness w;
    try {
      w = PoolSpendAir.witness(
          SpendNote.dummy(sk: lanes(PoolHash.skLanes), rho: lanes(PoolHash.rhoLanes)),
          SpendNote.dummy(sk: lanes(PoolHash.skLanes), rho: lanes(PoolHash.rhoLanes)),
          notePlain.toOutputNote(address.pkd),
          zeroPlain.toOutputNote(address.pkd),
          -amount,
          anchor: List.filled(PoolHash.digestLanes, 0),
          outHash: PoolOutHash.transferLanes(PoolOutHash.bundleHash(bundle)));
    } on ArgumentError catch (e) {
      return (null, Refusal('transfer', '${e.message}'));
    }
    own.stop();

    final proving = Stopwatch()..start();
    final proof = StarkProver.prove(spendP, PoolSpendAir.air(w.publics), w.rows, rng: r, hash: const Poseidon2ProofHash());
    proving.stop();

    final unbacked = ShieldedTransfer(w.publics, proof, bundle);
    final why = unbacked.refusal();
    if (why != null) return (null, Refusal(why.field, why.reason));
    return (
      ProvedDeposit._(NoteOpening.of(notePlain), address, unbacked, ownWork: own.elapsed, proving: proving.elapsed),
      null
    );
  }

  /// Null when [transfer] is a well-formed deposit, else the rule it breaks.
  ///
  /// This is tstokenlib's rule, surfaced as a [Refusal] under the field it
  /// names: a real note spent beside a deposit comes back at step `deposit`,
  /// because a deposit is public and a real input beside it would name the
  /// depositor as the owner of an earlier note. A transfer that names no
  /// covenant at all is not a deposit, and is refused as one here.
  static Refusal? check(ShieldedTransfer transfer) {
    if (transfer.depositOutpoint == null) {
      return const Refusal('deposit', 'this transfer names no covenant outpoint, so it backs no deposit');
    }
    final why = transfer.refusal();
    return why == null ? null : Refusal(why.field, why.reason);
  }
}

/// A withdrawal a wallet has built and not yet submitted.
class BuiltWithdrawal {
  final ShieldedTransfer transfer;

  /// The note this spends, as the store holds it.
  final HeldNote spent;

  /// The payout: the pubkey hash and exactly the amount the proof takes out.
  final PoolWithdrawal withdrawal;

  /// The wallet's change, and the address it went to. Value zero when the
  /// whole note was withdrawn.
  final NoteOpening change;
  final NoteAddress changeTo;

  /// The commitment root the spend proof anchors to, and the round the view
  /// stood at, as for a payment.
  final List<int> anchor;
  final int anchorRound;

  final Duration ownWork, proving;

  const BuiltWithdrawal._(
      {required this.transfer,
      required this.spent,
      required this.withdrawal,
      required this.change,
      required this.changeTo,
      required this.anchor,
      required this.anchorRound,
      required this.ownWork,
      required this.proving});

  int get amount => withdrawal.satoshis.toInt();

  /// The change note's commitment in the 32 bytes a round carries it in: what
  /// the wallet looks for in the mined round to learn its leaf.
  List<int> get changeCommitment => BlockFold.lanesToBytes(change.plaintext.cmUnder(changeTo.pkd));

  /// The id this withdrawal's journal entries are threaded under.
  List<int> get threadId => _threadOf(transfer);
}

/// Building a withdrawal: a note, an amount and a transparent pubkey hash in,
/// a transfer taking the amount out of the pool.
///
/// The order the checks run in is [PaymentBuilder]'s, stopping at the first
/// failure, because everything past the last of them costs a STARK:
///
/// 1. the request: a 20-byte pubkey hash, an amount of at least 1, a change
///    address of the wallet's own;
/// 2. the note: held here, not reserved or spent, BSV, and holding at least
///    the amount;
/// 3. the path: the view yields one at the pool's tip;
/// 4. the anchor: the path reaches the root the view holds.
class WithdrawalBuilder {
  /// Builds a withdrawal of [amount] satoshis out of [note] to [payTo], a
  /// 20-byte pubkey hash the pool pays by P2PKH.
  ///
  /// [changeAddress] is an address of the wallet's own, a fresh one; it is
  /// checked to be the wallet's, because change written anywhere else is
  /// money gone. The note is **not** reserved here, as with a payment:
  /// reserving is what submitting does.
  static Future<(BuiltWithdrawal?, Refusal?)> build({
    required PoolWalletKeys keys,
    required HeldNote note,
    required NoteStore notes,
    required int amount,
    required List<int> payTo,
    required NoteAddress changeAddress,
    required PoolView view,
    required StarkParams spendP,
    required int tip,
    Random? rng,
  }) async {
    // 1. the request
    if (payTo.length != 20) {
      return (null, Refusal('payTo', 'a withdrawal pays a 20-byte pubkey hash, and ${payTo.length} bytes were given'));
    }
    if (amount < 1) {
      return (null, Refusal('amount', 'a withdrawal takes at least 1 satoshi out, not $amount'));
    }
    if (!_ownsAddress(keys, changeAddress)) {
      return (
        null,
        const Refusal('address',
            'the change address is not one of this wallet\'s, so the change could not be spent by it')
      );
    }

    // 2. the note
    if (!identical(notes.at(note.position), note)) {
      return (null, Refusal('note', 'this wallet is not holding the note at leaf ${note.position}'));
    }
    if (!note.isProven) {
      return (
        null,
        Refusal('note',
            'the note at leaf ${note.position} is ${note.state.name}, so a withdrawal cannot be built against it')
      );
    }
    if (!PoolHash.isBsv(note.asset)) {
      return (
        null,
        Refusal('asset', 'a withdrawal pays out satoshis and the note at leaf ${note.position} holds another asset')
      );
    }
    if (note.value < amount) {
      return (
        null,
        Refusal('amount',
            'this withdrawal asks for $amount and the note at leaf ${note.position} holds ${note.value}; '
            'a transfer spends one note, so no proof was computed')
      );
    }

    // 3. the path
    final tracked = view.trackedAt(note.position);
    if (tracked == null) {
      return (null, Refusal('view', 'the pool view is keeping no path for the note at leaf ${note.position}'));
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
    NotePlaintext plain(int value) => NotePlaintext(
        asset: note.asset, d: changeAddress.d, value: value, rho: lanes(PoolHash.rhoLanes), rcm: lanes(PoolHash.rcmLanes));
    final changePlain = plain(note.value - amount), zeroPlain = plain(0);
    final withdrawal = PoolWithdrawal(List<int>.of(payTo), BigInt.from(amount));

    final bundle = [
      ...(await NoteEncryption.encrypt(changePlain, changeAddress, keys.ovk, rng: r)).bytes,
      ...(await NoteEncryption.encrypt(zeroPlain, changeAddress, keys.ovk, rng: r)).bytes,
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
          changePlain.toOutputNote(changeAddress.pkd),
          zeroPlain.toOutputNote(changeAddress.pkd),
          amount,
          outHash: PoolOutHash.transferLanes(PoolOutHash.bundleHash(bundle), withdrawal: withdrawal));
    } on ArgumentError catch (e) {
      return (null, Refusal('transfer', '${e.message}'));
    }
    own.stop();

    final proving = Stopwatch()..start();
    final proof = StarkProver.prove(spendP, PoolSpendAir.air(w.publics), w.rows, rng: r, hash: const Poseidon2ProofHash());
    proving.stop();

    final transfer = ShieldedTransfer(w.publics, proof, bundle, withdrawal: withdrawal);
    final why = check(transfer);
    if (why != null) return (null, why);

    return (
      BuiltWithdrawal._(
          transfer: transfer,
          spent: note,
          withdrawal: withdrawal,
          change: NoteOpening.of(changePlain),
          changeTo: changeAddress,
          anchor: anchor,
          anchorRound: view.round,
          ownWork: own.elapsed,
          proving: proving.elapsed),
      null
    );
  }

  /// Null when [transfer] is a well-formed withdrawal, else the rule it
  /// breaks.
  ///
  /// The record's amount is compared with the public amount **before**
  /// tstokenlib's own check runs, because that check tests `outHash` first,
  /// and a record swapped after the proof fails there naming neither amount.
  /// A person needs both numbers to see what went wrong.
  static Refusal? check(ShieldedTransfer transfer) {
    final w = transfer.withdrawal;
    final out = transfer.publics.publicOut;
    if (w == null) {
      return Refusal('withdrawal', 'this transfer carries no withdrawal record and takes $out out');
    }
    if (out <= 0) {
      return Refusal('withdrawal', 'this transfer carries a withdrawal of ${w.satoshis} and takes nothing out');
    }
    if (w.satoshis != BigInt.from(out)) {
      return Refusal('withdrawal',
          'the proof takes $out out and the withdrawal record pays ${w.satoshis}; they must be the same amount');
    }
    final why = transfer.refusal();
    return why == null ? null : Refusal(why.field, why.reason);
  }
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
