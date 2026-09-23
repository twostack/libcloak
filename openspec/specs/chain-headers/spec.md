# chain-headers Specification

## Purpose

What libcloak requires of a source of block headers, and what it does with them:
a header chain the wallet holds itself, and the merkle-proof check that binds a
transaction to one of those headers. This is the only thing in the library that
takes evidence from the chain, and it takes it in bulk, never by asking about
anything the wallet owns.

## Requirements

### Requirement: A port, not an implementation
libcloak SHALL define a header source as a port: the chain's tip height and
hash, whether a given block hash is on the chain the source accepts and at what
height, and the header for a height. libcloak SHALL NOT implement header sync,
difficulty or network access itself, and SHALL work against any implementation
of the port, including a fake.

#### Scenario: A fake source drives every check
- **WHEN** the suite runs with a fake header source built from the localnet regtest chain
- **THEN** every payment check in `payments` passes without any network access

### Requirement: A proven header is one the wallet accepts
A header SHALL count as proven only when the source reports it on the chain it
accepts, at a height the source will also report as buried by a configured number
of confirmations (default 1 on regtest, 6 on testnet and mainnet). libcloak SHALL
treat a header the source does not vouch for as absent, never as provisional.

#### Scenario: Not yet buried
- **WHEN** a witness is in a block with fewer confirmations than configured
- **THEN** the payment check reports the payment as not yet final, naming the confirmations it has and the number required

#### Scenario: A header the source does not know
- **WHEN** a payment proof names a block hash the source does not have
- **THEN** the check fails naming the block hash, and does not fall back to asking anyone about it

### Requirement: A transaction is bound to a header by its merkle proof
libcloak SHALL check a transaction's membership in a block from the transaction's
bytes, its merkle proof and the proven header's merkle root, and SHALL compute
the transaction's txid from its bytes rather than taking it from the proof.

#### Scenario: The fixture's witness
- **WHEN** the fixture's witness transaction, its merkle proof and its block header are checked
- **THEN** the check passes and reports the height

#### Scenario: A proof for another transaction
- **WHEN** the merkle proof of a different transaction in the same block is supplied
- **THEN** the check fails naming both txids

### Requirement: Nothing is asked that names the wallet
Every call libcloak makes through the port SHALL be about a block: a height, a
hash, or the tip. libcloak SHALL NOT ask the port about an address, a txid it
learned from its own notes, or an outpoint, and the port SHALL NOT offer such a
call, so that a source cannot learn what the wallet holds from the questions it
is asked.

#### Scenario: The port's surface
- **WHEN** the port's declared methods are listed
- **THEN** none takes an address, an outpoint or a wallet-derived txid

#### Scenario: Checking a payment asks only about blocks
- **WHEN** a payment proof is checked against a recording fake source
- **THEN** every recorded call names a block height or a block hash, and the block hash is one that arrived inside the proof

### Requirement: Untrusted input
A header, a merkle proof and a transaction from a payment proof are all outside
input. Sizes SHALL be bounded before reading, a header SHALL be refused unless it
is 80 bytes, a merkle proof unless its length is inside a configured bound
(default 64 levels), and every refusal SHALL name the field and the reason.

#### Scenario: Mutated proofs
- **WHEN** 10,000 randomly mutated headers and merkle proofs are checked
- **THEN** every one is refused with a named reason and none throws an unnamed error

### Requirement: Determinism and compatibility
The same transaction, proof and header SHALL always give the same verdict. The
serialized form of a merkle proof SHALL be versioned and an unknown version
refused, naming it.

#### Scenario: Unknown proof version
- **WHEN** a serialized merkle proof carries a version this library does not write
- **THEN** it is refused, naming the version

### Requirement: Resources and failure behaviour
A membership check SHALL take under 5 ms at 64 levels on one core of an Apple M3
Pro, and SHALL make no call to the port beyond the header it needs. A port call
that fails SHALL surface as a named error carrying the port's reason, and SHALL
leave no partial state behind.

#### Scenario: Check cost
- **WHEN** a membership check runs at 64 levels
- **THEN** it takes under 5 ms and the measurement is recorded in the design record

#### Scenario: The source is unavailable
- **WHEN** the port reports a failure
- **THEN** the payment check fails naming the port's reason, and the wallet's stored state is unchanged
