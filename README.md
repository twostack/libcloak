# libcloak

The wallet library for the TSL1_SP shielded pool.

libcloak holds keys, notes and their proofs for one person. It is a headless library and
as such has no UI, no daemon or network of its own. A host (a CLI, an app, a server) supplies
a transport and a source of block headers.

## What it is for

P2P Payments. A payment is made in consideration of something, so the
payer has to be able to *show* that it was made:

1. the payee writes an **invoice** naming a fresh address,
2. the payer builds a **transfer** and submits it to the pool's coordinator,
3. the round is proved and mined, and the payer sends the payee a **payment
   proof**,
4. the payee checks that proof against block headers it holds itself, and
   **acknowledges**.

The acknowledgement is signed under a key the invoice carries the public half
of, so the payer ends up holding evidence, from the only person who could have
produced it, that the consideration was delivered against a payment the payee
itself checked. That is why a payer keeps an invoice after paying it.

## What it does not do

It does no blockchain scanning, and it does not perform lookups for
addresses, txids or outpoints. Those are the habits that run counter to
SPV (Simplified Payment Verification). Everything a payee needs arrives
over a P2P comms channel along with the payment. The single exception is restoring a wallet from its
seed.

Nothing is taken on trust either. Every answer a pool gives is checked against
something the wallet proved for itself, so the pool is a convenient server and
never an authority: a wallet handed the same bytes by a stranger reaches the
same verdict.

## What a host supplies

Two ports, and nothing else touches the world.

| port | what it answers |
|---|---|
| `HeaderSource` | the chain tip; the height of a block hash, or null when it is not on the accepted chain; the 80-byte header at a height |
| `Transport` | send a frame and get a reply; read the pool's feed from a sequence number |

The narrowness is the privacy property rather than a matter of care. Neither
port declares a method that takes an address, an outpoint or a wallet-derived
txid, so neither can leak one.

## Using it

```dart
// the payee asks
final invoice = await Invoice.issueFor(
    tokenId: pool.tokenId, keys: payee, amount: 200, expiry: due, memo: 'a crate of oranges');

// the payer checks the bytes it was handed, then pays out of a note it holds
final (inv, _) = await Invoice.read(bytes, tokenId: pool.tokenId, now: DateTime.now());
final (client, _) = await CoordinatorClient.open(transport);
await client!.follow(view);                       // 32 bytes a round
await client.bringForward(view, checker);         // and check the fold once
final (choice, _) = store.choose(amount: inv!.amount, asset: asset, view: view, tip: view.round);
final (payment, _) = await PaymentBuilder.build(
    invoice: inv, keys: keys, changeAddress: change, note: choice!.note,
    notes: store, view: view, spendP: pool.spendP, tokenId: pool.tokenId,
    tip: view.round, now: DateTime.now());
final answer = await client.submit(payment!, notes: store);
// accepted reserves the note; a refusal names one of the protocol's twelve reasons

// once the round is mined, the payer hands over a proof. The leaf comes from
// the round itself: PaymentProofs.positionOf finds the payer's own commitment
final (proof, _) = PaymentProofs.standingFor(payment!,
    round: n, roundTx: roundBytes, witnessTx: witnessBytes,
    blockHash: block, txIndex: i, branch: branch, position: leaf, path: path);

// and the payee checks it against headers of its own
final (paid, whyNot) = await checker.check(proof!, pkd: address.pkd);
final (note, _) = store.take(paid!);
final (ack, _) = await Acknowledgement.of(
    invoice: inv, payment: paid!, ivk: payee.ivk, minedAt: header.time);
```

Nothing above throws on bad input. Everything that takes bytes from somebody
else returns a value or a `Refusal` naming the step that stopped it, so a host
can tell a person which rule failed rather than "invalid".

The whole exchange, runnable and checked by the suite, is
`test/end_to_end_test.dart`. The same flow against a real coordinator on a real
chain is `test/localnet_e2e_test.dart`.

## How a note stays spendable

