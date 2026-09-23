import 'dart:async';
import 'dart:io';

import '../refusal.dart';
import 'entry.dart';

/// What a read of the journal found: the entries, and every file that would
/// not read.
///
/// Both halves are returned because both are facts. A journal with one
/// truncated entry in it still holds the other nine thousand, and a reader
/// that threw the lot away over one bad file would have thrown away the
/// evidence. A reader that skipped the bad file silently would be worse: the
/// one thing a record of what you paid must never do is quietly lose a line.
class JournalRead {
  /// The entries that read, in sequence order.
  final List<JournalEntry> entries;

  /// One refusal per file that did not read, naming the file.
  final List<Refusal> refused;

  const JournalRead(this.entries, this.refused);

  bool get whole => refused.isEmpty;

  /// The entries belonging to one invoice, in order.
  List<JournalEntry> threadOf(List<int> invoiceId) =>
      [for (final e in entries) if (_eq(e.invoiceId, invoiceId)) e];

  @override
  String toString() =>
      '${entries.length} entries${refused.isEmpty ? '' : ', ${refused.length} refused'}';
}

/// The wallet's record of what it promised, paid, proved and acknowledged.
///
/// **One file per entry, named by its sequence.** An entry is written to a
/// temporary name and renamed, so it is either whole or absent: a crash half
/// way through a write leaves a `.tmp` beside the journal and no entry, which
/// is the honest outcome. Nothing is ever rewritten and nothing is ever
/// deleted; a correction is a new entry naming the one it corrects, so what
/// was believed at the time survives beside what replaced it.
///
/// **There is no index.** The design sketch suggested one for the 10,000-entry
/// read; measured, the read is 224 ms in batches of eight against a 1 s bound,
/// so an index would buy nothing but a second thing to go stale. A journal
/// small enough to read whole is a journal that cannot disagree with itself.
///
/// The directory is made owner-only. The entry files are not chmodded one by
/// one — that would be a process spawn per entry, and a directory nobody else
/// can traverse is the same protection at 1/10,000th the cost.
class Journal {
  /// Entry files end in this; anything else in the directory is not one.
  static const suffix = '.entry';

  /// The sequence is zero-padded to this width, so the names sort in the order
  /// the entries happened.
  static const digits = 9;

  /// Past this the names stop sorting, so past this the journal stops.
  static const maxSequence = 999999999;

  /// How many entry files are read at once. Measured: one at a time is 658 ms
  /// for 10,000 and eight at a time is 224 ms, because the cost is syscall
  /// latency and not bandwidth. Past eight it gets worse again.
  static const readBatch = 8;

  final String directory;
  int _next;

  Journal._(this.directory, this._next);

  /// The sequence the next entry written will get.
  int get nextSequence => _next;

