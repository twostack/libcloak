import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// The one secret a wallet has.
///
/// Everything else — the pool spending key, the viewing keys, every address —
/// is a function of these 32 bytes and a stated derivation, so a wallet
/// restored from a seed is the same wallet and not a similar one. There is no
/// backup anywhere else: the pool holds commitments, not owners, and the
/// coordinator could not return this wallet's money if it wanted to.
///
/// The seed is deliberately awkward to print. It has no `==`, because
/// comparing secrets in variable time is a habit worth not having, and its
/// [toString] says how many bytes it is and nothing else, so a seed cannot
/// reach a log line through an interpolated object.
class WalletSeed {
  static const length = 32;

  /// The salt of every expansion, fixing this library's HKDF apart from any
  /// other use of the same seed. The derivation *version* is not here: it is
  /// in the `info` each caller passes, so one seed can be expanded under two
  /// derivations without the two colliding.
  static const hkdfSalt = 'tsl1-libcloak/hkdf';

  final Uint8List _bytes;

  WalletSeed(List<int> bytes) : _bytes = Uint8List.fromList(bytes) {
    if (bytes.length != length) throw ArgumentError('a wallet seed is $length bytes, ${bytes.length} given');
    for (int i = 0; i < bytes.length; i++) {
      if (bytes[i] < 0 || bytes[i] > 255) throw ArgumentError('a seed byte is 0 to 255, position $i is not');
    }
  }

  /// A fresh seed from [rng], which defaults to the platform's secure source.
  ///
  /// Pass a seeded [Random] only in a test. A wallet whose seed came from a
  /// predictable generator is a wallet anybody can empty.
  factory WalletSeed.generate({Random? rng}) {
    final r = rng ?? Random.secure();
    return WalletSeed(List.generate(length, (_) => r.nextInt(256)));
  }

  /// The seed [hex] spells, for a recorded vector or a host that keeps its
  /// own backup. Case insensitive, no separators.
  factory WalletSeed.fromHex(String hex) {
    if (hex.length != 2 * length) throw ArgumentError('a seed is ${2 * length} hex characters, ${hex.length} given');
    final out = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      final b = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (b == null) throw ArgumentError('position $i is not hexadecimal');
      out.add(b);
    }
    return WalletSeed(out);
  }

  /// A copy of the bytes, for the one caller that needs them: the wallet
  /// file, on its way into an AEAD. Nothing else in this library asks.
  Uint8List get bytes => Uint8List.fromList(_bytes);

  /// [n] bytes of HKDF-SHA256 over the seed under [info].
  ///
  /// [info] carries the derivation's domain and version, so a change to the
  /// derivation changes every key it produces rather than some of them.
  /// [counter] appends a four-byte little-endian word, which the key
  /// derivation uses to draw a further block when a candidate lane falls
  /// outside the field.
  List<int> expand(String info, int n, {int counter = 0}) {
    if (n < 1 || n > 8160) throw ArgumentError('an expansion is 1 to 8160 bytes, $n asked for');
    final prk = crypto.Hmac(crypto.sha256, hkdfSalt.codeUnits).convert(_bytes).bytes;
    final tail = [
      ...info.codeUnits,
      0,
      counter & 0xff,
      (counter >> 8) & 0xff,
      (counter >> 16) & 0xff,
      (counter >> 24) & 0xff,
    ];
    final out = <int>[];
    var block = const <int>[];
    for (int i = 1; out.length < n; i++) {
      block = crypto.Hmac(crypto.sha256, prk).convert([...block, ...tail, i]).bytes;
      out.addAll(block);
    }
    return out.sublist(0, n);
  }

  @override
  String toString() => 'WalletSeed($length bytes, not printed)';
}
