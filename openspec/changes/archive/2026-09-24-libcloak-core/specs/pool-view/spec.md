## Purpose

The wallet's picture of the pool's commitment tree: enough of it to keep every
unspent note's Merkle path current, and no more. It follows one 32-byte block
root a round, checks what it folds against a header it proved off the chain
itself, and never asks a question that names the wallet.

## ADDED Requirements

### Requirement: The pool's shape comes from its descriptor
The view SHALL take the pool's layout from the descriptor `pool-protocol`
defines: the plan, the genesis, the pool's tokenId, its genesis header, and the
number of leaves a round appends. It SHALL refuse a descriptor whose leaf count
is not a power of two, naming the count, because the view's whole structure
rests on round N owning the aligned subtree at level log2(count).

#### Scenario: The test pool's descriptor
- **WHEN** a view opens on the descriptor of tstokenlib's fixture pool (4 transfers a round, 1 subtree, 32 leaves)
- **THEN** it reports a block level of 5 and 27 upper levels, and is ready to fold

#### Scenario: A leaf count that is not a power of two
- **WHEN** a descriptor states 608 leaves a round
- **THEN** the view refuses to open, naming 608, and no state is written

#### Scenario: A pool that changed its block size
- **WHEN** a descriptor states a leaf count different from the one the view's stored state was built under
- **THEN** the view refuses to open, naming both counts, rather than folding into a tree that is no longer aligned

### Requirement: Following costs one block root a round
The view SHALL keep its paths current from one block root per round: 32 bytes,
the root of the aligned subtree that round owns. It SHALL NOT require a round's
commitments, transfers, bundles or proofs in order to stay current, and the cost
SHALL NOT grow with the number of notes the wallet holds.

#### Scenario: Thirty-two bytes a round
- **WHEN** a view holding 8 unspent notes is advanced by one round
- **THEN** the only round-derived input it consumed is 32 bytes

#### Scenario: Notes do not multiply the feed
- **WHEN** a view holding 1 note and a view holding 100 notes are each advanced by 10 rounds
- **THEN** both consumed the same 320 bytes

### Requirement: A fold is checked, never trusted
After folding a block root the view SHALL compute the tree's root and compare it
with the `cmRoot` of the pool header in a round the wallet has proven against a
block header it holds (`chain-headers`). A fold that does not match SHALL leave
the view unchanged and be reported, naming the round; the wallet SHALL NOT build
a spend from an unchecked fold. This is what makes it safe to accept block roots
from anyone, the coordinator included.

#### Scenario: A wrong block root
- **WHEN** a block root with one byte changed is folded
- **THEN** the fold is refused naming the round, and the view still reports the paths it had before

#### Scenario: The fixture's two rounds
- **WHEN** the fixture's round 1 and round 2 block roots are folded in order
- **THEN** each fold matches that round's `cmRoot`, and a note's maintained path equals `ShieldedLedger.path` for the same position

### Requirement: Rounds arrive in order, with no gaps
The view SHALL accept block roots only in round order starting from the round
after the one it holds, and SHALL refuse a root for any other round, naming both
numbers. A fold is only correct if it is complete, so a skipped round is an
error and not something to paper over.

#### Scenario: A skipped round
- **WHEN** a view at round 7 is given the block root for round 9
- **THEN** it refuses naming 8 and 9, and remains at round 7

#### Scenario: Catching up
- **WHEN** a view at round 7 is given the roots for rounds 8, 9 and 10 in order
- **THEN** it reaches round 10 and every unspent note's path is current

### Requirement: What a note keeps
For each unspent note the view SHALL keep the note's leaf position, the siblings
below the block level (frozen when the note's own round was mined, and never
recomputed afterwards) and the siblings above it (folded forward each round).
The path it yields SHALL be the one `PoolSpendAir` accepts: `depth` siblings,
leaf level first.

#### Scenario: The lower siblings never change
- **WHEN** a note received in the fixture's round 1 is carried forward through round 2
- **THEN** its siblings below the block level are byte-identical before and after

#### Scenario: A maintained path against a built tree
- **WHEN** a tree of 1,000 blocks of 512 leaves is built directly and a view folds the same 1,000 block roots
- **THEN** the view's path for a leaf in block 3 equals `NoteCommitmentTree.path` for that position

### Requirement: Spending needs a root the pool still accepts
The view SHALL report, for each note, how many rounds are left before its anchor
leaves the pool's ring (`PoolHeader.ringEntries`, 4), and SHALL refuse to yield a
path for a spend when the view is more than that many rounds behind the pool's
tip, naming how far behind it is. Being behind is a reason to catch up, never a
reason to build a proof that will be refused.

#### Scenario: Four rounds of slack
- **WHEN** a view is current with the tip
- **THEN** it reports 4 rounds left for a note whose path it is maintaining

#### Scenario: Too far behind to spend
- **WHEN** a view is 5 rounds behind the tip
- **THEN** a request for a spend path is refused, naming 5, and the view says what it needs to catch up

