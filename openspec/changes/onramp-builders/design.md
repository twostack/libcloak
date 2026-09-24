## Context

See proposal.md for why. `PaymentBuilder` (`lib/src/pay/builder.dart`) is the
model: static builders returning `(Result?, Refusal?)`, checks in cost order
with the STARK last, `ownWork` and `proving` timed apart, and the note reserved
by an accepted submission rather than by the builder.

What tstokenlib and the coordinator accept, read from the code rather than
assumed:

- `PoolSpendAir.witness` proves a deposit as two dummies with a negative
  `publicOut`; with no real input it needs an explicit `anchor`, and the ring
  check is waived when neither input is real. `ShieldedCoordinator._check`
  checks the anchor only `if (p.real1 || p.real2)`, and `../pool-coordinator`
  adds only that the covenant is mined and unspent before handing the bytes to
  the same intake.
- `ShieldedTransfer.refusal()` checks, in order, `outHash` against the bundle
  and withdrawal record, a withdrawal exactly when BSV leaves and for exactly
  that amount, the bundle's commitments against the proof's, and last
  `depositRefusal()` (two dummies, BSV, money in, a 36-byte outpoint).
- `outHash = SHA256(W ‖ SHA256(bundle))` with `W` the 28-byte withdrawal
  record. The deposit outpoint is **not** in it, and not in the proof's public
  lanes (`PoolPublicInputs` has no field for it); it rides beside the transfer
  in the encoding only. That is what lets the proof come before the covenant.
- The coordinator's `_checkDeposit` requires the covenant transaction, the
  outpoint naming one of its outputs, a covenant there naming the live PP3 with
  a refund far enough ahead, and the covenant's commitment and value equal to
  the transfer's `receipt` (`cmOut1`, `-publicOut`).
- A non-empty bundle must parse as exactly two note bundles whose commitments
  are `cmOut1` and `cmOut2`, so output 2 has to be a real encrypted note, not
  the padding note (whose zero `pk_d` is not an address anyone can encrypt to).
  The fixture's own deposit does the same: a zero-value second note.

## Goals / Non-Goals

**Goals:** the two builders, their shape checks, submission of each, journal
entries, and a suite that shows tstokenlib's own coordinator intake accepts what
they build.

**Non-Goals:** building, funding, signing or broadcasting the covenant
transaction (the host's transparent wallet, with
`ShieldedPoolTool.createDepositTxn`); choosing the refund height or checking the
covenant's PP3 against the live round (the host knows which round it deposits
into; the coordinator refuses a stale PP3 by name, `depositTarget`); refunds;
restore from a seed.

## Decisions

**D1. A deposit is built in two steps: `DepositBuilder.prove` then
`ProvedDeposit.backedBy(covenantTx)`.** The covenant needs the commitment and
the transfer needs the covenant's outpoint, and the outpoint is outside the
proof, so the proof is computed once, first. The second step takes the whole
covenant **transaction**, not a bare outpoint, because the submission has to
carry that transaction anyway and because it lets the step check what the
outpoint alone cannot: that the output really is a covenant locking this
commitment and exactly this amount. A deposit whose covenant locks another value
would be refused by the coordinator as `depositCovenant` after a round trip;
here it is refused before anything leaves. Alternative considered: one call that
also builds the covenant. Rejected because it would pull a funding transaction,
a transparent signer and a refund key into a shielded library.

**D2. A deposit's anchor is all zeros.** No real input means no ring check, and
the padding transfers every round carries are proved against the same zero
anchor, so a deposit takes exactly the path they take. Using the view's current
root would tie a deposit to when it was built for nothing, and would make the
builder need a checked view it has no use for. The builder therefore takes no
view.

**D3. Output 2 of a deposit is a zero-value note to the depositor's own
address, and output 2 of a withdrawal is a zero-value note to the change
address.** Both are real notes with real ciphertexts, as the bundle rule
requires. The store never takes them on; they cost one encryption each.

**D4. Each builder checks that the address it writes the wallet's own note to is
the wallet's** (`pkdFromIvk(ivk, d) == pk_d`). A deposit or change written to
someone else's address is money gone, and the check is one Poseidon2 hash.

**D5. The covenant is recognised through `ShieldedPoolTool.findDeposits`.**
tstokenlib does not export `PoolDepositGen.parse`. `findDeposits` does parse the
covenant in full (fixed pushes, then the exact body), but asks which PP3 to look
for; the step passes the PP3 outpoint read from the output's own push, so the
match is on everything else and a script that is not a covenant is still refused.
If tstokenlib ever exports its parser this becomes a direct call with no change
in behaviour.

**D6. Shape checks are libcloak functions over tstokenlib's rule.**
`DepositBuilder.check` requires a deposit outpoint and then surfaces
`ShieldedTransfer.refusal()` as `Refusal(field, reason)`, so a real input beside
a deposit comes back as step `deposit`, "spends a real note beside a deposit".
`WithdrawalBuilder.check` compares the record's amount with the public amount
**before** `refusal()`, because `refusal()` checks `outHash` first and a record
swapped after proving fails there, naming neither amount; the spec asks for both.

**D7. Submission: `submitWithdrawal` and `submitDeposit` beside `submit`.**
`submit` and `submitWithdrawal` share one private path (reserve, send, release
when settled), so the note discipline is written once. `submitDeposit` builds
the `PoolSubmission` with the covenant attached and sends it; `send`'s id
routing and resend of the same bytes are unchanged.

**D8. Journal: four kinds (10 to 13), threaded by a derived id.** The entry's
16-byte `invoiceId` field is the thread; a deposit or withdrawal answers no
invoice, so it carries `SHA256("tsl1-libcloak/onramp/1" ‖ bundleHash)[0..16]`.
The bundle hash is public (it is in the round's `outHash` preimage on chain) and
unique to the transfer, so the id is known at build time, says nothing new, and
cannot collide with an invoice's random id except by chance. The entry version
stays 1: no field changed, and an old reader refuses an unknown kind by name
rather than misreading it.

## Risks / Trade-offs

- [The coordinator may someday check a deposit's anchor] → the padding
  transfers use the same zero anchor, so such a change would break padding too
  and could not land silently; a one-line change here would follow.
- [Bound set before measuring: own work under 200 ms] → if a build measured
  over it, the bound would be reported in DESIGN.md with the phase that broke it
  and the cloak-cli bound (500 ms) checked instead, rather than relaxed quietly.
- [Bound set before measuring: refusals before the proof under 100 ms] → a miss
  would mean a check is doing work it should not, and would be fixed, not
  relaxed.
- [findDeposits with a PP3 read from the script] → it is only the argument to a
  full parse; a non-covenant or a changed body is still refused. Recorded as a
  small tstokenlib export that would make this direct.
