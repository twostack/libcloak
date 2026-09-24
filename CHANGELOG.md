## 0.1.1

- **The native STARK kernels arrive with the package.** libcloak now depends on
  tstokenlib 2.1.0, whose build hook bundles the kernels into every program
  that uses it: a prebuilt, checksum-verified library for macOS, iOS, Linux,
  Android and Windows, or a cargo build anywhere else. Nothing needs building
  or pointing at by hand, and `STARK_KERNELS_LIB` is only an override now.
- **Requires Dart 3.10**, the first release where build hooks are stable.

## 0.1.0

The first release: a headless wallet library for the TSL1_SP shielded pool,
for people paying people without scanning a chain.

- **Keys.** One seed per wallet (`WalletSeed`, `WalletKeys`), written to disk
  encrypted under a passphrase (`WalletFile`).
- **Two ports, and nothing else touches the world.** A host supplies a
  `HeaderSource` and a `Transport`. Neither declares a method that takes an
  address, an outpoint or a wallet-derived txid, so neither can leak one.
- **The pool view.** `PoolView` keeps a note's spend path current by folding
  one 32-byte block root a round, and hands out a path only once that fold
  has been checked against a round the wallet proved for itself.
- **Notes.** `NoteStore`, `Balance` and `NoteSelection` handle the wallet's
  own bookkeeping. No nullifier is ever written down.
- **Invoices, payments and their proofs.** `Invoice`, `PaymentBuilder`,
  `PaymentProofs`, `PaymentChecker` and `Acknowledgement` cover the whole
  exchange: ask, pay, prove, check against your own headers, and
  acknowledge.
- **The coordinator client.** `CoordinatorClient` submits transfers, follows
  the pool's feed and catches up by round number, checking every answer it
  gets. A refused catch-up comes back as a named refusal.
- **Deposits and withdrawals.** `DepositBuilder` and `WithdrawalBuilder`.
- **The journal.** A record of what the wallet did, one file per entry.
- **Nothing throws on bad input.** Everything that takes bytes from somebody
  else returns a value or a `Refusal` naming the step that stopped it.

Not yet included: restoring from a seed, an SPV `HeaderSource`
implementation, and production parameters end to end. See the README's
Status section.

Proving needs `tstokenlib`'s native STARK kernels. Build them from
`tstokenlib` and point `STARK_KERNELS_LIB` at the library.
