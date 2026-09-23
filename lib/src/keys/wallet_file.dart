import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../msg/codec.dart';
import '../refusal.dart';
import 'seed.dart';
import 'wallet_keys.dart';

/// How a passphrase becomes a key.
///
/// Argon2id, because a passphrase is short and an attacker with the file has
/// every guess it likes: the cost has to be in memory, where a rented machine
/// cannot buy its way out cheaply. The parameters are written into the file,
/// so a wallet written under one cost opens under it after the defaults move.
class WalletKdf {
  /// The only KDF this version has.
  static const argon2id = 1;

  static const minMemory = 8, maxMemory = 1024 * 1024; // KiB
  static const maxIterations = 16, maxParallelism = 16;

  /// KiB of working memory.
  final int memory;
  final int iterations, parallelism;

  const WalletKdf({this.memory = 65536, this.iterations = 3, this.parallelism = 1});

  /// The default a wallet is written under: 64 MiB and three passes, about
  /// 0.4 s on the machine this was measured on.
  static const strong = WalletKdf();

  /// 8 MiB and one pass, about 15 ms. For suites, and for a host that opens a
  /// wallet on every keystroke and knows what it is giving up.
  static const fast = WalletKdf(memory: 8192, iterations: 1, parallelism: 1);

  /// The refusal these parameters earn, or null. Read before anything is
  /// allocated, so a file cannot ask a reader for a terabyte.
  Refusal? get refusal {
    if (memory < minMemory || memory > maxMemory) {
      return Refusal('kdf memory', 'asks for $memory KiB, $minMemory to $maxMemory');
    }
    if (iterations < 1 || iterations > maxIterations) {
      return Refusal('kdf iterations', 'asks for $iterations, 1 to $maxIterations');
    }
    if (parallelism < 1 || parallelism > maxParallelism) {
      return Refusal('kdf parallelism', 'asks for $parallelism, 1 to $maxParallelism');
    }
    return null;
  }

  Future<SecretKey> keyFor(String passphrase, List<int> salt) => Argon2id(
        parallelism: parallelism,
        memory: memory,
        iterations: iterations,
        hashLength: 32,
      ).deriveKey(secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);

  @override
  String toString() => 'Argon2id($memory KiB, $iterations iterations, $parallelism lane)';
}

/// What a wallet file holds, once it has been opened.
class StoredWallet {
  final int derivation;
  final WalletSeed seed;
  final int addressesIssued, birthday;

  const StoredWallet({
    required this.derivation,
    required this.seed,
    required this.addressesIssued,
    required this.birthday,
  });

  /// The wallet these bytes are. Refuses a derivation this library does not
  /// implement rather than deriving the wrong keys from the right seed.
  WalletKeys get keys {
    if (derivation != WalletKeys.derivation) {
      throw Refusal('derivation',
          'this wallet was made under derivation $derivation and this library implements ${WalletKeys.derivation}');
    }
    return WalletKeys(seed: seed, birthday: birthday, addressesIssued: addressesIssued);
  }

  @override
  String toString() => 'StoredWallet(derivation $derivation, birthday $birthday, $addressesIssued addresses issued)';
}

/// Where a freshly created wallet went, and what that means.
class WalletFileNotice {
  final String path;
  final String notice;
  const WalletFileNotice(this.path, this.notice);

  @override
  String toString() => notice;
}

/// The wallet at rest: the seed and the address counter, under a passphrase.
///
/// The file is one AEAD box with a plain header. The header carries the
/// version, the KDF and its cost, the salt and the nonce, and it is the box's
/// associated data — so an attacker cannot quietly lower the cost of the file
/// it stole and have it still open.
///
/// Writes go to a temporary name beside the file and are renamed over it, so a
/// process killed partway leaves the previous wallet exactly as it was, and
/// the file is created before it is written to and made owner-only in between,
/// so the seed is never on disk under permissions anybody else can read.
class WalletFile {
  static const version = 1;
  static const kind = 1;

  /// The only cipher this version has: XChaCha20-Poly1305, whose 24-byte
  /// nonce can be drawn at random without a counter to keep.
  static const xchacha20Poly1305 = 1;

  static const saltLength = 16, nonceLength = 24, macLength = 16;

  /// A wallet file is a seed and two numbers. Anything larger is not one.
  static const maxFile = 4096;

  /// The plaintext: the derivation, the seed, the counter and the birthday.
  static const bodyLength = 1 + WalletSeed.length + 4 + 4;

  /// The name a write goes to before it is renamed into place. A file left
  /// under this name is the wreckage of a crash and is ignored by [open].
  static String temporaryFor(String path) => '$path.tmp';

  static final _cipher = Xchacha20.poly1305Aead();

  /// Writes [keys] to [path] for the first time, and says what that means.
  ///
  /// Refuses if something is already there: overwriting a wallet file is how
  /// a seed is lost, and it takes [save] and a decision to do it.
  static Future<WalletFileNotice> create({
    required String path,
    required String passphrase,
    required WalletKeys keys,
    WalletKdf kdf = WalletKdf.strong,
    Random? rng,
  }) async {
    if (await File(path).exists()) {
      throw Refusal('file', 'there is already a file at $path, and a wallet file is not overwritten by accident');
    }
    await save(path: path, passphrase: passphrase, keys: keys, kdf: kdf, rng: rng);
    return WalletFileNotice(
        path,
        'the wallet is at $path. Its seed is in that file and nowhere else: the pool holds commitments, '
        'not owners, and nobody — not the coordinator, not this library — can give it back. Keep a copy of '
        'the file, or of the seed, somewhere the passphrase is not.');
  }

