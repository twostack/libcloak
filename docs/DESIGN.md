# libcloak design record

Dated sections, appended. Each one records what was built, what was measured,
and what was attacked — with the numbers from the machine they were taken on,
not from memory.

## 1. The gate: a round with a forged lineage (2026-09-23)

**Result: the claim holds. The forgery is refused, and libcloak proceeds.**

Every payment proof this library will ever check rests on one claim: that a
mined witness spending a round's PP1 and PP2, with the pool's tokenId in that
PP1, places the round in the pool's own chain back to genesis. The whole of
`libcloak-core` was made conditional on attacking it first, because if it is
wrong the payment proof is wrong and nothing else here matters.

### The attack

The claim's strength is that PP1's round branch is the induction: it rebuilds
the round from its parent's raw bytes and refuses a round the parent did not
produce, terminating at a create branch anchored to an outpoint that can be
spent once. A witness that was mined had that argument run over it by miners.

The claim's weakness is that **a payee runs no script**. It reads bytes. So the
attack is not against the covenant but against the reader:

```
[ a real PP1's first 563 bytes ] OP_DROP ×5 [ P2PKH to the forger ]
```

The head is the pool's own — owner, tokenId, verifier body hash, genesis header,
and a pool state of the forger's choosing — so every field a reader looks up by
offset is genuine. The body spends on a signature. It is **593 bytes where a
real PP1_SP is 16,924**, and the first byte the two differ at is 563.

### What was run

`test/lineage_attack_test.dart`, 13 cases, all passing (with the 8 port and
fake tests in `test/fakes_test.dart` that groups 1 and 2 rest on):

- **In process.** The forgery is built from the fixture's own round 1, given a
  witness of the forger's making, placed in a block the payee's header source
  vouches for and buried past the required confirmations, and handed to the
  payee as a standing payment proof. The payee refuses at the step named
  **`PP1 is this pool's script`**, with the sentence *"the output at 1 carries
  the fields of a PP1_SP but not its body, so nothing was enforced when it was
  spent (593 bytes given, 16924 rebuilt)"*.
- **On localnet** (`POOL_LOCALNET=1`, regtest node of ../localnet). The forger
  is funded, the forged round (830 B, PP1 593 B) and its witness (487 B) are
  broadcast and **mined**, and the merkle branch and header come from the node
  itself. The block check passes — the block really is on the chain, buried —
  and the payment check refuses at the same step. Mining the attack costs two
  ordinary transactions; what stops it is the reader.
- **The controls.** A real payment on the fixture's chain is accepted and
  reports the note's value; a note that is not the payee's fails at the path;
  the same forgery offered under the *pool's real* witness fails one step
  earlier, at `witness spends PP1`, because swapping the PP1 changes the round's
  txid — the spend chain is a second, independent reason this attack does not
  work; and a genuine round of a *different* pool is refused at `tokenId`,
  which is the failure mode the body check cannot catch and does not have to.

### Why the check is what it is

`PP1SpLockBuilder.parse`, the obvious thing for a wallet to reach for, reads
every field at a fixed offset and never looks at the body — so it reads the
forgery exactly as it reads a real PP1 and hands back the forger's chosen pool
state. The fix, in tstokenlib's `PoolEvidence.readPP1`, is to parse the fields,
**regenerate the whole script from them, and require all 16,924 bytes to
match**. That is now the only way anything in tstokenlib reads a PP1, and
libcloak's checker goes through it. The same attack was run against tstokenlib's
ledger first and is recorded in its design record, section 16.

### What a payee actually checks, in order

1. the encoding and its bounds;
2. the witness is in a block this wallet's **own** source vouches for, by its
   merkle branch, buried deep enough (1 confirmation on regtest, 6 elsewhere);
3. the witness spends the round's PP1 and PP2;
4. the PP1 is a real PP1_SP carrying the descriptor's tokenId and genesis
   header, and its pool header parses;
5. the opening commits under the payee's own `pk_d`;
6. the path takes that commitment to the round's commitment root.

Steps 3 to 6 are tstokenlib's `PoolEvidence`, deliberately: they are rules about
the pool, so they live beside the pool where a coordinator and a wallet cannot
drift apart.

### Measured (Apple M3 Pro, `dart test`)

| | |
|---|---|
| a standing payment proof at test parameters | **720,701 B** (bound 1 MB) |
| a short payment proof | **1,098 B** (bound 4 KB) |
| the forged PP1 | 593 B, against 16,924 for a real one |
| the mined forgery | round 830 B, witness 487 B |
| 10,000 mutated and truncated proofs | 5,604 refused at the encoding, 4,396 decoded and then refused by a check, **0 reported paid** |

A standing proof is dominated by bytes the payee hashes once and never reads:
the witness's PP1 unlock, which carries the round's STARK proof. The payee never
verifies it, because the chain already did. That is also why there is no shorter
standing form — a txid is the hash of the whole serialisation, and the witness's
txid is what its merkle branch commits to.

### Two bugs this found in the building of it

- **An encoder that could produce undecodable output.** `PaymentProof.standing`
  bounded each transaction at the chain's 10 MB limit but not the whole proof,
  while the reader refuses anything over 8 MB before it touches a byte. So a
  caller could build a proof this library would not read back. The builder now
  computes the encoded size and refuses, naming both numbers.
- **A merkle index outside its block.** `rootFor` checked `index` against the
  branch depth only when the branch was non-empty, so a single-transaction block
  accepted any index. The comparison now covers the empty branch, where the only
  valid index is 0.

### Also built, because the gate needed them

`HeaderSource` and `Transport` as ports with in-memory fakes; `HeaderChecker`
and `MerkleMembership`; the versioned `PaymentProof` in both forms; and
`PaymentChecker`. A short proof carries **no commitment root** — that is the one
thing it has no evidence for — and one appended to it is refused naming the
field. A payee that has not folded the round refuses a short proof naming both
rounds and asks for the standing form, rather than failing the payment.

## 2. Keys: one seed, and where it is written (2026-09-23)

**Result: built. The derivation is fixed by a recorded vector, and the wallet
file holds nothing in the clear.**

### The derivation, stated

```
  sk   = the first 5 lanes of HKDF-SHA256(seed, "tsl1-libcloak/derivation/1/sk"),
         taken as little-endian 32-bit words, each masked to 31 bits and drawn
         again on the one value M31 has no room for
  ivk  = PoolHash.ivk(sk)      d(i) = PoolHash.diversifier(ivk, i)
  nk   = PoolHash.nk(sk)       pk_d = PoolHash.pkdFromIvk(ivk, d)
  ovk  = PoolHash.ovk(sk)
```

Everything below `sk` is tstokenlib's, and had to be: the spend circuit derives
`ivk` and `nk` from the `sk` register itself, so a wallet that derived them any
other way would build proofs the pool refuses. The only thing libcloak decides
is how one seed becomes one `sk`, and `WalletKeys.derivation` is the number
that says which way.

The masking matters more than it looks. A 32-bit word reduced modulo
2^31 − 1 is biased; a 31-bit word is uniform except for the single value
`0x7fffffff`, which is drawn again from the next HKDF block. So the key is
uniform over the field and the derivation is still a pure function of the seed.

`test/wallet_keys_test.dart` carries the vector — `sk`, `ivk`, `nk`, `ovk` and
the diversifiers and `pk_d` of addresses 0 and 1, from a stated test seed. A
change to any of it fails the suite, which is the point: a restored wallet
derived under a changed derivation is a different wallet holding none of the
same money.

### The file

One AEAD box with a plain header. The header carries the version, the KDF and
its cost, the salt and the nonce, **and is the box's associated data** — so an
attacker who steals the file cannot quietly rewrite 64 MiB down to 8 KiB and
grind the passphrase at the lower price; the test that tries it is refused at
`passphrase`. Argon2id (the pure-Dart implementation in `package:cryptography`,
checked here against the RFC 9106 vector) and XChaCha20-Poly1305, whose 24-byte
nonce can be drawn at random with no counter to keep.

A write creates the temporary file, makes it owner-only, writes it, and renames
it over the wallet. In that order: no secret reaches the disk before the
permissions are narrowed, and the wallet itself is only ever replaced by a
rename. The temporary name is `<path>.tmp`, and a file left under it is the
wreckage of a crash — the test writes a whole, valid, *newer* wallet there and
then checks that opening the wallet gives the older one, untouched.

### Measured (Apple M3 Pro, `dart test`)

| | |
|---|---|
| seed to `sk`, `ivk`, `nk`, `ovk` | **38.2 us** |
| one address (hybrid KEM, ML-KEM keygen included) | **0.54 ms**, 1,261 B |
| wallet file, `WalletKdf.strong` (64 MiB, 3 passes) | write **413 ms**, open **402 ms** |
| wallet file, `WalletKdf.fast` (8 MiB, 1 pass) | write 80 ms, open 18 ms |
| the file itself | **114 bytes** |
| 10,000 mutated addresses | 5,028 refused (2,415 length, 1,883 `pkd`, 724 `diversifier`, 4 empty, 2 `kem`), 4,972 parsed and re-encoded to what was given, **0 crashes** |

