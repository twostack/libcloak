import 'dart:async';
import 'dart:math';

import 'package:dartsv/dartsv.dart' show Transaction;
import 'package:tstokenlib/tstokenlib.dart';

import '../headers/merkle_membership.dart';
import '../notes/note.dart';
import '../notes/note_store.dart';
import '../pay/builder.dart';
import '../pay/checker.dart';
import '../pay/onramp.dart';
import '../pool/descriptor.dart';
import '../pool/frontier.dart';
import '../pool/pool_view.dart';
import '../refusal.dart';
import 'transport.dart';

/// Where a submission ended up.
///
/// The five states are not five shades of failure: they are the answer to one
/// question, **is this transfer in a round or not**, and the wallet's note
/// follows it. A note is released only where the wallet knows the transfer is
/// not in a round, which is why a timeout and a reply the client could not
/// attribute both leave it reserved. Releasing a note on a maybe is how a
/// wallet double-spends itself.
enum Submitted {
  /// The coordinator took it, for the round it named. The note is reserved.
  accepted,

  /// The coordinator refused it, with one of the protocol's twelve reasons.
  /// The note is released and the payment is unpaid.
  refused,

  /// It sat in the coordinator's inbox until it was too old. The note is
  /// released and the payment is unpaid.
  expired,

  /// No answer this client could attribute to it arrived. The note stays
  /// reserved: the transfer may be in a round.
  unanswered,

  /// Every attempt to send it failed. The note is released, because it was
  /// never sent.
  unsent,
}

/// What came of submitting a transfer.
///
/// [refusal] is the named reason, for anything but an acceptance, and for a
/// coordinator's refusal its step is the protocol's own [RefusalReason] name —
/// `anchor`, `nullifierSpent`, `proof` and the rest — so a journal records the
/// twelve reasons under the names the protocol defines rather than under
/// twelve sentences of this library's own invention.
class SubmissionOutcome {
  final Submitted outcome;

  /// The submission id, which is what a resend uses: the same id, so a
  /// coordinator that did take the first copy can tell it is the same one.
  final List<int> id;

  /// The round the coordinator is holding it for, when accepted.
  final int? round;

  /// The protocol's reason, when refused.
  final RefusalReason? reason;

  /// The coordinator's own sentence, when refused or expired.
  final String? sentence;

  final Refusal? refusal;

  const SubmissionOutcome._(this.outcome, this.id,
      {this.round, this.reason, this.sentence, this.refusal});

  bool get isAccepted => outcome == Submitted.accepted;

  /// Whether the wallet knows this transfer is not in a round. The note's
  /// state follows exactly this.
  bool get isSettled => outcome == Submitted.refused ||
      outcome == Submitted.expired ||
      outcome == Submitted.unsent;

  @override
  String toString() => switch (outcome) {
        Submitted.accepted => 'accepted into round $round',
        Submitted.refused => 'refused (${reason!.name}): $sentence',
        Submitted.expired => 'expired: $sentence',
        Submitted.unanswered => 'unanswered: ${refusal!.reason}',
        Submitted.unsent => 'unsent: ${refusal!.reason}',
      };
}

/// An announcement that contradicts one the wallet already has.
///
/// This is the one thing a following wallet can catch without proving
/// anything off the chain: the pool told it two different stories about the
/// same round. It is reported rather than folded, and it is not a refusal of
/// a frame — the frame was perfectly well formed.
class Disagreement {
  final int round;
  final String what;
  const Disagreement(this.round, this.what);

  @override
  String toString() => 'round $round: $what';
}

/// A run of block roots the pool serves, in round order.
class BlockRootRun {
  /// The first round served.
  final int from;

  /// The roots, round [from] first.
  final List<List<int>> roots;

  BlockRootRun(this.from, List<List<int>> roots)
      : roots = List<List<int>>.unmodifiable([for (final r in roots) List<int>.unmodifiable(r)]);

  /// The last round served.
  int get to => from + roots.length - 1;

  /// Round [round]'s root, which the caller has established is in this run.
  List<int> operator [](int round) => roots[round - from];
}

