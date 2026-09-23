## Purpose

The notes the wallet holds, what state each is in, the balance a person reads,
and which note a payment spends. It is the wallet's own bookkeeping: no note in
it was found by looking, every one arrived with a payment proof or was created
as the payer's own change.

## ADDED Requirements

### Requirement: A note's states
Each note SHALL be in exactly one state: **proven** (a payment proof checked out,
or the wallet's own change from a round it has seen), **reserved** (a submission
spending it has been accepted and its round is not yet mined), or **spent** (its
nullifier is in a round the wallet has seen). The store SHALL record for each
note its value, `rho`, `rcm`, asset, diversifier, leaf position and the round it
was created in.

#### Scenario: A note through its states
- **WHEN** a note is proven, then spent in an accepted submission, then its round is seen
- **THEN** it reports proven, then reserved, then spent, and never goes backwards

#### Scenario: A refused submission releases the note
- **WHEN** a submission spending a reserved note is refused
- **THEN** the note returns to proven and is spendable again

### Requirement: One note, one payment at a time
The store SHALL refuse to reserve a note that is already reserved or spent,
naming the note's position and its state, so two payments cannot be built
against the same note.

#### Scenario: A second payment on the same note
- **WHEN** a payment is built against a note already reserved
- **THEN** it is refused naming the position and the state, and no proof is computed

### Requirement: Balance lines a person can read
The store SHALL report the balance as separate lines, not one number:
**spendable** (proven notes whose paths the view can still anchor), **reserved**
(in flight), and **stale** (proven notes the view is too far behind to anchor,
with how far behind it is). A single total would hide the only two things that
stop a payment being made.

#### Scenario: A stale line
- **WHEN** the pool view is 5 rounds behind the tip and the wallet holds one proven note
- **THEN** the balance reports 0 spendable and that note as stale, naming 5

### Requirement: Choosing what to spend
Given an amount, the store SHALL choose a spendable note by a stated,
deterministic rule and SHALL report which it chose, refusing with the largest
spendable value when no single note covers the amount. The pool's transfer
spends at most two notes, so the rule SHALL NOT assume it can gather many.

#### Scenario: The same choice twice
- **WHEN** the same amount is requested twice against the same store
- **THEN** the same note is chosen both times

#### Scenario: No note covers it
- **WHEN** the amount exceeds every spendable note
- **THEN** the request is refused, naming the largest spendable value

### Requirement: Nullifiers stay inside
The store SHALL compute a note's nullifier with the wallet's `nk` only when it
needs to recognise the note as spent in a round it already holds, and SHALL NOT
send a nullifier anywhere except inside a transfer the wallet is submitting.

#### Scenario: Nullifiers are not published
- **WHEN** every message this library sends is collected
- **THEN** the only nullifiers in them are those inside a submitted transfer's own statement

### Requirement: Untrusted input, determinism and compatibility
A note added from a payment proof SHALL be refused unless the proof checked out
in `payments`. The stored form SHALL be versioned, an unknown version refused
naming it, and two stores that took the same notes in the same order SHALL hold
byte-identical bytes.

#### Scenario: A note without a checked proof
- **WHEN** a note is offered to the store without a checked proof
- **THEN** it is refused, and the store is unchanged

#### Scenario: Two stores agree
- **WHEN** two stores take the fixture's notes in the same order
- **THEN** their stored bytes are identical

### Requirement: Resources and failure behaviour
The store SHALL hold 10,000 notes in under 4 MB and answer a balance in under
10 ms on one core of an Apple M3 Pro. A failed write SHALL leave the previous
state whole, and a truncated file SHALL be refused at the next open naming the
file.

#### Scenario: Ten thousand notes
- **WHEN** a store holds 10,000 notes
- **THEN** it occupies under 4 MB and answers a balance in under 10 ms

#### Scenario: A truncated store
- **WHEN** the stored file is cut short
- **THEN** the next open refuses it, naming the file
