import 'dart:convert';
import 'dart:typed_data';

import '../msg/codec.dart';
import '../msg/invoice.dart';
import '../msg/payment_proof.dart';
import '../net/coordinator_client.dart';
import '../pay/acknowledgement.dart';
import '../pay/builder.dart';
import '../pay/checker.dart';
import '../refusal.dart';

/// What happened, as the journal names it.
///
/// The nine are the six moments a payment has — the invoice, the build, the
/// submission, the reply, the proof and the acknowledgement — with the three
/// that have two sides split by side, because "I issued this invoice" and "I
/// was handed this invoice" are different facts about the same bytes and a
/// person reading the record needs to know which happened.
enum JournalKind {
  invoiceIssued(1),
  invoiceReceived(2),
  paymentBuilt(3),
  paymentSubmitted(4),
  paymentAnswered(5),
  proofBuilt(6),
  proofChecked(7),
  acknowledgementSent(8),
  acknowledgementReceived(9);

  final int number;
  const JournalKind(this.number);

  static JournalKind? of(int number) {
    for (final k in values) {
      if (k.number == number) return k;
    }
    return null;
  }
}

/// One thing that happened, written down.
///
/// Every entry names the invoice it belongs to, so a payment's whole life
/// reads as one thread: what was asked for, what was built, what was sent,
/// what came back, what was proved and what was acknowledged. That thread is
/// the evidence behind a payment made in consideration of something, and it is
/// the reason a person can answer "did I pay that?" without asking anybody.
///
/// **Nothing secret goes in one.** There is no field here a key, a seed, a
/// passphrase or a note's randomness could be put in, and the constructors
/// below take the whole object and write down a handful of numbers from it, so
/// a caller cannot put one in by mistake either. Values, leaf positions and an
/// invoice's own contents do go in: they are the wallet's own business and the
/// note store already holds them.
class JournalEntry {
  /// Bumped when any field changes. An unknown version is refused, never
  /// guessed at.
  static const version = 1;

  /// An entry is at most this many bytes, checked before one is read.
  static const maxEntry = 1024;

  static const maxWord = 64;
  static const maxReference = 32;
  static const maxNote = 512;

  /// The invoice id every entry carries, which is what makes a thread.
  static const invoiceIdLength = Invoice.idLength;

  /// Where this entry stands in the journal, from 1. Zero until the journal
  /// has taken it, which is the only thing about an entry the journal decides.
  final int sequence;

  final JournalKind kind;

  /// When it was written, in UTC. The one field two wallets doing the same
  /// things are allowed to differ in.
  final DateTime at;

  final List<int> invoiceId;

  /// The entry this corrects, or zero. A correction is a new entry, never a
  /// rewrite: what was believed at the time survives beside what replaced it.
  final int corrects;

  /// What was moved, when the entry is about a value.
  final int amount;

  /// The round it is about, or zero.
  final int round;

  /// The leaf, when the entry is about a particular note. Null, not zero,
  /// because leaf zero is a real leaf and the fixture's first note is in it.
  final int? position;

  /// One word for what happened: `issued`, `built`, `accepted`, `refused`,
  /// `paid`. Short and from a fixed set, so a journal can be counted.
  final String outcome;

  /// The named step that refused, when something did: the protocol's own
  /// `RefusalReason` name for a coordinator's refusal, and libcloak's
  /// [Refusal.step] for everything else. It is a field of its own rather than
  /// a phrase inside [note] so the twelve reasons can be counted.
  final String reason;

  /// A public identifier the entry is about: a submission id, and nothing that
  /// is not already public.
  final List<int> reference;

  /// One sentence for a person.
  final String note;

