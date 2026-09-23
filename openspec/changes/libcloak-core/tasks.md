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

- [x] 5.1 Implement `descriptor.dart` and the view's open path: block size from the descriptor, the power-of-two refusal, the block level and upper level counts, and the refusal when stored state was built under another block size; verify pool-view "The test pool's descriptor", "A leaf count that is not a power of two" and "A pool that changed its block size".
- [x] 5.2 Implement `frontier.dart` and `note_path.dart`: the upper frontier, folding one block root, the frozen lower siblings, and the `PoolSpendAir.depth` path yielded for a spend; verify pool-view "The lower siblings never change" and "A maintained path against a built tree" (a directly built tree of 1,000 blocks of 512 leaves, compared against `NoteCommitmentTree.path`).
- [x] 5.3 Implement the checked fold and the ordering rules; verify "A wrong block root", "The fixture's two rounds", "A skipped round" and "Catching up".
- [x] 5.4 Implement the ring accounting and the idle path; verify "Four rounds of slack", "Too far behind to spend" and "Resuming from a payment".
- [x] 5.5 Implement the versioned stored state with temporary-name-then-rename writes; verify "Two views agree", "Unknown state version", "A state file cut short" and "Advancing makes no requests".
- [x] 5.6 Verify pool-view "Thirty-two bytes a round", "Notes do not multiply the feed" and "Mutated input" (10,000 mutated roots, paths and positions).
- [x] 5.7 Measure in `tool/scratch/view_cost_probe.dart` the 1,000-round catch-up holding 8 notes and the stored state of 100 notes; verify "Catch-up cost" (under 2 s) and "State size" (under 200 KB) and record both in `docs/DESIGN.md`.

**Group 5 note.** The spec's "32 bytes a round" and its "a fold is checked"
are two verbs, not one: `PoolView.fold` takes the round's `cmRoot` as optional
and the view carries `round` and `checkedTo` separately, because a wrong block
root anywhere in a run makes the root at the end of the run wrong — so catching
up from a stranger and checking once is sound, and `spendPath` is where a
wallet is held to checking before it spends. A verified payment path turned out
to already be a frontier, which is what makes "resume from a payment" free and
what brings a path that arrives a few rounds late forward. Measured at
production shape: 1,000 rounds holding 8 notes in 189 ms (bound 2 s) and a
100-note state in 106,988 B (bound 200 KB); see `docs/DESIGN.md` section 4.

## 6. Notes

- [x] 6.1 Implement `note.dart` and `note_store.dart`: the three states, the fields recorded, the reservation rule, and the versioned stored form; verify note-store "A note through its states", "A refused submission releases the note", "A second payment on the same note", "A note without a checked proof", "Two stores agree" and "A truncated store".
- [x] 6.2 Implement `balance.dart` and `selection.dart`: the three balance lines and the deterministic choice of at most two notes; verify "A stale line", "The same choice twice" and "No note covers it".
- [x] 6.3 Verify note-store "Nullifiers are not published" (every message the library sends collected) and measure 10,000 notes; verify "Ten thousand notes" (under 4 MB, balance under 10 ms) and record it in `docs/DESIGN.md`.

**Group 6 note.** `CheckedPayment`'s constructor is now private to
`checker.dart` and it carries the `NoteOpening`, so "refused unless the proof
checked out" is the argument type and not a rule: there is no way to hand the
store a proof nobody verified. The store records `rho` and `rcm` but never a
nullifier — `nk` is an argument to `settle`, not a field — and the test searches
the saved file for the nullifier lane by lane. Selection is one note, smallest
that covers, lowest leaf among equals, and the refusal names the largest
spendable value rather than the total, because a transfer spends one note.
Measured: 10,000 notes in 730,010 B (bound 4 MB) and a balance in 2.1 ms (bound
10 ms, and 7.1 ms before the balance stopped building refusals nobody reads).
**Left open:** the store file is not encrypted, which is what the spec asks for
and is a decision with a stated cost; see `docs/DESIGN.md` section 5.

## 7. Invoices

- [x] 7.1 Implement `invoice.dart` and its codec: the versioned encoding with explicit lengths, the fresh address, the amount, the expiry, the id, the bounded memo and the signature; verify invoices "An invoice round trips", "A substituted address", "An invoice names one pool" and "Expired before proving".
- [x] 7.2 Verify invoices "Mutated invoices" (10,000 mutated and truncated), "Unknown version", "Nothing extra in an invoice" and "A refused invoice changes nothing"; measure and verify "Size" (a 256-byte memo under 2 KB) and record it in `docs/DESIGN.md`.