/// How far a read of the pool's feed got.
///
/// A read is reported rather than thrown, because a feed that stops being
/// readable half way through still folded the rounds before that, and a wallet
/// that threw the lot away would ask for them all again.
class FeedProgress {
  /// Feed entries read, including ones that folded nothing.
  final int entries;

  /// Rounds folded into the view.
  final int folded;

  /// The sequence the next read starts at.
  final int nextSequence;

  /// The refusal that stopped the read, or null when it ran to the end of the
  /// feed.
  final Refusal? stopped;

  /// The contradiction that stopped it, when that is what it was.
  final Disagreement? disagreement;

  const FeedProgress(
      {required this.entries,
      required this.folded,
      required this.nextSequence,
      this.stopped,
      this.disagreement});

  bool get ok => stopped == null;

  @override
  String toString() => 'read $entries, folded $folded, next $nextSequence'
      '${stopped == null ? '' : ', stopped at $stopped'}';
}

/// The wallet's side of the pool's protocol.
///
/// It does four things and no more: it reads the descriptor, it sends
/// submissions and matches their replies, it folds the feed's announcements
/// into a [PoolView], and it asks the three catch-up questions. Everything it
/// reads is bounded and decoded as hostile input, and everything it sends is
/// either a transfer the wallet built or a request from a fixed published set.
///
/// **It asks the pool nothing about the wallet.** There is no method here that
/// takes an address, a note, a leaf position or a txid, so there is no way to
/// use this class to look one up — which is the point, because a wallet that
/// can ask "what is mine" has already told the answer to whoever it asked.
///
/// **The pool is a server, not an authority.** A block root folds because the
/// arithmetic works, and the arithmetic becomes evidence only when a root the
/// wallet proved off the chain agrees with it. An announcement's pool header
/// is a claim; this client uses it to catch the pool contradicting itself, and
/// never as the check that makes a fold count. Those two numbers stay apart in
/// [PoolView.round] and [PoolView.checkedTo] on purpose.
class CoordinatorClient {
  /// How long a reply has to arrive. A submission that is not answered in this
  /// time is unanswered, which is not refused.
  static const defaultTimeout = Duration(seconds: 30);

  /// How many times a frame is sent before the send is an error. The same
  /// bytes and the same id each time.
  static const defaultAttempts = 3;

  /// Rounds whose announcements are remembered, for catching the pool telling
  /// two stories about one round. Bounded because a wallet that remembered
  /// every round would grow without limit for a check that only matters near
  /// the tip.
  static const defaultRemember = 64;

  final Transport transport;

  /// The pool's descriptor, read from the head of its feed.
  final PoolDescriptor pool;

  /// The shape every path the wallet keeps rests on.
  final PoolShape shape;

  final Duration timeout;
  final int sendAttempts;
  final int remember;

  int _nextSequence;

  /// Submissions in flight, by id. A reply is matched against this and not
  /// against whichever call happened to get the bytes back, so two
  /// submissions whose replies cross still each get their own.
  final Map<String, Completer<PoolReply>> _pending = {};

  /// What the pool has said about each recent round: the header's bytes and
  /// the block root.
  final Map<int, (List<int>, List<int>)> _seen = {};

  CoordinatorClient._(this.transport, this.pool, this.shape, this._nextSequence,
      {required this.timeout, required this.sendAttempts, required this.remember});

