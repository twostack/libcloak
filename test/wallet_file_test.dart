import 'dart:io';
import 'dart:math';

import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

/// The wallet at rest.
///
/// The file is the only copy of the seed there is, so the tests here are about
/// the two ways it is lost: opened by somebody who should not have it, and
/// destroyed by a write that did not finish. Everything runs under
/// [WalletKdf.fast], which is 8 MiB and one pass — the cost belongs in the
/// defaults, not in a suite that opens a wallet forty times.
void main() {
  const passphrase = 'correct horse battery staple';
  const seedHex = '0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0';

  late Directory dir;
  late String path;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('libcloak-file-');
    path = '${dir.path}/wallet.cloak';
  });
  tearDown(() => dir.delete(recursive: true));

  WalletKeys keys({int birthday = 7, int issued = 3}) =>
      WalletKeys(seed: WalletSeed.fromHex(seedHex), birthday: birthday, addressesIssued: issued);

  Future<void> write({WalletKdf kdf = WalletKdf.fast, WalletKeys? k, String pass = passphrase, String? at}) =>
      WalletFile.save(path: at ?? path, passphrase: pass, keys: k ?? keys(), kdf: kdf, rng: Random(11));

  group('keys at rest', () {
    test('a wallet written is the wallet read back', () async {
      final notice = await WalletFile.create(
          path: path, passphrase: passphrase, keys: keys(), kdf: WalletKdf.fast, rng: Random(11));
      expect(notice.path, path);
      expect(notice.notice, contains(path));
      expect(notice.notice, contains('nowhere else'), reason: 'creation says the seed has no other copy');

      final stored = await WalletFile.open(path: path, passphrase: passphrase);
      expect(stored.derivation, WalletKeys.derivation);
      expect(stored.seed.bytes, WalletSeed.fromHex(seedHex).bytes);
      expect(stored.addressesIssued, 3);
      expect(stored.birthday, 7);
      expect(stored.keys.ivk, keys().ivk, reason: 'the same wallet, not a similar one');
    });

    test('creating over an existing file is refused, saving over it is not', () async {
      await write();
      await expectLater(
          WalletFile.create(path: path, passphrase: passphrase, keys: keys(), kdf: WalletKdf.fast),
          throwsA(isA<Refusal>().having((r) => r.step, 'step', 'file')));
      await write(k: keys(issued: 9));
      expect((await WalletFile.open(path: path, passphrase: passphrase)).addressesIssued, 9);
    });

    test('the file is owner-only', () async {
      await write();
      final mode = (await File(path).stat()).mode & 0x1ff;
      expect(mode, 0x180, reason: 'rw for the owner and nothing for anybody else, not ${mode.toRadixString(8)}');
    }, skip: Platform.isWindows ? 'POSIX permissions' : null);

    test('Wrong passphrase', () async {
      await write();
      await expectLater(
          WalletFile.open(path: path, passphrase: 'not it'),
          throwsA(isA<Refusal>()
              .having((r) => r.step, 'step', 'passphrase')
              .having((r) => r.reason, 'names the file', contains(path))));
      final refusal = await WalletFile.open(path: path, passphrase: 'not it').then<Object?>((_) => null, onError: (e) => e);
      expect('$refusal', isNot(contains(seedHex)));
      expect('$refusal', isNot(contains('not it')), reason: 'the refusal names the file, never the key tried');
      // and the file is untouched by the attempt
      expect((await WalletFile.open(path: path, passphrase: passphrase)).birthday, 7);
    });

    test('Nothing in the clear', () async {
      final k = keys();
      await write(k: k);
      final bytes = await File(path).readAsBytes();
      final secrets = <String, List<int>>{
        'the seed': k.seed.bytes,
        'sk': lanesToBytes(k.sk),
        'ivk': lanesToBytes(k.ivk),
        'nk': lanesToBytes(k.nk),
        'ovk': lanesToBytes(k.ovk),
      };
      for (final entry in secrets.entries) {
        expect(_contains(bytes, entry.value), isFalse, reason: '${entry.key} is in the file in the clear');
      }
      expect(_contains(bytes, passphrase.codeUnits), isFalse);
      // the counter and the birthday are inside the box too: what an attacker
      // can read is the version, the cost and the salt
      expect(bytes.length, lessThan(WalletFile.maxFile));
      expect(bytes[0], WalletFile.version);
      expect(bytes[1], WalletFile.kind);
    });

    test('the header is the box\'s associated data, so the cost cannot be lowered in place', () async {
      await write(kdf: const WalletKdf(memory: 16384, iterations: 2));
      final bytes = (await File(path).readAsBytes()).toList();
      expect(bytes[3], 16384 & 0xff);
      bytes[3] = 8; // 8 KiB: cheap enough to grind, if it were allowed to stand
      bytes[4] = 0;
      bytes[5] = 0;
      bytes[6] = 0;
      await File(path).writeAsBytes(bytes);
      await expectLater(WalletFile.open(path: path, passphrase: passphrase),
          throwsA(isA<Refusal>().having((r) => r.step, 'step', 'passphrase')));
    });

    test('a file that asks for a terabyte of memory is refused before it is allocated', () async {
      await write();
      final bytes = (await File(path).readAsBytes()).toList();
      bytes.setRange(3, 7, const [0xff, 0xff, 0xff, 0x0f]); // 268 GiB
      await File(path).writeAsBytes(bytes);
      await expectLater(WalletFile.open(path: path, passphrase: passphrase),
          throwsA(isA<Refusal>().having((r) => r.step, 'step', 'kdf memory')));
    });
  });

  group('compatibility and failure behaviour', () {
    test('Unknown version', () async {
      await write();
      final bytes = (await File(path).readAsBytes()).toList()..[0] = 99;
      await File(path).writeAsBytes(bytes);
      await expectLater(
          WalletFile.open(path: path, passphrase: passphrase),
          throwsA(isA<Refusal>()
              .having((r) => r.step, 'step', 'version')
              .having((r) => r.reason, 'names the version', contains('99'))));
    });

    test('an unknown KDF, cipher or derivation is refused by name', () async {
      await write();
      final good = await File(path).readAsBytes();

      final kdf = good.toList()..[2] = 7;
      await File(path).writeAsBytes(kdf);
      await expectLater(WalletFile.open(path: path, passphrase: passphrase),
          throwsA(isA<Refusal>().having((r) => r.step, 'step', 'kdf')));

      final cipher = good.toList()..[12] = 7;
      await File(path).writeAsBytes(cipher);
      await expectLater(WalletFile.open(path: path, passphrase: passphrase),
          throwsA(isA<Refusal>().having((r) => r.step, 'step', 'cipher')));

      // a derivation this library does not implement is refused where it is
      // used, not where it is read: the seed is still the seed
      final stored = StoredWallet(
          derivation: 2, seed: WalletSeed(List.filled(WalletSeed.length, 0)), addressesIssued: 0, birthday: 0);
      expect(() => stored.keys,
          throwsA(isA<Refusal>().having((r) => r.step, 'step', 'derivation')));
    });

    test('a file cut short, or with bytes added, is refused', () async {
      await write();
      final good = await File(path).readAsBytes();
      for (final bytes in [good.take(good.length - 5).toList(), [...good, 0, 0, 0]]) {
        await File(path).writeAsBytes(bytes);
        await expectLater(WalletFile.open(path: path, passphrase: passphrase), throwsA(isA<Refusal>()));
      }
      await File(path).writeAsBytes(List.filled(WalletFile.maxFile + 1, 0));
      await expectLater(WalletFile.open(path: path, passphrase: passphrase),
          throwsA(isA<Refusal>().having((r) => r.step, 'step', 'size')));
    });

    test('A crash during a write', () async {
      await write(k: keys(issued: 3));
      final before = await File(path).readAsBytes();

      // the process died between the write and the rename: the temporary file
      // holds a whole, valid, newer wallet, and the rename never happened
      final tmp = WalletFile.temporaryFor(path);
      await write(k: keys(issued: 99), at: tmp);
      expect(await File(tmp).exists(), isTrue);

      final stored = await WalletFile.open(path: path, passphrase: passphrase);
      expect(stored.addressesIssued, 3, reason: 'the previous wallet, unchanged');
      expect(await File(path).readAsBytes(), before);
      expect(await File(tmp).exists(), isTrue, reason: 'opening leaves the wreckage alone, it does not read it');

      // and the next write goes over the temporary name and lands
      await write(k: keys(issued: 4));
      expect((await WalletFile.open(path: path, passphrase: passphrase)).addressesIssued, 4);
      expect(await File(tmp).exists(), isFalse, reason: 'the temporary name was renamed into place');
    });

    test('there is no wallet file', () async {
      await expectLater(WalletFile.open(path: '${dir.path}/nothing', passphrase: passphrase),
          throwsA(isA<Refusal>().having((r) => r.step, 'step', 'file')));
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
