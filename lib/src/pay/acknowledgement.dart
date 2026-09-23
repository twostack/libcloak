import 'dart:typed_data';

import '../msg/codec.dart';
import '../msg/invoice.dart';
import '../refusal.dart';
import 'checker.dart';

/// The payee saying: this invoice is paid, and here is what I accepted.
///
/// It names the invoice, the round the payment is in and the value, signed
/// under the key that invoice was issued from. The payer checks it **against
/// the invoice alone** — the invoice carries the public half — so the payer
/// ends up holding evidence, from the only person who could have produced it,
/// that the consideration was delivered against a payment the payee itself
/// checked and accepted.
///
/// That is the second half of "payment in consideration of something", and it
/// is the reason the payer keeps the invoice after paying it.
class Acknowledgement {
  /// Bumped when any field changes. An unknown version is refused, never
  /// guessed at.
  static const version = 1;
  static const kind = 1;

  /// Version, kind, the id, the round, the value and the signature.
  static const encodedSize = 2 + Invoice.idLength + 4 + 8 + InvoiceKey.signatureLength;

  /// The invoice this acknowledges.
  final List<int> invoiceId;

  /// The round the payment is in, and what the payee accepted.
  final int round, value;

  final List<int> signature;

  Acknowledgement._(
      {required List<int> invoiceId, required this.round, required this.value, required List<int> signature})
      : invoiceId = List<int>.unmodifiable(invoiceId),
        signature = List<int>.unmodifiable(signature);

  /// Acknowledges [payment] against [invoice], signed with [ivk] — the
  /// payee's own incoming viewing key, which with the invoice's address is
  /// what the invoice was signed from.
  ///
  /// [minedAt] is when the round holding the payment was mined, which the
  /// payee reads off the header it proved for itself. An invoice that had
  /// already expired by then is **not** acknowledged: the payee is not
  /// refusing the money, it is refusing to sign that the money arrived in
  /// time, and those are different statements.
  static Future<(Acknowledgement?, Refusal?)> of({
    required Invoice invoice,
    required CheckedPayment payment,
    required List<int> ivk,
    required DateTime minedAt,
  }) async {
    if (payment.value < invoice.amount) {
      return (
        null,
        Refusal('amount',
            'this invoice asks for ${invoice.amount} and the payment delivers ${payment.value}')
      );
    }
    if (!invoice.expiry.isAfter(minedAt)) {
      return (
        null,
        Refusal('expiry',
            'this invoice expired at ${invoice.expiry.toUtc().toIso8601String()} and the round holding the payment '
            'was mined at ${minedAt.toUtc().toIso8601String()}')
      );
    }
    final body = _body(invoiceId: invoice.id, round: payment.round, value: payment.value);
    final signature = await InvoiceKey.sign(body, ivk: ivk, d: invoice.address.d);
    return (
      Acknowledgement._(
          invoiceId: invoice.id, round: payment.round, value: payment.value, signature: signature),
      null
    );
  }

  // ---- wire format ----
  //
  //   version, kind   1 + 1
  //   invoice id      16
  //   round           4
  //   value           8
  //   signature       64

  static Uint8List _body({required List<int> invoiceId, required int round, required int value}) {
    final w = Writer(version, kind)
      ..bytes(invoiceId)
      ..u32(round)
      ..u64(value);
    return w.done();
  }

  /// The bytes the signature covers.
  Uint8List get signedBody => _body(invoiceId: invoiceId, round: round, value: value);

  Uint8List encode() => Uint8List.fromList([...signedBody, ...signature]);

  /// The acknowledgement [bytes] hold, or a [Refusal] naming the field.
  static Acknowledgement decode(List<int> bytes) {
    final k = Reader.kindOf(bytes, version);
    if (k == null) {
      if (bytes.length < 2) throw const Refusal('size', 'an acknowledgement is at least 2 bytes');
      throw Refusal(
          'version', 'this library writes acknowledgement version $version and does not read ${bytes[0]}');
    }
    if (k != kind) throw Refusal('kind', 'kind $k is not an acknowledgement ($kind)');
    final r = Reader.open(bytes, version: version, kind: kind, max: encodedSize, what: 'an acknowledgement');
    return Reader.guard(() {
      final id = r.take('invoiceId', Invoice.idLength);
      final round = r.u32('round');
      final value = r.u64('value');
      final signature = r.take('signature', InvoiceKey.signatureLength);
      r.end('end', '%n bytes after the signature');
      if (round < 1) throw Refusal('round', 'a round number is 1 or more, not $round');
      return Acknowledgement._(invoiceId: id, round: round, value: value, signature: signature);
    });
  }

  /// Whether this acknowledges [invoice], checked against the invoice alone.
  ///
  /// The id is compared first: an acknowledgement for somebody else's invoice
  /// is a different failure from a forged one, and a payer holding several
  /// unpaid invoices needs to be told which.
  Future<Refusal?> check(Invoice invoice) async {
    if (!_eq(invoiceId, invoice.id)) {
      return Refusal('invoice',
          'this acknowledges invoice ${shortHex(invoiceId)} and the invoice given is ${shortHex(invoice.id)}');
    }
    if (value < invoice.amount) {
      return Refusal('amount', 'this invoice asks for ${invoice.amount} and this acknowledges $value');
    }
    final ok =
        await InvoiceKey.verify(signedBody, publicKey: invoice.signingKey, signature: signature);
    if (!ok) {
      return Refusal('signature',
          'does not verify under the key invoice ${shortHex(invoice.id)} carries, so it was not written by the '
          'payee that issued it');
    }
    return null;
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => 'Acknowledgement(${shortHex(invoiceId)}, round $round, $value)';
}
