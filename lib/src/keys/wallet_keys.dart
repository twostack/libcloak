import 'package:tstokenlib/tstokenlib.dart';

import '../refusal.dart';
import 'seed.dart';

/// One seed, and everything the wallet is.
///
/// The derivation is versioned and stated here in full:
///
/// ```
///   sk   = the first 5 lanes of HKDF-SHA256(seed, "tsl1-libcloak/derivation/1/sk")
///          taken as little-endian 32-bit words, each masked to 31 bits and
///          drawn again when it lands on the one value outside M31
///   ivk  = PoolHash.ivk(sk)      d(i) = PoolHash.diversifier(ivk, i)
///   nk   = PoolHash.nk(sk)       pk_d = PoolHash.pkdFromIvk(ivk, d)
///   ovk  = PoolHash.ovk(sk)
/// ```
///
/// Everything below `sk` is tstokenlib's, and deliberately so: the spend
/// circuit derives `ivk` and `nk` from the `sk` register itself, so a wallet
/// that derived them any other way would build proofs the pool refuses. The
/// only thing libcloak decides is how one seed becomes one `sk`.
///
/// [derivation] is written into the wallet file. A future derivation gets the
/// next number and its own `info` string, so the same seed under two
/// derivations gives two unrelated wallets rather than a silent collision.
class WalletKeys {
  static const derivation = 1;
  static const _domain = 'tsl1-libcloak/derivation/$derivation';

  /// The largest address index, kept inside the field because the index is a
  /// lane of the diversifier's hash.
  static const maxAddressIndex = 0x7ffffffe;

  final WalletSeed seed;

  /// The pool round this wallet was made at. Rounds before it hold nothing of
  /// this wallet's, so the pool view starts here and nothing in this library
  /// reads a round below it.
  final int birthday;

  /// The KEM every address of this wallet is issued under.
  final int kem;

  int _issued;

  WalletKeys({required this.seed, required this.birthday, int addressesIssued = 0, this.kem = NoteAddress.kemHybrid})
      : _issued = addressesIssued {
    if (birthday < 0) throw ArgumentError('a birthday is a round number, 0 or more, not $birthday');
    if (addressesIssued < 0 || addressesIssued > maxAddressIndex) {
      throw ArgumentError('an address counter is 0 to $maxAddressIndex, not $addressesIssued');
    }
    if (!NoteKem.isKem(kem)) throw ArgumentError('unknown KEM id $kem');
  }

  /// The pool spending key: five lanes, 155 bits.
  late final List<int> sk = _deriveSk();

  late final PoolWalletKeys pool = PoolWalletKeys(sk);

  /// The incoming viewing key. Handing it out discloses every note this
  /// wallet receives, and every address it will ever issue, without the power
  /// to move anything.
  List<int> get ivk => pool.ivk;

  /// The nullifier key: with [ivk] it also shows a note being spent.
  List<int> get nk => pool.nk;

  /// The outgoing viewing key, which opens the sender's copy of a note this
  /// wallet sent.
  List<int> get ovk => pool.ovk;

  /// How many addresses have been issued. One invoice takes one, so this is
  /// also the number of invoices this wallet has written.
  int get addressesIssued => _issued;

  /// Whether a round can hold anything of this wallet's. Rounds below the
  /// birthday cannot, so they are not read.
  bool couldHoldNotesIn(int round) => round >= birthday;

  List<int> _deriveSk() {
    final lanes = <int>[];
    for (int counter = 0; lanes.length < PoolHash.skLanes; counter++) {
      final block = seed.expand('$_domain/sk', 32, counter: counter);
      for (int i = 0; i + 4 <= block.length && lanes.length < PoolHash.skLanes; i += 4) {
        final word = block[i] | (block[i + 1] << 8) | (block[i + 2] << 16) | (block[i + 3] << 24);
        final lane = word & 0x7fffffff;
        // the one value a 31-bit word can take that M31 has no room for; the
        // next block supplies a replacement, so no lane is ever biased
        if (lane != M31.p) lanes.add(lane);
      }
    }
    return lanes;
  }

  /// Address [index] of this wallet. Deterministic: the same seed and index
  /// give the same address, which is what lets a wallet restored from a seed
  /// recognise what it was paid.
  Future<NoteAddress> addressAt(int index) {
    if (index < 0 || index > maxAddressIndex) {
      throw ArgumentError('an address index is 0 to $maxAddressIndex, not $index');
    }
    return NoteAddress.at(ivk, index, kem: kem);
  }

  /// The next unissued address, advancing the counter.
  ///
  /// One invoice takes one address. Two invoices never share a diversifier,
  /// so a payer learns nothing about the payee's other dealings from the
  /// address it was given, and two addresses of one wallet cannot be told to
  /// belong together without [ivk].
  Future<NoteAddress> nextAddress() async {
    if (_issued >= maxAddressIndex) throw StateError('this wallet has issued every address its derivation has');
    final a = await addressAt(_issued);
    _issued++;
    return a;
  }

  @override
  String toString() => 'WalletKeys(derivation $derivation, birthday $birthday, $_issued addresses issued)';
}

/// Reading a [NoteAddress] somebody else wrote.
///
/// An address arrives inside an invoice, which is outside input: it names its
/// own KEM, and that name fixes how long it must be. Everything here is a
/// refusal with the field named, never an exception, because an invoice that
/// will not parse is a thing a person has to be told about.
class AddressCodec {
  /// The longest address any KEM here defines, so a caller can bound a field
  /// before it reads one.
  static const maxLength = 45 + 32 + NoteKem.mlPublicKeyLength;

  /// The address [bytes] hold, or the refusal that stopped it.
  static (NoteAddress?, Refusal?) read(List<int> bytes) {
    if (bytes.isEmpty) return (null, const Refusal('address', 'an address is empty'));
    final kem = bytes[0];
    if (!NoteKem.isKem(kem)) {
      return (null, Refusal('kem', 'names KEM $kem, which this library does not have'));
    }
    final want = 45 + NoteKem.publicKeyLength(kem);
    if (bytes.length != want) {
      return (null, Refusal('length', 'a KEM $kem address is $want bytes, ${bytes.length} given'));
    }
    final refusal = _lanesInField('diversifier', bytes, 1, PoolHash.dLanes) ??
        _lanesInField('pkd', bytes, 13, PoolHash.digestLanes);
    if (refusal != null) return (null, refusal);
    try {
      return (NoteAddress.parse(bytes), null);
    } catch (e) {
      return (null, Refusal('address', '$e'));
    }
  }

  static Refusal? _lanesInField(String field, List<int> b, int at, int count) {
    for (int i = 0; i < count; i++) {
      final o = at + 4 * i;
      final lane = b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
      if (lane >= M31.p) return Refusal(field, 'lane $i is outside the field');
    }
    return null;
  }
}
