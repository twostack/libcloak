## ADDED Requirements

### Requirement: Building a deposit
libcloak SHALL build the transfer backing a deposit through tstokenlib: two
dummy inputs, BSV brought in as a negative public amount, the depositor's own
note as output 1 under an address of the depositor's, and a zero-value note as
output 2. Because the covenant transaction that carries the money needs the
note's commitment and the transfer needs the covenant's outpoint, it SHALL be
built in two steps: the first proves the transfer and exposes the note's 32-byte
commitment and its opening; the second takes the covenant transaction, checks
that its covenant output locks exactly that commitment and that amount, and
yields a transfer naming the covenant's outpoint. It SHALL refuse an amount
below 1 or above what a note can hold, and an address that is not the
depositor's own, before any proof is computed.

#### Scenario: A deposit on the fixture's pool
- **WHEN** a deposit is proved at test parameters and backed by a covenant transaction built from its commitment
- **THEN** the transfer's own `refusal()` is null, `verifyProof` passes, output 1 is the depositor's note, and the opening and commitment the store will need are exposed

#### Scenario: The transfer's shape is checked before it is sent
- **WHEN** a deposit transfer is built
- **THEN** its own shape check passes with both inputs dummy, the asset BSV, and money coming in
- **AND** a transfer built with a real input beside a deposit is refused naming the rule

#### Scenario: A covenant that is not this deposit's
- **WHEN** the covenant transaction locks another commitment, another amount, or has no covenant at the covenant's output
- **THEN** it is refused naming the covenant and what differs, and no transfer is produced

#### Scenario: The depositor finds its note in the mined round
- **WHEN** the round carrying the deposit's receipt is read
- **THEN** the leaf is found by the deposit's commitment, and the note store takes the note on from the deposit's opening at that leaf

### Requirement: Building a withdrawal
Given a note to spend, an amount and a transparent pubkey hash, libcloak SHALL
build a transfer taking that amount of BSV out, carrying a withdrawal record
naming exactly that amount to that pubkey hash, with `outHash` committing to the
record, and change returning as a note to an address of the wallet's own. It
SHALL check, in order and before any proof is computed: the request (a 20-byte
pubkey hash, an amount of at least 1, a change address of the wallet's own); the
note (held by this store, not reserved or spent, BSV, and holding at least the
amount); the path (the view yields one at the pool's tip); and the anchor (the
path reaches the root the view holds).

#### Scenario: A withdrawal on the fixture's chain
- **WHEN** a wallet holding the fixture's round-1 note withdraws part of it
- **THEN** the transfer's own `refusal()` is null, `verifyProof` passes, the withdrawal record pays the amount to the pubkey hash given, and the change note is recoverable by the wallet

#### Scenario: The withdrawal and the public amount agree
- **WHEN** a withdrawal transfer is built
- **THEN** the amount its withdrawal record names equals the amount its proof takes out
- **AND** a transfer where they differ is refused naming both

#### Scenario: Withdrawing more than the note holds
- **WHEN** an amount above the chosen note's value is asked for
- **THEN** the build is refused naming the amount asked and the note's value, and no proof is computed

#### Scenario: A note already in flight
- **WHEN** the note is reserved by an earlier submission
- **THEN** the build is refused naming the note's state, before any proof is computed

### Requirement: Submitting a deposit or a withdrawal
libcloak SHALL submit a withdrawal as a payment is submitted: its note reserved
before the frame leaves the machine and released only when the answer says the
transfer is not in a round (refused, expired, or never sent). It SHALL submit a
deposit with its covenant transaction attached, and a deposit has no note to
reserve. Both SHALL keep the client's reply matching by id and its resend of the
same bytes under the same id.

#### Scenario: A withdrawal refused, and one accepted
- **WHEN** a withdrawal is refused by the coordinator, and then submitted again and accepted
- **THEN** its note is proven after the refusal and reserved after the acceptance, and a second submission of it never leaves the machine

#### Scenario: A withdrawal unanswered
- **WHEN** no reply to a withdrawal arrives inside the timeout
- **THEN** it is reported unanswered and its note stays reserved

#### Scenario: A deposit goes with its covenant
- **WHEN** a deposit is submitted
- **THEN** the submission carries the covenant transaction, and the coordinator's own intake accepts the deposit and a withdrawal built on the fixture's chain

### Requirement: Deposit and withdrawal input, privacy and cost
A covenant transaction handed to a deposit's second step SHALL be treated as
bytes this library did not build: every failure a named refusal, never an
exception. Neither builder SHALL make any request of anyone; a refusal SHALL
carry no key and no note randomness. The wallet's own work for either build,
excluding the spend proof, SHALL take under 200 ms at test parameters on one
core of an Apple M3 Pro, and a refusal that stops before the proof SHALL come
back in under 100 ms.

#### Scenario: Mutated covenant transactions
- **WHEN** 1,000 covenant transactions, each the real one with bytes mutated or truncated, are offered to a deposit's second step
- **THEN** every one either backs the deposit or is refused with a named reason, and none throws

#### Scenario: Nothing secret in a refusal
- **WHEN** every refusal the deposit and withdrawal builders produce in the suite is collected
- **THEN** none contains a run equal to the wallet's spending key, viewing keys, or a note's randomness

#### Scenario: Building inside the bound
- **WHEN** a deposit and a withdrawal are built against the fixture and their phases timed
- **THEN** each one's own work, outside the spend proof, is under 200 ms