`WalletKdf.strong` is what a wallet is written under; `fast` exists for the
suite, and for a host that opens a wallet on every keystroke and knows what it
is giving up. The cost is written into the file, so wallets written under one
cost keep opening after the defaults move.

The 4,972 mutations that *parse* are not a hole: a flipped byte inside the
1,216-byte KEM public key gives a perfectly well formed address for a key
nobody holds. An address is a destination, not a claim — what stops a payment
going to the wrong place is the invoice's signature over it, which is group 7.

### What the privacy claim actually is

Two addresses of one wallet share exactly one field, the KEM id, which is a
format constant. The test walks every four-byte run of one address's
diversifier, `pk_d` and KEM key and requires that none of them appears anywhere
in the other's. With the `ivk` they link immediately — `d(i)` is just a hash of
it — and that asymmetry is the design: a viewer can enumerate every address a
wallet will ever issue, and a payer holding one address learns nothing about
the payee's other dealings.

### Left for later

`AddressCodec.read` ends in a `try`/`catch` that turns anything
`NoteAddress.parse` throws into a refusal. Across 10,000 mutations it never
fired — every rejection came from the length, KEM and field checks in front of
it. It stays, because a reader whose only defence is the checks somebody
remembered to write is a reader one field away from throwing at a caller.

## 3. Headers: the only evidence taken from the chain (2026-09-23)

**Result: built and verified. Two bugs found, one of them a real one.**

`proven_header.dart` and `merkle_membership.dart` arrived in group 2 because
the gate needed them; group 4 is their scenarios, the serialized form the spec
asks for, and the measurement.

### What a merkle proof is now

`MerkleProof` is the standalone, versioned form: a txid, a block hash, an
index and the branch. A payment proof still carries those fields inline —
it also carries the transaction, so the two travel as one message — and
`PaymentProof.membership` hands one back, so the merkle check has exactly one
implementation and the checker goes through it.

The txid in a `MerkleProof` is a **claim**, and `MerkleMembership.confirm`
hashes the transaction it was handed and refuses if the two disagree, **naming
both**. That is what makes "compute the txid, do not take it" a rule with a
test behind it rather than a sentence in a doc comment. Inside a payment proof
the two cannot disagree, because the transaction is right there; that is why
the payment proof's wire format carries no txid of its own and did not change.

`confirm` also takes the block hash of the header whose root it was given, and
refuses a proof that names another block. In the payment path the two are the
same field, so it never fires; it exists for the standalone form, where a proof
for block A checked against block B's root would otherwise turn on the branch
arithmetic alone.

### What a payee asks the chain

The privacy claim is checked, not asserted. A full payment check against a
recording fake source makes exactly these calls:

```
heightOfBlock <the block hash that arrived inside the proof>
headerAtHeight <a height>
tip
```

The test walks every recorded call, requires each to be one of those three,
requires the one block hash asked about to be the proof's own, and then
searches the whole recorded transcript for the round txid, the witness txid,
the payee's `pk_d` and the payee's `ivk`. None of them appears. A short proof
asks the port nothing at all.

When the source does not have the block, the check stops: the transcript is a
single `heightOfBlock` call and there is no second source to fall back to.

### Two bugs this found

- **`1 << 64` is zero.** `rootFor` bounded the index with
  `index >= (1 << branch.length)`, and at the full 64 levels that shift wraps
  to zero in Dart, so *every* index was refused as "outside a block of 0
  transactions". A 64-level branch was unusable, which is precisely the case
  the cost requirement names. The comparison is now skipped at 63 levels and
  above, where every non-negative 64-bit index is inside the block by
  construction. The same wrap was in `MerkleProof` and in `PaymentProof`, and
  both are fixed.
- **A header handed back by the wallet's own source was re-hashed, but a
  `MerkleProof` naming another block was not caught.** `confirm` now takes the
  block hash; see above.

### Measured (Apple M3 Pro, `dart test`)

| | |
|---|---|
| a 64-level membership check | **0.153 ms** (bound 5 ms) |
| a serialized `MerkleProof`, 32 levels | 1,095 B (bound 2,119 at 64 levels) |
| 10,000 mutated proofs and headers | 2,676 refused at the encoding, 2,324 decoded and then refused by a check (3 were no-op mutations and still confirmed), 3,275 headers refused by length, **0 unnamed errors** |

The 0.153 ms is 64 double-SHA-256 hashes of 64 bytes each and nothing else. It
is two orders under the bound because there is nothing else in it: the payee
does not verify a STARK, and the round's proof was verified by the chain when
the witness was mined.

### The confirmation rule

One on regtest, six everywhere else, from `HeaderChecker.forNetwork`. A block
counts itself, so a witness in the tip has one confirmation. Below the
threshold the refusal names both numbers — what it has and what this wallet
requires — because "not yet" and "no" are different answers and a person acts
on them differently.

### Left honest

"The source is unavailable" is verified in the half that exists: the check
fails carrying the port's own reason, and the same proof is accepted the moment
the source answers again, because the checker holds no state. The other half —
that the wallet's *stored* state is unchanged — needs the pool view and the
note store, and is owed in groups 5 and 6.

## 4. The pool view: 32 bytes a round, and what they buy (2026-09-23)

The wallet's picture of the pool is the tree above the block level and one path
per unspent note. It is advanced by one 32-byte block root a round and it has
no port, no socket and no callback. The privacy property is not that the view
is careful about what it asks — it is that there is nothing for it to ask.

### Why the power of two is load-bearing

`PoolShape` refuses a leaf count that is not a power of two, naming it. That is
not tidiness. Round N appends a fixed block of leaves, so round N *owns* the
aligned subtree at level log2(count), index N − 1 — and that sentence is true
only at a power of two. At 608 leaves a round the leaves straddle two subtrees,
no round owns a node, and there is no such thing as "the round's block root".
The whole design rests on that one number, so it is checked before a view is
opened and again when stored state is read back under a descriptor that may
have changed. tstokenlib's own `PoolDescriptor` refuses 608 as well; the
libcloak check is the second line, and it exists because a wallet should not
learn the pool changed shape at the round where a path stops reaching a root.

The fixture pool appends 32 leaves a round: **block level 5, 27 upper levels**.
Production appends 512: **block level 9, 23 upper levels**.

### Folding and checking are two verbs

The spec asks for two things that look contradictory: a round must cost 32
bytes, and a fold must be checked against a commitment root the wallet proved
off the chain. A commitment root is another 32 bytes, so doing both every round
costs 64.

They are not contradictory, because a wrong block root anywhere in a run makes
the root at the *end* of the run wrong too. So `PoolView.fold` takes the
`cmRoot` as optional and the view carries two numbers, `round` and `checkedTo`:
folding a thousand roots from a stranger and checking once at the end is
sound, and is what a wallet catching up actually does. What a wallet may not do
is build a spend on an unchecked fold, and that is enforced where it belongs —
`spendPath` refuses while `checkedTo != round`, naming both.

### What a note keeps, and why a checkpoint cannot replace it

A path splits at the block level. The **lower** siblings are the note's company
inside the block its own round appended; they were fixed when that round was
mined and are never recomputed. The **upper** siblings follow the pool, and at
most one of them moves a round.

A `Checkpoint` — the round, its block root, and the complete left subtrees above
the block level — is everything a follower needs to fold *forward*. It is at
most 23 nodes, **736 bytes**, whatever the pool's age, and it is accepted with
no signature and no trust: the frontier is taken only if the root it computes is
the `cmRoot` of a round the wallet proved off the chain, and a frontier of some
other tree reaches some other root.

What it cannot do is bring an existing note's path up to date, because a note's
upper siblings are made of the block roots appended since its round and a
frontier does not contain them. So `restoreTo` does not silently drop the notes
and does not silently update them: it **freezes** them where they stood, and
`spendPath` refuses a frozen note naming the first round that was never folded
into it. That is the difference between the pool's two kinds of wallet — one
holding no note rejoins for 736 bytes and a head proof, one holding a note pays
32 bytes a round for as long as it holds it.

### A verified path is a frontier

This fell out of the shape rather than being designed in, and it is what makes
"a wallet with no money may stop following" workable. A note's path already
contains a checkpoint: its lower siblings and its leaf give its block's root,
and its upper siblings at the levels where the block index has a bit set are
exactly the complete left subtrees `BlockFold.at` wants. So a view that stopped
at round 4 and is handed one verified path for a note from round 9 resumes at
round 9 for nothing — `PoolView.resume` — and never reads rounds 5 to 8.

The same machinery brings a path that arrives a few rounds late forward:
`track` rebuilds a detached frontier from the note's own path, replays the block
roots the view retained, and takes the result only if it lands on the view's own
root. The view keeps the last `PoolHeader.ringEntries` (4) block roots for this,
128 bytes, and that bound is not arbitrary — a path more than four rounds stale
is unspendable anyway, because its root has left the pool's ring.

### Ring accounting

`roundsLeft` is `ringEntries − (tip − currentAt)`: four when the view is current
with the tip, and `spendPath` refuses at zero or less, naming how far behind the
view is *and* which rounds it needs. Being behind is a reason to catch up, never
a reason to build a proof the pool will refuse.