  /// Opens a client on [transport] by reading the pool's descriptor, which is
  /// the first thing in its feed and has to be: the block size, the tokenId
  /// and the genesis header all come from it, and until the client has them it
  /// cannot fold a round or tell whether one is this pool's.
  ///
  /// A feed that does not begin with a descriptor is refused naming what it
  /// found, and no client is made — so there is no state in which this class
  /// exists without one.
  static Future<(CoordinatorClient?, Refusal?)> open(
    Transport transport, {
    Duration timeout = defaultTimeout,
    int sendAttempts = defaultAttempts,
    int remember = defaultRemember,
  }) async {
    if (sendAttempts < 1) return (null, Refusal('sendAttempts', 'a frame is sent at least once, not $sendAttempts times'));
    final List<FeedEntry> head;
    try {
      head = await transport.readFeed(0, max: 1);
    } on TransportFailure catch (e) {
      return (null, Refusal('transport', 'the pool\'s feed could not be read from the start: ${e.reason}'));
    }
    if (head.isEmpty) {
      return (null, const Refusal('descriptor', 'the pool\'s feed is empty, so it has published no descriptor'));
    }
    final entry = head.first;
    final (msg, why) = _decode(entry.bytes, max: PoolMessage.maxOther, what: 'a feed entry');
    if (msg == null) return (null, why);
    if (msg is! PoolDescriptor) {
      return (
        null,
        Refusal('descriptor',
            'this feed begins with ${msg.kind.name}, and a pool\'s feed begins with its descriptor; until there is '
            'one this client has no block size, no tokenId and no genesis header, so it submits nothing and folds '
            'nothing')
      );
    }
    final (shape, whyShape) = PoolShape.forPool(msg);
    if (shape == null) return (null, whyShape);
    return (
      CoordinatorClient._(transport, msg, shape, entry.sequence + 1,
          timeout: timeout, sendAttempts: sendAttempts, remember: remember),
      null
    );
  }

  /// The sequence the next feed read starts at.
  int get nextSequence => _nextSequence;

  /// Submissions this client is waiting for replies to.
  int get inFlight => _pending.length;

  // ---- submissions ----

  /// Sends [submission] and returns the reply matched to **its own id**.
  ///
  /// Nothing about a note happens here; [submit] is the method that moves one.
  /// A send that fails is retried [sendAttempts] times with the same bytes and
  /// the same id, so a coordinator that took the first copy can recognise the
  /// second as the same submission rather than as a second spend.
  Future<SubmissionOutcome> send(PoolSubmission submission) async {
    final key = _key(submission.id);
    if (_pending.containsKey(key)) {
      return SubmissionOutcome._(Submitted.unsent, submission.id,
          refusal: Refusal('id',
              'submission ${shortHex(submission.id)} is already in flight; a resend uses the same call, not a '
              'second one'));
    }
    final waiting = Completer<PoolReply>();
    _pending[key] = waiting;
    try {
      final frame = submission.encode();
      Refusal? failed;
      for (int attempt = 1; attempt <= sendAttempts; attempt++) {
        final List<int> bytes;
        try {
          bytes = await _request(frame);
        } on TransportFailure catch (e) {
          failed = Refusal('transport',
              'attempt $attempt of $sendAttempts to send submission ${shortHex(submission.id)} failed: ${e.reason}');
          continue;
        } on TimeoutException {
          return SubmissionOutcome._(Submitted.unanswered, submission.id,
              refusal: Refusal('reply',
                  'the transport did not come back on submission ${shortHex(submission.id)} within '
                  '${_hardDeadline.inMilliseconds}ms; that is not a refusal — an accepted submission may still '
                  'be in a round, so nothing here says the payment failed'));
        }
        failed = null;
        final why = _route(bytes);
        // a frame that did not decode, or that answered an id nobody is
        // waiting for, is not retried: the same answer would come back
        if (why != null) return SubmissionOutcome._(Submitted.unanswered, submission.id, refusal: why);
        break;
      }
      if (failed != null) {
        return SubmissionOutcome._(Submitted.unsent, submission.id,
            refusal: Refusal('transport',
                '${failed.reason}; submission ${shortHex(submission.id)} was never sent, so nothing of it is in a '
                'round'));
      }
      final PoolReply reply;
      try {
        reply = await waiting.future.timeout(timeout);
      } on TimeoutException {
        return SubmissionOutcome._(Submitted.unanswered, submission.id,
            refusal: Refusal('reply',
                'the pool did not answer submission ${shortHex(submission.id)} within '
                '${timeout.inMilliseconds}ms; that is not a refusal — an accepted submission may still be in a '
                'round, so nothing here says the payment failed'));
      }
      return switch (reply.outcome) {
        ReplyOutcome.accepted =>
          SubmissionOutcome._(Submitted.accepted, submission.id, round: reply.round),
        ReplyOutcome.refused => SubmissionOutcome._(Submitted.refused, submission.id,
            reason: reply.reason,
            sentence: reply.sentence,
            refusal: Refusal(reply.reason!.name, reply.sentence ?? 'the pool gave no sentence')),
        ReplyOutcome.expired => SubmissionOutcome._(Submitted.expired, submission.id,
            sentence: reply.sentence,
            refusal: Refusal('expired',
                reply.sentence ?? 'the pool held this submission until it was too old to put in a round')),
      };
    } finally {
      _pending.remove(key);
    }
  }