  JournalEntry._({
    required this.sequence,
    required this.kind,
    required DateTime at,
    required List<int> invoiceId,
    this.corrects = 0,
    this.amount = 0,
    this.round = 0,
    this.position,
    this.outcome = '',
    this.reason = '',
    List<int> reference = const [],
    this.note = '',
  })  : at = at.toUtc(),
        invoiceId = List<int>.unmodifiable(invoiceId),
        reference = List<int>.unmodifiable(reference) {
    if (sequence < 0 || sequence > 0xffffffff) throw ArgumentError('a sequence fits 32 bits');
    if (invoiceId.length != invoiceIdLength) {
      throw ArgumentError('an invoice id is $invoiceIdLength bytes, ${invoiceId.length} given');
    }
    if (corrects < 0 || corrects > 0xffffffff) throw ArgumentError('a corrected sequence fits 32 bits');
    if (amount < 0) throw ArgumentError('an amount is not negative');
    if (round < 0 || round > 0xffffffff) throw ArgumentError('a round fits 32 bits');
    if (position != null && (position! < 0 || position! > 0xffffffff)) {
      throw ArgumentError('a leaf position fits 32 bits');
    }
    for (final (v, name, bound) in [(outcome, 'outcome', maxWord), (reason, 'reason', maxWord), (note, 'note', maxNote)]) {
      if (v.length > bound) throw ArgumentError('a $name is at most $bound bytes, ${v.length} given');
    }
    if (reference.length > maxReference) {
      throw ArgumentError('a reference is at most $maxReference bytes, ${reference.length} given');
    }
  }

  /// The same entry at [sequence]. Only [Journal] calls this: the sequence is
  /// the journal's to assign, because it is what says what came before what.
  JournalEntry atSequence(int sequence) => JournalEntry._(
      sequence: sequence,
      kind: kind,
      at: at,
      invoiceId: invoiceId,
      corrects: corrects,
      amount: amount,
      round: round,
      position: position,
      outcome: outcome,
      reason: reason,
      reference: reference,
      note: note);

  /// The same entry, correcting [earlier].
  JournalEntry correcting(JournalEntry earlier) => JournalEntry._(
      sequence: sequence,
      kind: kind,
      at: at,
      invoiceId: invoiceId,
      corrects: earlier.sequence,
      amount: amount,
      round: round,
      position: position,
      outcome: outcome,
      reason: reason,
      reference: reference,
      note: note);

  bool get isCorrection => corrects != 0;

  // ---- the nine things that happen ----

  /// An invoice this wallet issued.
  static JournalEntry invoiceIssued(Invoice invoice, {DateTime? at}) =>
      _aboutInvoice(JournalKind.invoiceIssued, invoice, 'issued', at);

  /// An invoice this wallet was handed.
  static JournalEntry invoiceReceived(Invoice invoice, {DateTime? at}) =>
      _aboutInvoice(JournalKind.invoiceReceived, invoice, 'received', at);

  static JournalEntry _aboutInvoice(JournalKind kind, Invoice invoice, String outcome, DateTime? at) =>
      JournalEntry._(
          sequence: 0,
          kind: kind,
          at: at ?? DateTime.now(),
          invoiceId: invoice.id,
          amount: invoice.amount,
          outcome: outcome,
          note: 'asks for ${invoice.amount}, expires ${invoice.expiry.toUtc().toIso8601String()}'
              '${invoice.memo.isEmpty ? '' : ' — ${_short(invoice.memo, 380)}'}');

  /// A payment built against an invoice, before anything was sent.
  static JournalEntry paymentBuilt(BuiltPayment payment, {DateTime? at}) => JournalEntry._(
      sequence: 0,
      kind: JournalKind.paymentBuilt,
      at: at ?? DateTime.now(),
      invoiceId: payment.invoice.id,
      amount: payment.amount,
      round: payment.anchorRound,
      position: payment.spent.position,
      outcome: 'built',
      note: 'spends the note at leaf ${payment.spent.position} holding ${payment.spent.value}, '
          'anchored to round ${payment.anchorRound}, change ${payment.change.value}');

  /// A submission that left the machine.
  static JournalEntry paymentSubmitted(Invoice invoice, List<int> submissionId, {DateTime? at}) =>
      JournalEntry._(
          sequence: 0,
          kind: JournalKind.paymentSubmitted,
          at: at ?? DateTime.now(),
          invoiceId: invoice.id,
          amount: invoice.amount,
          outcome: 'submitted',
          reference: submissionId,
          note: 'submission ${shortHex(submissionId)}');