### Measured (Apple M3 Pro, `dart test` and `tool/scratch/view_cost_probe.dart`)

At production shape: 512 leaves a round, 1,000 rounds, folded against a tree of
512,000 leaves built directly from its leaves and compared path for path.

| | |
|---|---|
| catch up 1,000 rounds holding 8 notes | **189 ms** (bound 2 s), 189 µs a round |
| the same holding 0 / 1 / 100 notes | 203 / 189 / 201 ms — the note count does not move it |
| the feed for those 1,000 rounds | 32,000 B |
| stored state, 100 notes | **106,988 B** (bound 200 KB), 1,069 B a note |
| reopening it | 2.1 ms |
| checkpoint at round 1,000 | 8 nodes, 295 B on the wire (worst case 23 nodes, 775 B) |
| joining from it | 0.26 ms |
| 10,000 mutated roots, paths and positions | 3,245 `cmRoot`, 4,019 `path`, 2,647 `position`, 89 `blockRoot`, **0 accepted, 0 unnamed errors** |

Two of those numbers are the requirement rather than a footnote. The first is
that 0 / 1 / 8 / 100 notes all cost the same: a round is 23 hashes up the upper
tree plus, for each note, at most one sibling copied — so the cost is the levels
above the block and not the size of the tree or the size of the wallet. The
second is the 0 accepted out of 10,000 mutations. Unlike an address, where a
flipped byte inside a KEM key is a well-formed address for a key nobody holds,
every input here is checked against a root: a bent block root does not fold to
the round's `cmRoot`, and a bent path or position does not reach the view's. A
mutation has nowhere to hide.

### The test's own tree

`_RefUpper` in `test/pool_view_test.dart` is the upper tree written out the long
way — every node kept, nothing pruned, no tracked paths — so the 1,000 rounds of
commitment roots the fold is checked against are not the fold's own opinion. It
is anchored twice: its root after 1,000 blocks equals the root of the tree built
straight from 512,000 leaves, and the fixture's rounds are checked against the
`cmRoot`s a `ShieldedLedger` rebuilt from the mined round transactions.

### Half-verified, and owed

"Born at a round" from group 3 is now whole on this side: a view opened at a
checkpoint starts there and refuses to yield a path for a note from a round it
never folded. "The source is unavailable" is still owed its second half — the
wallet's *stored* state unchanged across a failed read — which needs the note
store in group 6, now that the view's own half (a refused fold and a refused
open both leave the file whole) is verified here.

### Left for later

The state file is written owner-only and holds no key and no seed. What it does
say is *which* commitments are this wallet's, and that link is the thing worth
protecting; encrypting it belongs with the note store in group 6, where the
memos and the viewing keys live, rather than half here.

## 5. Notes: the wallet's own bookkeeping (2026-09-23)

Nothing in the note store was found by looking. Every note in it arrived with a
payment proof that checked out, or was the wallet's own change out of a round it
had already seen. There is no third way in, and that is enforced by the type
rather than by a rule: `NoteStore.take` accepts a `CheckedPayment`, whose
constructor is private to `checker.dart`, so an unchecked proof has nothing to
hand over.

### The three states, and the one that looks backwards

**Proven**, **reserved**, **spent**. A note is reserved when a submission
spending it is accepted, and reserved before anything expensive happens — which
is what stops two payments being built against one note. The second attempt is
refused naming the leaf and the state, and no proof is computed.

Reserved back to proven is the only move that looks like going backwards and it
is not: it means the pool refused the submission, so the note was never spent.
Spent is final, because what made it spent is a nullifier in a mined round and
no wallet gets a vote on that.

The fixture puts a note through all three without anything being staged. Its
round 1 pays the wallet 500 at leaf 0; round 2 inserts exactly that note's
nullifier and pays 200 back at leaf 32. So `settle` is tested against the real
round's own insertions.

### Nullifiers are computed and dropped

The store records value, `rho`, `rcm`, asset, diversifier, leaf and round — and
**not** the nullifier. `nk` is an argument to `settle`, never a field, so the
store computes `H(nk, rho)`, compares it against what a round inserted, and
keeps neither the key nor the answer. A store that cached nullifiers would be a
file that hands whoever reads it the wallet's spending history in advance.

The test does not take this on trust: it saves the store, reads the file back,
and searches the bytes for the note's nullifier in every shape it could have
been written in, lane by lane, and for `nk` itself.

That rule has a price, and it is written down below: recognising spends costs
one hash per held note per round seen.

### Three lines, never one number

A single total is a lie of omission. The two things that stop a payment being
made are money already in flight and money whose path the view can no longer
anchor, and a total hides both behind a number that looks spendable. So the
balance is **spendable**, **reserved** and **stale**, and stale carries how far
behind the view is — which turns "you cannot pay" into "fold some block roots",
a thing the wallet can do by itself for 32 bytes a round.

Spendable is not a property of the store. A proven note counts as spendable only
when the pool view will actually yield a spend path for it at the pool's tip, so
the balance asks the view about every note, and `PoolView.canSpend` exists for
exactly that question — the same conditions as `spendPath` with no sentence
built for the failing case.

Lines are never added across assets either. A hundred of one and a hundred of
another is not two hundred of anything.

### Choosing one note, and why the refusal names the largest

The rule is **the smallest spendable note that covers the amount, lowest leaf
among equals**: stated so a person can predict it, deterministic so the same
wallet asked twice does not reserve a second note, smallest-that-covers so large
notes stay whole for the payments they are for.

There is no gathering. A TSL1_SP transfer has two inputs and two outputs and a
payment needs one of each pair for its change, so a payment is one note or it is
nothing. That is why the refusal names the **largest spendable value** and never
the total: the total is the wrong number to show somebody who cannot pay,
because it is not what they can pay. A wallet whose money is in pieces too small
consolidates with a payment to itself, which is a payment like any other rather
than a rule hidden inside selection.

### A round number in a proof is a claim

A standing proof's round number carries no weight in the payment check, so the
store checks it: leaf `p` is in round `(p >> blockLevel) + 1` and a note recorded
under any other round is one the view will never be able to anchor. Same check as
`TrackedNote`, same reason.

### Measured (Apple M3 Pro, `dart test`)

| | |
|---|---|
| 10,000 notes, stored | **730,010 B** (bound 4 MB), 73 B a note |
| a balance over them | **2.1 ms** (bound 10 ms) |
| encoding them | 10 ms |
| `settle` over them | 94 ms — one Poseidon2 hash a note |

The balance started at **7.1 ms**, which passed the bound and was still wrong:
it built a refusal sentence for each of nine thousand stale notes that nobody
reads, and made a 32-character key out of each note's asset to group by. Naming
the reason once and dealing notes into assets by comparing four lanes took it to
2.1 ms. `PoolView.spendPath` also checked membership by scanning its own list,
which is quadratic in the notes a view keeps; it uses the leaf index now.

The 94 ms is the price of the nullifier rule, and it is paid once per round the
wallet sees, by a wallet holding ten thousand notes. Caching them in memory for
a session would remove it and would not break the rule — what the rule forbids
is writing them down and sending them — but it is not built, because no measured
wallet needs it.

### Left open, and it is a decision not an oversight

**The store file is not encrypted.** It holds each note's `rho` and `rcm`, which
are the note's own secrets: `rho` plus `nk` gives the nullifier, and the full
opening plus `pk_d` reproduces the commitment. It is written owner-only, the
same as the wallet file, but the wallet file is sealed and this is not.

That is what the spec asks for. `note-store` requires that two stores which took
the same notes in the same order hold **byte-identical** bytes, and a sealed
file with a fresh nonce does not; the proposal scopes "encrypted at rest" to
`wallet-keys`, which is the seed. Both can be true at once — seal it under a key
derived from the seed with a synthetic nonce (the nonce a PRF of the plaintext,
as AES-SIV does it), which keeps identical stores identical and leaks only that
two files hold the same notes — but that is a change to the capability and not
something to slip into an apply. `NoteStore.encode` and `decode` are public and
deterministic, so a host that wants its own at-rest story already has the bytes.

## 6. Invoices: asking for money (2026-09-23)

An invoice is the first half of "payment in consideration of something": a fresh
address, an amount, an expiry, an id and what it is for. A payee writes one
without looking anything up — it names the pool by its tokenId and carries
nothing else about it.

### What signs an invoice, and what that proves

The spec asks for a signature "under the key the address was issued from",
checked by the payer "against the address's own key". An address carries a
diversifier, `pk_d = H(ivk, d)` and a KEM public key, and none of those is a
signing key: a hash has no private counterpart and a KEM is not a signature
scheme.

So the signing key is derived the same way the address is — `Ed25519` from
`SHA256("tsl1-libcloak/invoice/1" ‖ ivk ‖ d)` — and its public half travels in
the invoice. One address, one key, derived and never stored. A wallet that can
issue the address can sign for it and a wallet that cannot, cannot.

Per address and not per wallet, deliberately. A wallet-wide key would let a
payer, or anybody who saw two invoices, tie them to one payee — the exact thing a
fresh address per invoice exists to prevent.