  /// Submits [payment], moving its note with the answer.
  ///
  /// The note is reserved **before** the frame goes out, and released again
  /// only where the answer says the transfer is not in a round. So the window
  /// in which a second payment could pick the same note is closed before
  /// anything leaves the machine, and a coordinator that goes quiet leaves the
  /// note reserved rather than free.
  Future<SubmissionOutcome> submit(
    BuiltPayment payment, {
    required NoteStore notes,
    Transaction? depositTx,
    Random? rng,
  }) =>
      _spending(payment.transfer, payment.spent, notes: notes, depositTx: depositTx, rng: rng);

  /// Submits [withdrawal], moving its note with the answer exactly as [submit]
  /// moves a payment's: reserved before the frame goes out, released only
  /// where the answer says the transfer is not in a round.
  Future<SubmissionOutcome> submitWithdrawal(
    BuiltWithdrawal withdrawal, {
    required NoteStore notes,
    Random? rng,
  }) =>
      _spending(withdrawal.transfer, withdrawal.spent, notes: notes, rng: rng);

  /// Submits [deposit] with its covenant transaction attached.
  ///
  /// A deposit spends no note, so there is nothing to reserve and nothing to
  /// release; what stops the same covenant being backed twice is the
  /// coordinator, which refuses a second pending transfer naming it
  /// (`depositPending`). The covenant goes with the transfer because the
  /// coordinator cannot take a deposit in without it, and it is public on the
  /// chain in any case.
  Future<SubmissionOutcome> submitDeposit(BuiltDeposit deposit, {Random? rng}) async {
    final PoolSubmission submission;
    try {
      submission = PoolSubmission.of(deposit.transfer, pool.spendP, depositTx: deposit.covenant, rng: rng);
    } on ArgumentError catch (e) {
      return SubmissionOutcome._(Submitted.unsent, const [], refusal: Refusal('submission', '${e.message}'));
    }
    return send(submission);
  }

  /// The one path a transfer that spends a note takes: reserve, send, and
  /// release only when the answer settles it. Written once so a payment and a
  /// withdrawal cannot drift apart on the rule a wallet double-spends itself
  /// by breaking.
  Future<SubmissionOutcome> _spending(
    ShieldedTransfer transfer,
    HeldNote spent, {
    required NoteStore notes,
    Transaction? depositTx,
    Random? rng,
  }) async {
    final PoolSubmission submission;
    try {
      submission = PoolSubmission.of(transfer, pool.spendP, depositTx: depositTx, rng: rng);
    } on ArgumentError catch (e) {
      return SubmissionOutcome._(Submitted.unsent, const [], refusal: Refusal('submission', '${e.message}'));
    }
    final whyReserve = notes.reserve(spent);
    if (whyReserve != null) {
      return SubmissionOutcome._(Submitted.unsent, submission.id, refusal: whyReserve);
    }
    final outcome = await send(submission);
    if (outcome.isSettled) notes.release(spent);
    return outcome;
  }

  /// How long the client waits for a transport that is not honouring the
  /// deadline it was given. A transport is somebody else's code, so a wallet
  /// that only ever waited as long as the transport felt like is a wallet a
  /// transport can hang.
  Duration get _hardDeadline => timeout * 2;