  /// What the coordinator said.
  ///
  /// The coordinator's own [RefusalReason] name goes in [reason], not into a
  /// sentence, so a wallet can count how often each of the twelve happened
  /// without parsing prose.
  static JournalEntry paymentAnswered(Invoice invoice, SubmissionOutcome answer, {DateTime? at}) =>
      JournalEntry._(
          sequence: 0,
          kind: JournalKind.paymentAnswered,
          at: at ?? DateTime.now(),
          invoiceId: invoice.id,
          amount: invoice.amount,
          round: answer.round ?? 0,
          outcome: answer.outcome.name,
          reason: answer.reason?.name ?? answer.refusal?.step ?? '',
          reference: answer.id,
          note: answer.isAccepted
              ? 'accepted into round ${answer.round}'
              : _short(answer.refusal?.reason ?? '$answer', maxNote));

  /// A payment proof this wallet built for a payee.
  static JournalEntry proofBuilt(Invoice invoice, PaymentProof proof, {DateTime? at}) => JournalEntry._(
      sequence: 0,
      kind: JournalKind.proofBuilt,
      at: at ?? DateTime.now(),
      invoiceId: invoice.id,
      amount: proof.note.value,
      round: proof.round,
      position: proof.position,
      outcome: 'built',
      note: 'a ${proof.form.name} proof of ${proof.note.value} at leaf ${proof.position} in round ${proof.round}');

  /// A payment proof this wallet checked, and the verdict.
  ///
  /// Either [payment] or [refusal], never both and never neither: a verdict is
  /// what this entry is for, and an entry that recorded a check without one
  /// would be a record of nothing.
  static JournalEntry proofChecked(Invoice invoice,
      {CheckedPayment? payment, Refusal? refusal, DateTime? at}) {
    if ((payment == null) == (refusal == null)) {
      throw ArgumentError('a checked proof is a payment or a refusal, and this is ${payment == null ? 'neither' : 'both'}');
    }
    return JournalEntry._(
        sequence: 0,
        kind: JournalKind.proofChecked,
        at: at ?? DateTime.now(),
        invoiceId: invoice.id,
        amount: payment?.value ?? 0,
        round: payment?.round ?? 0,
        position: payment?.position,
        outcome: payment == null ? 'refused' : 'paid',
        reason: refusal?.step ?? '',
        note: payment == null
            ? _short(refusal!.reason, maxNote)
            : 'paid ${payment.value} at leaf ${payment.position} in round ${payment.round}, '
                '${payment.confirmations} confirmation${payment.confirmations == 1 ? '' : 's'} deep');
  }

  /// An acknowledgement this wallet signed and handed back.
  static JournalEntry acknowledgementSent(Invoice invoice, Acknowledgement ack, {DateTime? at}) =>
      JournalEntry._(
          sequence: 0,
          kind: JournalKind.acknowledgementSent,
          at: at ?? DateTime.now(),
          invoiceId: invoice.id,
          amount: ack.value,
          round: ack.round,
          outcome: 'sent',
          note: 'acknowledged ${ack.value} in round ${ack.round}');

  /// An acknowledgement this wallet was handed, and whether it checked out.
  static JournalEntry acknowledgementReceived(Invoice invoice, Acknowledgement ack,
          {Refusal? refusal, DateTime? at}) =>
      JournalEntry._(
          sequence: 0,
          kind: JournalKind.acknowledgementReceived,
          at: at ?? DateTime.now(),
          invoiceId: invoice.id,
          amount: ack.value,
          round: ack.round,
          outcome: refusal == null ? 'received' : 'refused',
          reason: refusal?.step ?? '',
          note: refusal == null
              ? 'the payee acknowledged ${ack.value} in round ${ack.round}'
              : _short(refusal.reason, maxNote));

