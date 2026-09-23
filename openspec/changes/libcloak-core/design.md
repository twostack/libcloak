# Design

## Shape

libcloak is a library, not a program. It has no `bin/`, no daemon, no sockets and
no UI. A host builds a wallet, hands it two ports, and calls it.

```
lib/
  libcloak.dart              the public surface
  src/
    keys/    seed.dart  wallet_keys.dart  wallet_file.dart
    headers/ header_source.dart  proven_header.dart  merkle_membership.dart
    pool/    descriptor.dart  pool_view.dart  frontier.dart  note_path.dart
    notes/   note.dart  note_store.dart  balance.dart  selection.dart
    msg/     invoice.dart  payment_proof.dart  acknowledgement.dart  codec.dart
    pay/     payment.dart  builder.dart  checker.dart
    net/     transport.dart  coordinator_client.dart
    journal/ journal.dart  entry.dart
```

Two ports, both defined here and implemented elsewhere:

- `HeaderSource` — the tip, whether a block hash is on the accepted chain, and a
  header for a height. Nothing else. The narrowness is the privacy property:
  a port with no method taking an address or an outpoint cannot leak one.
- `Transport` — send a frame and await a reply, and read a feed from a sequence
  number. Opaque bytes; the protocol is tstokenlib's.

## The decisions this change settles

| | decision | why |
|---|---|---|
| D1 | Notes stay spendable by following **block roots**, 32 B a round | Settled in conversation 2026-09-23 and revised from the original plan, which had wallets follow every commitment at 16 KB a round. See below. |
| D2 | The SPV core is **extracted** from libspiffy into a package both depend on | 2,324 lines in 8 files; 7 depend only on `package:spiffynode` and pub packages, and one (`block_header_chain.dart`) reaches into libspiffy's internal storage. That single seam becomes a storage port. libcloak does not wait for it: it depends on `HeaderSource`, and the extraction implements that. |
| D3 | Message **formats** live here, **checks** live in tstokenlib | The rules a payee applies are rules about the pool, and they belong beside the pool so the coordinator and the wallet cannot drift. The envelope, expiry and signature are wallet concerns. |
| D4 | The journal is **files** | It is append-only, small, and read whole. SQLite buys indexes nothing here needs and costs a native dependency in a library meant to be embedded. |
| D5 | Transparent scope is **pool-only** | Deposits and withdrawals only, and not in this change. Anything more re-opens what libspiffy already answers. |
| D6 | The **coordinator delivers** proven rounds to submitters, and puts block roots on the feed | It already holds the reply channel, so a submitter learns its transfer landed without asking. The feed serves everyone else. This is a change in ../pool-coordinator, not here. |

## How a note stays spendable

The pool's commitment tree is depth 32. A round appends a fixed power-of-two
block of leaves: 512 at production parameters (16 subtrees of 32), 32 at test
parameters (1 subtree). Round N therefore owns exactly the aligned node at level
log2(block), index N - 1 (round 1 owns block 0; the genesis appends nothing).

That splits a note's 32 siblings in two:

| | production | test | changes? |
|---|---|---|---|
| below the block level | 9 | 5 | frozen when the note's own round is mined |
| above it | 23 | 27 | folded forward, one block root a round |

So the wallet keeps, per note, its position and its frozen lower siblings; and
per wallet, an upper frontier. Each round it folds one 32-byte block root and
recomputes the upper siblings. Following costs 32 bytes a round whatever the
wallet holds, against 16,384 bytes if it followed every commitment.

Two things make this safe rather than merely cheap:

- **It is checked.** After folding, the computed root must equal the `cmRoot` of a
  round the wallet proved against a block header it holds. A wrong root, or a
  skipped round, fails that check. So the 32 bytes can come from anyone.
- **It names nobody.** A block root is one value a round, identical for every
  follower. Asking a server for a path, by contrast, tells it which leaf is
  yours, and repeated over a few rounds that is the wallet's whole history. The
  point of following is that there is no question to answer.

The pool's header carries four anchors, so a wallet must be current within four
rounds when it spends. At 32 bytes a round, being current is not a burden; a
wallet that has been away catches up first and then spends.

### The invariant this rests on

The block size must be a power of two and must never change for the life of the
pool. If it is not a power of two, round boundaries and block boundaries drift
apart, a note's lower siblings stop being determined by its own round, and the
wallet needs a neighbouring round's commitments as well. If it changes mid-life,
nothing after the change is aligned and there is no repair short of a new pool.