  Future<List<int>> _request(List<int> frame) =>
      transport.request(frame, timeout: timeout).timeout(_hardDeadline);

  Refusal? _route(List<int> bytes) {
    final (msg, why) = _decode(bytes, max: PoolMessage.maxOther, what: 'a reply');
    if (msg == null) return why;
    if (msg is! PoolReply) {
      return Refusal('reply', 'the pool answered a submission with ${msg.kind.name}, which is not a reply');
    }
    final waiting = _pending[_key(msg.id)];
    if (waiting == null) {
      return Refusal('id',
          'this reply is for submission ${shortHex(msg.id)}, which is not one this client is waiting for; nothing '
          'was recorded against any payment');
    }
    if (!waiting.isCompleted) waiting.complete(msg);
    return null;
  }

  // ---- the feed ----

  /// Reads the feed from where it left off, folding each announcement's block
  /// root into [view].
  ///
  /// Rounds go in order and none is skipped, because the rounds between a gap
  /// and here hold the leaves the later ones sit on. A round the view has
  /// already folded is history: it is checked against what the pool said the
  /// first time and otherwise passed over, so a wallet that joined at a
  /// checkpoint can read a feed that starts before it.
  ///
  /// The announcement's own pool header is used for one thing only — a round
  /// whose block root does not fold to the commitment root the same message
  /// claims is a pool contradicting itself, and it is caught **before**
  /// anything is folded. It is not used to mark the fold checked; only a round
  /// proved off the chain does that.
  Future<FeedProgress> follow(PoolView view, {int batch = 100}) async {
    final whyShape = shape.sameSizeAs(view.shape.leavesPerRound);
    if (whyShape != null) {
      return FeedProgress(entries: 0, folded: 0, nextSequence: _nextSequence, stopped: whyShape);
    }
    var entries = 0, folded = 0;
    while (true) {
      final List<FeedEntry> got;
      try {
        got = await transport.readFeed(_nextSequence, max: batch);
      } on TransportFailure catch (e) {
        return FeedProgress(
            entries: entries,
            folded: folded,
            nextSequence: _nextSequence,
            stopped: Refusal('transport',
                'the pool\'s feed could not be read from sequence $_nextSequence: ${e.reason}'));
      }
      if (got.isEmpty) break;
      for (final entry in got) {
        if (entry.sequence != _nextSequence) {
          return FeedProgress(
              entries: entries,
              folded: folded,
              nextSequence: _nextSequence,
              stopped: Refusal('sequence',
                  'this client asked for the feed from sequence $_nextSequence and was handed sequence '
                  '${entry.sequence}; a feed read out of order would leave a gap in the rounds'));
        }
        final (didFold, clash, why) = _take(entry.bytes, view);
        entries++;
        if (why != null || clash != null) {
          return FeedProgress(
              entries: entries,
              folded: folded,
              nextSequence: _nextSequence,
              stopped: why ?? Refusal('announcement', '$clash'),
              disagreement: clash);
        }
        if (didFold) folded++;
        _nextSequence = entry.sequence + 1;
      }
    }
    return FeedProgress(entries: entries, folded: folded, nextSequence: _nextSequence);
  }

