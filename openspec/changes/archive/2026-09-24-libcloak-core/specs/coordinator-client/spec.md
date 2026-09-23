## Purpose

The wallet's side of tstokenlib's wallet-to-coordinator protocol, over a
transport the host supplies. It carries submissions out, matches replies to
them, and takes in the descriptor, the announcements and the block roots the
pool view folds.

## ADDED Requirements

### Requirement: A transport port, not a network
libcloak SHALL define the transport as a port carrying opaque frames: send a
frame to the pool and receive a reply, and read the pool's feed from a sequence
number. It SHALL NOT implement a network, and SHALL work against any
implementation, including a fake.

#### Scenario: The suite runs on a fake transport
- **WHEN** every scenario in this capability runs against an in-memory transport
- **THEN** all pass without a network

### Requirement: The descriptor comes first
The client SHALL read the pool's descriptor before anything else, take the
plan, the block size, the tokenId and the genesis header from it, and refuse to
submit or fold until it has one. A feed whose first entry is not a descriptor
SHALL be refused, naming what it found.

#### Scenario: Descriptor first
- **WHEN** a feed is read from the start
- **THEN** the first entry parses as a descriptor and the client is ready

#### Scenario: A feed that does not start with a descriptor
- **WHEN** the first feed entry is an announcement
- **THEN** the client refuses, naming the kind it found, and does not submit

### Requirement: Submissions and replies
The client SHALL encode a transfer as a `PoolSubmission`, send it, and match the
reply by the submission's id, refusing a reply whose id is not one it is waiting
for. A reply that does not arrive inside a configured timeout SHALL be reported
as unanswered, with the payment left awaiting rather than refused, because an
accepted submission may still be in a round.

#### Scenario: A reply matched by id
- **WHEN** two submissions are in flight and their replies arrive out of order
- **THEN** each is matched to its own submission

#### Scenario: A reply for an unknown id
- **WHEN** a reply names an id the client did not send
- **THEN** it is refused, naming the id, and no payment changes state

#### Scenario: No reply
- **WHEN** no reply arrives inside the timeout
- **THEN** the payment is reported unanswered and the note stays reserved

### Requirement: Announcements in order, with their block roots
The client SHALL read announcements in round order, refuse one whose number is
not the next it expects, and hand each round's block root to the pool view. It
SHALL detect an announcement that disagrees with a round the wallet already
holds and report it as a disagreement rather than folding it.

#### Scenario: Announcements in order
- **WHEN** the fixture's two announcements are read
- **THEN** both fold and the view reaches round 2

#### Scenario: A round out of order
- **WHEN** an announcement for round 4 arrives while the client expects 3
- **THEN** it is refused, naming both numbers, and nothing is folded

#### Scenario: A disagreeing announcement
- **WHEN** an announcement's header differs from the round the wallet already holds
- **THEN** it is reported as a disagreement and the view is unchanged

### Requirement: Catching up
The client SHALL be able to ask the pool for three things a wallet needs to
become current without reading the chain: **block roots** over a round range,
the **current frontier**, and a **head proof** (the tip round, its witness and
the witness's merkle proof), which is a standing payment proof without the note.
Each answer SHALL be checked as `pool-view` and `payments` check it, so the pool
is a convenient server and never a trusted one; a wallet MAY take any of the
three from anywhere else and reach the same verdict.

#### Scenario: A wallet with no state becomes current
- **WHEN** a client with no stored state asks for the frontier and a head proof on the fixture's chain
- **THEN** it verifies the frontier against the head proof's `cmRoot` and the view opens at the tip

#### Scenario: A wallet that fell behind
- **WHEN** a client holding a note at round 1 asks for block roots over rounds 2 to the tip
- **THEN** every root folds in order, the final fold matches the head proof's `cmRoot`, and its note's path is current

#### Scenario: The pool lies
- **WHEN** the pool answers with a frontier, a block root or a head proof that does not check out
- **THEN** the client refuses it naming the check that failed, keeps the state it had, and does not retry the same answer

### Requirement: A catch-up request says nothing about the wallet
A block-root request SHALL name a round range from a fixed set the descriptor
publishes (the pool's genesis, or a published checkpoint round), never a round
derived from what the wallet holds. Asking for "everything since round 4,117"
says the wallet was last current at 4,117, which over a few catch-ups is a
fingerprint; the fixed set makes every wallet's request one of a handful.

At 32 bytes a round this costs little: a year of a pool closing a round every ten
minutes is 52,560 rounds, about 1.68 MB, and a wallet with no notes does not need
the roots at all.

#### Scenario: Requests come from the published set
- **WHEN** a client catches up from any state against a recording transport
- **THEN** every block-root request names a range from the descriptor's published set

#### Scenario: Nothing wallet-derived is sent
- **WHEN** a full catch-up runs
- **THEN** no request names an address, a note, a leaf position, a txid or a round the wallet chose

### Requirement: Untrusted input
Every frame is outside input. The client SHALL bound a frame's size before
reading it (the protocol's own bounds), decode through `PoolMessage`, refuse an
unknown kind or version naming it, and treat a refusal as a named error rather
than an exception.

#### Scenario: Random frames
- **WHEN** 10,000 random and mutated frames arrive on the transport
- **THEN** every one is refused with a named reason, none throws an unnamed error, and the client stays usable

### Requirement: Privacy
The only thing the client sends is a submission the wallet built. It SHALL NOT
send a request naming an address, a note, a position, a txid or an outpoint, and
SHALL NOT ask the pool for anything about what the wallet holds.

#### Scenario: What is sent
- **WHEN** a full payment is made against a recording transport
- **THEN** the only frames sent are submissions, and the only frames read are the descriptor and feed entries every follower reads

### Requirement: Resources and failure behaviour
A send that fails SHALL be retried a configured number of times before it is an
error naming the transport's reason, and the client SHALL never block without a
bound. A transport failure SHALL leave the wallet's stored state unchanged, with
the payment recorded as unsent.

#### Scenario: The transport is down
- **WHEN** the transport fails every send
- **THEN** the client fails after the configured retries, names the reason, and the note is released