**What that buys, stated plainly.** The signature covers every other field, so a
substituted address, a changed amount or an altered expiry is caught: the
scenario the spec names is exactly this, and it is verified for the address, the
amount and the tokenId. What it does **not** buy is protection from a man in the
middle who replaces the whole invoice — address, key and signature together —
because the key is as new as the address and a payer has never seen it before.
No self-contained message can do better; binding an invoice to a person needs
that person's key from somewhere else. For libcloak that is the point rather
than a gap: people pay people, and the invoice is handed over inside a
conversation that already establishes who is who. A host that wants more can pin
a payee's key across invoices, but it cannot be done here, because per-address
keys are what keeps two invoices from the same payee unlinkable.

### The check order is the contract

`Invoice.read` runs, stopping at the first failure: the encoding and its bounds,
then the pool, then the expiry, then the signature. Cheapest and most decisive
first — the first three are comparisons on fields and the fourth is the first
thing that costs a key operation. The spend proof, which costs seconds, is
behind all four.

The test does not take the order on trust. An invoice that is both expired and
unsigned is refused for being **expired**, which is what shows the expiry gate
stands in front of the key work.

### An expiry is a UTC instant

Round-tripping an invoice through its own codec changed the expiry field, and
that was a real bug rather than a test being fussy:
`DateTime.fromMillisecondsSinceEpoch` returns a **local** time, and Dart's
`DateTime ==` compares the zone flag as well as the instant. Two people in
different places would have held different values for the same field. The
expiry is normalised to UTC on construction, so the field a payee wrote is the
field a payer reads whichever zones they are in.

### Measured (Apple M3 Pro, `dart test`)

| | |
|---|---|
| invoice with a 256-byte memo, hybrid KEM | **1,687 B** (bound 2 KB) |
| the same with the memo full (512 B) | 1,943 B |
| of which the address | 1,261 B |
| 10,000 mutated and truncated invoices | 7,823 parsed, of those **1** still verified — a flip that flipped back — and 7,440 refused at the signature; 2,177 refused at the encoding; **0 unnamed errors** |

That 7,823 looks alarming and is the same fact group 3 recorded about addresses:
three quarters of an invoice is the 1,216-byte ML-KEM public key, and a flipped
bit inside one is a well-formed key nobody holds. Parsing is not the defence and
was never meant to be. The signature is, and it caught every one of them.

### Owed

The spec's other half of the expiry rule — a payee refusing to acknowledge a
payment against an invoice that had expired when the transfer was submitted —
needs the acknowledgement, and lands with payments in group 8.

## 7. Payments: the thing the library is for (2026-09-23)

A payer builds a transfer against an invoice it checked and a path its own view
vouches for. A payee checks the proof against headers its own source vouches for
and acknowledges. Neither side asks anybody a question that names a note, an
address or a wallet, and neither side has to believe anyone.

Two payments are under test, and they are different payments on purpose. One
libcloak builds itself — a real spend proof against the fixture's round-1 note —
which is what the **build** path is tested on. One the fixture already mined —
round 2 pays the wallet 200 at leaf 32 — which is what the **check** path is
tested on, because checking needs a round a chain really carried.

### The build order is the contract, because a STARK is behind it

`PaymentBuilder.build` stops at the first failure: the invoice (its pool, its
expiry, its signature), the note (held here, not already in flight, covers the
amount), the path (the view will yield one at the pool's tip — where "too far
behind" is caught), and the anchor (the path really reaches the root the view
holds). Only then are the notes made, the bundle sealed and the proof proved.

The test does not take that on trust either: an invoice that asks for more than
the note holds, an expired invoice and a view eight rounds behind all come back
in under 100 ms, against the 118 ms the proof itself costs.

**The note is not reserved by the builder.** Reserving is what an *accepted*
submission does, because until a coordinator has taken the transfer nothing has
been spent. A note already reserved or spent is refused at step 2 instead.

### The step that cannot fail on its own

The spec asks that a proof for somebody else's note fail "at the commitment
step, naming it". There is no such step to name, and this is worth writing down
rather than faking.

An opening carries no commitment. The commitment is **computed** from the
opening and the payee's own `pk_d`, so the only thing that can then fail is the
walk to the round's root — and under another key the commitment is a different
value, so the walk lands somewhere else. The refusal says exactly that, naming
the position, the root the path reached and the round's own root, which is the
answer a person can act on. The step that *can* fail by itself is an opening
that is not a note at all, and tstokenlib does name that one `commitment`.

The clause in that scenario which carries the weight is its second one, and it
holds: the witness being mined and the round being this pool's are **not**
reported as proof of anything when the note is not the payee's. Nothing is
reported paid, the note is not taken into the store, and the store and the view
are byte-identical afterwards.

### An acknowledgement is checked against the invoice alone

The payee signs the invoice id, the round and the value under the key that
invoice was issued from; the payer verifies with the public half the invoice
already carries. So the payer ends up holding evidence, from the only person who
could have produced it, that the consideration was delivered against a payment
the payee itself checked.

This is also where the invoices spec's other half lands: a payee will not
acknowledge a payment against an invoice that had already expired when the round
was mined. The clock it uses is the **block's own timestamp**, read off the
header the payee proved for itself — the only clock in the exchange that the
payer did not supply. It is approximate, and it is unforgeable by the payer, and
those are the two properties that matter. A payee refusing here is not refusing
the money; it is refusing to sign that the money arrived in time, which is a
different statement.

### Measured (Apple M3 Pro, `dart test`, test parameters)

| | |
|---|---|
| the wallet's own build work | **8 ms** (bound 200 ms) |
| the spend proof beside it | 118 ms |
| the transfer that comes out | 14,812 B |
| a standing payment proof | **793,304 B** (bound 1 MB) — round 141,070, witness 651,059 |
| checking one | **63.7 ms** (bound 100 ms; best of 7, 176 ms worst under a loaded suite) |
| a short payment proof | **1,098 B** (bound 4 KB) |
| an acknowledgement | 94 B |

Two of those are the argument of the whole capability. The first is 8 ms against
118: everything libcloak does for a payment is cheap, and the only expensive
thing is a STARK that the pool's own parameters fix. The second is 1,098 bytes
against 793,304 — a factor of **722** — which is what a payee buys by following
the pool for 32 bytes a round, and it is the same proof: the payee applies the
same commitment and path checks, against a root its own fold produced rather
than one inside the message.

The 63.7 ms is the best of seven readings, and it is reported that way for a
reason: the bound is *per core*, `dart test` runs files beside each other, and a
single wall-clock reading under a loaded suite measured 176 ms — the machine,
not the check. Interference can only make a reading longer, so the minimum is
the honest estimate of one core's cost. This was the one measurement in the
library with less than 2x of headroom, which is why it was the one that noticed.

The check is parsing and hashing and nothing else. No STARK is verified, because
the round was mined, which means the chain already ran the pool's verifier over
it; almost all of the 793 KB is the PP1 unlock's proof, which the payee hashes
once for the txid and never reads.

### What the short form must never carry

Its own commitment root. A short proof with 32 bytes appended is refused at the
`cmRoot` field as malformed, rather than that root being used — because a root
that arrived inside a proof is evidence of nothing, and it is the one thing the
short form has no evidence for. A payee that has not folded the round refuses
naming both rounds, and the payer then sends the standing form; that is a
fallback, not a failed payment, and the test runs the whole exchange.

### Already verified elsewhere

The spec's "Mutated payment proofs" — 10,000 mutated and truncated proofs, every
one refused with a named reason and none reported paid — is the mutation run in
`test/lineage_attack_test.dart` from group 2 (5,604 refused at the encoding,
4,396 decoded and then refused, **0 still paid**). "A round with a forged
lineage" is the localnet attack in the same file: a lookalike PP1 mined on a real
regtest node and still refused at `PP1 is this pool's script`.

### Owed

Submitting — "Each of the twelve refusals" and "Accepted and awaiting" — needs
the coordinator client, and is task 9.2 by the plan's own reckoning.

## 8. The coordinator client (2026-09-23)

The wallet's side of tstokenlib's wallet-to-coordinator protocol, over a
transport the host supplies. `lib/src/net/coordinator_client.dart`, and one
addition to `lib/src/pay/checker.dart` that the spec needed and nothing had
built yet.

### Folding and checking, once more

`CoordinatorClient.follow` hands each announcement's block root to the view
**unchecked**. An announcement is a claim: it arrives on a feed anyone can
write, it carries no proof, and a client that let one set `PoolView.checkedTo`
would have turned the pool into an authority in the one place the library says
it is not. The number that makes a fold evidence comes from `headProof`, and
from nowhere else.

That leaves a wallet folding arithmetic it cannot yet spend from, which is
exactly what `round` and `checkedTo` are two numbers for. The sequence a
spending wallet runs is: `follow` to stay current, `bringForward` (or one
`headProof` plus `PoolView.check`) before building a payment.

### The head proof

A head proof is a standing payment proof with the note taken out —
`PaymentChecker.head` runs steps 2 to 4 of the payment check and stops. Both
paths now share `_provenRound`, so there is one implementation of "this witness
is in a block I accept, and it spends a round that is really this pool's".

