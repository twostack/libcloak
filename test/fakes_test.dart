import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';

import 'fakes.dart';

/// The two ports and their fakes.
///
/// The fakes are not scenery: the whole suite runs on them, so what they can
/// and cannot be asked is what the library can and cannot ask. The surface
/// test below is the one that matters — a port that cannot take an address is
/// a port that cannot leak one.
void main() {
  List<int> txid(int n) => crypto.sha256.convert([n]).bytes;

  group('the header port', () {
    test('a fake source answers the three questions, and its blocks hold real headers', () async {
      final source = FakeHeaderSource.holding([txid(1), txid(2), txid(3)], before: 2, after: 3);
      final tip = await source.tip();
      expect(tip.height, 5);
      expect(tip.hash.length, 32);

      final held = source.blockOf(txid(2))!;
      expect(held.height, 2);
      expect(held.header.length, 80, reason: 'a header is 80 bytes');
      expect(await source.heightOfBlock(held.hash), 2);
      expect(await source.headerAtHeight(2), held.header);

      // the header commits to the block's transactions
      expect(held.header.sublist(36, 68), held.merkleRoot.reversed.toList());

      // and a block it does not have is absent, not provisional
      expect(await source.heightOfBlock(List.filled(32, 9)), isNull);
      expect(await source.headerAtHeight(99), isNull);
    });

    test('a merkle branch from the fake reaches the header\'s root', () {
      final source = FakeHeaderSource.holding([for (int i = 1; i <= 5; i++) txid(i)]);
      final block = source.blockOf(txid(4))!;
      final (index, branch) = block.branchFor(3);
      expect(index, 3);

      // walked the way a payee walks it: internal order, index bit picks the side
      var cur = txid(4).reversed.toList();
      var at = index;
      for (final sib in branch) {
        final other = sib.reversed.toList();
        cur = crypto.sha256
            .convert(crypto.sha256.convert(at.isEven ? [...cur, ...other] : [...other, ...cur]).bytes)
            .bytes;
        at >>= 1;
      }
      expect(cur.reversed.toList(), block.merkleRoot);

      // another transaction's branch does not
      final (otherIndex, otherBranch) = block.branchFor(1);
      expect(otherIndex, 1);
      expect(otherBranch, isNot(branch));
    });

    test('a source that fails names the call and its reason', () async {
      final source = FakeHeaderSource.holding([txid(1)])..fail = 'the node is down';
      await expectLater(
          source.tip(),
          throwsA(isA<HeaderSourceFailure>()
              .having((e) => e.call, 'call', 'tip')
              .having((e) => e.reason, 'reason', 'the node is down')));
    });

    test('the port\'s surface names no address, outpoint or wallet-derived txid', () {
      // The privacy property is structural, so it is checked structurally: the
      // declared methods of the port are read from the source and every
      // parameter is inspected. A method that took a txid would pass every
      // other test in this suite and lose the property the library exists for.
      final src = File('lib/src/headers/header_source.dart').readAsStringSync();
      final body = src.substring(src.indexOf('abstract interface class HeaderSource'));
      final methods = [
        for (final line in body.split('\n'))
          if (line.trimLeft().startsWith('Future<')) RegExp(r'\s(\w+)\(([^)]*)\);').firstMatch(line)!
      ];
      expect(methods.map((m) => m.group(1)).toSet(), {'tip', 'heightOfBlock', 'headerAtHeight'},
          reason: 'the port has three methods and no more');
      for (final m in methods) {
        final params = m.group(2)!.toLowerCase();
        for (final forbidden in ['address', 'outpoint', 'txid', 'script', 'note', 'position', 'commitment']) {
          expect(params.contains(forbidden), isFalse,
              reason: '${m.group(1)} takes something that names the wallet: $forbidden');
        }
      }
    });
  });

  group('the transport port', () {
    test('a fake transport carries frames and a feed, recording both', () async {
      final feed = [
        [1, 2, 3],
        [4, 5, 6],
        [7, 8, 9]
      ];
      final t = FakeTransport(feed: feed)..answer = (frame) => [for (final b in frame) b ^ 0xff];
      expect(await t.request([1, 2]), [0xfe, 0xfd]);
      expect(t.sent, [
        [1, 2]
      ]);

      final entries = await t.readFeed(1, max: 10);
      expect(entries.map((e) => e.sequence), [1, 2]);
      expect(entries.map((e) => e.bytes), [feed[1], feed[2]]);
      expect(await t.readFeed(3), isEmpty, reason: 'the end of the feed is an empty read, not an error');
      expect(t.reads, ['readFeed 1 10', 'readFeed 3 100']);

      // bounded: a read takes at most what it asks for
      expect((await t.readFeed(0, max: 2)).length, 2);
    });

    test('a transport that fails names the call and its reason, and retries can succeed', () async {
      final down = FakeTransport()..fail = 'no route to the pool';
      await expectLater(
          down.request([0]),
          throwsA(isA<TransportFailure>()
              .having((e) => e.call, 'call', 'request')
              .having((e) => e.reason, 'reason', 'no route to the pool')));

      final flaky = FakeTransport()
        ..failFirst = 2
        ..answer = (_) => [42];
      await expectLater(flaky.request([0]), throwsA(isA<TransportFailure>()));
      await expectLater(flaky.request([0]), throwsA(isA<TransportFailure>()));
      expect(await flaky.request([0]), [42]);
      expect(flaky.attempts, 3);
    });

    test('a request with no answer set fails loudly rather than passing quietly', () async {
      await expectLater(FakeTransport().request([0]),
          throwsA(isA<TransportFailure>().having((e) => e.reason, 'reason', contains('no answer'))));
    });
  });

  test('the fakes touch no network and no file', () async {
    final source = FakeHeaderSource.holding([crypto.sha256.convert([1]).bytes]);
    final t = FakeTransport(feed: [
      [1]
    ])
      ..answer = (_) => [2];
    await HttpOverrides.runZoned(() async {
      await IOOverrides.runZoned(() async {
        expect((await source.tip()).height, 2);
        expect(await source.heightOfBlock((await source.tip()).hash), 2);
        expect(await t.request([0]), [2]);
        expect((await t.readFeed(0)).length, 1);
      },
          createFile: (p) => throw StateError('the fakes opened the file $p'),
          socketConnect: (host, port, {sourceAddress, sourcePort = 0, timeout}) =>
              throw StateError('the fakes opened a socket to $host'));
    }, createHttpClient: (_) => throw StateError('the fakes made an HTTP request'));
  });
}