The pool's commitment tree appends a fixed power-of-two block of leaves per
round, so round N owns exactly one node at the block level. A note's lower
siblings freeze when its own round is mined, and the wallet keeps its paths
current by folding **one 32-byte block root a round** into an upper frontier.
That costs the same whatever the wallet holds, it is the same broadcast every
follower reads, and it names nobody.

Folding is arithmetic. It becomes evidence when the root it computes equals the
commitment root of a round the wallet proved off the chain for itself, which is
why a `PoolView` carries `round` and `checkedTo` as two numbers and refuses to
hand over a spend path while they differ.

## What it keeps on disk

| | |
|---|---|
| the wallet | one seed, encrypted under a passphrase, temp-name-then-rename |
| the pool view | the upper frontier and one path per unspent note, 1,069 B a note |
| the note store | openings, positions and states, 73 B a note |
| the journal | one file per entry, 142 B each, in an owner-only directory |

The note store is **not** encrypted, though it holds a note's randomness. That
is a scoped decision rather than an oversight: the spec asks two stores that
took the same notes to hold byte-identical bytes, which a fresh nonce breaks,
and scopes encryption at rest to the wallet file. The reasoning, and what it
would take to have both, is in `docs/DESIGN.md` section 5.

No nullifier is ever written down. One is computed to recognise a spend and
dropped, because a file of nullifiers is a wallet's spending history.

## Status

`libcloak-core` is complete: 8 capabilities, 68 requirements, 118 scenarios,
219 tests.

It was built back to front, and the claim every payment proof rests on was
attacked before anything was built on it. A round forged to carry the pool's
tokenId, mined on a regtest node for the price of two ordinary transactions, is
refused by a payee at the step named `PP1 is this pool's script`. A payee that
parsed PP1 by offset would have accepted it.

Typical sizes and costs at test parameters, measured on an Apple M3 Pro: an
invoice 1,687 B, a transfer 14,812 B, a standing payment proof 793 KB checked
in 64 ms, a short proof 1,098 B, an acknowledgement 94 B. Building a payment
costs the wallet 8 ms of its own work and one spend proof.

Not here yet:

- **the three catch-up messages in the coordinator.** `../pool-coordinator`
  speaks protocol version 2's descriptor, submission, reply and announcement,
  and refuses anything else, so a wallet with no stored state cannot yet join a
  running pool without reading its whole feed. The wallet side is built and
  tested against a fake pool.
- **restore from a seed.** Deposits and withdrawals are built
  (`DepositBuilder`, `WithdrawalBuilder`, change `onramp-builders`); restore is
  the one place the no-scanning rule does not apply and deserves its own
  thinking.
- **an SPV implementation.** libcloak depends on `HeaderSource`; the
  implementation is being extracted from `../libspiffy`. Until it lands the
  suite runs against its own fakes and a regtest node.
- **production parameters end to end.** ARC caps a scriptSig at 1,636,802 bytes
  and a production witness is larger, so testnet runs at test parameters.

## The suite

```
dart test                                          # 231 pass, 3 skipped
POOL_LOCALNET=1 dart test                          # adds the mined forgery, 215 pass
POOL_LOCALNET=1 POOL_E2E=1 \
  dart test test/localnet_e2e_test.dart            # against a real coordinator
```

The last one is asked for separately on purpose. It stands up a ricochet
server, a coordinator and a one-per-second miner and proves two rounds; run in
the same pack as the rest it triples the wall clock of every measured bound,
and those are bounds on one core. It needs `../localnet` up and a built
`../go-ricochet/ricochet`.

## Embedding it

`docs/developer-guides/INTEGRATING_LIBCLOAK.md` is the guide for a host author:
the two ports and why they are narrow, the rules the library cannot enforce for
you, and every place where a plausible-looking shortcut costs money or privacy.
Read it before writing an adapter.

## The record

`docs/DESIGN.md` is the running record, appended in dated sections: what was
built, what was measured, and what was decided against. `openspec/specs/` holds
the capabilities as they now stand, and `openspec/changes/archive/` the changes
that put them there.