Its round number is **not** the number the reply states. It is the pool
header's own `size` divided by the descriptor's `leavesPerRound`, and the
reply's claim is then compared with it. A pool that says "this is round 900"
over a header holding two rounds of leaves is refused at the step named `head`,
naming both numbers. This matters because the round number is what a frontier
is matched against, and a frontier is only evidence against the root of the
round it stands at.

### An announcement's two claims have to agree with each other

An announcement carries both a block root and the round's pool header, which
carries that round's commitment root. Those are two claims by the same party
and they are checkable against each other for free: the block root has to fold
to the commitment root the same message states.

The client does that on a **probe** — a detached `UpperFrontier` standing where
the view stands, built from `view.checkpoint` — so a contradiction is caught
with nothing folded rather than reported after the fact. It is not a trust
check and it is not a substitute for one; it catches a coordinator contradicting
itself, which is the only lie a following wallet can catch without proving
anything off the chain. Measured cost: **1,371 us for two rounds, 686 us a
round**, against 204 us a round for the fold alone — a second fold, plus
rebuilding the probe's frontier from the view's checkpoint each round. That is
the price of catching a contradiction with nothing folded rather than after the
fact, and at 686 us a round a year of a pool closing a round every ten minutes
is 36 seconds of arithmetic.

The premise was measured rather than assumed: the fixture's `round1.header
.cmRoot == cm1` and `round2.header.cmRoot == cm2`, asserted in the suite, so a
check that refuses a mismatch cannot be refusing honest announcements.

### A note moves with the answer, and the rule is one sentence

Five outcomes, and one rule: **a note is released only where the wallet knows
the transfer is not in a round.**

| outcome | what it means | the note |
| --- | --- | --- |
| `accepted` | taken, for the round it named | reserved |
| `refused` | one of the protocol's twelve reasons | released |
| `expired` | it sat in the inbox too long | released |
| `unanswered` | no answer this client could attribute to it | **reserved** |
| `unsent` | every send attempt failed | released |

The note is reserved *before* the frame leaves the machine, so the window in
which a second payment could pick the same note closes before anything is sent.
A timeout, and a reply the client could not attribute, both leave it reserved:
the submission may be in a round, and releasing a note on a maybe is how a
wallet double-spends itself.

A refusal's `Refusal.step` is the protocol's own `RefusalReason` name —
`anchor`, `nullifierSpent`, `proof` and the other nine — so a journal records
the twelve reasons under the names the protocol defines rather than under twelve
sentences of this library's invention.

### Replies are matched by id, not by which call got the bytes

The client keeps a table of submissions in flight and routes every reply
through it. A call that is handed another submission's reply completes that
one and goes on waiting for its own; a reply for an id nobody is waiting for is
refused naming the id, and no payment changes state. Two submissions whose
replies cross therefore each get their own, which is what the suite does: the
fake transport hands each call the *other* one's reply and both still come back
right.

A resend after a failed send is the **same bytes and the same id**, so a
coordinator that took the first copy can tell it is the same submission rather
than a second spend.

### Nothing the client sends says anything about the wallet

There is no method on this class that takes an address, a note, a leaf position
or a txid, so there is no way to use it to look one up. Two things go out and
that is all: a submission the wallet built, and a catch-up request.

A block-root request names an **aligned run of `catchUpRange` rounds from round
1** — the run the wanted round falls in — never the round the wallet wants.
"Everything since round 4,117" would say when this wallet was last current, and
over a few catch-ups that is a fingerprint. The suite asserts
`PoolDescriptor.publishesRange` for every range sent across a full catch-up,
and separately walks rounds 1 to 8 against a pool with `catchUpRange = 2` to
show the quantisation is real: rounds 1 and 2 both ask from 1, rounds 3 and 4
both ask from 3, and so on.

It also greps every frame sent for the note's commitment, the wallet's
diversifier, the change address's `pk_d` and both fixture txids, and finds none
of them.

### Measured (Apple M3 Pro, test parameters)

| | |
| --- | --- |
| follow, 2 rounds | 1,371 us — 686 us a round, including the contradiction probe |
| catch up with no state | one head proof and one frontier, 2 requests |
| catch up holding a note at round 1 | one head proof and one block-root run, 2 requests |
| 10,000 random and mutated frames | 9,433 refused, 567 taken, 0 unnamed |
| 2,000 random and mutated replies | 0 unnamed |

The 567 is not a hole and is asserted as such. A bend that lands in a field
this client never acts on — the three txids, the nullifier root, the balance,
the out hash — leaves a perfectly valid announcement, and the two fields it
does act on have to agree with each other before anything moves. So the claim
the suite makes is not "nothing got through" but **nothing was folded that was
not round 1's own block root**: every one of the 567 left the view at round 1
with round 1's real commitment root.

Twenty-one distinct refusal steps were named across the 10,000.

### What this does not do

- **The client never fetches a transaction by txid.** An announcement's three
  txids are carried and not used, which is why a bent one is not caught. The
  round bytes a head proof needs come with the head proof and are checked in
  full.
- **`Disagreement` is reported, not resolved.** The honest recovery from a pool
  telling two stories is for the host to decide, and it is not a decision a
  library should make silently.
- **The journal is group 10.** A refusal's reason is on the outcome, ready to
  be written down; nothing writes it yet.

## 9. The journal (2026-09-23)

The wallet's record of what it promised, paid, proved and acknowledged.
`lib/src/journal/entry.dart` and `lib/src/journal/journal.dart`.

### One file per entry, and no index

The spec's shape is fixed by one sentence — "each entry written to a temporary
name and renamed, so an entry is either whole or absent" — which is a statement
about a file per entry. A crash half way through a write leaves a `.tmp` beside
the journal and no entry, which is the honest outcome, and the reader treats a
leftover `.tmp` as the "absent" half rather than as a fault.

design.md sketched an index file beside the entries so the 10,000-entry read
would fit its 1 s bound. **Measured, it is not needed.** Reading 10,000 entry
files one at a time is 658 ms; in batches of eight it is 224 ms, because the
cost is syscall latency and not bandwidth. Past eight it gets worse again
(32 -> 283 ms, 128 -> 433 ms, 512 -> 494 ms). So the journal reads in batches of
eight and keeps no index, which leaves nothing to go stale: a journal small
enough to read whole is a journal that cannot disagree with itself.

The names carry the sequence, zero-padded to nine digits, so a directory
listing sorts into the order the entries happened. The **directory** is made
owner-only; the entry files are not chmodded one by one, because that is a
process spawn per entry and a directory nobody else can traverse is the same
protection at 1/10,000th the cost.

### Nine kinds and one shape

A payment has six moments — the invoice, the build, the submission, the reply,
the proof and the acknowledgement — and three of those have two sides. "I
issued this invoice" and "I was handed this invoice" are different facts about
the same bytes, so they are different kinds; that is nine.

Every kind writes into the same fields: a sequence, a time, the invoice id, an
optional `corrects`, an amount, a round, an optional leaf position, three short
strings and a public reference. One shape rather than nine is what lets a
journal be counted — how many refusals, of which reason, against which invoice
— without nine parsers.

Two details that are not arbitrary:

- **`position` is nullable, not zero-when-absent.** Leaf zero is a real leaf,
  and the fixture's first note is in it.
- **`reason` is a field, not a phrase inside the sentence.** A coordinator's
  refusal records the protocol's own `RefusalReason` name — `anchor`,
  `nullifierSpent`, `proof` — so the twelve can be counted rather than
  grepped. The suite drives all twelve through a real `CoordinatorClient`
  against a fake coordinator and checks each lands under its own name.

### Secrets stay out by construction

There is no field an entry could hold a key in, and the constructors take the
whole object — a `BuiltPayment`, a `PaymentProof`, an `Acknowledgement` — and
write a handful of numbers out of it. So a caller cannot put a secret in by
mistake either, which is a stronger property than a rule about what callers
should pass.

The suite writes a full end-to-end payment's journal and searches every byte of
it for ten secrets: both wallets' `sk`, `ivk`, `ovk` and `nk`, the spent note's
`rho` and `rcm`, the paid note's, the change note's, and a seeded wallet's
seed. None of them is there. Values, leaf positions and invoice contents are,
and are meant to be: they are the wallet's own business and the note store
already holds them.

### A correction is a new entry

`JournalEntry.correcting(earlier)` sets `corrects` to the earlier entry's
sequence. Nothing is rewritten and nothing is deleted, so what was believed at
the time survives beside what replaced it — the suite checks a proof recorded
**refused** because the wallet had no headers that far back, then recorded
**paid** once it did, and then re-reads the first entry off the disk to show it
still says refused.

A sequence with no file at all is reported as `missing`: the journal never
deletes an entry, so if one is gone somebody outside took it, and a record of
what you paid must not quietly lose a line.

### Measured (Apple M3 Pro, test parameters)

| | |
| --- | --- |
| an entry | 142 bytes |
| 10,000 entries written, temp-then-rename with flush | 1,814 ms (182 us each) |
| 10,000 entries read, quiet machine | **286 ms**, best of 15 (worst 334), against a 1 s bound |
| the same inside the full parallel suite | 482 ms best of 15, worst 1,858 |
| the same read, one file at a time (probe) | 658 ms |
| 1,000 mutated entries | 221 read, 779 refused, **0 unnamed**, 17 distinct steps |

### What this does not do

- **The journal is not tamper-evident, on purpose.** The spec's threat model is
  a file that "may have been edited", and the answer to that is to refuse what
  does not parse, not to authenticate what does. 221 of the 1,000 mutations
  still read, and they should: a bend in an amount or in the sentence produces
  a perfectly well-formed entry. A checksum would not change this — an
  unkeyed one is recomputable by whoever edited the file, and a keyed one puts
  a key in reach of the one part of the wallet that is supposed to hold none.
  A host that needs tamper-evidence signs the directory from outside.
- **Nothing writes entries for you.** The journal records what it is handed.
  Wiring it into the payment path is group 11's business, not a side effect
  buried in `PaymentBuilder`.

## 10. End to end (2026-09-23)

Two runs of the same flow. `test/end_to_end_test.dart` against a fake pool, in
seconds, in every suite. `test/localnet_e2e_test.dart` against a pool issued on
localnet and a real `../pool-coordinator` over ricochet, in about 70 seconds,
asked for on its own.

### The seam the second one closes

The in-suite run has one: the transfer libcloak builds is **not** in the round
that gets mined, because assembling a round means proving an aggregation and
that is the coordinator's job. So there the proof handed to the payee is of the
note the fixture's round 2 really holds at the invoice's address.

On localnet there is no seam. A pool is issued from nothing, a coordinator runs
it, libcloak's own transfer goes into round 2 with three padding transfers
around it, the round is mined, and `PaymentProofs.positionOf` finds the payer's
own commitment in it at leaf 32. The proof the payee checks comes out of the
round the coordinator built.

That is also the strongest statement this change can make about the two
libraries agreeing: the wallet's `PoolDescriptor`, its block-root fold, its
`PoolSubmission` and its `PaymentProof` were all read and written by code in
the other repo, and every check passed against a chain neither of them wrote.

### Measured (Apple M3 Pro, test parameters, regtest localnet)

| | in the suite | on localnet |
| --- | --- | --- |
| issue a pool from nothing | — | 8,362 ms |
| round 1, four transfers, submitted to announced | — | 10,122 ms |
| build a payment (a spend proof) | 284 ms | 52 ms |
| submit and be answered | 13 ms | 325 ms |
| round 2, one real transfer and three padding, submitted to announced | — | 29,302 ms |
| the standing proof | 793,304 B | 793,300 B |
| the payee's check | 71 ms | 87 ms |
| the acknowledgement | 94 B | 94 B |
| the whole run, invoice to acknowledgement | 602 ms | — |

Round 2's 29 s is 20 s of the coordinator's configured round deadline — the
round waits for transfers that never come and then pads — plus about 9 s of
proving and mining. It is a measurement of the coordinator's settings, not of
the wallet.

The payment proof is 793 KB because it carries the round transaction and the
witness whole, and the witness carries the pool's STARK. That is the price of a
proof that needs nothing looked up. The short form, for a payee that follows
the pool, is 1,098 bytes — a factor of 722 — and is measured in section 7.

### What is unmeasured

- **Production parameters.** The pool this runs on is the four-transfer test
  plan. A production round is 256 transfers and its witness is megabytes;
  ARC's scriptSig limit of 1,636,802 bytes is where a production witness
  stalls, so it cannot go on testnet and has not been run end to end here. The
  numbers above do not extrapolate: the spend proof is the same size at both
  (the wallet proves one transfer either way), but the round transaction and
  therefore the standing proof are not.
- **A pool with real traffic.** Round 2 closed on its deadline with three
  padding transfers. A busy pool closes on capacity and pays no padding, which
  is faster per transfer and cheaper per round, and is not measured.
- **The transport under loss.** Ricochet ran on one machine over loopback.

### The suite is two commands

The localnet run stands up a ricochet server, a coordinator and a
one-per-second miner, and proves two rounds. In the same pack as the rest it
triples the wall clock of every measured bound in the suite, and those are
bounds on one core: the journal's 10,000-entry read went from 271 ms to
1,108 ms and failed its own 1 s bound, which is a fact about the machine and
not about the journal. So it is asked for rather than swept up:

```
dart test                                         the suite
POOL_LOCALNET=1 dart test                         with the localnet attack
POOL_LOCALNET=1 POOL_E2E=1 dart test test/localnet_e2e_test.dart
```

Bounds that are read off a loaded machine now take the best of several
readings, because interference can only make a reading longer: the payee's
check (best of 7), the note store's balance (best of 7) and the journal's read
(best of 15). Each prints the worst beside the best, and the note store prints
its first reading separately — 3.2 ms cold against 0.3 ms warm — because the
cold one is what a wallet pays when it opens.

The journal's fifteen is not five because the readings are contended by **the
test's own writeback**: it has just written ten thousand fsynced files, which
takes 1.8 s alone and 13 s inside the suite, and the first readings queue behind
that. Five readings stay inside the storm and the test failed about one run in
three; fifteen outlast it, and three consecutive suite runs measured 482, 474
and 495 ms against the 1 s bound.

### What the coordinator does not do yet

`../pool-coordinator` implements protocol version 2's descriptor, submission,
reply and announcement, and **not** its three catch-up messages: its inbox
refuses anything that is not a submission. So `CoordinatorClient.headProof`,
`frontier` and `blockRootsFor` are verified against a fake pool and not against
the real one, and the localnet run reaches the coordinator's tip by folding the
feed's announcements and checking the fold against a payment proof it was
handed rather than against a head proof it asked for.

That is not a hole in the wallet — checking a fold against a proof somebody
handed you is the "people pay people" path, and is stronger than asking a
server — but it is work owed in the coordinator repo before a wallet with no
state can join a running pool without reading its whole feed.

## 11. The library, as built (2026-09-24)

Sections 1 to 10 are the record of building each piece. This one is the whole
of it in one place, for a reader who has not read them.

### Two ports, and nothing else touches the world

libcloak is headless: no daemon, no sockets, no UI, no database. It reaches
outside itself through two interfaces the host implements.

| port | what it answers | what it cannot be asked |
|---|---|---|
| `HeaderSource` | the chain tip; the height of a block hash, or null when it is not on the accepted chain; the 80-byte header at a height | anything naming an address, an outpoint or a wallet-derived txid — there is no method |
| `Transport` | send a frame and get a reply; read the pool's feed from a sequence number | the same — a frame is opaque bytes, and what goes in them is a transfer the wallet built or a question from a published set |

The narrowness *is* the privacy property. A port with no method that takes an
address cannot leak one, and that is a stronger statement than a rule about how
callers should use it. The suite asserts it twice: `test/fakes_test.dart`
checks the declared surface, and the end-to-end runs grep every frame sent for
the note's commitment, the wallet's diversifier, the change address's key and
both fixture txids.

### How a note stays spendable: 32 bytes a round

The pool's commitment tree is depth 32. A round appends a fixed **power of two**
block of leaves — 512 at production, 32 at test — so round N owns exactly the
aligned node at level `log2(block)`, index `N - 1`. That splits a note's 32
siblings in two:

| | production | test | |
|---|---|---|---|
| below the block level | 9 | 5 | frozen once the note's own round is mined |
| above it | 23 | 27 | folded forward, one 32-byte block root a round |

So a wallet keeps, per note, its position and its frozen lower siblings; and per
wallet, one upper frontier. Following costs **32 bytes a round whatever it
holds**, against 16,384 if it followed every commitment.

The power of two is not tidiness. At any other count a round's leaves straddle
two subtrees, a round owns no node, and following the pool by one root a round
is not a thing that can be done. `PoolShape.of` refuses a non-power-of-two and
says so.

**The invariant.** Folding is arithmetic; it becomes evidence when the root it
computes equals the `cmRoot` of a round the wallet proved off the chain for
itself. A wrong root, or a skipped round, fails that check. So the 32 bytes can
come from anyone — and a wallet may fold a thousand rounds from a stranger and
check once at the end, because a wrong block root anywhere in a run makes the
root at the end of the run wrong too.

What it may **not** do is spend from an unchecked fold. That is why a
`PoolView` carries two numbers, `round` and `checkedTo`, and why `spendPath`
refuses while they differ.

Three things follow from the same arithmetic and are worth stating because each
looks like a special case and is not:

- **A verified payment path is a frontier.** A note's lower siblings and its
  leaf give its block's root; its upper siblings at the levels where the block
  index has a bit set are exactly the `left` nodes a fold needs. So
  `PoolView.resume` is free, and a path that arrives a few rounds late is
  brought forward by replaying the retained block roots.
- **A checkpoint cannot bring an existing note's path up to date.** A frontier
  says where the tree stands and says nothing about the rounds a particular
  leaf's siblings missed. `restoreTo` therefore **freezes** held notes rather
  than dropping or silently updating them, and `spendPath` refuses a frozen note
  naming the first round that was never folded into it.
- **Nullifiers are computed and dropped.** `nk` is an argument to
  `NoteStore.settle`, never a field. A store that cached nullifiers would hand
  whoever read the file the wallet's spending history.

### A payment, end to end

```
payee                                   payer
  |  Invoice.issue ─── bytes ──────────►  Invoice.read: pool, expiry, signature
  |                                       PoolView: fold, check, spendPath
  |                                       NoteStore.choose: one note
  |                                       PaymentBuilder.build ──► a spend proof
  |                                       CoordinatorClient.submit
  |                                    ◄── accepted into round N; note reserved
  |                                       follow the feed, fold round N
  |  PaymentChecker.check ◄─ proof ────── PaymentProofs.standing/short
  |  NoteStore.take
  |  Acknowledgement.of ─── bytes ─────►  Acknowledgement.check(invoice)
