**Unblocked 2026-09-23: `sp-block-roots` is applied in ../tstokenlib.** It
delivered everything this change waited on, and a little more:

- `ShieldedRound.blockRoot` and `ShieldedLedger.blockRoot` / `blockRootOf(n)`,
  `ShieldedPoolLayout.leavesPerRound` / `blockLevel` (round N owns the aligned
  subtree at the block level, index **N - 1**);
- the power-of-two assertion in `AggregationTree`, and the coordinator's
  `size == round x leaves` check;
- protocol **format version 2**: the descriptor carries the leaf count, the
  tokenId, the genesis header and the catch-up range; the announcement carries
  the block root; and two new messages carry catch-up (block roots over a
  published run, the frontier, a head proof). A version 1 message is refused;
- `BlockFold` / `FoldedPath` on `NoteCommitmentTree` (fold 204.2 us a round with
  one path kept), `BlockFold.at` and `ShieldedLedger.frontier()` for joining
  from a checkpoint;
- `PoolEvidence.provenRound`, `provenNote` and `readPP1` (12.52 ms for the pair
  at test parameters), with **every** PP1 read in tstokenlib routed through the
  body check and `ShieldedLedger.open` now requiring the pool's tokenId and
  genesis header;
- `package:tstokenlib/testing.dart` exporting `PoolChainFixture` and
  `PoolTestParams`, verified from a package outside the repo.

Group 2's gate was run there as well (`test/pool_lineage_attack_test.dart`,
mined on localnet): the claim holds and the forgery is refused at the step named
`PP1 is this pool's script`. Task 2.1 here is the same attack carried through a
**payment proof** rather than a ledger, and is still owed.

## 1. The package and its ports

