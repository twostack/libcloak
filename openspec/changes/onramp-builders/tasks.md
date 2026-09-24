## 1. Deposits

- [x] 1.1 Build `DepositBuilder.prove` (two dummies, zero anchor, the depositor's note as output 1, a zero-value note as output 2, negative public amount) and `ProvedDeposit` exposing the commitment, the opening and both durations; verified by `test/onramp_test.dart` "A deposit on the fixture's pool" (`refusal()` null, `verifyProof` passes)
- [x] 1.2 Build `ProvedDeposit.backedBy(covenantTx)` checking the covenant output's commitment and value and the submission's size bound, yielding `BuiltDeposit`; verified by "A covenant that is not this deposit's" (another commitment, another amount, no covenant at the output)
- [x] 1.3 Build `DepositBuilder.check` surfacing `refusal()` and `depositRefusal()` as a named `Refusal`; verified by "The transfer's shape is checked before it is sent" (a real input beside a deposit refused at step `deposit`)
- [x] 1.4 Show the depositor learns its leaf and takes the note on: `PaymentProofs.positionOf` over the fixture's round 1 finds the fixture deposit's commitment, and `NoteStore.takeChange` takes the opening there; verified by "The depositor finds its note in the mined round"

## 2. Withdrawals

- [x] 2.1 Build `WithdrawalBuilder.build` in `PaymentBuilder`'s check order with `outHash` over the withdrawal record; verified by "A withdrawal on the fixture's chain" (`refusal()` null, `verifyProof`, record amount and pubkey hash, change recoverable)
- [x] 2.2 Build `WithdrawalBuilder.check` naming both amounts when the record and the public amount differ; verified by "The withdrawal and the public amount agree"
- [x] 2.3 Verify the cheap refusals stop before the proof in under 100 ms: more than the note holds (naming both numbers), a reserved note, a bad pubkey hash, a change address not the wallet's

## 3. Submission

- [x] 3.1 Add `CoordinatorClient.submitWithdrawal` sharing `submit`'s reserve and release path, and `submitDeposit` attaching the covenant transaction; verified against `FakeTransport`: refused releases, accepted reserves and a second submission never leaves, a timeout leaves it reserved, a deposit's frame carries the covenant
- [x] 3.2 Show tstokenlib's own `ShieldedCoordinator` intake, opened at the fixture's round 1, accepts the built deposit and the built withdrawal

## 4. Journal and exports

- [x] 4.1 Add `JournalKind` 10 to 13 and `JournalEntry.depositBuilt/depositAnswered/withdrawalBuilt/withdrawalAnswered` threaded by `threadId`; verified by a round trip of each, one thread each, and a search of the encoded entries for the wallet's keys
- [x] 4.2 Export the new types from `lib/libcloak.dart`; verified by the test reaching every new type through `package:libcloak/libcloak.dart` alone

## 5. Non-functional verification

- [x] 5.1 Mutation test: 1,000 mutated and truncated covenant transactions offered to `backedBy`, every one backing the deposit or refused by name, none throwing
- [x] 5.2 Collect every refusal the new builders produce in the suite and search them for the wallet's keys and the notes' randomness; none found
- [x] 5.3 Time both builds' own work (bound 200 ms) and record own work against proving in `docs/DESIGN.md` section 12
- [x] 5.4 `dart analyze lib test` clean, and `dart test` passes
