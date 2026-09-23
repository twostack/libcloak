import 'dart:math';

import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

/// The message a payee writes to ask for money.
///
/// An invoice is the first half of "payment in consideration of something", so
/// what it has to be is unambiguous about **which pool**, **how much**, **to
/// which address** and **until when**, and it has to be those things after
/// crossing a channel nobody controls. Everything here is about that crossing:
/// a signature over every field, bounds before allocation, and a check order a
/// person can act on.
///
/// No pool is proved here. An invoice names a pool by its tokenId and carries
/// nothing else about it, which is the point — a payee writes one without
/// looking anything up.
void main() {
  // the payee's wallet, from the vector seed the keys suite records
  final payeeSeed = WalletSeed.fromHex('0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0');
  final payerSeed = WalletSeed.fromHex('f0e1d2c3b4a5968778695a4b3c2d1e0ff0e1d2c3b4a5968778695a4b3c2d1e0f');
  final ourPool = List<int>.generate(32, (i) => i + 1);
  final otherPool = List<int>.generate(32, (i) => 200 - i);

  late WalletKeys payee;
  late Invoice good;
  late DateTime now, soon;

  setUp(() async {
    payee = WalletKeys(seed: payeeSeed, birthday: 1);
    now = DateTime.utc(2026, 9, 23, 12);
    soon = now.add(const Duration(hours: 1));
    good = await Invoice.issueFor(
        tokenId: ourPool,
        keys: payee,
        amount: 12500,
        expiry: soon,
        memo: 'one crate of oranges',
        id: List<int>.generate(Invoice.idLength, (i) => i),
        rng: Random(7));
  });

  group('what an invoice carries', () {
    test('An invoice round trips', () async {
      final bytes = good.encode();
      final back = Invoice.decode(bytes);

      expect(back.tokenId, good.tokenId);
      expect(back.address.bytes, good.address.bytes);
      expect(back.amount, 12500);
      expect(back.expiry, soon);
      expect(back.expiry.isUtc, isTrue);

      // an expiry written in a local zone comes back as the same instant
      final local = await Invoice.issueFor(
          tokenId: ourPool,
          keys: payee,
          amount: 1,
          expiry: soon.toLocal(),
          id: List<int>.generate(Invoice.idLength, (i) => i));
      expect(Invoice.decode(local.encode()).expiry, local.expiry);
      expect(local.expiry, soon);
      expect(back.id, good.id);
      expect(back.memo, 'one crate of oranges');
      expect(back.signingKey, good.signingKey);
      expect(back.signature, good.signature);
      expect(back.encode(), bytes, reason: 'byte-identical');

      final (checked, why) = await Invoice.read(bytes, tokenId: ourPool, now: now);
      expect(why, isNull);
      expect(checked!.amount, 12500);
    });

    test('One invoice, one address', () async {
      expect(payee.addressesIssued, 1, reason: 'issuing the fixture invoice took one');
      final second = await Invoice.issueFor(
          tokenId: ourPool, keys: payee, amount: 1, expiry: soon, rng: Random(8));
      expect(payee.addressesIssued, 2);
      expect(second.address.bytes, isNot(equals(good.address.bytes)));
      expect(second.signingKey, isNot(equals(good.signingKey)),
          reason: 'a new key with the new address, so two invoices cannot be tied together');
      expect(await second.verifySignature(), isNull);

      // and an invoice that is refused before it is written does not burn one
      expect(() => Invoice.issueFor(tokenId: ourPool, keys: payee, amount: 0, expiry: soon),
          throwsA(isA<Refusal>()));
      expect(payee.addressesIssued, 2);
    });

    test('Size', () async {
      final memo = 'o' * 256;
      final big = await Invoice.issueFor(
          tokenId: ourPool, keys: payee, amount: 1 << 40, expiry: soon, memo: memo, rng: Random(9));
      final bytes = big.encode();
      expect(big.address.kem, NoteAddress.kemHybrid);
      print('    hybrid-KEM invoice with a 256-byte memo: ${bytes.length} bytes '
          '(address ${big.address.bytes.length}, memo 256)');
      expect(bytes.length, lessThan(2048));

      // and the largest this library writes is still under 2 KB
      final full = await Invoice.issueFor(
          tokenId: ourPool, keys: payee, amount: 1, expiry: soon, memo: 'x' * Invoice.maxMemo, rng: Random(10));
      print('    the same with the memo full (${Invoice.maxMemo} bytes): ${full.encode().length} bytes');
      expect(full.encode().length, lessThan(2048));
      expect(full.encode().length, lessThan(Invoice.maxInvoice));
    });

    test('A memo longer than the bound', () {
      expect(
          () => Invoice.issueFor(
              tokenId: ourPool, keys: payee, amount: 1, expiry: soon, memo: 'x' * (Invoice.maxMemo + 1)),
          throwsA(isA<Refusal>().having((e) => e.step, 'step', 'memo')));
      expect(payee.addressesIssued, 1);
    });
  });

  group('an invoice names one pool', () {
    test('Another pool\'s invoice', () async {
      final (read, why) = await Invoice.read(good.encode(), tokenId: otherPool, now: now);
      expect(read, isNull);
      expect(why!.step, 'pool');
      expect(why.reason, contains(shortHex(ourPool)), reason: 'the invoice\'s pool');
      expect(why.reason, contains(shortHex(otherPool)), reason: 'and the payer\'s');
    });
  });

  group('expiry is checked before work is done', () {
    test('Expired before proving', () async {
      final late = now.add(const Duration(hours: 2));
      final (read, why) = await Invoice.read(good.encode(), tokenId: ourPool, now: late);
      expect(read, isNull);
      expect(why!.step, 'expiry');
      expect(why.reason, contains(soon.toUtc().toIso8601String()));

      // the expiry gate is in front of the key work: an invoice that is both
      // expired and unsigned is refused for being expired, so nothing past
      // that gate — a signature check, and later a spend proof — ever ran
      final unsigned = List<int>.of(good.encode());
      for (int i = unsigned.length - InvoiceKey.signatureLength; i < unsigned.length; i++) {
        unsigned[i] = 0;
      }
      final (none, whyUnsigned) = await Invoice.read(unsigned, tokenId: ourPool, now: late);
      expect(none, isNull);
      expect(whyUnsigned!.step, 'expiry');

      // and at the moment it expires it is already too late
      expect((await Invoice.read(good.encode(), tokenId: ourPool, now: soon)).$2!.step, 'expiry');
      expect(
          (await Invoice.read(good.encode(),
                  tokenId: ourPool, now: soon.subtract(const Duration(milliseconds: 1))))
              .$2,
          isNull);
    });
  });

  group('the signature binds the address to the payee', () {
    test('A substituted address', () async {
      final mallory = WalletKeys(seed: payerSeed, birthday: 1);
      final hers = await mallory.nextAddress();
      expect(hers.bytes.length, good.address.bytes.length);

      // her address, his signature: every other byte left exactly as it was
      final bytes = List<int>.of(good.encode());
      final at = _indexOf(bytes, good.address.bytes);
      expect(at, greaterThan(0), reason: 'the address is in there');
      bytes.setRange(at, at + hers.bytes.length, hers.bytes);

      final (read, why) = await Invoice.read(bytes, tokenId: ourPool, now: now);
      expect(read, isNull);
      expect(why!.step, 'signature');
      expect(why.reason, contains(shortHex(hers.bytes)), reason: 'it names the address it refused');

      // every other field is the same one-field story
      for (final (field, mutate) in <(String, void Function(List<int>))>[
        ('amount', (b) => b[_indexOf(b, good.address.bytes) + good.address.bytes.length] ^= 1),
        ('tokenId', (b) => b[3] ^= 1),
      ]) {
        final bent = List<int>.of(good.encode());
        mutate(bent);
        final (_, w) = await Invoice.read(bent, tokenId: ourPool, now: now);
        expect(w, isNotNull, reason: field);
        expect(w!.step, anyOf('signature', 'pool'), reason: field);
      }
    });

    test('A signature from another address', () async {
      // the signing key swapped for one the payee really does hold, for a
      // different address: the signature no longer covers the body
      final other = await payee.addressAt(50);
      final key = await InvoiceKey.publicKeyFor(payee.ivk, other.d);
      final bytes = List<int>.of(good.encode());
      final at = bytes.length - InvoiceKey.signatureLength - InvoiceKey.publicKeyLength;
      bytes.setRange(at, at + key.length, key);

      final (read, why) = await Invoice.read(bytes, tokenId: ourPool, now: now);
      expect(read, isNull);
      expect(why!.step, 'signature');
    });
  });

  group('untrusted input', () {
    test('Mutated invoices', () async {
      final rng = Random(4711);
      final base = good.encode();
      final counts = <String, int>{};
      var parsed = 0, verified = 0, unnamed = 0;
      const runs = 10000;

      for (int i = 0; i < runs; i++) {
        final bent = List<int>.of(base);
        if (i % 5 == 4) {
          // truncated, at every length from nothing to one byte short
          bent.removeRange(rng.nextInt(bent.length), bent.length);
        } else {
          final flips = 1 + rng.nextInt(3);
          for (int f = 0; f < flips; f++) {
            bent[rng.nextInt(bent.length)] ^= 1 << rng.nextInt(8);
          }
        }
        Invoice? invoice;
        try {
          invoice = Invoice.decode(bent);
        } on Refusal catch (e) {
          counts[e.step] = (counts[e.step] ?? 0) + 1;
          expect(e.reason, isNotEmpty);
          continue;
        } catch (e) {
          unnamed++;
          fail('an invoice mutation threw ${e.runtimeType}: $e');
        }
        parsed++;
        // it parsed; it still has to be the invoice the payee wrote
        final why = await invoice.check(tokenId: ourPool, now: now);
        if (why == null) {
          verified++;
          expect(invoice.encode(), base, reason: 'anything that verifies is the original');
        } else {
          counts['checked: ${why.step}'] = (counts['checked: ${why.step}'] ?? 0) + 1;
        }
      }

      expect(unnamed, 0);
      print('    $runs mutations: $parsed parsed, $verified of those still verified, '
          '${[for (final e in counts.entries) '${e.value} ${e.key}'].join(', ')}');
    });

    test('An invoice larger than the bound', () {
      final huge = [...good.encode(), ...List<int>.filled(Invoice.maxInvoice, 0)];
      final why = _refusalFrom(() => Invoice.decode(huge));
      expect(why.step, 'size');
      expect(why.reason, contains('${Invoice.maxInvoice}'));
    });

    test('A memo that is not text', () {
      final bytes = List<int>.of(good.encode());
      // the memo sits between the id and the signing key
      final at = bytes.length - InvoiceKey.signatureLength - InvoiceKey.publicKeyLength - 20;
      bytes[at] = 0xff;
      bytes[at + 1] = 0xfe;
      final why = _refusalFrom(() => Invoice.decode(bytes));
      expect(why.step, 'memo');
    });
  });

  group('privacy, determinism and compatibility', () {
    test('Nothing extra in an invoice', () {
      final bytes = good.encode();
      final secrets = <String, List<int>>{
        'seed': payeeSeed.bytes,
        'sk': lanesToBytes(payee.sk),
        'ivk': lanesToBytes(payee.ivk),
        'nk': lanesToBytes(payee.nk),
        'ovk': lanesToBytes(payee.ovk),
        'the invoice signing seed': InvoiceKey.seedFor(payee.ivk, good.address.d),
      };
      secrets.forEach((name, secret) {
        expect(_indexOf(bytes, secret), -1, reason: '$name is in the invoice');
        // and not four bytes of it either, which would be enough to notice
        for (int i = 0; i + 4 <= secret.length; i++) {
          expect(_indexOf(bytes, secret.sublist(i, i + 4)), -1, reason: '$name at $i');
        }
      });
    });

    test('Unknown version', () {
      final bytes = List<int>.of(good.encode());
      bytes[0] = 4;
      final why = _refusalFrom(() => Invoice.decode(bytes));
      expect(why.step, 'version');
      expect(why.reason, contains('4'));
    });

    test('Deterministic', () async {
      Future<List<int>> write() async => (await Invoice.issueFor(
              tokenId: ourPool,
              keys: WalletKeys(seed: payeeSeed, birthday: 1),
              amount: 12500,
              expiry: soon,
              memo: 'one crate of oranges',
              id: List<int>.generate(Invoice.idLength, (i) => i)))
          .encode();
      expect(await write(), await write());
      expect(await write(), good.encode());
    });
  });

  group('failure behaviour', () {
    test('A refused invoice changes nothing', () async {
      final payer = WalletKeys(seed: payerSeed, birthday: 1);
      await payer.nextAddress();
      final (shape, _) = PoolShape.of(32);
      final store = NoteStore(shape!);
      final view = PoolView.atGenesis(shape);

      final before = (
        addresses: payer.addressesIssued,
        notes: store.encode(),
        view: view.encode(),
      );

      final bent = List<int>.of(good.encode());
      bent[40] ^= 1;
      for (final (what, bytes, tokenId, at) in [
        ('another pool', good.encode(), otherPool, now),
        ('expired', good.encode(), ourPool, now.add(const Duration(days: 1))),
        ('a bent field', bent, ourPool, now),
        ('nonsense', List<int>.filled(200, 3), ourPool, now),
        ('nothing at all', <int>[], ourPool, now),
      ]) {
        final (read, why) = await Invoice.read(bytes, tokenId: tokenId, now: at);
        expect(read, isNull, reason: what);
        expect(why, isNotNull, reason: what);
        expect(why!.step, isNotEmpty, reason: what);
      }

      expect(payer.addressesIssued, before.addresses);
      expect(store.encode(), before.notes);
      expect(view.encode(), before.view);
    });
  });
}

int _indexOf(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return -1;
  for (int i = 0; i + needle.length <= haystack.length; i++) {
    var same = true;
    for (int k = 0; k < needle.length; k++) {
      if (haystack[i + k] != needle[k]) {
        same = false;
        break;
      }
    }
    if (same) return i;
  }
  return -1;
}

Refusal _refusalFrom(void Function() f) {
  try {
    f();
  } on Refusal catch (e) {
    return e;
  }
  fail('expected a refusal');
}
