# libcloak

The wallet library for the TSL1_SP shielded pool.

libcloak holds keys, notes and their proofs for one person. It is a headless library and
as such has no UI, no daemon or network of its own. A host (a CLI, an app, a server) supplies
a transport and a source of block headers.

## What it is for

P2P Payments. A payment is made in consideration of something, so the
payer has to be able to *show* that it was made:

1. the payee writes an **invoice** naming a fresh address,
2. the payer builds a **transfer** and submits it to the pool's coordinator,
3. the round is proved and mined, and the payer sends the payee a **payment
   proof**,
4. the payee checks that proof against block headers it holds itself, and
   **acknowledges**.

## What it does not do

It does no blockchain scanning, and it does not perform lookups for
addresses, txids or outpoints. Those are the habits that run counter to
SPV (Simplified Payment Verification). Everything a payee needs arrives
over a P2P comms channel along with the payment. The single exception is restoring a wallet from its
seed.

## Status

Early, and deliberately built back to front: the claim every payment proof rests
on was attacked before anything was built on it. A round forged to carry the
pool's tokenId, mined on a regtest node for the price of two ordinary
transactions, is refused by a payee at the step named `PP1 is this pool's
script`. That result, and the numbers, are in `docs/DESIGN.md`.

Built so far: the two ports and their fakes, the header and merkle-membership
checks, the payment proof in both forms, and the payee's checker. See
`openspec/changes/` for what is being built and `docs/DESIGN.md` for the running
record.
