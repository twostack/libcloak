import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:libcloak/libcloak.dart';
import 'package:tstokenlib/tstokenlib.dart' show NotePlaintext;

import '../fakes.dart';

/// Just enough of the regtest node's RPC for the tests that need a real
/// chain, as ../localnet runs it. The credentials are the localnet harness's
/// published ones and are never a real node's.
class LocalNode {
  final Uri uri = Uri.parse(Platform.environment['LOCALNET_RPC'] ?? 'http://localhost:18332');
  final HttpClient _http = HttpClient();

  Future<dynamic> rpc(String method, [List<dynamic> params = const []]) async {
    final req = await _http.postUrl(uri);
    req.headers.set('Authorization',
        'Basic ${base64.encode(utf8.encode('bitcoin:${Platform.environment['POOL_RPC_PASSWORD'] ?? 'bitcoin'}'))}');
    req.headers.contentType = ContentType.json;
    req.persistentConnection = false;
    req.write(jsonEncode({'jsonrpc': '1.0', 'id': method, 'method': method, 'params': params}));
    final res = await req.close();
    final json = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
    if (json['error'] != null) throw StateError('$method: ${json['error']}');
    return json['result'];
  }

  Future<void> mine([int n = 1]) async => rpc('generatetoaddress', [n, await rpc('getnewaddress')]);

  Future<void> ready() async {
    try {
      await rpc('getblockcount');
    } catch (e) {
      throw StateError('No regtest node at $uri ($e). Start ../localnet.');
    }
    if ((await rpc('getbalance') as num) < 2) await mine(101);
  }

  Future<Transaction> fund(Address to, BigInt sats) async {
    final txid = await rpc('sendtoaddress', [to.toBase58(), sats.toInt() / 1e8]) as String;
    await mine();
    return Transaction.fromHex(await rpc('getrawtransaction', [txid, 0]) as String);
  }

  Future<Transaction?> fetch(String txid) async {
    try {
      return Transaction.fromHex(await rpc('getrawtransaction', [txid, 0]) as String);
    } on StateError {
      return null;
    }
  }

  Future<void> submit(String name, Transaction tx) async {
    await rpc('sendrawtransaction', [tx.serialize()]);
    await mine();
    final info = await rpc('getrawtransaction', [tx.id, 1]) as Map<String, dynamic>;
    if ((info['confirmations'] ?? 0) < 1) throw StateError('$name ${tx.id} was accepted but not mined');
  }

  /// The block [txid] is in, rebuilt from its own txids so a branch is
  /// computed here rather than taken on the node's word, with the index of
  /// [txid] in it. Null while the transaction is not mined.
  Future<(BlockFromNode, int)?> blockHolding(String txid) async {
    final raw = await rpc('getrawtransaction', [txid, 1]) as Map<String, dynamic>;
    final hash = raw['blockhash'] as String?;
    if (hash == null) return null;
    final block = await rpc('getblock', [hash]) as Map<String, dynamic>;
    final txids = (block['tx'] as List).cast<String>();
    final built = BlockFromNode(block['height'] as int, [for (final t in txids) hex.decode(t)],
        hex.decode(block['previousblockhash'] as String), block);
    return (built, txids.indexOf(txid));
  }

  /// A standing proof built from what the node says, with a header source
  /// answering out of the node's own block.
  Future<(PaymentProof, FakeHeaderSource)> proofFor(Transaction round, Transaction witness,
      {required int roundNumber,
      required NotePlaintext note,
      required int position,
      required List<List<int>> path}) async {
    final held = await blockHolding(witness.id);
    if (held == null) throw StateError('${witness.id} is not mined');
    final (built, index) = held;
    final (_, branch) = built.branchFor(index);
    return (
      PaymentProof.standing(
          round: roundNumber,
          roundTx: hex.decode(round.serialize()),
          witnessTx: hex.decode(witness.serialize()),
          blockHash: built.hash,
          txIndex: index,
          branch: branch,
          position: position,
          path: path,
          note: NoteOpening.of(note)),
      FakeHeaderSource([built])
    );
  }

  void close() => _http.close(force: true);
}

/// A block the node really mined, with the node's own header bytes, so the
/// hash and the merkle root the payee checks against are the chain's and not
/// this test's arithmetic.
class BlockFromNode extends FakeBlock {
  final Map<String, dynamic> raw;
  BlockFromNode(super.height, super.txids, super.previous, this.raw);

  /// The 80 bytes, rebuilt from the fields `getblock` returns, in the order a
  /// header carries them. The payee hashes these to get the block hash, so if
  /// this were wrong the header check would fail and the test would say so
  /// rather than quietly passing.
  @override
  List<int> get header {
    final out = BytesBuilder(copy: false)
      ..add(_le32(raw['version'] as int))
      ..add(hex.decode(raw['previousblockhash'] as String).reversed.toList())
      ..add(hex.decode(raw['merkleroot'] as String).reversed.toList())
      ..add(_le32(raw['time'] as int))
      ..add(_le32(int.parse(raw['bits'] as String, radix: 16)))
      ..add(_le32(raw['nonce'] as int));
    return out.toBytes();
  }

  @override
  List<int> get hash => hex.decode(raw['hash'] as String);

  @override
  List<int> get merkleRoot => hex.decode(raw['merkleroot'] as String);

  static List<int> _le32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
}

/// libcloak's [HeaderSource] over the node's own headers.
///
/// The three questions and no others: the tip, whether a block hash is on the
/// accepted chain, and the header at a height. A payee checking a payment
/// proof asks this and nothing else, and there is no method here that could
/// be asked about an address.
class NodeHeaderSource implements HeaderSource {
  final LocalNode node;
  final List<String> calls = [];
  NodeHeaderSource(this.node);

  @override
  Future<ChainTip> tip() async {
    calls.add('tip');
    final height = await node.rpc('getblockcount') as int;
    final hash = await node.rpc('getblockhash', [height]) as String;
    return ChainTip(height, hex.decode(hash));
  }

  @override
  Future<int?> heightOfBlock(List<int> blockHash) async {
    calls.add('heightOfBlock');
    try {
      final h = await node.rpc('getblockheader', [hex.encode(blockHash), true]) as Map<String, dynamic>;
      // a header the node holds but that is not on the accepted chain has a
      // confirmations of -1, and is not an answer a payee may act on
      if ((h['confirmations'] as num) < 0) return null;
      return h['height'] as int;
    } on StateError {
      return null;
    }
  }

  @override
  Future<List<int>?> headerAtHeight(int height) async {
    calls.add('headerAtHeight');
    try {
      final hash = await node.rpc('getblockhash', [height]) as String;
      return hex.decode(await node.rpc('getblockheader', [hash, false]) as String);
    } on StateError {
      return null;
    }
  }
}