  /// Writes [keys] to [path], replacing what is there.
  static Future<void> save({
    required String path,
    required String passphrase,
    required WalletKeys keys,
    WalletKdf kdf = WalletKdf.strong,
    Random? rng,
  }) async {
    final bad = kdf.refusal;
    if (bad != null) throw bad;
    if (passphrase.isEmpty) throw ArgumentError('a wallet passphrase is not empty');
    final r = rng ?? Random.secure();
    final salt = List.generate(saltLength, (_) => r.nextInt(256));
    final nonce = List.generate(nonceLength, (_) => r.nextInt(256));

    final header = Writer(version, kind)
      ..byte(WalletKdf.argon2id)
      ..u32(kdf.memory)
      ..u32(kdf.iterations)
      ..byte(kdf.parallelism)
      ..byte(xchacha20Poly1305)
      ..bytes(salt)
      ..bytes(nonce);
    final headerBytes = header.done();

    final body = Writer.raw()
      ..byte(WalletKeys.derivation)
      ..bytes(keys.seed.bytes)
      ..u32(keys.addressesIssued)
      ..u32(keys.birthday);

    final box = await _cipher.encrypt(body.done(),
        secretKey: await kdf.keyFor(passphrase, salt), nonce: nonce, aad: headerBytes);

    final out = Writer.raw()
      ..bytes(headerBytes)
      ..sized([...box.cipherText, ...box.mac.bytes]);
    await _writeThenRename(path, out.done());
  }

  /// The wallet at [path] under [passphrase], or the refusal that stopped it.
  ///
  /// Every failure names a field or the file. None of them names the
  /// passphrase, the seed or a key, because a refusal is shown to a person
  /// and written to a journal.
  static Future<StoredWallet> open({required String path, required String passphrase}) async {
    final f = File(path);
    if (!await f.exists()) throw Refusal('file', 'there is no wallet file at $path');
    final length = await f.length();
    if (length > maxFile) throw Refusal('size', 'a wallet file is at most $maxFile bytes, $length at $path');
    final bytes = await f.readAsBytes();

    final k = Reader.kindOf(bytes, version);
    if (k == null) {
      if (bytes.length < 2) throw Refusal('size', 'a wallet file is at least 2 bytes, ${bytes.length} at $path');
      throw Refusal('version', 'this library writes wallet file version $version and does not read ${bytes[0]}');
    }
    if (k != kind) throw Refusal('kind', 'kind $k is not a wallet file ($kind)');

    final r = Reader.open(bytes, version: version, kind: kind, max: maxFile, what: 'wallet file');
    final (kdf, salt, nonce, sealed) = Reader.guard(() {
      final id = r.byte('kdf');
      if (id != WalletKdf.argon2id) throw Refusal('kdf', 'names KDF $id, which this library does not have');
      final memory = r.u32('kdf memory'), iterations = r.u32('kdf iterations');
      final parallelism = r.byte('kdf parallelism');
      final cipher = r.byte('cipher');
      if (cipher != xchacha20Poly1305) {
        throw Refusal('cipher', 'names cipher $cipher, which this library does not have');
      }
      final salt = r.take('salt', saltLength);
      final nonce = r.take('nonce', nonceLength);
      final sealed = r.sized('body', bodyLength + macLength, min: macLength + 1);
      r.end('end', '%n bytes after the wallet file');
      final kdf = WalletKdf(memory: memory, iterations: iterations, parallelism: parallelism);
      final bad = kdf.refusal;
      if (bad != null) throw bad;
      return (kdf, salt, nonce, sealed);
    });

    final headerBytes = bytes.sublist(0, bytes.length - 4 - sealed.length);
    final List<int> plain;
    try {
      plain = await _cipher.decrypt(
          SecretBox(sealed.sublist(0, sealed.length - macLength),
              nonce: nonce, mac: Mac(sealed.sublist(sealed.length - macLength))),
          secretKey: await kdf.keyFor(passphrase, salt),
          aad: headerBytes);
    } on SecretBoxAuthenticationError {
      throw Refusal('passphrase', 'the passphrase does not open $path');
    }

    return Reader.guard(() {
      final b = Reader.raw(plain);
      final derivation = b.byte('derivation');
      final seed = WalletSeed(b.take('seed', WalletSeed.length));
      final issued = b.u32('addresses issued');
      final birthday = b.u32('birthday');
      b.end('end', '%n bytes after the wallet');
      if (issued > WalletKeys.maxAddressIndex) {
        throw Refusal('addresses issued', 'is $issued, above the ${WalletKeys.maxAddressIndex} a derivation has');
      }
      return StoredWallet(derivation: derivation, seed: seed, addressesIssued: issued, birthday: birthday);
    });
  }

  /// Creates the file empty, makes it owner-only, writes it, and renames it
  /// over [path]. The order matters: no secret reaches the disk before the
  /// permissions are narrowed, and [path] itself is only ever replaced by a
  /// rename, which is atomic.
  static Future<void> _writeThenRename(String path, Uint8List bytes) async {
    final tmp = File(temporaryFor(path));
    await tmp.writeAsBytes(const <int>[], flush: true);
    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', ['600', tmp.path]);
      if (chmod.exitCode != 0) {
        await tmp.delete();
        throw Refusal('permissions', 'could not make ${tmp.path} owner-only, so the seed was not written');
      }
    }
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
  }
}