```

Two rules run through it. **People pay people:** the payer hands the payee a
proof and the payee checks it against headers it already holds; nobody scans a
chain, and the library asks no server what it owns. **Nothing is taken on
trust:** every answer a pool gives is checked against something the wallet
proved for itself.

An invoice is signed under an Ed25519 key derived from
`SHA256("tsl1-libcloak/invoice/1" ‖ ivk ‖ d)` — one per address, because one per
wallet would make invoices linkable. It catches a substituted address, a changed
amount and an altered expiry. It does **not** catch a full man-in-the-middle who
replaces the key and the signature too; that is what handing the invoice over a
channel the payer already trusts is for.

An acknowledgement's clock is the **block's own timestamp**, which is the only
clock in the exchange the payer did not supply.

### What a payee checks, in order

The order is the contract, because a refusal names the step and a person acts on
that name.

1. the encoding and its bounds — done when the proof was decoded;
2. the witness is in a block this wallet's own source vouches for, by its merkle
   branch, buried deep enough;
3. the witness spends the round's PP1 and PP2;
4. **the PP1 is a real PP1_SP script** carrying the descriptor's tokenId and
   genesis header, and its pool header parses;
5. the opening commits under the payee's own `pk_d`;
6. the path takes that commitment to the round's commitment root at the stated
   position.

Steps 3 to 6 are tstokenlib's `PoolEvidence`, on purpose: they are rules about
the pool and they belong beside the pool, so the coordinator and the wallet
cannot drift apart.

Step 4 is the one the whole thing turns on. A reader that parses PP1 by fixed
offset sees a forgery's own account of itself: a script with the pool's tokenId
at the right offset over a body that enforces nothing reads as genuine. The
check regenerates the script from the fields it parsed and requires it to be
byte-identical. Section 1 records the attack mined on a real regtest node, and
it is still refused at the step named `PP1 is this pool's script`.