### Requirement: Nothing is asked that names the wallet
The view SHALL make no request of its own. It is advanced by block roots handed
to it, which are the same bytes for every wallet following the pool. It SHALL
NOT request a path, a position, a note or a round by any identifier derived from
what the wallet holds.

#### Scenario: Advancing makes no requests
- **WHEN** a view is advanced through 10 rounds with a transport port that records every call
- **THEN** no call was made

### Requirement: Idle when there is nothing to keep fresh
A view holding no unspent note SHALL be allowed to stop folding, and SHALL
resume from the path delivered with the wallet's next payment rather than from
the rounds it skipped. A wallet with no money has nothing whose freshness
matters.

#### Scenario: Resuming from a payment
- **WHEN** a view that stopped at round 4 is given a verified path for a note received in round 9
- **THEN** it resumes at round 9 without the roots for rounds 5 to 8

### Requirement: Joining a pool from a checkpoint
A view MAY start from a **checkpoint** rather than from the pool's genesis: the
upper frontier as of round N, together with a standing payment proof or head
proof for round N. It SHALL verify the checkpoint by computing the tree's root
from the frontier and requiring it to equal the `cmRoot` of that round's proven
header, and SHALL refuse a frontier that does not, naming the round. A frontier
that reproduces a proven root is authentic by collision resistance, so the
checkpoint needs no signature and its server needs no trust.

#### Scenario: A wallet joins at the head
- **WHEN** a view with no state is given the frontier at the fixture's round 2 and a head proof for round 2
- **THEN** the computed root equals round 2's `cmRoot`, the view opens at round 2, and it never reads round 1

#### Scenario: A frontier that does not reproduce the root
- **WHEN** one node of the frontier is changed
- **THEN** the checkpoint is refused, naming the round, and the view stays empty

### Requirement: What a checkpoint does and does not replace
A checkpoint gives a view an authenticated root and lets it follow forward from
that round. It SHALL NOT be used to bring an existing note's path up to date: a
note's upper siblings follow from the block roots appended since its round, and
the frontier alone does not contain them. A view holding an unspent note
therefore SHALL fold every block root from that note's round onward, and SHALL
refuse to yield a spend path for a note whose rounds it skipped, naming the first
round it is missing.

This is the difference between the two kinds of wallet the pool has: one with no
notes joins for 736 bytes and a head proof, and one holding notes pays 32 bytes a
round for as long as it holds them.

#### Scenario: A note across a checkpoint
- **WHEN** a view takes a checkpoint at round 2 and is then asked for a spend path for a note received in round 1
- **THEN** it refuses, naming round 2 as the first round it folded, rather than yielding a path it cannot have

#### Scenario: A wallet with no notes rejoins cheaply
- **WHEN** a view holding no unspent note takes a fresh checkpoint
- **THEN** it is current, and it consumed the frontier and one head proof rather than the rounds it missed

### Requirement: Untrusted input
Every block root and every path handed to the view is outside input: a root SHALL
be refused unless it is exactly 32 bytes of lanes inside the field, a path unless
it has `PoolSpendAir.depth` siblings of the right width, and a position unless it
is inside the tree. Each refusal SHALL name the field and the reason, and SHALL
leave the view unchanged.

#### Scenario: Mutated input
- **WHEN** 10,000 randomly mutated block roots, paths and positions are handed to a view
- **THEN** every one is either folded and checked or refused with a named reason, and none throws an unnamed error

### Requirement: Determinism and compatibility
Two views advanced through the same rounds from the same state SHALL hold
byte-identical state and yield byte-identical paths. The stored state SHALL be
versioned, and a state of an unknown version SHALL be refused naming the version.

#### Scenario: Two views agree
- **WHEN** two views are advanced through the fixture's rounds in the same order
- **THEN** their stored state bytes are identical

#### Scenario: Unknown state version
- **WHEN** a stored view state's version byte is not the one this library writes
- **THEN** opening it is refused, naming the version

### Requirement: Resources
Folding one round SHALL cost work proportional to the number of upper levels
times the notes held, and not to the size of the tree. A view holding 100 unspent
notes SHALL occupy under 200 KB of stored state, and catching up 1,000 rounds
holding 8 unspent notes SHALL take under 2 s on one core of an Apple M3 Pro.

#### Scenario: Catch-up cost
- **WHEN** a view holding 8 notes folds 1,000 block roots
- **THEN** it finishes in under 2 s and the measurement is recorded in the design record

#### Scenario: State size
- **WHEN** a view holds 100 unspent notes
- **THEN** its stored state is under 200 KB

### Requirement: Failure behaviour
A refused fold, a refused path and a failed write SHALL each leave the view at
the last round it checked, with its stored state whole. A state file written
partially SHALL be refused at the next open rather than read, naming the file.

#### Scenario: A state file cut short
- **WHEN** a stored view state is truncated
- **THEN** the next open refuses it, naming the file, and nothing is folded
