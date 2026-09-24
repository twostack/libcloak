# Integrating libcloak

For the author of a host: a CLI, an app, a server that embeds this library.

libcloak holds one person's keys, notes, payments and proofs. It is headless. You
supply two ports and the files, and you call it. Everything below is a rule that
libcloak either cannot enforce for you, or enforces in a way you can defeat by
trying hard enough. Each one says what breaks if you get it wrong.

Read `../../README.md` for the flow and `../DESIGN.md` section 11 for the API.
This document is only the parts where a mistake costs money or privacy.

---

## 1. The two ports are narrow on purpose. Do not widen them.

```dart
abstract interface class HeaderSource {
  Future<ChainTip> tip();
  Future<int?> heightOfBlock(List<int> blockHash);
  Future<List<int>?> headerAtHeight(int height);
}

abstract interface class Transport {
  Future<List<int>> request(List<int> frame, {Duration timeout});
  Future<List<FeedEntry>> readFeed(int from, {int max});
}
```

Five methods. **Not one of them takes an address, an outpoint, or a transaction id
derived from what the wallet holds.** That is the privacy property. A source,
however curious and however well logged, cannot learn what this wallet owns from
the questions it is asked.

**What breaks it:**

- Adding `getTransaction(txid)` or `getUtxosFor(address)` to your adapter because
  a command would be easier with it. Everything a payee needs arrives inside the
  proof the payer handed over. If you find yourself wanting a lookup, the design
  is wrong, not the library.
- Satisfying `heightOfBlock` by **fetching that block**. A request naming a block
  a payer just gave you says which payment you are checking, to whoever answers.
  Answer from headers you already hold and validated, or answer `null`.
- Treating `null` as "ask somebody else". `null` means *not on the chain I
  accept*. libcloak treats it as absent. It is never provisional.

**A correct header adapter** answers from a validated chain it maintains
independently of any particular query. libspiffy's `BlockHeaderChain` does this:
`bestHeight`/`chainTip`, `getHeightByHash`, and `getHeaderByHeight(n).serialize()`
for the 80 bytes.

**The transport must stay opaque.** It moves bytes. It must not decode a pool
message, must not route on message contents, and must not inspect a frame to
decide anything. A transport that cannot decode is a transport that cannot leak.

---

## 2. A push is not a reply

`Transport.request(frame) → reply` assumes the channel it reads from carries
**answers to questions you asked**. Protocol version 3 added `PoolRoundMined`,
which a coordinator sends unasked.

If an unsolicited notice can appear in the stream `request()` reads, it will be
consumed as the answer to whatever call is in flight. Measured, through the real
client:

```
--- a submission answered by an unsolicited mined-round notice ---
outcome : unanswered
refusal : size: a reply is at most 4096 bytes and 719563 arrived

--- a frontier request answered by the same notice ---
refusal : catch-up: the pool answered a frontier request with roundMined
```

An accepted payment reports "no answer arrived" and its real reply is orphaned.
No money is lost, because the note stays reserved, but the wallet lies to the
person about what happened.

**Do this.** Deliver pushes to a separate channel and drain them with a method of
your own that libcloak never calls:

```dart
// yours, on the concrete transport class
Future<List<PoolRoundMined>> readNotices();
```

**Do not** make `request()` read until an id matches. That forces the transport to
decode, which breaks rule 1.

---

## 3. Bound every frame before you read it

Everything arriving from a coordinator is hostile input, including from a
coordinator you trust, because a transport can be interposed. libcloak bounds
what it decodes. Your transport must bound what it buffers.

- Check a declared length against the protocol's maximum for that message kind
  **before** allocating.
- Discard an over-long frame naming both sizes. Do not truncate it and try.
- A frame that does not decode is discarded, not retried. The same bytes produce
  the same answer, and a client that retries a lie spins.

---

## 4. Folding is arithmetic; checking is evidence

`PoolView` carries two numbers, `round` and `checkedTo`, and refuses to yield a
spend path while they differ.

Folding a block root updates the wallet's picture of the tree. It becomes
*evidence* only when the root it computes equals the commitment root of a round
the wallet proved off the chain for itself. A wrong block root anywhere in a run
makes the root at the end of the run wrong too, which is why folding a thousand
rounds from a stranger and checking once at the end is sound.

```dart
await client.follow(view);                  // folds
await client.bringForward(view, checker);   // folds, then checks once
final (v, why) = await client.current(checker);  // for a wallet with no state
```

**What breaks it:**

- Reading `view.round` and treating it as "synced". Print both numbers. A person
  refused at the view needs to see *folded to 812, checked to 806*.
- Advancing a held note's path from a frontier or a checkpoint. A frontier says
  where the tree stands; it says nothing about the rounds a particular leaf's
  siblings missed. A note's path comes forward only by folding **every** round
  since it was minted. `current()` is for a wallet with no notes.
- Accepting a frontier on the pool's word. `current()` takes a head proof first
  and accepts the frontier only because the frontier computes that head's root.
  Do not reimplement that sequence with the two halves swapped.

