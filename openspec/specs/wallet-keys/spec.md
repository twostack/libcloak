# wallet-keys Specification

## Purpose

One seed, and everything the wallet is derived from it: the pool spending key,
a fresh diversified address for each invoice, the round the wallet was born in,
and the encrypted file the lot lives in. Losing the seed loses the money, so
what the seed is and where it is written has to be stated plainly.

## Requirements

### Requirement: One seed, derived deterministically
The wallet SHALL derive its pool spending key from a single seed by a stated,
versioned derivation, and SHALL derive the viewing keys (`ivk`, `nk`, `ovk`)
from it through `PoolHash`. The same seed SHALL always give the same keys, so a
wallet restored from a seed is the same wallet.

#### Scenario: Same seed, same wallet
- **WHEN** two wallets are created from the same seed
- **THEN** their spending key, `ivk`, `nk`, `ovk` and first ten addresses are identical

#### Scenario: A derivation vector
- **WHEN** the library's recorded seed vector is derived
- **THEN** the keys match the vector, which is checked in the suite so a change to the derivation cannot pass unnoticed

### Requirement: A fresh address per invoice
The wallet SHALL issue a diversified address (`NoteAddress.at`) from a counter
that advances once per invoice, and SHALL NOT reuse a diversifier across two
invoices. Two addresses of the same wallet SHALL NOT be linkable to each other
without the wallet's `ivk`.

#### Scenario: Ten invoices, ten addresses
- **WHEN** ten invoices are issued
- **THEN** their addresses have ten distinct diversifiers and the counter is 10

#### Scenario: Addresses do not link
- **WHEN** two addresses of one wallet are compared without the `ivk`
- **THEN** no field is shared between them

### Requirement: The birthday
The wallet SHALL record the pool round it was created at, and SHALL treat rounds
before it as containing nothing of its own. Nothing in this change reads a round
before the birthday.

#### Scenario: Born at a round
- **WHEN** a wallet is created against a pool at round 7
- **THEN** its birthday is 7 and its pool view starts there

### Requirement: Keys at rest
The wallet file SHALL hold the seed and the address counter encrypted under a
passphrase supplied by the host, using a memory-hard key derivation and an
authenticated cipher. The file SHALL be versioned, written with owner-only
permissions, and SHALL never be written in the clear. On creation the library
SHALL report where the file is and that the seed cannot be recovered from
anywhere else.

#### Scenario: Wrong passphrase
- **WHEN** a wallet file is opened with a passphrase that does not decrypt it
- **THEN** it refuses, naming the file and not the key

#### Scenario: Nothing in the clear
- **WHEN** a wallet file's bytes are searched
- **THEN** they contain no run equal to the seed, the spending key, `ivk`, `nk` or `ovk`

### Requirement: Untrusted input
A `NoteAddress` parsed from an invoice is outside input: it SHALL be refused
unless its length matches the KEM it names and its lanes are inside the field,
with the field and reason named.

#### Scenario: Mutated addresses
- **WHEN** 10,000 randomly mutated address encodings are parsed
- **THEN** every one either parses to a well formed address or is refused with a named reason

### Requirement: Secrets never leave
No key, seed or passphrase SHALL appear in any error message, log line, journal
record or encoded message this library produces.

#### Scenario: Errors carry no secrets
- **WHEN** every error this capability can raise is collected
- **THEN** none contains the seed, a key or the passphrase

### Requirement: Compatibility and failure behaviour
An unknown wallet-file version SHALL be refused naming the version. A write
interrupted partway SHALL leave the previous file intact, because the file is
written to a temporary name and renamed.

#### Scenario: Unknown version
- **WHEN** a wallet file carries a version this library does not write
- **THEN** opening it is refused, naming the version

#### Scenario: A crash during a write
- **WHEN** the temporary file exists but the rename did not happen
- **THEN** the previous wallet file opens unchanged, and the temporary file is ignored
