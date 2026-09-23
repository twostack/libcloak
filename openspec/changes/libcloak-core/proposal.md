## Why

The shielded pool has a coordinator and a protocol, but nobody can hold money in
it. Everything on the wallet side exists today only as pieces inside tstokenlib's
test fixture: keys are made by hand, notes are scanned out of a round in a test,
a transfer is assembled inline, and no one has ever checked a payment the way a
payee would have to. A payee's whole position rests on being able to verify, from
headers it holds itself, that a payment was made. That check does not exist.

libcloak is the library that holds one person's side of the pool. It is built
now because the coordinator is built: the two halves of the protocol have to meet
before either can be trusted, and the meeting has to happen at test parameters on
localnet before testnet is worth attempting.

The rule it is shaped by is that people pay people in consideration of something.
The payer and the payee already have a channel, so the payment and its proof go
over that channel. libcloak therefore scans nothing and looks nothing up by
address, txid or outpoint. Restoring a wallet from its seed is the one exception,
and it is out of scope for this change.

## What Changes

- A new package `libcloak`: headless, no UI, no daemon, no network of its own.
  A host supplies a transport and a source of block headers through ports
  libcloak defines.
- **Keys** from one seed: a pool-key branch, a fresh diversified address per
  invoice, a birthday round, and the whole lot encrypted at rest.
- **A pool view** that keeps every unspent note's Merkle path current by
  folding one 32-byte block root per round into an upper frontier, then checking
  the fold against the `cmRoot` of a header it proved off the chain itself. This
  is the change's central number: **32 bytes a round**, against 16,384 if a
  wallet followed every commitment. It is the same broadcast for everyone and
  names nobody.
- **Invoices**: a payee asks for money at a fresh address, with an amount, an
  expiry and a memo.
- **Payments**: build a transfer against a note, submit it, and when the round
  is mined turn it into a **payment proof** the payee checks against its own
  headers. A payee that is satisfied **acknowledges**.
- **A coordinator client** speaking tstokenlib's protocol over a transport port,
  including the descriptor and the round feed.
- **A journal** on files recording every invoice, payment, proof and
  acknowledgement, so a wallet can say what it owes and what it is owed.
- Deposits, withdrawals and restore-from-seed are deliberately **not** in this
  change; they follow in `libcloak-onramp`.

### Numbers this change is meant to move, and their bounds

| | bound | where it becomes a requirement |
|---|---|---|
| data followed per round, per wallet | **32 B**, independent of the number of notes held | `pool-view` |
| catching up 1,000 rounds holding 8 unspent notes | under **2 s** | `pool-view` |
| wallet state for 100 unspent notes | under **200 KB** | `pool-view` |
| checking a received payment proof | under **100 ms** at test parameters | `payments` |
| a payment proof at test parameters | under **1 MB** | `payments` |
| libcloak's own work building a payment, excluding the spend proof | under **200 ms** | `payments` |
| rounds a wallet may fall behind and still spend | **4** (`PoolHeader.ringEntries`) | `pool-view` |

Two of these are the point of the change. The 32 bytes is what makes a wallet
that is not a server possible at all. The 100 ms is what makes a payee's check
something that happens while the payer waits, rather than a batch job.

A payment proof is checked **without verifying a STARK**. The round was mined,
which means the chain ran the pool's verifier script and accepted it. The payee
therefore checks that the witness is in a block it has a header for, that the
witness spends its round's PP1 and PP2, that the PP1 carries the pool's tokenId,
and that its own commitment sits under that round's root. That is why 100 ms is
a plausible bound and 20 ms of proof verification never appears in it.

## Capabilities

### New Capabilities

- `wallet-keys`: one seed to a pool spending key, diversified addresses issued
  one per invoice, the birthday round, and the encrypted file they live in.
- `chain-headers`: the port libcloak requires of a header source, what a proven
  header is, and the merkle-proof check that binds a transaction to one.
- `pool-view`: the pool's descriptor and its block-size invariant, the upper
  frontier, folding block roots, keeping note paths current, refusing gaps, and
  going idle when there is nothing to keep fresh.
- `note-store`: notes and their states, the balance lines a person reads, and
  choosing which notes a payment spends.
- `invoices`: the shielded invoice a payee writes and a payer reads.
- `payments`: building a transfer for an invoice, submitting it, building a
  payment proof once the round is mined, checking a received one, and
  acknowledging.
- `coordinator-client`: tstokenlib's protocol over a transport port, the
  descriptor, submissions and replies, and the round feed.
- `journal`: the file-backed record of everything the wallet has promised,
  paid, proved and acknowledged.

### Modified Capabilities

None. libcloak is a new package with no existing specs.

## Impact

**New:** the `libcloak` package (`lib/`, `test/`, `docs/DESIGN.md`).

**Depends on ../tstokenlib**, which needs four things this change cannot supply
itself. They are a separate change in that repo (`sp-block-roots`) and this one
is blocked on them:

1. the per-round block root published on the announcement, and an assertion at
   plan construction that a round's leaf count is a power of two;
2. the descriptor carrying the block size, the pool's tokenId and its genesis
   header, since txids alone are useless to a wallet that cannot look them up;
3. a proven-round check and a proven-note check, so the rules a payee applies
   live beside the pool they describe rather than being restated here;
4. path maintenance on `NoteCommitmentTree`: fold a block root into a frontier,
   and update a note's siblings from it.

**Depends on nothing else.** Transport and headers are ports. The SPV
implementation is being extracted from ../libspiffy (`lib/src/spv`, 8 files,
2,324 lines; only `block_header_chain.dart` reaches into libspiffy's internal
storage) into a package both can depend on; until that lands libcloak is tested
against its own fakes, and the port is what makes that possible.

**Hosts affected later, not by this change:** ../pool-coordinator must deliver
proven rounds to submitters and put block roots on the feed; a CLI over
../ricochet-dart-client and ../overnode_v2 are the expected first hosts.

**Not in this change:** deposits, withdrawals, restore from seed, and any
transparent coin handling beyond the ports that will need them.