---

## 5. There is exactly one way a note enters the store from someone else

```dart
(HeldNote?, Refusal?) take(CheckedPayment payment)
```

`CheckedPayment` is produced only by `PaymentChecker.check`. **The argument type
is the rule**: there is no path into the note store for a proof nobody verified,
because the value you would need does not exist until one was.

`takeChange` is the other door, and it is for notes **the wallet built itself and
watched into a round**: a payment's change, a deposit's note, a withdrawal's
change. It is not weaker, because there is nobody to have lied. It is also not a
back door:

**Never use `takeChange` to admit a note described by somebody else.** If you
find yourself reaching for it with an opening that arrived over the wire, you are
about to accept an unverified payment. Use `check` and `take`.

---

## 6. `unanswered` is not a failure

A submission ends in one of five outcomes. libcloak reserves the note **before**
the frame leaves the machine and releases it only where the answer establishes
the transfer is not in a round.

| outcome | the note | what it means |
|---|---|---|
| `accepted` | stays reserved | it is in round N |
| `refused` | released | the coordinator said no, by name |
| `expired` | released | it aged out of the inbox |
| `unsent` | released | nothing left the machine |
| `unanswered` | **stays reserved** | no answer arrived; it may be in a round |

**The trap.** `unanswered` looks like a failure. It is not. The transfer may be in
a round right now.

- **Do not release the note.** Do not "clean up" reserved notes on startup.
- **Do not retry as a fresh payment.** A second payment built against that note is
  a double-spend you constructed by hand. The coordinator will refuse it at the
  nullifier, after you have paid for a STARK, and the person will not understand
  why.
- Say no answer arrived, leave the note reserved, and let the next sync settle it.

**A resend is the same submission.** Call `client.send` with the *same*
`PoolSubmission`: same bytes, same id, so a coordinator that took the first copy
recognises the second as the same submission and not a second spend.

---

## 7. One process owns the wallet, and identity is how the store knows

The note store recognises its own notes by **object identity**. `submit` reserves
in the store you hand it. A `BuiltPayment` and the `NoteStore` it was built
against must travel together: hand `submit` a different store holding "the same"
note, reloaded from disk between building and submitting, and you get
`Submitted.unsent`.

That guard works inside one process and **not at all across two**. Two processes
each read the store, each reserve a different note, and each write back a file
that has forgotten the other's reservation.

- Open the store once per command. Build and submit against that instance. Save.
  Exit.
- Take an exclusive lock on the wallet directory **before building**, not before
  submitting. The expensive work is the proof, and the race is decided before it.
- Read-only commands need no lock.

---

## 8. Never write a nullifier down

```dart
List<HeldNote> settle(List<List<int>> nullifiers, {required List<int> nk})
```

`nk` is an argument and never a field. The store computes `H(nk, rho)`, compares,
and keeps neither the key nor the answer. **A file of nullifiers is a file that
says which spends on a public chain were this wallet's.** Do not cache them, do
not log them, do not put them in a debug dump.

---

## 9. What the files are, and which one is not encrypted

| file | holds | encrypted |
|---|---|---|
| the wallet | one seed | yes, under a passphrase |
| the pool view | the frontier and one path per note, 1,069 B a note | no |
| the note store | openings, positions, states, 73 B a note | **no** |
| the journal | one file per entry, 142 B each | no |

**The note store is deliberately not encrypted**, and it holds note randomness.
The spec asks that two stores which took the same notes hold byte-identical
bytes, which a fresh nonce breaks; encryption at rest is scoped to the wallet
file. The reasoning is in `../DESIGN.md` section 5.

So the host is responsible for the note store's confidentiality: owner-only
permissions on the directory and every file in it, and telling a person plainly
which files matter. Say so in your `status` command.

**Write every state file temp-then-rename**, into the same directory, so a crash
leaves either the old state or the new one and never a half-written file.

---

## 10. Journal before you send, and never repair one

Write the `...Built` entry **before** the frame leaves and the `...Answered`
entry when the answer arrives. A process that dies between them leaves a record
you can find. The other order leaves a spend nobody wrote down.

**The journal is deliberately not tamper-evident.** The threat model is "this file
may have been edited". Report an entry that does not parse as refused, name the
file, show the rest. Never rewrite, truncate or delete one to make a read
succeed.

Deposits and withdrawals answer no invoice, so they thread under
`built.threadId`, the same 16 bytes an invoice id occupies.

---

## 11. Money crossing the edge is public, and a deposit is the one place you act before you can check

### A deposit is four steps and the order is forced

```dart
// 1. prove first: the covenant must lock the note's commitment, and the
//    proof is what produces it
final (proved, why) = await DepositBuilder.prove(
    keys: keys, address: fresh, amount: 50000, spendP: pool.spendP);

// 2. build the covenant (tstokenlib), fund and sign it (your transparent side)
final covenant = tool.createDepositTxn(
    commitment: proved!.commitment,
    pp3Outpoint: getOutpoint(announced.roundTxId, outputIndex: 3),
    refundPKH: mine, refundAfter: height, /* ... */);

// 3. back the proof with the covenant: checks it locks THIS commitment and
//    EXACTLY this amount, before anything leaves
final (built, whyBacked) = proved.backedBy(covenant);
final answer = await client.submitDeposit(built!);

// 4. take the note on ONLY from a mined round
final leaf = PaymentProofs.positionOf(round, built.commitment);
notes.takeChange(opening: built.note, position: leaf!, round: n);
```

