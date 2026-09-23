@Tags(['localnet'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:libcloak/libcloak.dart';
import 'package:logging/logging.dart';
import 'package:pool_coordinator/pool_coordinator.dart' as co;
import 'package:test/test.dart';
import 'package:tstokenlib/testing.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'support/node.dart';
import 'support/ricochet_server.dart';
import 'support/wallet_transport.dart';

/// A payment through the **real** coordinator, on a real chain.
///
/// `test/end_to_end_test.dart` runs the same flow against a fake pool and
/// leaves one seam: the transfer libcloak builds is not in the round that gets
/// mined, because assembling a round means proving an aggregation and that is
/// the coordinator's job. This closes it. Here a pool is issued on localnet, a
/// coordinator server runs it over ricochet, libcloak's own transfer goes into
/// round 2, that round is mined, and the proof handed to the payee comes out
/// of the round the coordinator actually built.
///
/// Off unless the localnet harness is up **and** `POOL_E2E` is set:
///
///   POOL_LOCALNET=1 POOL_E2E=1 dart test test/localnet_e2e_test.dart
///
/// The second switch is not timidity. This run stands up a ricochet server, a
/// coordinator and a one-per-second miner, and proves two rounds; in the same
/// pack as the rest of the suite it triples the wall clock of every measured
/// bound in it, and those bounds are bounds on one core. So it is asked for
/// rather than swept up, and the suite is two commands.
void main() async {
  final env = Platform.environment;
  final ricochetSkip = await RicochetTestServer.available();
  final skip = env['POOL_LOCALNET'] == null
      ? 'needs ../localnet up; set POOL_LOCALNET=1'
      : env['POOL_E2E'] == null
          ? 'runs a coordinator and a miner, so it is asked for on its own; set POOL_E2E=1'
          : ricochetSkip;

  group('a payment through the real coordinator', () {
    late PoolTestChain c;
    late RicochetTestServer ricochet;
    late LocalNode node;
    late Directory dir;
    late String configPath;
    late Timer miner;
    late co.Created created;
    final passphrase = 'libcloak e2e passphrase';
    final rng = Random(53);
    final timings = <String, int>{};

    setUpAll(() async {
      Logger.root.level = Level.INFO;
      c = await PoolTestChain.build();
      ricochet = (await RicochetTestServer.start())!;
      node = LocalNode();
      await node.ready();
      // localnet's autominer mines every ten minutes; this mines every second
      miner = Timer.periodic(const Duration(seconds: 1), (_) => node.mine().catchError((_) {}));
      dir = Directory.systemTemp.createTempSync('libcloak-e2e');
      configPath = '${dir.path}/config.yaml';
      File(configPath).writeAsStringSync('''
plan: test
network: test
chain:
  kind: node
  rpc_url: ${node.uri}
  rpc_user: bitcoin
ricochet:
  server: ${ricochet.address}
  identity_file: identity.seed
wallet:
  file: wallet.enc
store:
  directory: store
round:
  fee_rate: 1
  fee_floor: 135
  deadline_seconds: 20
  padding_stock: 3
  deposit_margin: 100
server:
  poll_ms: 200
  status_file: status.json
  mined_poll_ms: 200
  funding_timeout_seconds: 600
''');
    });

    tearDownAll(() async {
      miner.cancel();
      await ricochet.dispose();
      node.close();
      print('  timings: ${timings.entries.map((e) => '${e.key} ${e.value}').join(', ')}');
    });

    co.Secrets secrets(co.PoolConfig config) => co.Secrets.load(config, env: {
          'POOL_WALLET_PASSPHRASE': passphrase,
          'POOL_RPC_PASSWORD': env['POOL_RPC_PASSWORD'] ?? 'bitcoin',
        });

    Future<void> untilMined(String txid) async {
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      while ((await node.rpc('getrawtransaction', [txid, 1]) as Map<String, dynamic>)['blockhash'] == null) {
        if (DateTime.now().isAfter(deadline)) fail('$txid was not mined');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    test('a pool is issued and its descriptor is first on the feed', () async {
      final config = await co.PoolConfig.load(configPath);
      final creator = co.PoolCreator(
        config: config,
        configPath: configPath,
        secrets: secrets(config),
        chain: co.NodeChain(
            rpcUrl: node.uri,
            user: 'bitcoin',
            password: env['POOL_RPC_PASSWORD'] ?? 'bitcoin',
            timeout: const Duration(seconds: 120)),
        connect: (seed) => co.RicochetTransport.connect(seed: seed, server: ricochet.address),
        pollInterval: const Duration(milliseconds: 500),
        kdf: co.KdfParams.light,
        say: (line) {
          final m = RegExp(r'^fund (\S+) with at least (\d+) satoshis').firstMatch(line);
          if (m != null) {
            unawaited(node.fund(Address.fromBase58(m.group(1)!), BigInt.parse(m.group(2)!) + BigInt.from(100000)));
          }
        },
      );
      final sw = Stopwatch()..start();
      created = await creator.run();
      timings['create ms'] = sw.elapsedMilliseconds;
      for (final tx in [created.slot0, created.issuance, created.witness0]) {
        await untilMined(tx.id);
      }
    }, timeout: const Timeout(Duration(minutes: 15)));

    test('libcloak pays through it, and the proof comes out of the round it built', () async {
      final config = await co.PoolConfig.load(configPath);
      final s = secrets(config);
      final chain = co.NodeChain(
          rpcUrl: node.uri,
          user: 'bitcoin',
          password: env['POOL_RPC_PASSWORD'] ?? 'bitcoin',
          timeout: const Duration(seconds: 120));
      final (file, contents) = await co.WalletFile.open(config.wallet.file, s.walletPassphrase);
      final serverWallet = co.FileWallet(
          file: file,
          contents: contents,
          chain: chain,
          feeRate: config.round.feeRate,
          feeFloor: config.round.feeFloor,
          minedPoll: config.server.minedPoll,
          fundingTimeout: config.server.fundingTimeout);
      final seed = await co.IdentityFile.read(config.ricochet.identityFile);
      final serverTransport = await co.RicochetTransport.connect(
          seed: seed, server: ricochet.address, retryDelay: const Duration(milliseconds: 500));
      final store = co.FileRoundStore(config.store.directory);
      final server = await co.PoolServer.start(
          config: config, wallet: serverWallet, store: store, chain: chain, transport: serverTransport);

      // the wallet's own ricochet identity: a fresh one, which is all a wallet
      // needs to talk to a pool
      final walletRicochet = await co.RicochetTransport.connect(
          seed: Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256))), server: ricochet.address);
      final transport = RicochetWalletTransport(walletRicochet, created.peerId);

      final journal = (await Journal.open('${dir.path}/journal')).$1!;
      final payeeJournal = (await Journal.open('${dir.path}/payee-journal')).$1!;

      try {
        // ---- the descriptor, off the real feed ----

        final (client, whyOpen) = await CoordinatorClient.open(transport, timeout: const Duration(minutes: 3));
        expect(whyOpen, isNull, reason: '$whyOpen');
        final pool = client!.pool;
        expect(hex.encode(pool.issuance), created.issuance.id);
        expect(client.shape.leavesPerRound, 32);

        final headers = NodeHeaderSource(node);
        final checker = PaymentChecker(pool: pool, headers: HeaderChecker(headers, confirmations: 1));
        final view = PoolView.atGenesis(client.shape);
        final store1 = NoteStore(client.shape);

        Future<PoolAnnouncement> announced(int round) async {
          final deadline = DateTime.now().add(const Duration(minutes: 15));
          while (true) {
            final got = await transport.readFeed(round + 1, max: 1);
            if (got.isNotEmpty) return PoolMessage.decode(got.single.bytes) as PoolAnnouncement;
            if (DateTime.now().isAfter(deadline)) {
              fail('round $round was not announced: ${server.status.lastFailure}');
            }
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }

        // ---- round 1: somebody deposits into the pool ----
        //
        // Not libcloak's business — a deposit is `libcloak-onramp` — so the
        // fixture's transfers play the depositor. They go through libcloak's
        // own submission path, so what is under test is still the wallet's.

        final stranger = PoolTestKeys.stranger.publicKey.toAddress(NetworkType.TEST);
        final coins = await node.fund(stranger, BigInt.from(100000));
        final vout = coins.outputs
            .indexWhere((o) => hex.encode(o.script.buffer).contains(stranger.pubkeyHash160));
        final height = await node.rpc('getblockcount') as int;
        final covenant = c.svc.createDepositTxn(
            fundingTx: coins,
            fundingVout: vout,
            fundingSigner: DefaultTransactionSigner(PoolTestKeys.sigHashAll, PoolTestKeys.stranger),
            fundingPubKey: PoolTestKeys.stranger.publicKey,
            changeAddress: stranger,
            commitment: c.f.receipt.commitment,
            satoshis: c.f.receipt.satoshis,
            pp3Outpoint: c.svc.getOutpoint(created.issuance.hash, outputIndex: 3),
            refundPKH: hex.decode(stranger.pubkeyHash160),
            refundAfter: height + 150);
        await node.rpc('sendrawtransaction', [covenant.serialize()]);
        await untilMined(covenant.id);
        final depositOutpoint = c.svc.getOutpoint(covenant.hash, outputIndex: ShieldedPoolTool.depositVout);

        final d = c.f.transfers1[0];
        final round1Transfers = [
          ShieldedTransfer(d.publics, d.proof, d.bundle, depositOutpoint: depositOutpoint),
          ...c.f.transfers1.sublist(1),
        ];
        final sw1 = Stopwatch()..start();
        for (final t in round1Transfers) {
          final outcome = await client.send(
              PoolSubmission.of(t, pool.spendP, depositTx: t.depositOutpoint == null ? null : covenant, rng: rng));
          expect(outcome.outcome, Submitted.accepted, reason: '${outcome.refusal}');
          expect(outcome.round, 1);
        }
        final a1 = await announced(1);
        timings['round 1 ms'] = sw1.elapsedMilliseconds;
        for (final id in [a1.slotId, a1.roundId, a1.witnessId]) {
          await untilMined(id);
        }

        // ---- the wallet becomes current, and takes its note ----

        var progress = await client.follow(view);
        expect(progress.ok, isTrue, reason: '${progress.stopped}');
        expect(view.round, 1);

        // the note round 1 paid this wallet. In a pool that is running, a
        // payer hands it over with a proof; here nobody did, so the test
        // plays the payer and reads the round the coordinator published.
        final ledger = ShieldedLedger.open(pool.layout, created.issuance, created.witness0, created.slot0,
            tokenId: pool.tokenId, genesisHeader: pool.genesisHeader);
        final r1 = (await node.fetch(a1.roundId))!;
        final w1 = (await node.fetch(a1.witnessId))!;
        final y1 = (await node.fetch(a1.slotId))!;
        final applied1 = ledger.apply(r1, w1, y1);
        expect(a1.disagreement(applied1), isNull, reason: 'the announcement is what the chain carries');
        expect(applied1.header.cmRoot, view.cmRoot,
            reason: 'one 32-byte block root put the wallet where the round did');

        final scanner = ShieldedNoteScanner.forWallet(c.f.wallet, [c.f.walletD]);
        final mine = (await scanner.scan(applied1)).single;
        final path1 = [for (final x in ledger.tree.path(mine.position).siblings) List<int>.of(x)];

        // and the fold becomes evidence, from a proof of the wallet's own
        // note against the node's headers
        final (ownProof, _) = await node.proofFor(r1, w1,
            roundNumber: 1, note: mine.note, position: mine.position, path: path1);
        final (ownChecked, whyOwn) = await checker.check(ownProof, pkd: (await NoteAddress.derive(c.f.wallet.ivk, c.f.walletD)).pkd);
        expect(whyOwn, isNull, reason: '$whyOwn');
        expect(view.check(1, ownChecked!.cmRoot), isNull);
        expect(view.checkedTo, 1);

        final (tracked, whyTrack) = view.track(
            round: 1, position: mine.position, leaf: BlockFold.lanesToBytes(mine.cm), path: path1);
        expect(whyTrack, isNull, reason: '$whyTrack');
        final (held, whyHold) =
            store1.takeChange(opening: NoteOpening.of(mine.note), position: mine.position, round: 1);
        expect(whyHold, isNull, reason: '$whyHold');
        expect(view.canSpend(tracked!, tip: 1), isTrue);

        // ---- the payee asks, and libcloak pays ----

        final payee = c.f.wallet;
        final payeeAddr = await NoteAddress.at(payee.ivk, 3);
        final now = DateTime.now().toUtc();
        final invoice = await Invoice.issue(
            tokenId: pool.tokenId,
            ivk: payee.ivk,
            address: payeeAddr,
            amount: 120,
            expiry: now.add(const Duration(hours: 1)),
            memo: 'a crate of oranges',
            rng: Random(54));
        await payeeJournal.add(JournalEntry.invoiceIssued(invoice));
        await journal.add(JournalEntry.invoiceReceived(invoice));

        final build = Stopwatch()..start();
        final (payment, whyBuild) = await PaymentBuilder.build(
            invoice: invoice,
            keys: payee,
            changeAddress: await NoteAddress.at(payee.ivk, 4),
            note: held!,
            notes: store1,
            view: view,
            spendP: pool.spendP,
            tokenId: pool.tokenId,
            tip: 1,
            now: now,
            rng: Random(55));
        build.stop();
        expect(whyBuild, isNull, reason: '$whyBuild');
        timings['build ms'] = build.elapsedMilliseconds;
        await journal.add(JournalEntry.paymentBuilt(payment!));

        final submit = Stopwatch()..start();
        final answer = await client.submit(payment, notes: store1, rng: Random(56));
        submit.stop();
        timings['submit ms'] = submit.elapsedMilliseconds;
        expect(answer.outcome, Submitted.accepted, reason: '${answer.refusal}');
        expect(answer.round, 2);
        expect(held.state, NoteState.reserved);
        await journal.add(JournalEntry.paymentSubmitted(invoice, answer.id));
        await journal.add(JournalEntry.paymentAnswered(invoice, answer));

        // ---- the coordinator builds round 2 around it ----
        //
        // One real transfer and three padding, closed at the deadline, which
        // is the ordinary case for a pool that is not busy.

        final sw2 = Stopwatch()..start();
        final a2 = await announced(2);
        timings['round 2 ms'] = sw2.elapsedMilliseconds;
        for (final id in [a2.slotId, a2.roundId, a2.witnessId]) {
          await untilMined(id);
        }

        progress = await client.follow(view);
        expect(progress.ok, isTrue, reason: '${progress.stopped}');
        expect(progress.folded, 1);
        expect(view.round, 2, reason: 'the pool view reaches the coordinator\'s tip');

        // ---- the proof, out of the round the coordinator built ----

        final r2 = (await node.fetch(a2.roundId))!;
        final w2 = (await node.fetch(a2.witnessId))!;
        final y2 = (await node.fetch(a2.slotId))!;
        final applied2 = ledger.apply(r2, w2, y2);
        expect(a2.disagreement(applied2), isNull);

        final position = PaymentProofs.positionOf(applied2, payment.paidCommitment);
        expect(position, isNotNull,
            reason: 'the note libcloak built is in the round the coordinator mined');
        final path2 = [for (final x in ledger.tree.path(position!).siblings) List<int>.of(x)];
        final (proof, _) = await node.proofFor(r2, w2,
            roundNumber: 2, note: payment.paid.plaintext, position: position, path: path2);
        timings['proof bytes'] = proof.encode().length;
        await journal.add(JournalEntry.proofBuilt(invoice, proof));

        // ---- the payee checks it against the node's own headers ----

        final check = Stopwatch()..start();
        final (checked, whyCheck) = await checker.check(PaymentProof.decode(proof.encode()), pkd: payeeAddr.pkd);
        check.stop();
        timings['check ms'] = check.elapsedMilliseconds;
        expect(whyCheck, isNull, reason: '$whyCheck');
        expect(checked!.value, 120);
        expect(checked.round, 2);
        await payeeJournal.add(JournalEntry.proofChecked(invoice, payment: checked));

        // and the wallet's fold agrees with the round it proved
        expect(view.check(2, checked.cmRoot), isNull,
            reason: 'the block roots folded off the feed reach the root the mined round carries');
        expect(view.checkedTo, 2);

        // ---- the payee acknowledges, and the payer keeps it ----

        // the clock an acknowledgement is against is the block's own, which is
        // the only clock in the exchange the payer did not supply
        final held2 = (await node.blockHolding(a2.witnessId))!;
        final (provenBlock, whyBlock) = await checker.headers.proven(held2.$1.hash);
        expect(whyBlock, isNull, reason: '$whyBlock');
        final (ack, whyAck) = await Acknowledgement.of(
            invoice: invoice, payment: checked, ivk: payee.ivk, minedAt: provenBlock!.time);
        expect(whyAck, isNull, reason: '$whyAck');
        await payeeJournal.add(JournalEntry.acknowledgementSent(invoice, ack!));
        final back = Acknowledgement.decode(ack.encode());
        expect(await back.check(invoice), isNull);
        await journal.add(JournalEntry.acknowledgementReceived(invoice, back));

        // ---- the record ----

        final thread = await journal.thread(invoice.id);
        expect(thread.whole, isTrue, reason: '${thread.refused}');
        expect([for (final e in thread.entries) e.kind], [
          JournalKind.invoiceReceived,
          JournalKind.paymentBuilt,
          JournalKind.paymentSubmitted,
          JournalKind.paymentAnswered,
          JournalKind.proofBuilt,
          JournalKind.acknowledgementReceived,
        ]);
        for (final e in thread.entries) {
          print('  payer $e');
        }
        for (final e in (await payeeJournal.thread(invoice.id)).entries) {
          print('  payee $e');
        }
      } finally {
        await server.stop();
        await transport.close();
      }
    }, timeout: const Timeout(Duration(minutes: 30)));
  }, skip: skip);
}
