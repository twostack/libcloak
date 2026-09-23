## Purpose

A payment from one person to another, and the proof that it happened. The payer
builds a transfer against an invoice, submits it, and when the round is mined
sends the payee a payment proof. The payee checks that proof against headers it
holds itself and acknowledges. This is the capability the whole library exists
for: nobody has to look anything up, and nobody has to be believed.

## ADDED Requirements

### Requirement: Building a payment
Given an invoice and a note to spend, libcloak SHALL build a `ShieldedTransfer`
through tstokenlib: the payee's output note under the invoice's address, the
payer's change note under its own address, the bundle carrying both ciphertexts
and the payer's outgoing copy, and the spend proof against a path the pool view
says is current. It SHALL refuse to build when the note's value is below the
invoice's amount, when the invoice has expired, or when the view is too far
behind to spend, naming which.

#### Scenario: A payment on the fixture's chain
- **WHEN** a wallet holding the fixture's round-1 note pays an invoice for part of it
- **THEN** the transfer's own `refusal()` is null, `verifyProof` passes, and the change note is recoverable by the payer

#### Scenario: Not enough in the note
- **WHEN** the invoice asks for more than the note holds
- **THEN** the build is refused naming the amount and the note's value, and no proof is computed

#### Scenario: An expired invoice
- **WHEN** the invoice's expiry has passed
- **THEN** the build is refused naming the expiry, before any proof is computed

### Requirement: Submitting and the reply
libcloak SHALL submit a built transfer as a `PoolSubmission` through
`coordinator-client` and SHALL record the coordinator's reply against the
payment. A refusal SHALL be surfaced with the `RefusalReason` the protocol
defines and the payment left unpaid; an acceptance SHALL leave the payment
awaiting its round.

#### Scenario: Each of the twelve refusals
- **WHEN** the coordinator replies with each of the protocol's twelve refusal reasons in turn
- **THEN** the payment is left unpaid, the reason is recorded in the journal, and the note is not marked spent

#### Scenario: Accepted and awaiting
- **WHEN** the coordinator accepts a submission
- **THEN** the payment is awaiting its round and the note is reserved, so a second payment cannot spend it

### Requirement: A standing payment proof is self-contained
A **standing** payment proof SHALL carry everything a payee needs and nothing it
must look up: the round transaction, the witness transaction, the witness's
merkle proof and the hash of the block holding it, the payee's note opening
(value, rho, rcm, asset and the diversifier the invoice named), the note's leaf
position, and its Merkle path to that round's commitment root. It SHALL be a
versioned encoding with every length explicit, and an unknown version SHALL be
refused naming it.

Both transactions SHALL be carried whole. The payee computes each txid from the
bytes rather than taking one it was given, and the witness's txid is what its
merkle proof commits to, so there is no shorter form of it. This is why a
standing proof is dominated by bytes the payee hashes and never reads: the
witness is 577,843 B at test parameters and 2.2 to 2.5 MB at production, almost
all of it the PP1 unlock's proof, which the payee never verifies because the
chain already did.

#### Scenario: Nothing to look up
- **WHEN** a payment proof is checked against a recording header source
- **THEN** the only external call made is for the block header named inside the proof

#### Scenario: Size at test parameters
- **WHEN** a payment proof is built on the fixture's chain at test parameters
- **THEN** it encodes to under 1 MB and the size is recorded in the design record

### Requirement: A short payment proof for a payee that already follows the pool
A **short** payment proof SHALL carry only the note opening, the leaf position
and the Merkle path, against a round the payee has already folded and checked in
`pool-view`. A payee holding an authenticated commitment root for that round
needs nothing else: the path either reaches that root or it does not.

A payer MAY send a short proof only when the payee's invoice says it follows the
pool and names the last round it has folded; otherwise the payer SHALL send a
standing proof. A payee SHALL refuse a short proof for a round it has not folded,
naming the round and the last one it holds, and the payer SHALL then send the
standing form rather than treating the refusal as a failed payment.

The two forms give the same guarantee. The short one reuses the work the payee
did while following, and is about 1 KB against 0.72 MB at test parameters and
2.6 to 2.9 MB at production.

#### Scenario: A short proof into a folded round
- **WHEN** a payee that has folded the fixture's round 2 is given a short proof for a note in round 2
- **THEN** it is accepted, reports the value, and the payee made no call to its header source

#### Scenario: A short proof for a round not folded
- **WHEN** a payee that has folded to round 1 is given a short proof for a note in round 2
- **THEN** it is refused, naming round 2 and round 1, and the payment is left unproven rather than failed

#### Scenario: The payer falls back
- **WHEN** a payer receives that refusal
- **THEN** it builds and sends the standing proof for the same payment, which the payee accepts

#### Scenario: Size of the short form
- **WHEN** a short proof is built on the fixture's chain
- **THEN** it encodes to under 4 KB, and the size is recorded in the design record