  (bool, Disagreement?, Refusal?) _take(List<int> bytes, PoolView view) {
    final (msg, why) = _decode(bytes, max: PoolMessage.maxOther, what: 'a feed entry');
    if (msg == null) return (false, null, why);
    if (msg is PoolDescriptor) {
      if (msg == pool) return (false, null, null);
      return (
        false,
        null,
        const Refusal('descriptor',
            'this feed re-published a descriptor that is not the one this client opened on; the pool it describes '
            'is not the pool this wallet\'s stored state was built against')
      );
    }
    if (msg is! PoolAnnouncement) {
      return (false, null, Refusal('feed', 'a pool\'s feed carries descriptors and announcements, not ${msg.kind.name}'));
    }

    if (msg.round < 1) {
      return (false, null, Refusal('round', 'a pool\'s rounds are numbered from 1, and this announcement is for round ${msg.round}'));
    }

    // a round the pool has already told us about
    final before = _seen[msg.round];
    if (before != null) {
      if (!_eq(before.$1, msg.header.encode())) {
        return (false, Disagreement(msg.round, 'the pool has published two different pool headers for this round'), null);
      }
      if (!_eq(before.$2, msg.blockRoot)) {
        return (
          false,
          Disagreement(msg.round,
              'the pool has published two different block roots for this round, ${shortHex(before.$2)} and '
              '${shortHex(msg.blockRoot)}'),
          null
        );
      }
      return (false, null, null);
    }
    if (msg.round <= view.round) {
      // history this view folded before it read this feed, and nothing said
      // about it disagrees with what it holds, because it holds no record
      return (false, null, null);
    }
    if (msg.round != view.round + 1) {
      return (
        false,
        null,
        Refusal('round',
            'this view stands at round ${view.round}, so the next announcement is round ${view.round + 1}\'s and '
            'this one is for round ${msg.round}; the rounds between hold the leaves this one sits on, so nothing '
            'was folded')
      );
    }

    // the pool's own two claims about this round have to agree with each
    // other before either is folded: the block root, against the commitment
    // root the same announcement's header carries. A probe of the view's own
    // frontier answers that without touching the view.
    final (probe, whyProbe) = _probeAt(view);
    if (probe == null) return (false, null, whyProbe);
    final whyFold = probe.fold(msg.round, msg.blockRoot, cmRoot: msg.header.cmRoot);
    if (whyFold != null) {
      return (
        false,
        Disagreement(msg.round,
            'the block root this announcement carries does not fold to the commitment root its own pool header '
            'claims, so the pool contradicted itself and nothing was folded'),
        null
      );
    }

    final why2 = view.fold(msg.round, msg.blockRoot);
    if (why2 != null) return (false, null, why2);
    _remember(msg);
    return (true, null, null);
  }

  /// A frontier standing where [view] stands, following nothing, for trying a
  /// fold without making one.
  (UpperFrontier?, Refusal?) _probeAt(PoolView view) {
    final cp = view.checkpoint;
    if (cp == null) return (UpperFrontier.atGenesis(shape), null);
    return UpperFrontier.at(shape, cp);
  }

  void _remember(PoolAnnouncement a) {
    _seen[a.round] = (a.header.encode(), List<int>.unmodifiable(a.blockRoot));
    if (_seen.length <= remember) return;
    final rounds = _seen.keys.toList()..sort();
    for (final r in rounds.take(_seen.length - remember)) {
      _seen.remove(r);
    }
  }

  // ---- catching up ----

  /// Asks the pool to prove its head, and checks the answer.
  ///
  /// This is the one question whose answer a wallet with nothing can act on:
  /// it comes back as a round transaction and a mined witness, and what makes
  /// it true is [checker]'s own block headers, not the pool's word. The round
  /// number is taken from the header's leaf count, so the number the pool
  /// stated is compared with the number the chain carries rather than used.
  Future<(CheckedHead?, Refusal?)> headProof(PaymentChecker checker) async {
    final (reply, why) = await _ask(PoolCatchUpRequest.head());
    if (reply == null) return (null, why);
    final MerkleProof membership;
    try {
      membership = MerkleProof.of(reply.witnessTx!,
          blockHash: reply.blockHash!, txIndex: reply.txIndex, branch: reply.branch);
    } on ArgumentError catch (e) {
      return (null, Refusal('head', '${e.message}'));
    }
    final (head, whyHead) =
        await checker.head(roundTx: reply.roundTx!, witnessTx: reply.witnessTx!, membership: membership);
    if (head == null) return (null, whyHead);
    if (head.round != reply.round) {
      return (
        null,
        Refusal('head',
            'the pool says its head is round ${reply.round} and the round it proved is round ${head.round} by its '
            'own leaf count')
      );
    }
    return (head, null);
  }

