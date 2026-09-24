## Why

libcloak can pay out of a note and check a payment into one, but it cannot put
money into the pool or take it out, so every note a wallet holds today came from
the fixture. `cloak-cli` (tasks 0.2 and 0.3 of its `cloak-cli` change) needs a
deposit and a withdrawal it can build, check and submit with the same discipline
`PaymentBuilder` has: every cheap check before the STARK, a named refusal and
never a throw, and a note that moves only with the coordinator's answer.

## What Changes

- A **deposit builder**: a TSL1_SP transfer with two dummy inputs, BSV brought in
  (negative public amount) and the depositor's own note as output 1, built in two
  steps because the covenant transaction that carries the money needs the note's
  commitment, and the transfer needs the covenant's outpoint. The first step
  proves and exposes the commitment and the note's opening; the second attaches
  the covenant transaction the host built from that commitment, checks that it
  locks exactly this note and this amount, and yields the transfer.
- A **withdrawal builder**: one real note in, BSV out to a transparent pubkey
  hash the caller names, a withdrawal record for exactly the amount taken out,
  and change to a fresh address of the wallet's own. Same check order as a
  payment: the request, the note, the path, the anchor, then the proof.
- A **shape check** for each, surfacing tstokenlib's `ShieldedTransfer.refusal()`
  (including `depositRefusal()`) as a libcloak `Refusal` naming the rule, so a
  deposit with a real input and a withdrawal whose record and public amount
  differ are refused by name.
- **Submission** of both through `CoordinatorClient`: a withdrawal reserves its
  note before the frame leaves and releases it only when the answer says the
  transfer is not in a round, exactly as a payment does; a deposit is submitted
  with its covenant transaction attached and has no note to reserve.
- **Journal** entries for a deposit or withdrawal built and answered, threaded
  under an id derived from the transfer's public bundle hash, since neither
  answers an invoice. Four new entry kinds; existing entries and the entry
  version are unchanged.
- Out of scope: restore from a seed, which is the one place the no-scanning rule
  does not apply and deserves its own change; building or broadcasting the
  covenant transaction itself, which is the host's transparent wallet's job
  through tstokenlib's `ShieldedPoolTool.createDepositTxn`; refunds.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `payments`: adds building a deposit, building a withdrawal, and submitting
  either, with their untrusted-input, privacy and performance contracts.
- `journal`: adds recording a deposit or withdrawal, built and answered, as one
  thread.

## Non-functional contract

- **Untrusted input:** the covenant transaction handed to the deposit's second
  step is the host's, but it is bytes this library did not build; a mutated one
  is refused naming the step, never thrown on (1,000 mutations, a task checks).
- **Secrets and privacy:** no refusal or journal entry carries a key or a note's
  randomness. Neither builder makes any request; the only thing that leaves the
  machine is the submission, and a deposit's covenant transaction goes with it
  because the coordinator must see it and it is public on the chain anyway.
- **Trust:** the builders check the covenant against the note they proved and
  the path against the view's checked root; nothing a coordinator says is used.
- **Determinism:** not applicable beyond what `payments` states; a build is
  randomised by design (fresh note randomness and ciphertexts).
- **Compatibility:** the journal's entry version stays 1; old entries read
  unchanged, and the four new kinds are numbers 10 to 13.
- **Performance:** the wallet's own work for either build, excluding the spend
  proof, SHALL stay under 200 ms (payments' own bound; cloak-cli asks 500 ms);
  every refusal that stops before the proof SHALL come back in under 100 ms.
  Measured at test parameters on an Apple M3 Pro and recorded in
  `docs/DESIGN.md` section 12.
- **Failure behaviour:** a refused build leaves the note store and the view as
  they were; a submission's note follows the answer as a payment's does.

## Impact

- New `lib/src/pay/onramp.dart`; additions to `lib/src/net/coordinator_client.dart`
  and `lib/src/journal/entry.dart`; exports in `lib/libcloak.dart`.
- New `test/onramp_test.dart`; the journal suite gains the four kinds.
- No change to tstokenlib or pool-coordinator. tstokenlib does not export its
  covenant parser (`PoolDepositGen.parse`), so the covenant is recognised through
  the exported `ShieldedPoolTool.findDeposits`; see design.md.