- [x] 1.1 Make `libcloak` a Dart package with `lib/libcloak.dart`, the `lib/src` layout from design.md, and a path dependency on tstokenlib; verify `dart pub get` and `dart analyze lib test` clean.
- [x] 1.2 Define `HeaderSource` in `lib/src/headers/header_source.dart` and `Transport` in `lib/src/net/transport.dart`, each with an in-memory fake in `test/fakes.dart` (the header fake built from blocks with real 80-byte headers and the chain's own merkle arithmetic rather than from a live localnet chain, so the suite needs no node; the transport fake recording every call); verify chain-headers "A fake source drives every check" and "The port's surface" (no declared method takes an address, outpoint or wallet-derived txid) and coordinator-client "The suite runs on a fake transport" in `test/fakes_test.dart`.

## 2. The lineage gate

- [x] 2.1 On localnet, forge a round that carries the pool's tokenId and a header of the attacker's choosing, give it a witness, mine it, and build a payment proof from it; verify payments "A round with a forged lineage" (the check refuses, naming the step that caught it) in `test/lineage_attack_test.dart`, guarded by `POOL_LOCALNET=1`.
- [x] 2.2 Record the result in `docs/DESIGN.md` with the forgery attempted and the step that caught it. **If the forged round passes, stop this change**, record what passed, and size the alternative (a chain of rounds in the payment proof) before any further task is started.

**Carried by group 2, because the gate needed them.** Verifying a forged
lineage through a *payment proof* meant building the proof and the checker
first, so these arrived early and are noted here rather than silently ticked
below: `merkle_membership.dart` and `proven_header.dart` (task 4.1's
implementation, its scenarios still owed), `msg/codec.dart`, `payment_proof.dart`
in both forms with its bounds and mutation run (8.2, and 8.5 in part), and
`pay/checker.dart` with the ordered checks (8.3). Group 8's remaining scenarios
— building a payment, the twelve refusals, acknowledgements, the short proof
against a *folded* round from a real `pool-view` — still need groups 3 to 7.

## 3. Keys

- [x] 3.1 Implement `seed.dart` and `wallet_keys.dart`: the versioned derivation from one seed to the pool spending key and, through `PoolHash`, to `ivk`/`nk`/`ovk`; the per-invoice diversifier counter; the birthday round; verify wallet-keys "Same seed, same wallet", "A derivation vector" (a recorded vector in the suite), "Ten invoices, ten addresses", "Addresses do not link" and "Born at a round".
- [x] 3.2 Implement `wallet_file.dart`: a versioned file holding the seed and the counter under a memory-hard KDF and an AEAD from `package:cryptography`, owner-only permissions, temporary-name-then-rename writes; verify "Wrong passphrase", "Nothing in the clear" (the bytes hold no run equal to the seed or any key), "Unknown version" and "A crash during a write".
- [x] 3.3 Verify wallet-keys "Mutated addresses" (10,000 mutated `NoteAddress` encodings) and "Errors carry no secrets" (every raisable error collected and searched).

**Group 3 note.** "Born at a round" is verified here in the half that exists:
`WalletKeys.birthday` is 7 and `couldHoldNotesIn` refuses every round below it.
The other half — that the *pool view* starts there — is verified in group 5,
which builds the view and takes this number from it.

## 4. Headers

- [x] 4.1 Implement `proven_header.dart` (the confirmation rule, default 1 on regtest and 6 elsewhere) and `merkle_membership.dart` (txid computed from the bytes, checked against the header's merkle root); verify chain-headers "The fixture's witness", "A proof for another transaction", "Not yet buried" and "A header the source does not know".
- [x] 4.2 Verify chain-headers "Mutated proofs" (10,000 mutated headers and proofs), "Unknown proof version", "Checking a payment asks only about blocks" and "The source is unavailable".
- [x] 4.3 Measure a 64-level membership check; verify "Check cost" (under 5 ms) and record it in `docs/DESIGN.md`.

**Group 4 note.** "The source is unavailable" is verified in the half that
exists — the check carries the port's own reason and the checker holds no state
— but the half about the wallet's *stored* state unchanged needs the pool view
and the note store, and is owed in groups 5 and 6. Group 4 also added the
standalone versioned `MerkleProof` the spec's "Unknown proof version" scenario
requires, and found that `1 << 64` wraps to zero, which made a 64-level branch
unusable; see `docs/DESIGN.md` section 3.

## 5. The pool view

- [ ] 5.1 Implement `descriptor.dart` and the view's open path: block size from the descriptor, the power-of-two refusal, the block level and upper level counts, and the refusal when stored state was built under another block size; verify pool-view "The test pool's descriptor", "A leaf count that is not a power of two" and "A pool that changed its block size".
- [ ] 5.2 Implement `frontier.dart` and `note_path.dart`: the upper frontier, folding one block root, the frozen lower siblings, and the `PoolSpendAir.depth` path yielded for a spend; verify pool-view "The lower siblings never change" and "A maintained path against a built tree" (a directly built tree of 1,000 blocks of 512 leaves, compared against `NoteCommitmentTree.path`).
- [ ] 5.3 Implement the checked fold and the ordering rules; verify "A wrong block root", "The fixture's two rounds", "A skipped round" and "Catching up".
- [ ] 5.4 Implement the ring accounting and the idle path; verify "Four rounds of slack", "Too far behind to spend" and "Resuming from a payment".
- [ ] 5.5 Implement the versioned stored state with temporary-name-then-rename writes; verify "Two views agree", "Unknown state version", "A state file cut short" and "Advancing makes no requests".
- [ ] 5.6 Verify pool-view "Thirty-two bytes a round", "Notes do not multiply the feed" and "Mutated input" (10,000 mutated roots, paths and positions).
- [ ] 5.7 Measure in `tool/scratch/view_cost_probe.dart` the 1,000-round catch-up holding 8 notes and the stored state of 100 notes; verify "Catch-up cost" (under 2 s) and "State size" (under 200 KB) and record both in `docs/DESIGN.md`.

## 6. Notes

- [ ] 6.1 Implement `note.dart` and `note_store.dart`: the three states, the fields recorded, the reservation rule, and the versioned stored form; verify note-store "A note through its states", "A refused submission releases the note", "A second payment on the same note", "A note without a checked proof", "Two stores agree" and "A truncated store".
- [ ] 6.2 Implement `balance.dart` and `selection.dart`: the three balance lines and the deterministic choice of at most two notes; verify "A stale line", "The same choice twice" and "No note covers it".
- [ ] 6.3 Verify note-store "Nullifiers are not published" (every message the library sends collected) and measure 10,000 notes; verify "Ten thousand notes" (under 4 MB, balance under 10 ms) and record it in `docs/DESIGN.md`.

## 7. Invoices

- [ ] 7.1 Implement `invoice.dart` and its codec: the versioned encoding with explicit lengths, the fresh address, the amount, the expiry, the id, the bounded memo and the signature; verify invoices "An invoice round trips", "A substituted address", "An invoice names one pool" and "Expired before proving".
- [ ] 7.2 Verify invoices "Mutated invoices" (10,000 mutated and truncated), "Unknown version", "Nothing extra in an invoice" and "A refused invoice changes nothing"; measure and verify "Size" (a 256-byte memo under 2 KB) and record it in `docs/DESIGN.md`.

## 8. Payments

- [ ] 8.1 Implement `builder.dart`: an invoice and a note to a `ShieldedTransfer` through tstokenlib, with the path from the view; verify payments "A payment on the fixture's chain", "Not enough in the note" and "An expired invoice".
- [ ] 8.2 Implement `payment_proof.dart`: the versioned self-contained encoding (round, witness, the witness's merkle proof and block hash, the note opening, the position, the path); verify payments "Nothing to look up" and "Two builds agree".
- [ ] 8.3 Implement `checker.dart`: the payee's checks in the specified order, calling tstokenlib's proven-round and proven-note checks; verify payments "A good payment is accepted", "A note that is not the payee's", "A path to another round" and the forged-lineage scenario from task 2.1.
- [ ] 8.4 Implement `acknowledgement.dart`; verify payments "An acknowledgement checks against its invoice" and "An acknowledgement for another invoice".
- [ ] 8.5 Verify payments "Mutated payment proofs" (10,000 mutated and truncated), "A proof that claims a huge length", "Nothing secret in a proof", "Nothing secret in a refusal" and "State after a failed check".
- [ ] 8.6 Measure the check and the encoding at test parameters; verify "Checking is cheap" (under 100 ms), "Size at test parameters" (under 1 MB) and libcloak's own build work (under 200 ms excluding the spend proof), and record all three in `docs/DESIGN.md`.

## 9. The coordinator client

- [ ] 9.1 Implement `coordinator_client.dart`: the descriptor first, submissions encoded through `PoolSubmission`, replies matched by id with a timeout, announcements in round order handing block roots to the view, and disagreement detection; verify coordinator-client "Descriptor first", "A feed that does not start with a descriptor", "A reply matched by id", "A reply for an unknown id", "No reply", "Announcements in order", "A round out of order" and "A disagreeing announcement".
- [ ] 9.2 Verify payments "Each of the twelve refusals" and "Accepted and awaiting" against the fake transport.
- [ ] 9.3 Verify coordinator-client "Random frames" (10,000 random and mutated frames), "What is sent" and "The transport is down".

## 10. The journal

- [ ] 10.1 Implement `journal.dart` and `entry.dart`: versioned entries under an invoice id, temporary-name-then-rename writes, corrections as new entries; verify journal "One payment, one thread", "A refusal is kept", "An entry cut short", "A correction" and "A write that fails".
- [ ] 10.2 Verify journal "Mutated journal files" (1,000 mutated), "Unknown entry version" and "Nothing secret in the journal"; measure 10,000 entries, verify "Ten thousand entries" (under 1 s) and record it in `docs/DESIGN.md`.

## 11. End to end

- [ ] 11.1 On the fixture's chain, run a payment end to end inside the suite: payee issues an invoice, payer builds and submits through the fake transport, the round is applied, the payer builds a payment proof, the payee checks it and acknowledges, and both journals read as one thread; verify it in `test/end_to_end_test.dart`.
- [ ] 11.2 On localnet against ../pool-coordinator at test parameters, run the same flow over the real coordinator: two wallets, an invoice, a submission, a mined round, a delivered proof and an acknowledgement; verify the round is mined, the payee's check passes against headers from the node, and the pool view reaches the coordinator's tip, guarded by `POOL_LOCALNET=1`.
- [ ] 11.3 Record in `docs/DESIGN.md` the end-to-end timings from 11.2 with the machine, and what is unmeasured (production parameters, which ARC's 1,636,802 byte scriptSig limit keeps off testnet).

## 12. Docs and the suite

- [ ] 12.1 Write the dated section in `docs/DESIGN.md`: the ports, the block-root following and its invariant, the payment flow and the payee's checks, the message formats with their sizes, the decisions D1 to D6 as settled, and every measurement from groups 4 to 11.
- [ ] 12.2 Run `dart analyze lib test` (0 errors) and the full suite (`dart test`), and report the counts.
- [ ] 12.3 Write the journal entry in ../openspec-practice recording anything this change taught about the conventions.