  /// Asks the pool where its tree stands, as a checkpoint.
  ///
  /// Nothing here is checked, and nothing here can be: a frontier is accepted
  /// by computing a commitment root the wallet proved off the chain, which is
  /// [PoolView.atCheckpoint]'s job. This method only gets the bytes into the
  /// right shape.
  Future<(Checkpoint?, Refusal?)> frontier() async {
    final (reply, why) = await _ask(PoolCatchUpRequest.frontier());
    if (reply == null) return (null, why);
    try {
      return (
        Checkpoint(round: reply.round, blockRoot: reply.blockRoot!, left: [for (final n in reply.left) n]),
        null
      );
    } on ArgumentError catch (e) {
      return (null, Refusal('frontier', '${e.message}'));
    }
  }

  /// The published run of block roots that holds [round].
  ///
  /// The range asked for is **not** derived from what the wallet holds: it is
  /// the aligned run of [PoolDescriptor.catchUpRange] rounds from round 1 that
  /// [round] falls in, which is one of a handful of ranges every wallet of
  /// this pool asks for. Asking for "everything since round 4,117" would say
  /// when this wallet was last current, and over a few catch-ups that is a
  /// fingerprint.
  Future<(BlockRootRun?, Refusal?)> blockRootsFor(int round) async {
    if (round < 1) return (null, Refusal('round', 'a round is 1 or more, not $round'));
    final range = pool.catchUpRange;
    final from = range * ((round - 1) ~/ range) + 1;
    if (!pool.publishesRange(from, range)) {
      return (
        null,
        Refusal('range', 'rounds $from to ${from + range - 1} are not one of the runs this pool publishes')
      );
    }
    final (reply, why) = await _ask(PoolCatchUpRequest.blockRoots(from: from, count: range));
    if (reply == null) return (null, why);
    if (reply.from != from) {
      return (
        null,
        Refusal('blockRoots',
            'this client asked for the run from round $from and the pool answered with the run from round '
            '${reply.from}')
      );
    }
    if (reply.roots.isEmpty) {
      return (null, Refusal('blockRoots', 'the pool served no block roots for the run from round $from'));
    }
    if (reply.roots.length > range) {
      return (
        null,
        Refusal('blockRoots', 'the pool served ${reply.roots.length} roots for a run of $range rounds')
      );
    }
    return (BlockRootRun(from, reply.roots), null);
  }

  /// A view standing at the pool's tip, for a wallet with no stored state.
  ///
  /// A head proof first, then the frontier, then the frontier is accepted only
  /// because it computes the head's commitment root. A wallet that took the
  /// same two answers from a stranger would reach the same verdict, and a pool
  /// that answers with someone else's tree is refused here naming the check
  /// rather than followed.
  Future<(PoolView?, Refusal?)> current(PaymentChecker checker) async {
    final (head, whyHead) = await headProof(checker);
    if (head == null) return (null, whyHead);
    final (cp, whyCp) = await frontier();
    if (cp == null) return (null, whyCp);
    if (cp.round != head.round) {
      return (
        null,
        Refusal('frontier',
            'the pool\'s frontier stands at round ${cp.round} and the head it proved is round ${head.round}; a '
            'frontier is only evidence against the root of the round it stands at')
      );
    }
    return PoolView.atCheckpoint(shape, cp, cmRoot: head.cmRoot);
  }

  /// Folds [view] forward to the pool's tip, by block roots.
  ///
  /// This is what a wallet holding a note does, and it cannot do what
  /// [current] does instead: a frontier says where the tree stands and says
  /// nothing about the rounds a particular leaf's siblings missed, so a note's
  /// path is brought forward only by folding every round since it was minted.
  ///
  /// The last thing that happens is the check: the fold is arithmetic until a
  /// commitment root the wallet proved off the chain agrees with it, and a
  /// wrong block root anywhere in the run makes the root at the end of the run
  /// wrong too. So one check at the end covers every round in it.
  Future<Refusal?> bringForward(PoolView view, PaymentChecker checker) async {
    final whyShape = shape.sameSizeAs(view.shape.leavesPerRound);
    if (whyShape != null) return whyShape;
    final (head, whyHead) = await headProof(checker);
    if (head == null) return whyHead;
    if (view.round > head.round) {
      return Refusal('head',
          'this view stands at round ${view.round} and the pool proved a head at round ${head.round}, which is '
          'behind it');
    }
    while (view.round < head.round) {
      final want = view.round + 1;
      final (run, whyRun) = await blockRootsFor(want);
      if (run == null) return whyRun;
      if (run.to < want) {
        return Refusal('blockRoots',
            'this view needs round $want and the pool served rounds ${run.from} to ${run.to}');
      }
      for (int r = want; r <= run.to && r <= head.round; r++) {
        final why = view.fold(r, run[r]);
        if (why != null) return why;
      }
    }
    return view.check(head.round, head.cmRoot);
  }

