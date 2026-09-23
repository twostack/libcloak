import 'dart:typed_data';

import '../refusal.dart';

/// Writing and reading the library's own messages.
///
/// Every message libcloak writes begins with a version and a kind, and every
/// field after that has an explicit length. Every message libcloak reads is
/// somebody else's bytes: the reader checks the whole size before it touches a
/// byte, checks each declared length against what remains **and** against its
/// field's own bound before allocating, and ends either in a message or in a
/// [Refusal] naming the field. There is no path out of here that throws
/// something else.

/// A bounded reader over hostile bytes.
class Reader {
  final List<int> b;
  int at = 0;
  Reader._(this.b);

  /// A reader past the version and kind of [bytes], refusing a size over
  /// [max], another version, or another kind, before anything else is read.
  static Reader open(List<int> bytes, {required int version, required int kind, required int max, required String what}) {
    if (bytes.length > max) throw Refusal('size', 'a $what is at most $max bytes, ${bytes.length} given');
    final r = Reader._(bytes);
    final v = r.byte('version');
    if (v != version) throw Refusal('version', 'this library writes $what version $version and does not read $v');
    final k = r.byte('kind');
    if (k != kind) throw Refusal('kind', 'kind $k is not $what ($kind)');
    return r;
  }

  /// A reader over bytes that carry no version and kind of their own,
  /// because something else already vouched for them: the plaintext an AEAD
  /// returned, whose version is in the header the AEAD authenticated. The
  /// bounds still apply — an authenticated message can still be the wrong
  /// shape.
  static Reader raw(List<int> bytes) => Reader._(bytes);

  /// The kind byte [bytes] carry, or null when they are too short or of
  /// another version. Reading it costs nothing, so a caller can route a
  /// message before decoding it.
  static int? kindOf(List<int> bytes, int version) {
    if (bytes.length < 2 || bytes[0] != version) return null;
    return bytes[1];
  }

  int get left => b.length - at;

  List<int> take(String field, int n) {
    if (n < 0 || n > left) throw Refusal(field, 'needs $n bytes, $left remain');
    final out = b.sublist(at, at + n);
    at += n;
    return out;
  }

  int byte(String field) => take(field, 1)[0];

  int u32(String field) {
    final x = take(field, 4);
    return x[0] | (x[1] << 8) | (x[2] << 16) | (x[3] << 24);
  }

  int u64(String field) {
    final x = take(field, 8);
    var v = 0;
    for (int i = 7; i >= 0; i--) {
      v = (v << 8) | x[i];
    }
    if (v < 0) throw Refusal(field, 'is outside the range a value can hold');
    return v;
  }

  /// A length-prefixed run, refused above [bound] before a byte is allocated.
  List<int> sized(String field, int bound, {int min = 1}) {
    final n = u32(field);
    if (n < min || n > bound) throw Refusal(field, 'declares $n bytes, $min to $bound');
    return take(field, n);
  }

  /// [count] lanes, each a little-endian 32-bit word inside the field.
  List<int> lanes(String field, int count) {
    final out = <int>[];
    for (int i = 0; i < count; i++) {
      final l = u32(field);
      if (l >= 0x7fffffff) throw Refusal(field, 'lane $i is outside the field');
      out.add(l);
    }
    return out;
  }

  void end(String field, String reason) {
    if (left != 0) throw Refusal(field, reason.replaceAll('%n', '$left'));
  }

  /// Runs [f], turning anything it throws other than a refusal into one, so no
  /// input reaches the caller as any other failure.
  static T guard<T>(T Function() f) {
    try {
      return f();
    } on Refusal {
      rethrow;
    } catch (e) {
      throw Refusal('malformed', '$e');
    }
  }
}

/// The writer side: the same fields, in the same order.
class Writer {
  final BytesBuilder _out = BytesBuilder(copy: false);

  Writer(int version, int kind) {
    _out
      ..addByte(version)
      ..addByte(kind);
  }

  /// A writer with no prefix, for a body that is sealed inside a message
  /// whose version and kind are outside it.
  Writer.raw();

  void byte(int v) => _out.addByte(v);
  void bytes(List<int> v) => _out.add(v);

  void u32(int v) => _out.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));

  void u64(int v) => _out.add(Uint8List(8)..buffer.asByteData().setUint64(0, v, Endian.little));

  void sized(List<int> v) {
    u32(v.length);
    _out.add(v);
  }

  void lanes(List<int> v) {
    for (final l in v) {
      u32(l);
    }
  }

  Uint8List done() => _out.toBytes();
}