  // ---- wire format ----
  //
  //   version, kind    1 + 1
  //   flags            1          bit 0: a leaf position is present
  //   sequence         4
  //   at               8          milliseconds since the epoch, UTC
  //   invoice id       16
  //   corrects         4          0 for an entry that corrects nothing
  //   amount           8
  //   round            4
  //   position         4
  //   outcome          4 + n
  //   reason           4 + n
  //   reference        4 + n
  //   note             4 + n

  Uint8List encode() {
    final w = Writer(version, kind.number)
      ..byte(position == null ? 0 : 1)
      ..u32(sequence)
      ..u64(at.millisecondsSinceEpoch)
      ..bytes(invoiceId)
      ..u32(corrects)
      ..u64(amount)
      ..u32(round)
      ..u32(position ?? 0)
      ..sized(_utf8(outcome))
      ..sized(_utf8(reason))
      ..sized(reference)
      ..sized(_utf8(note));
    return w.done();
  }

  /// The entry [bytes] hold, or a [Refusal] naming the field that stopped it.
  static JournalEntry decode(List<int> bytes) {
    if (bytes.length < 2) throw const Refusal('size', 'a journal entry is at least 2 bytes');
    if (bytes[0] != version) {
      throw Refusal('version', 'this library writes journal entry version $version and does not read ${bytes[0]}');
    }
    final kind = JournalKind.of(bytes[1]);
    if (kind == null) throw Refusal('kind', '${bytes[1]} is not one of the journal\'s entry kinds');
    final r = Reader.open(bytes, version: version, kind: kind.number, max: maxEntry, what: 'a journal entry');
    return Reader.guard(() {
      final flags = r.byte('flags');
      if (flags > 1) throw Refusal('flags', 'declares flags $flags, and only bit 0 is defined');
      final sequence = r.u32('sequence');
      final at = r.u64('at');
      final invoiceId = r.take('invoiceId', invoiceIdLength);
      final corrects = r.u32('corrects');
      final amount = r.u64('amount');
      final round = r.u32('round');
      final position = r.u32('position');
      final outcome = _text(r.sized('outcome', maxWord, min: 0), 'outcome');
      final reason = _text(r.sized('reason', maxWord, min: 0), 'reason');
      final reference = r.sized('reference', maxReference, min: 0);
      final note = _text(r.sized('note', maxNote, min: 0), 'note');
      r.end('end', '%n bytes after the last field');
      if (flags == 0 && position != 0) {
        throw Refusal('position', 'declares no leaf position and carries $position');
      }
      if (corrects != 0 && sequence != 0 && corrects >= sequence) {
        throw Refusal('corrects',
            'entry $sequence says it corrects entry $corrects, which is not earlier than it');
      }
      return JournalEntry._(
          sequence: sequence,
          kind: kind,
          at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
          invoiceId: invoiceId,
          corrects: corrects,
          amount: amount,
          round: round,
          position: flags == 0 ? null : position,
          outcome: outcome,
          reason: reason,
          reference: reference,
          note: note);
    });
  }

  static List<int> _utf8(String s) => utf8.encode(s);

  static String _text(List<int> bytes, String field) {
    try {
      return utf8.decode(bytes);
    } on FormatException catch (e) {
      throw Refusal(field, 'is not UTF-8 (${e.message})');
    }
  }

  /// [s] cut to [bound] bytes on a rune boundary, with an ellipsis when it was
  /// cut. Deterministic, so two wallets writing the same long memo write the
  /// same bytes, and never cut through the middle of a character.
  static String _short(String s, int bound) {
    if (utf8.encode(s).length <= bound) return s;
    final out = StringBuffer();
    var used = 0;
    for (final rune in s.runes) {
      final n = utf8.encode(String.fromCharCode(rune)).length;
      if (used + n > bound - 3) break;
      out.writeCharCode(rune);
      used += n;
    }
    return '$out...';
  }

  @override
  String toString() => '#$sequence ${kind.name} ${outcome.isEmpty ? '' : '($outcome) '}'
      '${shortHex(invoiceId)}${note.isEmpty ? '' : ': $note'}';
}
