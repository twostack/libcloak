import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:tstokenlib/tstokenlib.dart';

import '../keys/wallet_keys.dart';
import '../refusal.dart';
import 'codec.dart';

/// The signing key one address gets.
///
/// An address is issued from `ivk` and a diversifier, and so is this: one
/// address, one signing key, derived and never stored. A wallet that can issue
/// the address can sign for it, and a wallet that cannot, cannot.
///
/// Per address and not per wallet, on purpose. A wallet-wide signing key would
/// let a payer — or anyone who saw two invoices — tie them to one payee, which
/// is the exact thing a fresh address per invoice exists to prevent. The price
/// is that the key is as new as the address, so it cannot be recognised across
/// invoices; see the design record for what the signature therefore does and
/// does not prove.
class InvoiceKey {
  static const domain = 'tsl1-libcloak/invoice/1';
  static const publicKeyLength = 32;
  static const signatureLength = 64;

  static final _ed = Ed25519();

  /// The 32-byte seed for address [d] of the wallet behind [ivk].
  static Uint8List seedFor(List<int> ivk, List<int> d) => Uint8List.fromList(
      crypto.sha256.convert([...domain.codeUnits, ...lanesToBytes(ivk), ...lanesToBytes(d)]).bytes);

  static Future<SimpleKeyPair> pairFor(List<int> ivk, List<int> d) => _ed.newKeyPairFromSeed(seedFor(ivk, d));

  /// The public key a payer checks an invoice for address [d] against.
  static Future<List<int>> publicKeyFor(List<int> ivk, List<int> d) async =>
      (await (await pairFor(ivk, d)).extractPublicKey()).bytes;

  static Future<List<int>> sign(List<int> message, {required List<int> ivk, required List<int> d}) async =>
      (await _ed.sign(message, keyPair: await pairFor(ivk, d))).bytes;

  /// Whether [signature] over [message] verifies under [publicKey]. Never
  /// throws: a key or a signature of the wrong shape is a false, not a crash,
  /// because both arrived from somebody else.
  static Future<bool> verify(List<int> message, {required List<int> publicKey, required List<int> signature}) async {
    if (publicKey.length != publicKeyLength || signature.length != signatureLength) return false;
    try {
      return await _ed.verify(message,
          signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)));
    } catch (_) {
      return false;
    }
  }
}

/// The message a payee writes to ask for money.
///
/// A fresh address, an amount, an expiry and what it is for — the first half of
/// "payment in consideration of something", and what an acknowledgement later
/// refers back to. It carries no key of the payee's beyond the address's own
/// public material, no note, no balance and no history: everything in it is
/// either a public parameter of the pool or a value made for this one invoice.
class Invoice {
  /// Bumped when any field changes. An unknown version is refused, never
  /// guessed at.
  static const version = 1;
  static const kind = 1;

  /// The outer bound, read before a byte is allocated. It is four times the
  /// largest invoice this library writes, so a bigger KEM later does not need
  /// a new bound.
  static const maxInvoice = 8 * 1024;

  /// The memo, in encoded bytes. Small enough that the whole invoice stays
  /// under 2 KB at the hybrid KEM's address size even when the memo is full.
  static const maxMemo = 512;

  static const idLength = 16;

  /// The pool this invoice is for: the descriptor's tokenId, so a payer can
  /// tell it was written for the pool the payer is in.
  final List<int> tokenId;

  /// The address to pay, issued for this invoice and no other.
  final NoteAddress address;

  final int amount;

  /// When it stops being payable, as an absolute time, always in UTC.
  ///
  /// Absolute rather than a duration because the payer's clock and the payee's
  /// are the only two in the conversation and neither knows when the other
  /// read it. UTC because the two of them are rarely in the same place: an
  /// expiry written down as a local time is a different instant for each of
  /// them, and a round trip through the wire would not give back the field it
  /// was handed.
  final DateTime expiry;

  /// What an acknowledgement refers back to.
  final List<int> id;

  /// What the money is for, as the payee wrote it.
  final String memo;

  /// The public half of the key this address signs with.
  final List<int> signingKey;

  /// Over every other field, in the order they are written.
  final List<int> signature;

  Invoice._({
    required List<int> tokenId,
    required this.address,
    required this.amount,
    required DateTime expiry,
    required List<int> id,
    required this.memo,
    required List<int> signingKey,
    required List<int> signature,
  })  : expiry = expiry.toUtc(),
        tokenId = List<int>.unmodifiable(tokenId),
        id = List<int>.unmodifiable(id),
        signingKey = List<int>.unmodifiable(signingKey),
        signature = List<int>.unmodifiable(signature);