Nothing here verifies a STARK. The round was mined, which means the chain ran
the pool's verifier over it.

### The formats, and what they cost

Every one is versioned, every length is explicit, and an unknown version is
refused naming it rather than guessed at.

| | bytes | bound |
|---|---|---|
| address (hybrid X25519 + ML-KEM-768) | 1,261 | — |
| invoice, 256-byte memo | 1,687 | 2 KB |
| invoice, memo full | 1,943 | 2 KB |
| acknowledgement | 94 | — |
| a transfer | 14,812 | — |
| **standing** payment proof | 793,304 | 1 MB |
| **short** payment proof | 1,098 | 4 KB |
| checkpoint, round 1,000 | 295 (8 nodes) | worst 775 (23 nodes) |
| pool view state, per note | 1,069 | — |
| note store, per note | 73 | — |
| journal entry | 142 | 1,024 |

The factor of **722** between the two proof forms is what a payee buys by
following the pool for 32 bytes a round. It is the same proof: the same
commitment and path checks, against a root the payee's own fold produced rather
than one inside the message. The short form carries **no** commitment root and
must not — that root is the one thing it has no evidence for.

### The six decisions, as settled

| | decision | how it turned out |
|---|---|---|
| D1 | notes stay spendable by following **block roots**, 32 B a round | Built and measured: 1,000 rounds in 189 ms, and the cost does not move with the number of notes held. |
| D2 | the SPV core is **extracted** from libspiffy into a package both depend on | Not done, and not needed here: libcloak depends on `HeaderSource`, and the extraction implements it. Still owed. |
| D3 | message **formats** here, **checks** in tstokenlib | Held. The payee's checks are `PoolEvidence`; the envelope, expiry and signature are libcloak's. |
| D4 | the journal is **files** | Held, and the index the design sketched was measured away: batches of eight read 10,000 entries in 271 ms against a 1 s bound. |
| D5 | transparent scope is **pool-only** | Held. Deposits and withdrawals are `libcloak-onramp`. |
| D6 | the **coordinator delivers** proven rounds to submitters, and puts block roots on the feed | Half: the feed carries block roots and libcloak folds them. Delivery to submitters, and the three catch-up messages, are not built in `../pool-coordinator` yet. |

### Every measurement, groups 4 to 11

Apple M3 Pro, test parameters unless the row says otherwise. A bound in bold is
one the spec sets.

**The pool view** (production shape: 512 leaves a round, 1,000 rounds)

| | |
|---|---|
| catch up 1,000 rounds holding 8 notes | 189 ms (**2 s**), 189 µs a round |
| the same holding 0 / 1 / 100 notes | 203 / 189 / 201 ms |
| the feed for those 1,000 rounds | 32,000 B |
| stored state, 100 notes | 106,988 B (**200 KB**) |
| reopening it | 2.1 ms |
| joining from a checkpoint | 0.26 ms |
| 10,000 mutated roots, paths, positions | 0 accepted, 0 unnamed |

**Notes**

| | |
|---|---|
| 10,000 notes stored | 730,010 B (**4 MB**) |
| a balance over them | 0.3 ms warm, 3.2 ms on the first reading (**10 ms**) |
| encoding them | 10 ms |
| `settle` over them | 94 ms — one Poseidon2 hash a note |

**Invoices**

| | |
|---|---|
| 10,000 mutated invoices | 7,823 parsed, 1 still verified (a flip that flipped back), 7,440 refused at the signature, 0 unnamed |

**Payments**

| | |
|---|---|
| the wallet's own build work | 8 ms (**200 ms**) |
| the spend proof beside it | 118 ms |
| checking a standing proof | 63.7 ms best of 7 (**100 ms**; 176 ms under a loaded suite) |

**The coordinator client**

| | |
|---|---|
| following the feed | 686 µs a round — 204 µs fold, the rest the contradiction probe |
| catch up with no state | 2 requests (a head proof and a frontier) |
| catch up holding a note | 2 requests (a head proof and one published run) |
| 10,000 random and mutated frames | 9,433 refused, 567 taken, **0 unnamed**, 21 distinct steps |
| 2,000 random and mutated replies | 0 unnamed |

The 567 is not a hole. A bend that lands in a field the client never acts on —
the three txids, the nullifier root, the balance, the out hash — leaves a
perfectly valid announcement, and the two fields it does act on must agree with
each other before anything moves. Every one of the 567 folded round 1's real
block root and reached round 1's real `cmRoot`, which is what the suite asserts.

**The journal**

| | |
|---|---|
| 10,000 entries written (temp-then-rename, flushed) | 1,814 ms — 182 µs each |
| 10,000 entries read | 286 ms best of 15 (**1 s**), 482 ms inside the suite |
| the same read one file at a time | 658 ms |
| 1,000 mutated entries | 221 read, 779 refused, **0 unnamed**, 17 steps |

**End to end**

| | in the suite | on localnet, real coordinator |
|---|---|---|
| issue a pool from nothing | — | 8,362 ms |
| round 1, four transfers | — | 10,122 ms |
| build a payment | 284 ms | 52 ms |
| submit and be answered | 13 ms | 325 ms |
| round 2, one real transfer and three padding | — | 29,302 ms |
| the payee's check | 71 ms | 87 ms |
| the whole run, invoice to acknowledgement | 602 ms | — |

### What is owed

- **The three catch-up messages in `../pool-coordinator`.** It runs protocol
  version 2's descriptor, submission, reply and announcement, and its inbox
  refuses anything that is not a submission. Until it answers a head proof, a
  frontier and a run of block roots, a wallet with **no state** cannot join a
  running pool without reading its whole feed. The wallet side is built and
  verified against a fake pool.
