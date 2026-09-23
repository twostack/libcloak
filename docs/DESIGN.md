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

`test/lineage_attack_test.dart`, 21 cases, all passing:

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