  /// Writes an invoice for [amount] payable to [address], signed under the
  /// key that address is issued from.
  ///
  /// [ivk] and the address's diversifier are the two things an address is made
  /// of, and they are the two things its signing key is made of, so a wallet
  /// holding [ivk] can write an invoice for any address it issued and nobody
  /// else can write one for that address at all.
  static Future<Invoice> issue({
    required List<int> tokenId,
    required List<int> ivk,
    required NoteAddress address,
    required int amount,
    required DateTime expiry,
    String memo = '',
    List<int>? id,
    Random? rng,
  }) async {
    final bad = _check(tokenId: tokenId, amount: amount, expiry: expiry, memo: memo);
    if (bad != null) throw bad;
    final r = rng ?? Random.secure();
    final theId = id ?? [for (int i = 0; i < idLength; i++) r.nextInt(256)];
    if (theId.length != idLength) throw ArgumentError('an invoice id is $idLength bytes, ${theId.length} given');
    final key = await InvoiceKey.publicKeyFor(ivk, address.d);
    final body = _body(
        tokenId: tokenId, address: address, amount: amount, expiry: expiry, id: theId, memo: memo, signingKey: key);
    final signature = await InvoiceKey.sign(body, ivk: ivk, d: address.d);
    return Invoice._(
        tokenId: tokenId,
        address: address,
        amount: amount,
        expiry: expiry,
        id: theId,
        memo: memo,
        signingKey: key,
        signature: signature);
  }

  /// The same at the **next fresh address** of [keys], advancing its counter.
  ///
  /// One invoice, one address, so two payers cannot be told apart by anyone
  /// but the payee and two payments to this payee cannot be tied together by
  /// anyone at all. The fields are checked before an address is taken, so an
  /// invoice that is refused does not burn one out of the counter.
  static Future<Invoice> issueFor({
    required List<int> tokenId,
    required WalletKeys keys,
    required int amount,
    required DateTime expiry,
    String memo = '',
    List<int>? id,
    Random? rng,
  }) async {
    final bad = _check(tokenId: tokenId, amount: amount, expiry: expiry, memo: memo);
    if (bad != null) throw bad;
    return issue(
        tokenId: tokenId,
        ivk: keys.ivk,
        address: await keys.nextAddress(),
        amount: amount,
        expiry: expiry,
        memo: memo,
        id: id,
        rng: rng);
  }

  static Refusal? _check(
      {required List<int> tokenId, required int amount, required DateTime expiry, required String memo}) {
    if (tokenId.length != 32) return Refusal('tokenId', 'a tokenId is 32 bytes, ${tokenId.length} given');
    if (amount < 1 || amount >= PoolHash.maxValue) {
      return Refusal('amount', 'an invoice asks for 1 to ${PoolHash.maxValue - 1}, not $amount');
    }
    final ms = expiry.millisecondsSinceEpoch;
    if (ms < 0 || ms > 0xffffffffffff) return Refusal('expiry', 'is not a time this format can carry');
    if (utf8.encode(memo).length > maxMemo) {
      return Refusal('memo', 'is ${utf8.encode(memo).length} bytes, at most $maxMemo');
    }
    return null;
  }

  // ---- wire format ----
  //
  //   version, kind    1 + 1
  //   tokenId          32
  //   address          4 + up to 1,261
  //   amount           8
  //   expiry           8, milliseconds since the epoch
  //   id               16
  //   memo             4 + up to 512, UTF-8
  //   signing key      32
  //   signature        64

  static Uint8List _body({
    required List<int> tokenId,
    required NoteAddress address,
    required int amount,
    required DateTime expiry,
    required List<int> id,
    required String memo,
    required List<int> signingKey,
  }) {
    final w = Writer(version, kind)
      ..bytes(tokenId)
      ..sized(address.bytes)
      ..u64(amount)
      ..u64(expiry.millisecondsSinceEpoch)
      ..bytes(id)
      ..sized(utf8.encode(memo))
      ..bytes(signingKey);
    return w.done();
  }

  /// The bytes the signature covers: everything but the signature.
  Uint8List get signedBody => _body(
      tokenId: tokenId,
      address: address,
      amount: amount,
      expiry: expiry,
      id: id,
      memo: memo,
      signingKey: signingKey);