Production (16 subtrees, 512 leaves) and test (1 subtree, 32 leaves) both satisfy
it today; a 300-transfer plan would give 19 subtrees and 608 leaves and would
not. So it is asserted where a plan is built, carried in the descriptor, and
checked by the view when it opens against stored state. This is a tstokenlib
change, listed below.

## Prerequisites in tstokenlib

This change is blocked on a change in ../tstokenlib (`sp-block-roots`). Four
items, all small:

1. **Block root published.** After applying round N the per-round block root is
   the tree node at level log2(block), index N - 1. Expose it on the ledger and carry
   it in `PoolAnnouncement`. Nothing on chain changes: neither the spend circuit
   (a flat 32-step Merkle chain that takes siblings as witness) nor the round
   proof (which already appends aligned subtrees at a known index) is touched.
2. **The power-of-two assertion** where an `AggregationTree` is built, throwing
   with the leaf count, so a bad plan fails in a unit test rather than at round
   4,000.
3. **The descriptor carries** the block size, the pool's tokenId and its genesis
   header. Txids are useless to a wallet that cannot look them up.
4. **Path maintenance on `NoteCommitmentTree`**: fold a block root into a
   frontier, and update a note's siblings from it, with the result checked
   against `NoteCommitmentTree.path` for a directly built tree.

5. **The fixture exported as a testing library.** `PoolChainFixture` lives in
   tstokenlib's `test/`, which no other package can import, so libcloak cannot
   build a scenario against the pool's own chain without it. It becomes
   `package:tstokenlib/testing.dart`, exporting the fixture and its plans and
   nothing a production wallet would reach for.

A proven-round check and a proven-note check belong in tstokenlib too, by D3, and
go in the same change.

## The risk this change cannot remove by itself

A payee's check of lineage is one hop: the witness spends the round's PP1 and
PP2, and that PP1 carries the pool's tokenId. The claim is that this is enough to
place the round in the pool's chain back to genesis. **That claim has never been
attacked.** If it is wrong, every payment proof is wrong, and the fix is more
than a patch here.

So the first task of this change is an attack test on localnet: forge a round
carrying the pool's tokenId and a header of the attacker's choosing, give it a
witness, mine it, and put the resulting payment proof through the payee's checks.
The expected result is a refusal naming the step that caught it. If instead it
passes, this change stops and the payment proof grows whatever it needs, most
likely a chain of rounds rather than one hop, at a cost in proof size that would
have to be measured before anything else is built.

Putting this first is deliberate: it is cheap, it is independent of every other
task, and it is the only one whose failure invalidates the rest.

## Bounds, and what happens if a measurement misses

| bound | if it is missed |
|---|---|
| catching up 1,000 rounds with 8 notes under 2 s | Fold per note instead of per round only when a note is about to be spent, keeping just the frontier between spends. Costs a lazy recompute of up to 23 hashes per level, still no extra data. |
| view state under 200 KB for 100 notes | Store lower siblings once per round rather than once per note: notes sharing a round share most of them. |
| checking a payment proof under 100 ms at test parameters | Report where the time went first. The check is hashing, parsing and script reading, so a miss means something is parsing a whole transaction where it should read one output. |
| a payment proof under 1 MB at test parameters | Accept it and record the number: the round and witness are what they are, and the alternative is asking the payee to fetch them, which is the thing this library does not do. |
| libcloak's own payment work under 200 ms excluding the spend proof | Accept and record; the spend proof dominates by an order of magnitude and this bound is a guard against accidental quadratic work, not a target. |
| a journal of 10,000 entries read under 1 s | Keep an index file beside the entries. Still files, still append-only. |

## What is deliberately not here

Deposits, withdrawals and any other transparent coin handling; restore from
seed; the SPV implementation; the ricochet transport; a CLI. Deposits,
withdrawals and restore follow in `libcloak-onramp`. Restore from seed is the one
place the no-scanning rule does not apply, and it deserves its own thinking
rather than being bolted on here.

## Testing

Everything in this change runs against tstokenlib's `PoolChainFixture` at test
parameters (two rounds, four transfers a round, a known wallet and diversifier)
plus fakes for both ports. Two things need more than the fixture and become
tasks: a directly built 1,000-block tree for the fold, and a localnet chain for
the lineage attack test and the end-to-end run against ../pool-coordinator.
