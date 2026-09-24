## ADDED Requirements

### Requirement: Deposits and withdrawals are recorded
The journal SHALL record a deposit or a withdrawal built and its reply, each as a
versioned entry of the existing entry version. Neither answers an invoice, so
each SHALL be threaded under an id derived from the transfer's public bundle
hash, and a deposit's or withdrawal's whole life SHALL read as one thread. An
entry SHALL name the amount and, for a withdrawal, the leaf spent; it SHALL NOT
carry a key or a note's randomness.

#### Scenario: A deposit and a withdrawal, each one thread
- **WHEN** a deposit and a withdrawal are built and answered, and their entries written and read back
- **THEN** each reads as one thread of a build and a reply, the refusal reason is kept when refused, and no entry contains the wallet's keys

#### Scenario: Old entries still read
- **WHEN** a journal written before the four new kinds existed is read
- **THEN** every entry reads unchanged, because the entry version did not change