- **Delivery of proven rounds to submitters** (D6's other half). A payer today
  learns its transfer landed by reading the feed and then fetching the round;
  the coordinator already holds the reply channel and could hand it over.
- **The SPV extraction** (D2), so `HeaderSource` has an implementation that is
  not a test fake or a node's RPC.
- **`libcloak-onramp`**: deposits, withdrawals, and restore from a seed —
  which is the one place the no-scanning rule does not apply and deserves its
  own thinking rather than being bolted on here.
- **Production parameters end to end.** ARC caps a scriptSig at 1,636,802 bytes
  and a production witness is larger, so it cannot go on testnet. The numbers
  above do not extrapolate: the spend proof is the same size at both, the round
  transaction and therefore the standing proof are not.

## 12. Money in and out: deposits and withdrawals (2026-09-24)

Change `onramp-builders`, for `cloak-cli`'s tasks 0.2 and 0.3. Two builders
beside `PaymentBuilder` in `lib/src/pay/onramp.dart`, two submission methods on
`CoordinatorClient`, four journal kinds. Restore from a seed is still not here.

### What the pool accepts, read rather than assumed

Everything below was read off tstokenlib and `../pool-coordinator` before
anything was built, and the suite then puts both builders' output through
tstokenlib's own `ShieldedCoordinator` intake, opened at the fixture's round 1:
the transfer's own rules, the ring, the nullifiers, the covenant, the balance
and the spend proof. Both are accepted into round 2, and a second transfer
backing the same covenant is refused `depositPending`.

- A deposit is two dummies with a negative `publicOut`. With no real input the
  coordinator checks no anchor (`if (p.real1 || p.real2)`), and
  `../pool-coordinator` adds only that the covenant is mined and unspent before
  the same intake runs.
- The covenant outpoint is **not** in the proof and **not** in `outHash`
  (`SHA256(W ‖ SHA256(bundle))`, with `W` the 28-byte withdrawal record). It rides
  beside the transfer in the encoding only. That is the fact the deposit's
  two-step shape rests on.
- A non-empty bundle must be exactly two note bundles naming `cmOut1` and
  `cmOut2`, so output 2 has to be a real encrypted note. The padding note's zero
  `pk_d` is not an address anyone can encrypt to.

### A deposit is proved first and backed second

`DepositBuilder.prove` checks the request (an amount from 1 to below
`PoolHash.maxValue`, an address the wallet's own `ivk` opens), proves, and
returns a `ProvedDeposit` exposing the 32-byte `commitment` and the note's
`NoteOpening`. The host builds its covenant from that commitment with
`ShieldedPoolTool.createDepositTxn`, and `ProvedDeposit.backedBy(covenantTx)`
checks the covenant and yields a `BuiltDeposit` naming the outpoint. The
covenant needs the commitment, the transfer needs the covenant's outpoint, and
the outpoint is outside the proof, so this order costs one proof and nothing is
redone.

`backedBy` takes the whole transaction rather than an outpoint because the
submission has to carry the transaction anyway, and because only the transaction
can show that the output **is** a covenant locking this commitment and exactly
this amount. A covenant locking 401 against a deposit of 400 is refused naming
both, before anything leaves the machine, rather than by the coordinator as
`depositCovenant` after a round trip. It also refuses a transaction past the
protocol's 4,096-byte bound for a submission's covenant, naming both sizes.

It does **not** check which PP3 the covenant names, its refund key or its refund
height. The host chose the round it deposits into, and the coordinator refuses a
stale PP3 by name (`depositTarget`) and a refund too close (`depositCovenant`).
The mutation run below shows this is real, not theoretical: 13 of the 1,000
mutations changed exactly those terms and still backed the deposit, which is
correct, because the note is what the deposit rests on.

**The anchor is all zeros.** Nothing real is spent, so nothing checks a ring,
and every round's padding transfers are proved against the same zeros. A root
from the view would say when the deposit was built and buy nothing, and the
builder would need a checked view it has no other use for. So it takes none.

**Output 2 is a zero-value note to the same address.** A real note with a real
ciphertext, as the bundle rule requires; the store never takes it on.

**A deposit's shape check** is `DepositBuilder.check(transfer)`: it requires a
covenant outpoint, then surfaces tstokenlib's `refusal()` (and through it
`depositRefusal()`) as a `Refusal` under the field it names. A real note spent
beside a deposit comes back at step `deposit`, "spends a real note beside a
deposit, which the root proof refuses". The suite makes one by attaching an
outpoint to the withdrawal's transfer.

**Learning the leaf** needs nothing new. Once the round carrying the receipt is
mined, `PaymentProofs.positionOf(round, deposit.commitment)` finds the leaf and
`NoteStore.takeChange(opening: deposit.note, position: leaf, round: n)` takes the
note on. The suite runs that flow on the fixture's own mined deposit (leaf 0,
500), since a deposit built in the suite is in no mined round.

### A withdrawal is a payment with the change kept and the rest paid out

`WithdrawalBuilder.build` runs `PaymentBuilder`'s order: the request (a 20-byte
pubkey hash, an amount of at least 1, a change address the wallet's own `ivk`
opens), the note (held here, proven rather than reserved or spent, BSV, and
holding at least the amount), the path, the anchor. Only then the proof, with
`outHash = PoolOutHash.transferLanes(bundleHash, withdrawal: w)` and `w` naming
exactly the amount. Output 1 is the change, output 2 a zero-value note to the
change address.

**The amounts are compared before tstokenlib's check, not after.**
`ShieldedTransfer.refusal()` tests `outHash` first, so a withdrawal record
swapped after proving fails there, "commits to another bundle or another
withdrawal", naming neither amount. `WithdrawalBuilder.check` compares the
record's amount with the public amount first and names both ("the proof takes
300 out and the withdrawal record pays 250"), then defers to tstokenlib for
everything else. The suite asserts both halves: libcloak names both numbers,
and tstokenlib's own check on the same transfer stops at `outHash`.

**Both builders check that the wallet's own note goes to the wallet's own
address** (`pkdFromIvk(ivk, d) == pk_d`, one Poseidon2 hash). `PaymentBuilder`
does not check its change address this way; that is a gap in section 7's builder
that this change did not widen its scope to close.

### Submitting: one path for anything that spends a note

`submit` and the new `submitWithdrawal` now share one private path: reserve
before the frame leaves, send, release only when `isSettled`. The rule a wallet
double-spends itself by breaking is written once, so a payment and a withdrawal
cannot drift apart on it. `submitDeposit` builds the `PoolSubmission` with the
covenant attached and sends it; there is no note to reserve, and what stops one
covenant being backed twice is the coordinator's `depositPending`. `send`'s id
routing and resend of the same bytes under the same id are untouched.

### The journal: four kinds, no new version

`depositBuilt` (10), `depositAnswered` (11), `withdrawalBuilt` (12),
`withdrawalAnswered` (13). An entry's 16-byte thread field is an invoice id, and
neither of these answers an invoice, so they carry
`SHA256("tsl1-libcloak/onramp/1" ‖ bundleHash)[0..16]`. The bundle hash is public
(it is in the round's `outHash` preimage) and unique to the transfer, so the id
is known at build time and says nothing a round does not. The version stays 1:
no field changed, and a reader that predates the kinds refuses one by name. A
deposit's reference is its covenant txid, which is public.

### Measured (Apple M3 Pro, test parameters, `dart test test/onramp_test.dart`, five runs)

| | own work | spend proof |
|---|---|---|
| building a deposit | **4 to 5 ms** (bound 200 ms; cloak-cli's 500 ms) | 37 to 41 ms |
| building a withdrawal | **8 ms** (bound 200 ms; cloak-cli's 500 ms) | 37 to 46 ms |
| a payment, for comparison, same session | 9 ms | 124 ms |

| | |
|---|---|
| a deposit's transfer | 14,848 B |
| a withdrawal's transfer | 14,840 B |
| the fixture-shaped covenant transaction | 1,513 B (bound 4,096 in a submission) |
| refusals before the proof (amount, address, note, request) | each under 100 ms, asserted |
| 1,000 mutated covenant transactions | 45 backed (32 with the covenant output untouched, 13 with other PP3 or refund terms), 687 refused at `covenant`, 268 not transactions at all, **0 thrown** |
| refusals searched for keys and note randomness | 17, none found |

The deposit's own work is smaller than a payment's because it has no path and no
anchor to check. The spend proofs here measure about a third of section 7's 118
ms. Same AIR, same parameters, and the payment's figure was reproduced in the
same session at 124 ms, so the difference is not the transfer; the likeliest
reading is that these proofs run after the setup has already proved once and
are warm. It was not chased further,
because nothing depends on it: the bound is on the wallet's own work.

The 268 are bytes `dartsv` would not parse as a transaction. `backedBy` takes a
`Transaction`, so those never reach it; the claim the suite makes is about every
one that does.

### Decided against

- **One call that also builds the covenant.** It would pull a funding
  transaction, a transparent signer and a refund key into a shielded library.
  The host's transparent wallet builds it with tstokenlib.
- **Checking the covenant's PP3 against the view.** The view does not hold the
  round's txid, and asking for it would be a lookup. The host knows which round
  it deposits into, and the coordinator refuses a stale one by name.
- **Parsing the covenant by offset.** tstokenlib does not export
  `PoolDepositGen.parse`, so `backedBy` calls the exported
  `ShieldedPoolTool.findDeposits`, which parses the covenant in full, and hands
  it the PP3 read from the output's own push so the match is on everything else.
  Exporting `PoolDepositGen.parse` and `PoolDepositTerms` from tstokenlib would
  make that a direct call, with no change in behaviour.
- **A journal version bump.** Nothing about an entry's fields changed.

### Owed

- Restore from a seed.
- A deposit built in the suite is not mined in the suite: the fixture's rounds
  are fixed, and proving a round with a new deposit costs an aggregation. The
  localnet run is where a built deposit would be taken in end to end.