**A deposit spends no note.** Nothing is reserved and nothing is released. What
stops one covenant being backed twice is the coordinator, which refuses a second
pending transfer naming it. Do not invent a local reservation for it.

### The trust you cannot avoid, and what bounds it

Everywhere else, a pool's answer is checked against something the wallet proved
for itself. A deposit cannot work that way: you must spend a transparent coin
into a covenant naming a round's PP3 **before** you can know whether any round
will take it in.

**The loss is bounded to time, and to nothing else.** The covenant refunds to a
key the depositor holds, at a block height the depositor chose. The exposure is
the deposited amount, illiquid, from broadcast until the refund height, recovered
in full. Nothing can take the money.

Therefore the host's obligation is that **the person chose that height knowingly**.
Print the amount, the round, and the refund height, and get confirmation, before
you broadcast. Too close and a coordinator skips the deposit, because a refund
mined before its round would invalidate the round; too far and the money is
illiquid for longer if it is never taken.

### Both edges are public

A deposit names an amount and a transparent source on the chain. A withdrawal
names an amount and a transparent destination. Say so before doing either. A
person who believes these are private is wrong, and your interface is what told
them.

### Addresses

Both builders check the address you pass is one of **this wallet's** before
spending a STARK on it, because change or a deposit written to somebody else's
address is money gone. Use a fresh address each time, and never derive a
transparent key from a pool key or the reverse: a person who learns one address
must not be able to test candidates for the other.

---

## 12. Refusals are the interface. Do not swallow them.

Everything that takes bytes from somebody else returns a value **or** a `Refusal`
naming the step that stopped it, never an exception that escaped.

```dart
class Refusal { final String step; final String reason; }
```

- **Print `step` and `reason` verbatim.** Never replace either with a word of your
  own. A message reading "invalid", "error" or "failed" is a defect: the whole
  point of the vocabulary is that a person is told which rule stopped them.
- **Do not wrap libcloak calls in a blanket `try/catch`.** It swallows the named
  refusals along with whatever you were guarding against.
- Catch-up refusals carry the protocol's own reason as the step. Those four names
  are fixed for the protocol's life, so switch on the step, not on the sentence:

| step | means |
|---|---|
| `notYet` | ask again after the next round |
| `unavailable` | the pool is degraded; ask again later |
| `notServed` | this pool will never serve it |
| `unpublishedRange` | never; not a run the descriptor publishes |

- A refusal never carries a key, a seed or note randomness. Keep it that way in
  anything you add: refusals are shown to people and written to journals.

---

## 13. Secrets

- No command prints a seed, a spending key, a passphrase or an RPC password, at
  any verbosity. Test this by searching both output streams for the real values.
- Take a passphrase from a terminal prompt with echo off, or from a named
  environment variable. **Never from a command-line argument**: arguments are
  visible to every process on the machine.
- The seed and the decrypted key live for the life of the process and are written
  nowhere.
- The one exception is `init` printing the seed once, on its own stream, so it can
  be redirected without carrying anything beside it.

---

## 14. Things that look like optimisations and are not

- **Reusing an address.** Invoices name a fresh address each time, and so does
  change. Reuse links payments.
- **Asking for "everything since round N" when catching up.** libcloak asks for
  one of the pool's published aligned runs. A range of your own choosing says
  when this wallet was last current, and over a few catch-ups that is a
  fingerprint.
- **Asking for a round by number.** `CatchUpKind.round` tells the pool which round
  this peer cares about. Harmless for a round you submitted into from the same
  peer id, because the pool already knows; a link between identities otherwise,
  and a receipt of payment if you are the payee. Prefer the pushed notice.
- **Caching answers across wallets.** The header chain is public and shareable.
  Nothing else is.

---

## 15. Testing your integration

- **A fake that can only succeed tests only success.** Give your fakes the
  refusals before you give them the answers. The crash fixed in `7c780c7` existed
  because every fake in this suite served an answer to every catch-up, since
  before protocol version 3 there was no other answer to give.
- **libcloak's own fakes never push.** `FakeTransport` answers only when asked, so
  this suite is blind to the notice problem in rule 2 by construction. Your notice
  path needs a test on your side.
- **Mutate.** Every place you take bytes from somebody else, feed it a thousand
  single-byte mutations and truncations and assert a named refusal every time and
  a crash never.
- **A measured bound is per core.** Three of libcloak's bounds passed alone and
  failed in a parallel pack: proof checking 63.7 to 176 ms, journal read 271 to
  1,371 ms. Measure best-of-N, and keep any test that *is* the load out of the
  default run.