  Future<(PoolCatchUpReply?, Refusal?)> _ask(PoolCatchUpRequest request) async {
    final frame = request.encode();
    Refusal? failed;
    for (int attempt = 1; attempt <= sendAttempts; attempt++) {
      final List<int> bytes;
      try {
        bytes = await _request(frame);
      } on TransportFailure catch (e) {
        failed = Refusal('transport',
            'attempt $attempt of $sendAttempts to ask the pool for ${request.what.name} failed: ${e.reason}');
        continue;
      } on TimeoutException {
        return (
          null,
          Refusal('transport',
              'the transport did not come back on a ${request.what.name} request within '
              '${_hardDeadline.inMilliseconds}ms')
        );
      }
      // an answer that does not check out is not asked for again: the same
      // answer would come back, and a client that retried a lie would spin
      final (msg, why) = _decode(bytes, max: PoolMessage.maxCatchUp, what: 'a catch-up reply');
      if (msg == null) return (null, why);
      if (msg is! PoolCatchUpReply) {
        return (
          null,
          Refusal('catch-up', 'the pool answered a ${request.what.name} request with ${msg.kind.name}')
        );
      }
      if (msg.what != request.what) {
        return (
          null,
          Refusal('catch-up',
              'the pool answered a ${request.what.name} request with a ${msg.what.name} reply')
        );
      }
      return (msg, null);
    }
    return (null, failed);
  }

  // ---- frames ----

  /// The message [bytes] hold, bounded at [max] before a byte is read.
  ///
  /// Everything that arrives ends here, and everything that ends here ends in
  /// a message or a named refusal. The protocol's decoders already refuse in
  /// one shape; the broad catch below is for the case they do not, because a
  /// wallet that threw on a frame a stranger sent would be a wallet a stranger
  /// can stop.
  static (PoolMessage?, Refusal?) _decode(List<int> bytes, {required int max, required String what}) {
    if (bytes.length > max) {
      return (null, Refusal('size', '$what is at most $max bytes and ${bytes.length} arrived'));
    }
    if (bytes.length < 2) {
      return (null, Refusal('size', '$what is at least 2 bytes and ${bytes.length} arrived'));
    }
    if (bytes[0] != PoolMessage.formatVersion) {
      return (
        null,
        Refusal('version',
            'this library speaks pool protocol version ${PoolMessage.formatVersion} and $what arrived at version '
            '${bytes[0]}')
      );
    }
    if (PoolMessageKind.of(bytes[1]) == null) {
      return (null, Refusal('kind', '${bytes[1]} is not one of the protocol\'s message kinds'));
    }
    try {
      return (PoolMessage.decode(bytes), null);
    } on ProtocolRefusal catch (e) {
      return (null, Refusal(e.field, e.reason));
    } on ArgumentError catch (e) {
      return (null, Refusal('malformed', '${e.message}'));
    } on FormatException catch (e) {
      return (null, Refusal('malformed', e.message));
    } on StateError catch (e) {
      return (null, Refusal('malformed', e.message));
    }
  }

  static String _key(List<int> id) {
    const d = '0123456789abcdef';
    final s = StringBuffer();
    for (final x in id) {
      s.write(d[(x >> 4) & 15]);
      s.write(d[x & 15]);
    }
    return '$s';
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
