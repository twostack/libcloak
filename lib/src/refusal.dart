/// Why libcloak said no.
///
/// Everything in this library that takes bytes from somebody else ends either
/// in a result or in one of these, never in an exception that escaped. The
/// [step] is the check that caught it, so a host can tell a person which rule
/// failed rather than "invalid", and so a test can assert the order the checks
/// run in.
///
/// A refusal is shown to people and written to journals, so it never carries a
/// key, a seed or a note's randomness. Where it has to name a value it names a
/// prefix of a public one: a txid, a root, a block hash.
class Refusal {
  final String step;
  final String reason;
  const Refusal(this.step, this.reason);

  @override
  String toString() => '$step: $reason';
}

/// The first eight bytes of [b] in hex, with an ellipsis. Used in refusals so
/// two roots or two txids can be told apart without printing a screenful.
String shortHex(List<int> b) {
  const d = '0123456789abcdef';
  final s = StringBuffer();
  for (final x in b.take(8)) {
    s.write(d[(x >> 4) & 15]);
    s.write(d[x & 15]);
  }
  return '$s...';
}
