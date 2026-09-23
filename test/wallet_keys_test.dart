import 'dart:io';
import 'dart:math';

import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

/// One seed, and everything the wallet is.
///
/// The two tests that matter here are the vector and the linkability one. The
/// vector is the reason a change to the derivation cannot pass quietly: every
/// key below is a number this machine printed once, and a wallet restored from
/// a seed under a changed derivation would be a different wallet holding none
/// of the same money. The linkability test is the privacy claim: two addresses
/// of one wallet are two unrelated strings unless you hold the `ivk`.
void main() {
  // the recorded vector's seed. A test value, and nothing is ever paid to it.
  const vectorSeed = '0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0';

  WalletKeys keys({String hex = vectorSeed, int birthday = 1, int issued = 0}) =>
      WalletKeys(seed: WalletSeed.fromHex(hex), birthday: birthday, addressesIssued: issued);

  group('one seed, derived deterministically', () {
    test('Same seed, same wallet', () async {
      final a = keys(), b = keys();
      expect(b.sk, a.sk);
      expect(b.ivk, a.ivk);
      expect(b.nk, a.nk);
      expect(b.ovk, a.ovk);
      for (int i = 0; i < 10; i++) {
        expect((await b.addressAt(i)).bytes, (await a.addressAt(i)).bytes, reason: 'address $i');
      }

      final other = keys(hex: '00' * 31 + '01');
      expect(other.sk, isNot(a.sk), reason: 'another seed is another wallet');
      expect(other.ivk, isNot(a.ivk));
    });

    test('A derivation vector', () async {
      final k = keys();
      expect(WalletKeys.derivation, 1, reason: 'the vector below is derivation 1; a new one gets a new number');
      expect(k.sk, [842271136, 1775936296, 1816971963, 2071168744, 632125368]);
      expect(k.ivk, [1009778970, 2072823930, 1696538744, 809588237, 1388827091, 1548207528, 1000809654, 2036092640]);
      expect(k.nk, [715058064, 746731601, 342641158, 273178814, 1332970092, 144843471, 1367560907, 531077815]);
      expect(k.ovk, [964058004, 1978336182, 1061990410, 741434912, 1299862567, 1265704623, 1759286136, 1673995544]);

      final a0 = await k.addressAt(0);
      expect(a0.d, [2071703561, 1773284095, 147134292]);
      expect(a0.pkd, [1858716667, 2031314884, 870788963, 49704688, 1954542084, 411024145, 2080987906, 32785929]);
      expect(a0.bytes.length, 1261, reason: 'the hybrid KEM address');

      final a1 = await k.addressAt(1);
      expect(a1.d, [230763602, 312407162, 1258453610]);
      expect(a1.pkd, [1164700870, 392025208, 1717067055, 892219808, 108171770, 302274507, 1136963008, 1160418846]);

      for (final lane in [...k.sk, ...k.ivk, ...k.nk, ...k.ovk, ...a0.d, ...a0.pkd]) {
        expect(lane, lessThan(2147483647), reason: 'every lane is inside M31');
        expect(lane, greaterThanOrEqualTo(0));
      }
    });

    test('the keys below sk are tstokenlib\'s, because the circuit derives them', () {
      final k = keys();
      expect(k.ivk, PoolHash.ivk(k.sk));
      expect(k.nk, PoolHash.nk(k.sk));
      expect(k.ovk, PoolHash.ovk(k.sk));
    });
  });

  group('a fresh address per invoice', () {
    test('Ten invoices, ten addresses', () async {
      final k = keys();
      expect(k.addressesIssued, 0);
      final issued = [for (int i = 0; i < 10; i++) await k.nextAddress()];
      expect(k.addressesIssued, 10, reason: 'one invoice, one address');

      final diversifiers = {for (final a in issued) a.d.join(',')};
      expect(diversifiers, hasLength(10), reason: 'no diversifier is used twice');
      expect({for (final a in issued) a.pkd.join(',')}, hasLength(10));

      // and the counter is what the wallet file carries, so a restored wallet
      // does not hand out an address it already used
      final restored = keys(issued: k.addressesIssued);
      expect((await restored.nextAddress()).d, isNot(anyOf([for (final a in issued) a.d])));
      expect(restored.addressesIssued, 11);
    });

    test('Addresses do not link', () async {
      final k = keys();
      final a = await k.addressAt(3), b = await k.addressAt(4);

      expect(a.d, isNot(b.d));
      expect(a.pkd, isNot(b.pkd));
      expect(a.epk, isNot(b.epk));

      // nothing of one turns up in the other: no four-byte run of a's secret
      // bearing fields appears anywhere in b's encoding, and the reverse
      final one = [...lanesToBytes(a.d), ...lanesToBytes(a.pkd), ...a.epk];
      final two = [...lanesToBytes(b.d), ...lanesToBytes(b.pkd), ...b.epk];
      for (int i = 0; i + 4 <= one.length; i++) {
        expect(_contains(two, one.sublist(i, i + 4)), isFalse, reason: 'a run of address 3 is in address 4 at $i');
      }
      expect(a.kem, b.kem, reason: 'the KEM id is the one field they share, and it is a format constant');

      // with the ivk they link at once, which is the point: a viewer can
      // enumerate every address, a payer cannot
      expect(await k.addressAt(3), isNotNull);
      expect(PoolHash.diversifier(k.ivk, 3), a.d);
      expect(PoolHash.diversifier(k.ivk, 4), b.d);
    });
  });

  group('the birthday', () {
    test('Born at a round', () async {
      final k = keys(birthday: 7);
      expect(k.birthday, 7);
      expect(k.couldHoldNotesIn(6), isFalse, reason: 'round 6 was over before this wallet existed');
      expect(k.couldHoldNotesIn(7), isTrue);
      expect(k.couldHoldNotesIn(8), isTrue);
      // the pool view starts here; it is built in group 5 and takes this number
      expect(() => keys(birthday: -1), throwsArgumentError);
    });
  });

  group('untrusted input', () {
    test('a well formed address reads back', () async {
      final a = await keys().addressAt(0);
      final (read, refusal) = AddressCodec.read(a.bytes);
      expect(refusal, isNull);
      expect(read!.bytes, a.bytes);
      expect(AddressCodec.maxLength, a.bytes.length);
    });

    test('Mutated addresses', () async {
      final good = (await keys().addressAt(0)).bytes;
      final rng = Random(4919);
      var refused = 0, accepted = 0;
      for (int i = 0; i < 10000; i++) {
        final b = List<int>.from(good);
        switch (rng.nextInt(4)) {
          case 0: // a flipped byte anywhere
            b[rng.nextInt(b.length)] ^= 1 << rng.nextInt(8);
          case 1: // a replaced byte anywhere
            b[rng.nextInt(b.length)] = rng.nextInt(256);
          case 2: // cut short
            b.removeRange(rng.nextInt(b.length), b.length);
          case 3: // a lane pushed out of the field
            final lane = 1 + 4 * rng.nextInt(11);
            b.setRange(lane, lane + 4, const [0xff, 0xff, 0xff, 0xff]);
        }
        final (address, refusal) = AddressCodec.read(b);
        expect(address == null, refusal != null, reason: 'one or the other, never both, at $i');
        if (refusal != null) {
          expect(refusal.step, isNotEmpty);
          expect(refusal.reason, isNotEmpty);
          refused++;
        } else {
          accepted++;
          expect(address!.bytes, b, reason: 'what parsed re-encodes to what was given');
          expect(NoteKem.isKem(address.kem), isTrue);
          expect(address.d, hasLength(PoolHash.dLanes));
          expect(address.pkd, hasLength(PoolHash.digestLanes));
          for (final lane in [...address.d, ...address.pkd]) {
            expect(lane, lessThan(2147483647));
          }
        }
      }
      expect(refused + accepted, 10000);
      expect(refused, greaterThan(0));
      expect(accepted, greaterThan(0), reason: 'a flipped byte in the KEM key is still a well formed address');
      printOnFailure('$refused refused, $accepted parsed');
    });

    test('a truncated, empty or unknown-KEM address is refused by name', () {
      expect(AddressCodec.read(const []).$2!.step, 'address');
      expect(AddressCodec.read(const [9, 1, 2]).$2!.step, 'kem');
      expect(AddressCodec.read(const [NoteKem.x25519, 1, 2]).$2!.step, 'length');
      final short = List.filled(45 + 32, 0)..[0] = NoteKem.x25519;
      short.setRange(1, 5, const [0xff, 0xff, 0xff, 0xff]);
      expect(AddressCodec.read(short).$2!.step, 'diversifier');
      final badPkd = List.filled(45 + 32, 0)..[0] = NoteKem.x25519;
      badPkd.setRange(13, 17, const [0xff, 0xff, 0xff, 0xff]);
      expect(AddressCodec.read(badPkd).$2!.step, 'pkd');
    });
  });

  group('secrets never leave', () {
    test('Errors carry no secrets', () async {
      final dir = await Directory.systemTemp.createTemp('libcloak-keys-');
      addTearDown(() => dir.delete(recursive: true));
      const passphrase = 'a passphrase nobody should see';
      final k = keys(birthday: 3);
      final path = '${dir.path}/wallet.cloak';
      await WalletFile.create(path: path, passphrase: passphrase, keys: k, kdf: WalletKdf.fast);

      final raised = <String>[];
      Future<void> collect(Future<void> Function() f) async {
        try {
          await f();
          fail('expected a refusal');
        } catch (e) {
          raised.add('$e');
        }
      }

      // every error this capability can raise, in one place
      void collectSync(void Function() f) {
        try {
          f();
          fail('expected an error');
        } catch (e) {
          raised.add('$e');
        }
      }

      collectSync(() => WalletSeed.fromHex('00'));
      collectSync(() => WalletSeed.fromHex('zz' * 32));
      collectSync(() => WalletSeed(const [1, 2, 3]));
      collectSync(() => keys(birthday: -1));
      collectSync(() => keys(issued: -1));
      collectSync(() => WalletKeys(seed: WalletSeed.fromHex(vectorSeed), birthday: 0, kem: 77));
      collectSync(() => k.addressAt(-1));
      collectSync(() => k.addressAt(WalletKeys.maxAddressIndex + 1));
      raised.add('$k');
      raised.add('${k.seed}');
      raised.add('${WalletKdf.fast}');
      for (final b in [const <int>[], const [9, 1, 2], const [NoteKem.x25519, 1, 2]]) {
        raised.add('${AddressCodec.read(b).$2}');
      }

      await collect(() => WalletFile.open(path: '${dir.path}/nothing-here', passphrase: passphrase));
      await collect(() => WalletFile.open(path: path, passphrase: 'not the passphrase'));
      await collect(() => WalletFile.create(path: path, passphrase: passphrase, keys: k, kdf: WalletKdf.fast));
      await collect(() =>
          WalletFile.save(path: path, passphrase: passphrase, keys: k, kdf: const WalletKdf(memory: 1 << 30)));
      await collect(() => WalletFile.save(path: path, passphrase: '', keys: k, kdf: WalletKdf.fast));
      final broken = '${dir.path}/broken.cloak';
      final good = await File(path).readAsBytes();
      await File(broken).writeAsBytes([99, ...good.skip(1)]);
      await collect(() => WalletFile.open(path: broken, passphrase: passphrase));
      await File(broken).writeAsBytes(good.take(good.length - 3).toList());
      await collect(() => WalletFile.open(path: broken, passphrase: passphrase));

      expect(raised.length, greaterThan(15));
      final secrets = <String, List<int>>{
        'the seed': k.seed.bytes,
        'sk': lanesToBytes(k.sk),
        'ivk': lanesToBytes(k.ivk),
        'nk': lanesToBytes(k.nk),
        'ovk': lanesToBytes(k.ovk),
      };
      for (final message in raised) {
        expect(message, isNot(contains(passphrase)), reason: 'a message carried the passphrase: $message');
        expect(message.toLowerCase(), isNot(contains(vectorSeed)), reason: 'a message carried the seed: $message');
        for (final entry in secrets.entries) {
          expect(_contains(message.codeUnits, entry.value), isFalse,
              reason: '${entry.key} appears in: $message');
          expect(message, isNot(contains(entry.value.join(', '))), reason: '${entry.key} appears in: $message');
        }
        for (final lanes in [k.sk, k.ivk, k.nk, k.ovk]) {
          expect(message, isNot(contains(lanes.join(', '))));
        }
      }
    });
  });
}

bool _contains(List<int> hay, List<int> needle) {
  if (needle.isEmpty || needle.length > hay.length) return false;
  for (int i = 0; i + needle.length <= hay.length; i++) {
    var same = true;
    for (int j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        same = false;
        break;
      }
    }
    if (same) return true;
  }
  return false;
}
