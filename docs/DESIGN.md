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