**Group 7 note.** An address carries no signing key — `pk_d` is a hash and the
KEM is not a signature scheme — so the invoice's key is derived the way the
address is, Ed25519 from `SHA256("tsl1-libcloak/invoice/1" ‖ ivk ‖ d)`, one per
address so two invoices from a payee stay unlinkable. That catches a
substituted address, a changed amount and an altered expiry; it does not catch a
man in the middle who replaces key and signature too, which no self-contained
message can, and `docs/DESIGN.md` section 6 says so rather than implying
otherwise. Found and fixed a real round-trip bug: `DateTime` carries a zone flag
and `fromMillisecondsSinceEpoch` returns local, so an expiry did not survive its
own codec; it is normalised to UTC now. Measured: 1,687 B with a 256-byte memo
and 1,943 B with the memo full, both under the 2 KB bound.

## 8. Payments

- [x] 8.1 Implement `builder.dart`: an invoice and a note to a `ShieldedTransfer` through tstokenlib, with the path from the view; verify payments "A payment on the fixture's chain", "Not enough in the note" and "An expired invoice".
- [x] 8.2 Implement `payment_proof.dart`: the versioned self-contained encoding (round, witness, the witness's merkle proof and block hash, the note opening, the position, the path); verify payments "Nothing to look up" and "Two builds agree".
- [x] 8.3 Implement `checker.dart`: the payee's checks in the specified order, calling tstokenlib's proven-round and proven-note checks; verify payments "A good payment is accepted", "A note that is not the payee's", "A path to another round" and the forged-lineage scenario from task 2.1.
- [x] 8.4 Implement `acknowledgement.dart`; verify payments "An acknowledgement checks against its invoice" and "An acknowledgement for another invoice".
- [x] 8.5 Verify payments "Mutated payment proofs" (10,000 mutated and truncated), "A proof that claims a huge length", "Nothing secret in a proof", "Nothing secret in a refusal" and "State after a failed check".
- [x] 8.6 Measure the check and the encoding at test parameters; verify "Checking is cheap" (under 100 ms), "Size at test parameters" (under 1 MB) and libcloak's own build work (under 200 ms excluding the spend proof), and record all three in `docs/DESIGN.md`.

**Group 8 note.** The spec's "commitment step" does not exist to be named: an
opening carries no commitment, so it is computed from the opening and the
payee's `pk_d` and the only thing that can fail is the walk to the round's root.
The refusal names the position and both roots, which is the actionable answer,
and the clause that matters — the earlier steps are not reported as proof of
anything — is verified. `PoolEvidence` does name `commitment` for the one
failure that stands alone, an opening that is not a note. An acknowledgement
uses the **block's own timestamp** for the invoices spec's expiry-at-mining
rule, because it is the only clock in the exchange the payer did not supply.
Measured: build work 8 ms beside a 118 ms proof, standing proof 793,304 B
checked in 63 ms, short proof 1,098 B — a factor of 722. "Mutated payment
proofs" and "A round with a forged lineage" are the runs already in
`test/lineage_attack_test.dart`; submitting is task 9.2.

## 9. The coordinator client

- [x] 9.1 Implement `coordinator_client.dart`: the descriptor first, submissions encoded through `PoolSubmission`, replies matched by id with a timeout, announcements in round order handing block roots to the view, and disagreement detection; verify coordinator-client "Descriptor first", "A feed that does not start with a descriptor", "A reply matched by id", "A reply for an unknown id", "No reply", "Announcements in order", "A round out of order" and "A disagreeing announcement".
- [x] 9.2 Verify payments "Each of the twelve refusals" and "Accepted and awaiting" against the fake transport.
- [x] 9.3 Verify coordinator-client "Random frames" (10,000 random and mutated frames), "What is sent" and "The transport is down".

**Carried by group 9, because the task list did not carry it.** The
coordinator-client spec's whole **Catching up** requirement, and the one after
it, are not in the three one-liners above. They are done here, in
`test/coordinator_client_test.dart`, because the client is where they live:

- "A wallet with no state becomes current" (`CoordinatorClient.current`),
  "A wallet that fell behind" (`bringForward`), and "The pool lies" — six of them,
  a bent frontier, a bent block root, a head whose witness does not spend the
  round it names, a head in a block this wallet does not have, a head that
  claims the wrong round number, and a frontier standing at the wrong round;
- "Requests come from the published set" and "Nothing wallet-derived is sent";
- "A transport port, not a network" / "The suite runs on a fake transport",
  which every test in the file runs under.

**One piece did not exist and was built here.** A head proof is a standing
payment proof without the note, and `PaymentChecker` had no path for one.
`PaymentChecker.head` now runs steps 2 to 4 and stops, sharing `_provenRound`
with the standing form, and takes the round number from the pool header's own
leaf count rather than from the reply. Without it there is nothing a frontier
or a thousand folded block roots could be checked against, so "the pool is a
convenient server and never a trusted one" would have had no implementation.

**One export was added to tstokenlib**: `PoolCatchUpRequest`,
`PoolCatchUpReply` and `CatchUpKind`, which a wallet needs to ask the three
catch-up questions.

**Owed to group 10.** "Each of the twelve refusals" says the reason is recorded
in the journal. The reason is on `SubmissionOutcome.refusal` under the
protocol's own name, and nothing writes it down yet; the journal is group 10.

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