  Uint8List encode() {
    final body = signedBody;
    return Uint8List.fromList([...body, ...signature]);
  }

  /// The invoice [bytes] hold, or a [Refusal] naming the field that stopped
  /// it. Nothing is verified here — [read] is what a payer calls.
  static Invoice decode(List<int> bytes) {
    final k = Reader.kindOf(bytes, version);
    if (k == null) {
      if (bytes.length < 2) throw const Refusal('size', 'an invoice is at least 2 bytes');
      throw Refusal('version', 'this library writes invoice version $version and does not read ${bytes[0]}');
    }
    if (k != kind) throw Refusal('kind', 'kind $k is not an invoice ($kind)');
    final r = Reader.open(bytes, version: version, kind: kind, max: maxInvoice, what: 'an invoice');
    return Reader.guard(() {
      final tokenId = r.take('tokenId', 32);
      final addressBytes = r.sized('address', AddressCodec.maxLength);
      final (address, whyAddress) = AddressCodec.read(addressBytes);
      if (address == null) throw whyAddress!;
      final amount = r.u64('amount');
      final expiry = r.u64('expiry');
      final id = r.take('id', idLength);
      final memoBytes = r.sized('memo', maxMemo, min: 0);
      final String memo;
      try {
        memo = utf8.decode(memoBytes);
      } on FormatException {
        throw const Refusal('memo', 'is not text this library can read');
      }
      final signingKey = r.take('signingKey', InvoiceKey.publicKeyLength);
      final signature = r.take('signature', InvoiceKey.signatureLength);
      r.end('end', '%n bytes after the signature');
      if (expiry > 0xffffffffffff) throw Refusal('expiry', 'is not a time this format can carry');
      final bad = _check(
          tokenId: tokenId,
          amount: amount,
          expiry: DateTime.fromMillisecondsSinceEpoch(expiry, isUtc: true),
          memo: memo);
      if (bad != null) throw bad;
      return Invoice._(
          tokenId: tokenId,
          address: address,
          amount: amount,
          expiry: DateTime.fromMillisecondsSinceEpoch(expiry, isUtc: true),
          id: id,
          memo: memo,
          signingKey: signingKey,
          signature: signature);
    });
  }

  /// Whether the signature covers these fields under the key the invoice
  /// carries. Null when it does.
  Future<Refusal?> verifySignature() async {
    final ok = await InvoiceKey.verify(signedBody, publicKey: signingKey, signature: signature);
    if (ok) return null;
    return Refusal('signature',
        'does not cover this invoice under the key it carries, so at least one field was changed after it was '
        'written; the address is ${shortHex(address.bytes)}');
  }

  /// The invoice in [bytes], checked the way a payer checks one, or the first
  /// check that failed.
  ///
  /// The order is part of the contract, because a refusal names the step and a
  /// person acts on that name. It is, stopping at the first failure:
  ///
  /// 1. the encoding and its bounds;
  /// 2. the pool, so a payment cannot go into a pool the payer did not mean;
  /// 3. the expiry, which is a comparison of two numbers;
  /// 4. the signature, which is the first thing here that costs a key
  ///    operation — and the spend proof, which costs seconds, comes after all
  ///    four.
  static Future<(Invoice?, Refusal?)> read(
    List<int> bytes, {
    required List<int> tokenId,
    required DateTime now,
  }) async {
    final Invoice invoice;
    try {
      invoice = decode(bytes);
    } on Refusal catch (e) {
      return (null, e);
    }
    final why = await invoice.check(tokenId: tokenId, now: now);
    return why == null ? (invoice, null) : (null, why);
  }

  /// The same checks on an invoice already decoded.
  Future<Refusal?> check({required List<int> tokenId, required DateTime now}) async {
    if (!_eq(this.tokenId, tokenId)) {
      return Refusal('pool',
          'this invoice is for pool ${shortHex(this.tokenId)} and this payer is in pool ${shortHex(tokenId)}');
    }
    if (!expiry.isAfter(now)) {
      return Refusal('expiry',
          'this invoice expired at ${expiry.toUtc().toIso8601String()} and it is now '
          '${now.toUtc().toIso8601String()}; ask the payee for another');
    }
    return verifySignature();
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'Invoice(${shortHex(id)} $amount, expires ${expiry.toUtc().toIso8601String()}, ${memo.length} chars)';
}
