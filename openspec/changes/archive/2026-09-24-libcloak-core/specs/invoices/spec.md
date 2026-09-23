## Purpose

The message a payee writes to ask for money: a fresh address, an amount, an
expiry and what it is for. It is the first half of "payment in consideration of
something", and it is what an acknowledgement later refers back to.

## ADDED Requirements

### Requirement: What an invoice carries
An invoice SHALL carry a format version, the pool it is for (the descriptor's
tokenId), a fresh `NoteAddress`, the amount in satoshis, an expiry as an
absolute time, an invoice id, an optional memo bounded in length, and a
signature under the key the address was issued from. Every length SHALL be
explicit.

#### Scenario: An invoice round trips
- **WHEN** an invoice is written and parsed back
- **THEN** every field is equal and the encoding is byte-identical

#### Scenario: Size
- **WHEN** an invoice with a 256-byte memo is encoded for the hybrid KEM
- **THEN** it is under 2 KB, and the size is recorded in the design record

### Requirement: An invoice names one pool
A payer SHALL refuse an invoice whose tokenId is not the pool its descriptor
names, naming both, so a payment cannot be made into a pool the payer did not
mean.

#### Scenario: Another pool's invoice
- **WHEN** an invoice names a tokenId the payer's descriptor does not
- **THEN** the payer refuses it, naming both

### Requirement: Expiry is checked before work is done
A payer SHALL check the expiry before building anything, so an expired invoice
costs no proof. A payee SHALL refuse to acknowledge a payment against an invoice
that had expired when the transfer was submitted.

#### Scenario: Expired before proving
- **WHEN** a payer is given an expired invoice
- **THEN** it refuses naming the expiry, and no spend proof is computed

### Requirement: The signature binds the address to the payee
The invoice's signature SHALL cover every other field, and a payer SHALL check
it against the address's own key before using the address, so a substituted
address is caught.

#### Scenario: A substituted address
- **WHEN** an invoice's address is replaced and the signature left alone
- **THEN** the payer refuses it, naming the signature

### Requirement: Untrusted input
An invoice arrives from another person. Its total size SHALL be bounded (default
8 KB) before allocation, every field's length bounded before reading, and every
failure SHALL be a named refusal.

#### Scenario: Mutated invoices
- **WHEN** 10,000 randomly mutated and truncated invoices are parsed
- **THEN** every one either parses or is refused with a named reason, and none throws an unnamed error

### Requirement: Privacy, determinism and compatibility
An invoice SHALL carry no key beyond the address's own public material, and no
note, balance or history of the payee. Encoding SHALL be deterministic, and an
unknown format version SHALL be refused naming it.

#### Scenario: Nothing extra in an invoice
- **WHEN** an invoice's bytes are searched
- **THEN** they contain no run equal to the payee's `ivk`, `nk`, `ovk`, seed or any note it holds

#### Scenario: Unknown version
- **WHEN** an invoice carries a version this library does not write
- **THEN** it is refused, naming the version

### Requirement: Failure behaviour
A refused invoice SHALL leave the payer's wallet unchanged, and an invoice the
payee issued but nobody paid SHALL expire without any state to clean up beyond
its journal record.

#### Scenario: A refused invoice changes nothing
- **WHEN** an invoice is refused for any reason
- **THEN** the payer's notes, view and address counter are as they were
