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