### Requirement: A short proof is not a weaker proof
A payee SHALL apply the same commitment and path checks to a short proof as to a
standing one, against the commitment root its own fold produced. It SHALL NOT
accept a commitment root supplied inside a short proof, because that root is the
one thing the short form does not carry evidence for.

#### Scenario: A short proof naming its own root
- **WHEN** a short proof carries a commitment root
- **THEN** it is refused as malformed, naming the field, rather than that root being used

### Requirement: What a payee checks
On a payment proof the payee SHALL check, in this order and stopping at the
first failure: the encoding and its bounds; that the witness is in a block the
header source vouches for, by its merkle proof; that the witness spends the
round's PP1 and PP2; that the PP1 carries the pool's tokenId from the
descriptor; that the round's pool header parses and its `cmRoot` is the one the
path leads to; that the opening's commitment equals `PoolHash.commit` over the
payee's own `pk_d` for the invoice's diversifier; and that the Merkle path takes
that commitment to the round's `cmRoot` at the stated position. A proof that
passes every check SHALL be reported paid, with the value and the round.

#### Scenario: A good payment is accepted
- **WHEN** the payee checks a proof for a payment made to its own invoice on the fixture's chain
- **THEN** every check passes and the payment is reported paid with the invoice's amount

#### Scenario: A note that is not the payee's
- **WHEN** the opening's commitment does not open under the payee's `pk_d`
- **THEN** the check fails at the commitment step, naming it, and the earlier steps are not reported as proof of anything

#### Scenario: A round with a forged lineage
- **WHEN** the payee is given a proof whose round carries the pool's tokenId but was not built by the pool
- **THEN** the check fails, naming the step that caught it

#### Scenario: A path to another round
- **WHEN** the Merkle path leads to a root that is not the round's `cmRoot`
- **THEN** the check fails naming both roots

### Requirement: No proof verification is required of a payee
A payee SHALL NOT verify the round's STARK proof. The round was mined, which
means the chain ran the pool's verifier script over it; the payee's evidence is
that the witness is buried in a block it accepts. The checks above SHALL
therefore use hashing, parsing and script reading only.

#### Scenario: Checking is cheap
- **WHEN** a payment proof is checked at test parameters
- **THEN** it completes in under 100 ms on one core of an Apple M3 Pro, and the measurement is recorded in the design record

### Requirement: Acknowledgement
A payee that has checked a proof SHALL be able to produce an acknowledgement
naming the invoice, the round and the value, signed under the key the invoice
was issued from, so the payer holds evidence that the consideration was
delivered against a payment the payee accepted. An acknowledgement SHALL be
checkable by the payer against the invoice alone.

#### Scenario: An acknowledgement checks against its invoice
- **WHEN** a payee acknowledges a checked payment
- **THEN** the payer's check of that acknowledgement against the invoice it issued passes

#### Scenario: An acknowledgement for another invoice
- **WHEN** an acknowledgement names an invoice the payer did not issue
- **THEN** the payer's check fails, naming the invoice

### Requirement: Untrusted input
A payment proof and an acknowledgement arrive from another person and are
hostile until checked. Every length SHALL be bounded before allocation, the
whole proof SHALL be bounded (default 8 MB, above the production estimate of
about 3 MB), transactions SHALL be parsed as `pool-ledger` parses them, and
every failure SHALL be a named refusal rather than an exception.

#### Scenario: Mutated payment proofs
- **WHEN** 10,000 randomly mutated and truncated payment proofs are checked
- **THEN** every one is refused with a named reason, none throws an unnamed error, and none is reported paid

#### Scenario: A proof that claims a huge length
- **WHEN** a proof's declared transaction length exceeds the bound
- **THEN** it is refused before allocation, naming the field and the bound

### Requirement: Secrets and privacy
A payment proof SHALL carry no key: not the payee's spending key, not its
incoming viewing key, not the payer's. It reveals the payee's note in that round
to whoever holds the proof, which is the payer, who already knows it. libcloak
SHALL NOT put a spending key, a seed or a note's `rcm` for any note other than
the one being proved into a proof, an acknowledgement or an error message.

#### Scenario: Nothing secret in a proof
- **WHEN** a payment proof's bytes are searched
- **THEN** they contain no run equal to the payer's or the payee's spending key, viewing keys, or seed

#### Scenario: Nothing secret in a refusal
- **WHEN** every named refusal this capability can produce is collected
- **THEN** none contains a key, a seed or a note's randomness

### Requirement: Determinism and failure behaviour
A payment proof built twice from the same round, note and path SHALL be
byte-identical. A failed check SHALL leave the payee's stored state exactly as
it was, with the payment recorded as unproven and the reason kept, so a retry
with a corrected proof is possible without repairing anything.

#### Scenario: Two builds agree
- **WHEN** the same payment proof is built twice
- **THEN** the two encodings are identical

#### Scenario: State after a failed check
- **WHEN** a check fails at any step
- **THEN** the note is not added to the wallet, the payment is recorded unproven with the reason, and no file is left half written
