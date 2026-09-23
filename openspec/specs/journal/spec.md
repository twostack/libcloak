# journal Specification

## Purpose

The wallet's record of what it promised, paid, proved and acknowledged. It is
what lets a person answer "did I pay that?" and "was I paid?" without asking
anybody, and it is the evidence behind a payment made in consideration of
something.

## Requirements

### Requirement: What is recorded
The journal SHALL record, each as a versioned entry with the time it was
written: an invoice issued or received; a payment built, submitted and its
reply; a payment proof built or checked, with its verdict; and an
acknowledgement sent or received. Each entry SHALL name the invoice it belongs
to, so a payment's whole life reads as one thread.

#### Scenario: One payment, one thread
- **WHEN** a payment is made end to end on the fixture's chain
- **THEN** the journal holds the invoice, the build, the submission, the reply, the proof and the acknowledgement, all under one invoice id

#### Scenario: A refusal is kept
- **WHEN** a submission is refused
- **THEN** the journal records the refusal reason and the payment stays readable as unpaid

### Requirement: Files, written whole
The journal SHALL be files on disk, each entry written to a temporary name and
renamed, so an entry is either whole or absent. A partially written entry SHALL
be refused at the next read, naming the file, rather than parsed.

#### Scenario: An entry cut short
- **WHEN** a journal entry file is truncated
- **THEN** the next read refuses it, naming the file, and the other entries still read

### Requirement: Append only in effect
The journal SHALL NOT rewrite or delete an entry. A correction SHALL be a new
entry that refers to the one it corrects, so the record of what was believed at
the time survives.

#### Scenario: A correction
- **WHEN** a payment first recorded unproven is later proved
- **THEN** both entries are present and the later names the earlier

### Requirement: Secrets stay out
The journal SHALL contain no seed, spending key, viewing key or passphrase. It
MAY contain note values, positions and invoice contents, which are the wallet's
own business and are already in its note store.

#### Scenario: Nothing secret in the journal
- **WHEN** a journal written by a full end-to-end payment is searched
- **THEN** it contains no run equal to either party's seed, spending key or viewing keys

### Requirement: Untrusted input and compatibility
A journal on disk may have been edited. Every entry's length SHALL be bounded
before reading, an unknown entry version refused naming it, and an unparseable
entry refused naming the file rather than skipped silently.

#### Scenario: Mutated journal files
- **WHEN** 1,000 mutated journal files are read
- **THEN** every one either reads or is refused with a named reason, and none throws an unnamed error

#### Scenario: Unknown entry version
- **WHEN** an entry carries a version this library does not write
- **THEN** the read refuses it, naming the version and the file

### Requirement: Determinism, resources and failure behaviour
Two wallets that did the same things in the same order SHALL write
byte-identical entries apart from their timestamps. Reading a journal of 10,000
entries SHALL take under 1 s on one core of an Apple M3 Pro. A failed write
SHALL leave every earlier entry readable.

#### Scenario: Ten thousand entries
- **WHEN** a journal of 10,000 entries is read
- **THEN** it completes in under 1 s and the measurement is recorded in the design record

#### Scenario: A write that fails
- **WHEN** the disk refuses a write
- **THEN** the error names the entry, and every earlier entry still reads