  /// Opens the journal at [directory], making it if it is not there.
  ///
  /// The highest sequence already present is found here and not on every
  /// write, so appending is one rename and not a directory scan.
  static Future<(Journal?, Refusal?)> open(String directory) async {
    final dir = Directory(directory);
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        if (!Platform.isWindows) {
          final chmod = await Process.run('chmod', ['700', directory]);
          if (chmod.exitCode != 0) {
            return (
              null,
              Refusal('permissions', 'could not make $directory owner-only, so no journal was opened')
            );
          }
        }
      }
    } on FileSystemException catch (e) {
      return (null, Refusal('directory', 'could not open a journal at $directory: ${e.osError?.message ?? e.message}'));
    }
    final (names, why) = await _names(directory);
    if (names == null) return (null, why);
    var highest = 0;
    for (final n in names) {
      final s = _sequenceOf(n);
      if (s != null && s > highest) highest = s;
    }
    return (Journal._(directory, highest + 1), null);
  }

  /// Writes [entry], which is given the next sequence, and returns it as it
  /// was written.
  ///
  /// A failure names the entry and leaves every earlier one readable: the
  /// temporary file is the only thing that can be half written, and it is not
  /// an entry until it is renamed.
  Future<(JournalEntry?, Refusal?)> add(JournalEntry entry) async {
    if (_next > maxSequence) {
      return (null, Refusal('sequence', 'this journal holds $maxSequence entries and is full'));
    }
    final stored = entry.atSequence(_next);
    final path = pathFor(_next);
    final tmp = File('$path.tmp');
    try {
      await tmp.writeAsBytes(stored.encode(), flush: true);
      await tmp.rename(path);
    } on FileSystemException catch (e) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } on FileSystemException {
        // the journal is already the thing that failed; there is nothing
        // useful to say about failing to tidy up after it
      }
      return (
        null,
        Refusal('write',
            'entry $_next (${stored.kind.name} for invoice ${shortHex(stored.invoiceId)}) could not be written '
            'to $path: ${e.osError?.message ?? e.message}; every earlier entry still reads')
      );
    }
    _next++;
    return (stored, null);
  }

  /// Writes [entries] in order, stopping at the first that fails.
  Future<(List<JournalEntry>, Refusal?)> addAll(Iterable<JournalEntry> entries) async {
    final out = <JournalEntry>[];
    for (final e in entries) {
      final (stored, why) = await add(e);
      if (stored == null) return (out, why);
      out.add(stored);
    }
    return (out, null);
  }

  /// Every entry, in order, and every file that would not read.
  Future<JournalRead> read() async {
    final (names, why) = await _names(directory);
    if (names == null) return JournalRead(const [], [why!]);
    final wanted = <int, String>{};
    final refused = <Refusal>[];
    for (final n in names) {
      final s = _sequenceOf(n);
      // anything that is not an entry file is not an entry: a leftover `.tmp`
      // from a crashed write is exactly the "absent" half of "whole or
      // absent", and is not a fault to report
      if (s == null) continue;
      wanted[s] = n;
    }
    final order = wanted.keys.toList()..sort();
    final entries = <JournalEntry>[];
    for (int i = 0; i < order.length; i += readBatch) {
      final end = i + readBatch < order.length ? i + readBatch : order.length;
      final batch = [for (int j = i; j < end; j++) _readOne(wanted[order[j]]!, order[j])];
      for (final got in await Future.wait(batch)) {
        if (got.$1 != null) {
          entries.add(got.$1!);
        } else {
          refused.add(got.$2!);
        }
      }
    }
    // a sequence with no file at all is a deleted entry. The journal does not
    // delete, so somebody else did, and that is worth saying out loud
    for (int s = 1; s <= (order.isEmpty ? 0 : order.last); s++) {
      if (!wanted.containsKey(s)) {
        refused.add(Refusal('missing',
            'there is no entry $s in $directory, and this journal never deletes one, so it was removed from '
            'outside'));
      }
    }
    entries.sort((a, b) => a.sequence.compareTo(b.sequence));
    return JournalRead(entries, refused);
  }

  /// The entries belonging to [invoiceId], in order, with the refusals from
  /// the whole read: a thread that looks complete beside a file that would not
  /// read is not a thread anybody should act on.
  Future<JournalRead> thread(List<int> invoiceId) async {
    final all = await read();
    return JournalRead(all.threadOf(invoiceId), all.refused);
  }

  /// The file entry [sequence] is kept in.
  String pathFor(int sequence) =>
      '$directory${Platform.pathSeparator}${sequence.toString().padLeft(digits, '0')}$suffix';

  Future<(JournalEntry?, Refusal?)> _readOne(String path, int sequence) async {
    final f = File(path);
    try {
      final length = await f.length();
      if (length > JournalEntry.maxEntry) {
        return (
          null,
          Refusal('size', 'a journal entry is at most ${JournalEntry.maxEntry} bytes and $path is $length')
        );
      }
      final entry = JournalEntry.decode(await f.readAsBytes());
      if (entry.sequence != sequence) {
        return (
          null,
          Refusal('sequence', '$path holds entry ${entry.sequence}, and its name says $sequence')
        );
      }
      return (entry, null);
    } on Refusal catch (e) {
      return (null, Refusal(e.step, '${e.reason} (reading $path)'));
    } on FileSystemException catch (e) {
      return (null, Refusal('file', 'could not read $path: ${e.osError?.message ?? e.message}'));
    }
  }

  static Future<(List<String>?, Refusal?)> _names(String directory) async {
    try {
      final out = <String>[];
      await for (final e in Directory(directory).list(followLinks: false)) {
        if (e is File) out.add(e.path);
      }
      return (out, null);
    } on FileSystemException catch (e) {
      return (null, Refusal('directory', 'could not read $directory: ${e.osError?.message ?? e.message}'));
    }
  }

  /// The sequence [path]'s name declares, or null when it is not an entry
  /// file. The name has to be exactly the padded digits and the suffix: a file
  /// called `7.entry`, or `000000007.entry.bak`, is not one of ours.
  static int? _sequenceOf(String path) {
    final sep = path.lastIndexOf(Platform.pathSeparator);
    final name = sep < 0 ? path : path.substring(sep + 1);
    if (name.length != digits + suffix.length) return null;
    if (!name.endsWith(suffix)) return null;
    final head = name.substring(0, digits);
    for (final c in head.codeUnits) {
      if (c < 0x30 || c > 0x39) return null;
    }
    final s = int.parse(head);
    return s < 1 ? null : s;
  }
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
