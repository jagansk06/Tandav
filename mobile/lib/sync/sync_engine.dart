import 'package:sqflite/sqflite.dart';

import '../core/app_role.dart';
import '../database/tandav_database.dart';
import 'sync_codec.dart';
import 'sync_state.dart';

/// Result of computing/sending our own changed rows.
class SyncDelta {
  /// table -> rows we have changed since the peer last saw our data.
  final Map<String, List<Map<String, Object?>>> tables = {};

  /// Our own clock at the moment this delta was snapshotted.
  ///
  /// This is the ceiling for [SyncEngine.recordAcks]. Rows merged from a
  /// peer carry the PEER's `updated_at`, which may sit in the future if its
  /// clock is fast; letting such a value become our "delivered" mark would
  /// strand every local edit until real time caught up. Clamping to the
  /// snapshot instant also guarantees that anything written *during* the
  /// upload stays above the mark and is still sent next time.
  String snapshotAt = '';

  bool get isEmpty => tables.values.every((rows) => rows.isEmpty);

  int get rowCount => tables.values.fold(0, (sum, rows) => sum + rows.length);
}

/// Result of applying changes received from the peer.
class SyncApplyResult {
  final Map<String, int> applied = {}; // table -> rows applied (new or updated)
  final Map<String, int> conflictsSkipped = {}; // table -> older rows skipped
  final Map<String, int> orphansSkipped = {}; // table -> rows with missing parent

  /// table -> the newest `updated_at` among the peer's rows we can honestly say
  /// we have handled, per layer.
  ///
  /// This is what the caller turns into an acknowledgement for that peer. A row
  /// is only acknowledgable when we made a decision about it (applied it, or
  /// skipped it because ours is newer, or skipped the whole table as out of
  /// scope). Orphaned rows are **excluded**, and a table with any orphan is not
  /// acknowledged at all, so the peer keeps re-offering it until every parent
  /// has arrived. See [SyncEngine.ackKey] for where this is stored.
  final Map<String, String> ackWatermarks = {};

  int get totalApplied => applied.values.fold(0, (a, b) => a + b);
}

/// The incremental, conflict-resolving merge engine.
///
/// Strategy:
/// - **Incremental** – every table keeps TWO independent marks, and conflating
///   them was a data-loss bug, so keep them apart:
///     * `sent.<peerId>.<table>` – the newest `updated_at` of OUR rows that
///       *that specific peer* has **confirmed reading**. This, and only this,
///       decides what [computeOutbound] sends. It is advanced by [recordAcks]
///       from the acknowledgements the peer carries back in its bundle — never
///       from our own upload.
///     * `watermark.<table>` – the newest `updated_at` we have **received**.
///       Bookkeeping/diagnostics only.
///   Filtering our own outbound rows by the *received* mark is wrong: the
///   peer's timestamps say nothing about which of OUR rows the peer has seen.
///   If the peer's clock ran even a minute ahead, every local edit we made in
///   that minute sorted below the mark and became permanently unsendable.
///
///   The sent mark is keyed **per peer** because it is a claim about one
///   device's contents, not about our upload history. With a third device in the
///   account a single `sent.<table>` was actively wrong: the two owner phones
///   would have advanced it months before the attender's phone existed, so the
///   newcomer's first sync would find our file nearly empty and it would never
///   receive the studio's history — a silent hole, reported as a clean sync on
///   both sides. Per-peer marks make the newcomer's absent mark mean what it
///   should: "this device holds nothing, send it everything."
/// - **Acknowledged delivery** – a sent mark advances only once the peer has
///   **read** our rows and said so. When we apply a peer's bundle we record,
///   per table, how far through *their* rows we got (`ack.<peer>.<table>`) and
///   carry those watermarks back in our own bundle; the peer feeds them through
///   [recordAcks] and advances *its* sent marks for us. Until that round trip,
///   our marks do not move, so rows a peer has not yet read stay in our file
///   no matter how many times we upload while it is offline. Overwriting our
///   one file used to destroy any batch a peer was away for; this is what makes
///   the overwrite safe.
/// - **Conflict resolution** – last-write-wins by `updated_at` (UTC ISO-8601).
///   On equal timestamps the lexicographically higher `device_id` wins
///   (deterministic and stable across all devices).
/// - **Identity** – every record carries a stable `sync_uuid`; local integer
///   ids differ per device and are re-mapped on merge via FK->uuid resolution.
/// - **Deletions** – records are soft-deleted (tombstoned with `deleted_at`),
///   so a deletion reaches the peers instead of vanishing permanently.
/// - **Atomicity** – all inbound rows for all tables are applied inside one
///   transaction with the watermark advances; a failure rolls everything back
///   and the local database is never left half-updated.
/// - **Scope** – [tables] is the set of tables this build participates in. The
///   attender's APK carries a strict subset, and because every loop here
///   iterates [tables] rather than [SyncCodec.applyOrder], rows outside it are
///   neither sent nor stored. See [syncTables].
class SyncEngine {
  final TandavDatabase db;
  final SyncState state;

  /// Tables this build syncs, in parent-before-child order.
  ///
  /// Defaults to the build's role scope rather than to every table, so a caller
  /// that forgets to pass it still gets the *restricted* behaviour on an
  /// attender build. Defaulting the other way would silently store the tables
  /// that build exists to keep off the device.
  final List<String> tables;

  SyncEngine(this.db, this.state, {List<String>? tables})
      : tables = tables ?? syncTables;

  /// Foreign-key columns per table: column name -> parent table.
  static const Map<String, Map<String, String>> fkMap = {
    'students': {'batch_id': 'batches'},
    'attendance': {'student_id': 'students', 'batch_id': 'batches'},
    'monthly_attendance': {'student_id': 'students'},
    'fees': {'student_id': 'students'},
    'fee_payments': {'fee_id': 'fees', 'student_id': 'students'},
    'events': {'batch_id': 'batches'},
    'event_participations': {'event_id': 'events', 'student_id': 'students'},
    'monthly_progress': {'student_id': 'students'},
  };

  /// Key holding the newest `updated_at` of our rows that [peerId] has
  /// **confirmed reading** for [table]. Absent (== '') means "that peer has
  /// never had anything from us", which correctly forces a full send.
  ///
  /// This is an *acknowledgement*, not an upload marker. It is written only by
  /// [recordAcks], fed from the `acks` section of the peer's own bundle; a
  /// successful upload writes nothing. Advancing it on upload was the bug that
  /// lost a batch any time a peer was offline across two of our uploads.
  static String sentKey(String peerId, String table) =>
      'sent.$peerId.$table';

  /// Prefix of every sent mark, used to clear them all without enumerating
  /// peers we may no longer know about.
  static const sentKeyPrefix = 'sent.';

  /// Key holding the newest `updated_at` of [peerId]'s rows that **we** have
  /// seen and handled for [table]. This is the acknowledgement we carry back to
  /// [peerId] in our bundle, which it feeds into [recordAcks] to advance its
  /// sent mark for us.
  ///
  /// Written during [applyIncoming] (same transaction, so the watermark is
  /// atomic with the rows it describes) and read by [outboundAcks] when we are
  /// about to upload. Monotonic: values only ever move forward.
  static String ackKey(String peerId, String table) =>
      'ack.$peerId.$table';

  /// Prefix of every acknowledgement key, cleared alongside `sent.` so a
  /// forgotten or reset peer can never be told "we have your data" again.
  static const ackKeyPrefix = 'ack.';

  /// The pre-per-peer key shape, still present in databases written by older
  /// builds.
  ///
  /// Nothing reads it any more: the new keys carry a peer segment, so on the
  /// first sync after an upgrade every peer's mark is absent and the whole
  /// database is re-offered — which is exactly the migration this change needs,
  /// achieved by *not* writing migration code. The old rows are deleted
  /// opportunistically by [clearSentMarks] so they cannot be misread if these
  /// keys ever mean something again.
  static String legacySentKey(String table) => 'sent.$table';

  /// Key holding the newest `updated_at` we have received for [table].
  /// Deliberately NOT used to filter outbound rows — see the class doc for why
  /// that was a bug.
  static String receivedKey(String table) => 'watermark.$table';

  /// Rows we must send: everything the least caught-up peer has not seen.
  ///
  /// Called with a read-only transaction so the snapshot is consistent with the
  /// marks it is based on.
  ///
  /// ## Why the *minimum* across peers
  ///
  /// The mailbox holds **one file per device**, and every peer reads the same
  /// one. So the file has to satisfy whichever peer is furthest behind: the
  /// floor is the lowest sent mark across [peers], and any peer with no mark at
  /// all drops the floor to "everything". A peer that is already up to date
  /// simply re-reads rows it has, matches them by `sync_uuid`, and skips them as
  /// unchanged echoes — bigger uploads in exchange for never leaving a device
  /// short, which is the only acceptable direction for this trade.
  ///
  /// ## Why an empty [peers] means "send everything"
  ///
  /// With nobody adopted yet we cannot know who will read the file, so the only
  /// safe content is the whole database. [recordAcks] cannot advance a mark in
  /// that state, which together fix a real hole in the two-device version: a
  /// first phone used for a week before the second one existed used to mark its
  /// rows delivered to nobody, and then overwrite its own file with an empty
  /// delta. The second phone arrived to find an empty mailbox and the first
  /// one insisting it had already sent everything.
  Future<SyncDelta> computeOutbound(
    Transaction txn, {
    Set<String> peers = const {},
  }) async {
    final delta = SyncDelta();
    // Read our clock BEFORE querying, so every row written after this point is
    // strictly above any mark [recordAcks] will set from a peer's clock.
    delta.snapshotAt = DateTime.now().toUtc().toIso8601String();
    for (final table in tables) {
      final floor = await _outboundFloor(txn, table, peers);
      final rows = floor.isEmpty
          ? await _selectAll(txn, table)
          : await txn.query(table, where: 'updated_at > ?', whereArgs: [floor]);
      if (rows.isEmpty) continue;
      final out = <Map<String, Object?>>[];
      for (final r in rows) {
        final copy = Map<String, Object?>.from(r);
        copy['_table'] = table;
        copy['_fk'] = await _fkUuids(txn, table, copy);
        out.add(copy);
      }
      delta.tables[table] = out;
    }
    return delta;
  }

  /// Lowest delivered mark across [peers] for [table]; '' meaning "send
  /// everything" when there are no peers or any one of them has no mark.
  Future<String> _outboundFloor(
    Transaction txn,
    String table,
    Set<String> peers,
  ) async {
    if (peers.isEmpty) return '';
    var floor = '';
    for (final peer in peers) {
      final mark = await state.readWithin(txn, sentKey(peer, table)) ?? '';
      if (mark.isEmpty) return ''; // this peer holds nothing for this table
      if (floor.isEmpty || mark.compareTo(floor) < 0) floor = mark;
    }
    return floor;
  }

  /// Advance our sent marks for [peerId] from the acknowledgements it carried
  /// back to us, so the next [computeOutbound] stops offering rows it has
  /// confirmed reading.
  ///
  /// **This is the only thing that may advance a sent mark.** The marks mean
  /// "that peer already holds everything up to this timestamp", which is only
  /// true once the peer has *read* the rows and said so. Advancing them from our
  /// own upload treated reachability as reading and lost any batch a peer was
  /// offline across two of our uploads — the file was overwritten before the
  /// peer ever saw it, and the mark then claimed it had.
  ///
  /// [watermarks] is the `acks` section of the peer's bundle addressed to us:
  /// table -> the newest `updated_at` of OUR rows the peer received.
  ///
  /// Three clamps, each closing a way a foreign value could rescue us into
  /// pretending data was delivered:
  /// - a watermark from a *fast* peer clock (its rows carry future stamps we
  ///   forwarded) is capped at our own `now`, so it cannot strand local edits
  ///   made before real time catches up — those rows are re-offered as echoes
  ///   until then, which the peer discards;
  /// - a watermark is never advanced past the newest `updated_at` we actually
  ///   hold for that table, so a peer cannot ack rows we never had;
  /// - a mark never moves backwards, so a clock that jumped back cannot trigger
  ///   pointless re-sends.
  Future<void> recordAcks(
    Transaction txn,
    String peerId,
    Map<String, String> watermarks,
  ) async {
    if (peerId.isEmpty) return;
    final now = DateTime.now().toUtc().toIso8601String();
    for (final table in tables) {
      final w = watermarks[table];
      if (w == null || w.isEmpty) continue;
      var mark = w.compareTo(now) > 0 ? now : w;
      final tableMax = await _maxUpdatedAt(txn, table);
      if (tableMax.isNotEmpty && mark.compareTo(tableMax) > 0) {
        mark = tableMax;
      }
      if (mark.isEmpty) continue;
      final key = sentKey(peerId, table);
      final current = await state.readWithin(txn, key) ?? '';
      if (mark.compareTo(current) > 0) {
        await state.writeWithin(txn, key, mark);
      }
    }
  }

  /// The acknowledgements to include in our next upload: peer -> table ->
  /// newest `updated_at` of that peer's rows we have handled.
  ///
  /// These are the rows stored by [applyIncoming] under [ackKey]; a peer only
  /// appears once we have something to tell it. Contained, idempotent and small
  /// enough to ride every bundle — losing one in an overwrite is harmless, the
  /// next upload repeats it.
  Future<Map<String, Map<String, String>>> outboundAcks(
    Transaction txn, {
    required Set<String> peers,
  }) async {
    final out = <String, Map<String, String>>{};
    for (final peer in peers) {
      if (peer.isEmpty) continue;
      final tables = <String, String>{};
      for (final table in this.tables) {
        final w = await state.readWithin(txn, ackKey(peer, table));
        if (w != null && w.isEmpty == false) tables[table] = w;
      }
      if (tables.isNotEmpty) out[peer] = tables;
    }
    return out;
  }

  Future<String> _maxUpdatedAt(Transaction txn, String table) async {
    final rows = await txn.rawQuery('SELECT MAX(updated_at) AS m FROM $table');
    return (rows.isEmpty ? null : rows.first['m']) as String? ?? '';
  }

  /// Forget which of our rows a peer has already received, so the next sync
  /// offers the **whole** local dataset again. Returns how many marks existed.
  ///
  /// Pass [peers] to clear specific devices, or omit it to clear **every** sent
  /// mark in the database — including marks for peers this build no longer knows
  /// the ids of, and the pre-per-peer `sent.<table>` rows left by older builds.
  /// "Forget everything I believed anyone had" is the only version of this that
  /// is safe to offer a customer who cannot diagnose which peer is stale.
  ///
  /// This is the recovery path for a peer whose database is gone — a phone that
  /// was wiped or replaced, or an iPhone whose PWA storage Safari evicted (which
  /// can happen without the customer doing anything). It is needed because a
  /// mailbox file is a **delta, not a snapshot**: once we have delivered
  /// everything, our file shrinks to nearly nothing, so a peer starting from an
  /// empty database would find nothing in the account to restore from. Clearing
  /// our marks is what turns our next bundle back into a full copy. On a
  /// local-first app with no server this is the only route back.
  ///
  /// The keys are **deleted**, not set to `''`. [computeOutbound] branches on
  /// an empty floor and falls back to selecting every row, so an empty string
  /// happens to work today — but the two branches do not agree on edge cases.
  /// `attendance`, `fee_payments` and `event_participations` gained
  /// `updated_at` by `ALTER TABLE … NOT NULL DEFAULT ''`, so an empty
  /// `updated_at` is representable there; `updated_at > ''` skips such a row
  /// while select-all includes it. Deleting the key keeps "everything" meaning
  /// one thing.
  ///
  /// **Safe to run when nothing is wrong.** The peer matches each row by
  /// `sync_uuid`, finds a copy it already has, and skips it as an unchanged
  /// echo; a row the peer has since edited is *newer* than ours and wins there
  /// too, so re-offering cannot overwrite it. The only cost is one larger
  /// upload. That matters: a customer who cannot tell whether they need this
  /// button must be able to press it without risk.
  ///
  /// Deliberately does **not** touch `watermark.<table>`. Those record what we
  /// have *received*, and lowering them would make us re-apply the peers' rows
  /// against our own — pointless work with real conflict-resolution risk.
  ///
  /// Also clears the `ack.<peer>.<table>` keys. Those are our claims that "we
  /// have already handled this peer's rows", and they die with the peer just
  /// like the sent marks do — a forgotten relationship has nothing to
  /// acknowledge. Over-clearing both directions is safe: it only costs the same
  /// larger upload the doc above describes.
  Future<int> clearSentMarks(SyncExecutor ex, {Set<String>? peers}) async {
    if (peers == null) {
      // Everything under the prefix, so an unknown or already-forgotten peer
      // cannot leave a mark behind claiming it holds our data — or that we hold
      // its.
      final sent = await state.deleteWithPrefix(ex, sentKeyPrefix);
      final ack = await state.deleteWithPrefix(ex, ackKeyPrefix);
      return sent + ack;
    }
    var cleared = 0;
    for (final table in tables) {
      // Older builds wrote one mark per table with no peer segment. Clear it
      // whenever we clear anything, so the dead row cannot be misread later.
      final legacy = legacySentKey(table);
      if (await state.readWithin(ex, legacy) != null) {
        await state.writeWithin(ex, legacy, null);
        cleared++;
      }
      for (final peer in peers) {
        for (final key in [sentKey(peer, table), ackKey(peer, table)]) {
          if (await state.readWithin(ex, key) == null) continue;
          await state.writeWithin(ex, key, null); // null deletes the row
          cleared++;
        }
      }
    }
    return cleared;
  }

  /// Apply rows received from a peer inside one transaction.
  ///
  /// Iterates [tables], which is what keeps the attender's build from ever
  /// storing the tables it has no business holding: an owner device's bundle
  /// carries events, and on that build those rows are skipped rather than
  /// inserted. Skipping is not deleting — an absent or ignored table means "no
  /// news", never "remove these" — so the owners keep their events untouched.
  Future<SyncApplyResult> applyIncoming(
    Transaction txn,
    Map<String, List<Map<String, Object?>>> incoming, {
    required String peerDeviceId,
  }) async {
    final result = SyncApplyResult();
    // uuid -> local id, built as parent tables are applied first so child
    // foreign keys can be resolved.
    final uuidMap = <String, Map<String, int>>{};

    // Pre-populate uuidMap from the local database so child rows whose parent
    // was sent in a *previous* sync (and is not in the current bundle) can
    // still resolve their foreign keys. Without this, the FK lookup falls
    // through to null and the child is silently orphaned.
    for (final table in tables) {
      final tableUuids = uuidMap.putIfAbsent(table, () => {});
      final rows = await txn.query(table,
          columns: ['id', 'sync_uuid'], where: "sync_uuid != ''");
      for (final r in rows) {
        final id = r['id'] as int;
        final uuid = r['sync_uuid'] as String;
        tableUuids[uuid] = id;
      }
    }

    for (final table in tables) {
      final rows = incoming[table];
      if (rows == null || rows.isEmpty) continue;
      result.applied[table] = 0;
      result.conflictsSkipped[table] = 0;
      result.orphansSkipped[table] = 0;
      final tableUuids = uuidMap.putIfAbsent(table, () => {});
      var orphans = false;
      List<String> advanceable = [];

      for (final raw in rows) {
        final row = Map<String, Object?>.from(raw);
        final uuid = (row['sync_uuid'] as String?) ?? '';
        if (uuid.isEmpty) continue;
        final updatedAt = (row['updated_at'] as String?) ?? '';

        final remapped = <String, Object?>{};
        for (final entry in row.entries) {
          if (entry.key == '_fk' || entry.key == '_table') continue;
          if (entry.key == 'id') continue; // local-only
          remapped[entry.key] = entry.value;
        }

        // Resolve foreign keys: peer id -> our local id via uuid.
        var orphaned = false;
        final fks = fkMap[table] ?? const <String, String>{};
        final fkUuidRows = row['_fk'] as Map<String, Object?>? ?? const {};
        for (final entry in fks.entries) {
          final parent = entry.value;
          final parentUuid = fkUuidRows[parent] as String?;
          if (parentUuid == null || parentUuid.isEmpty) {
            if (row[entry.key] != null) {
              orphaned = true;
              break;
            }
            remapped[entry.key] = null;
            continue;
          }
          final localParentId = uuidMap[parent]?[parentUuid];
          if (localParentId == null) {
            orphaned = true;
            break;
          }
          remapped[entry.key] = localParentId;
        }
        if (orphaned) {
          orphans = true;
          result.orphansSkipped[table] = result.orphansSkipped[table]! + 1;
          continue;
        }

        // Find the local counterpart.
        final existing = await _findByUuid(txn, table, tableUuids, uuid, remapped);
        if (existing == null) {
          final id = await txn.insert(table, remapped);
          tableUuids[uuid] = id;
          result.applied[table] = result.applied[table]! + 1;
          _maxOf(advanceable, updatedAt);
        } else {
          final localUpdatedAt = (existing['updated_at'] as String?) ?? '';
          final localDeviceId = (existing['device_id'] as String?) ?? '';
          remapped['sync_uuid'] = uuid;
          remapped['device_id'] = (row['device_id'] as String?) ?? peerDeviceId;
          final incomingDevice = (row['device_id'] as String?) ?? peerDeviceId;
          if (_newerThan(updatedAt, incomingDevice, localUpdatedAt, localDeviceId)) {
            await txn.update(table, remapped,
                where: 'id = ?', whereArgs: [existing['id']]);
            tableUuids[uuid] = existing['id'] as int;
            result.applied[table] = result.applied[table]! + 1;
            _maxOf(advanceable, updatedAt);
          } else if (updatedAt.compareTo(localUpdatedAt) < 0 ||
              (incomingDevice == localDeviceId &&
                  updatedAt.compareTo(localUpdatedAt) == 0)) {
            // Incoming is strictly older (our newer version wins), or it is an
            // exact echo of a row we already sent. Either way there is nothing
            // to change locally.
            tableUuids[uuid] = existing['id'] as int;
            result.conflictsSkipped[table] =
                result.conflictsSkipped[table]! + 1;
            _maxOf(advanceable, updatedAt);
          } else {
            // Perfect tie between two different devices and we hold the winner
            // (our device id is higher). The peer must still learn our version.
            // That is guaranteed by `sent.<table>`: our winning row was either
            // never delivered — so it is still queued — or it was delivered and
            // the peer will reach the same verdict, because the tie-break is
            // pure comparison and runs identically on both sides.
            tableUuids[uuid] = existing['id'] as int;
            result.conflictsSkipped[table] =
                result.conflictsSkipped[table]! + 1;
          }
        }
      }

      // Advance the received mark only if nothing was orphaned — an orphaned
      // row may need the parent to arrive in a future sync, so it must be
      // retried. This mark is bookkeeping only; it never gates what we send.
      if (advanceable.isNotEmpty && !orphans) {
        final current = await state.readWithin(txn, receivedKey(table)) ?? '';
        final maxSeen = advanceable.reduce((a, b) => a.compareTo(b) > 0 ? a : b);
        if (maxSeen.compareTo(current) > 0) {
          await state.writeWithin(txn, receivedKey(table), maxSeen);
        }
        // Same gate, and the same reason, for the acknowledgement. Skipping the
        // ack when orphans were present is what makes the peer keep re-offering
        // this table until every parent has arrived — otherwise the child rows
        // would be declared handled and quietly vanish.
        await _recordAck(txn, peerDeviceId, table, maxSeen);
        result.ackWatermarks[table] = maxSeen;
      }
    }

    // Tables this build deliberately does not hold (the attender's phone and
    // the owner's events): we read the rows, chose to store none of them, and
    // there is no parent dependency to wait for. Acknowledging them keeps the
    // owner from re-offering the whole table to a scope that will never store
    // it — we have handled as much as this build ever will.
    for (final table in incoming.keys) {
      if (tables.contains(table)) continue;
      var max = '';
      for (final raw in incoming[table]!) {
        final at = (raw['updated_at'] as String?) ?? '';
        if (at.compareTo(max) > 0) max = at;
      }
      if (max.isNotEmpty) {
        await _recordAck(txn, peerDeviceId, table, max);
        result.ackWatermarks[table] = max;
      }
    }

    await state.writeWithin(txn, 'last_sync_at', DateTime.now().toUtc().toIso8601String());
    return result;
  }

  /// Persist an acknowledgement for [peerId]'s table rows up to [watermark],
  /// monotonically — it only ever moves forward.
  ///
  /// Runs inside the same transaction as the rows it acknowledges, so a failed
  /// apply cannot leave an ack on top of rows that were never stored.
  Future<void> _recordAck(
    SyncExecutor ex,
    String peerId,
    String table,
    String watermark,
  ) async {
    if (peerId.isEmpty || watermark.isEmpty) return;
    final key = ackKey(peerId, table);
    final current = await state.readWithin(ex, key) ?? '';
    if (watermark.compareTo(current) > 0) {
      await state.writeWithin(ex, key, watermark);
    }
  }

  void _maxOf(List<String> list, String value) {
    if (value.compareTo(list.isEmpty ? '' : list.last) > 0) list.add(value);
  }

  /// Last-write-wins: newer `updatedAt` wins; on ties the higher `deviceId`
  /// wins (deterministic on both devices).
  bool _newerThan(String incomingAt, String incomingDevice,
      String localAt, String localDevice) {
    final cmp = incomingAt.compareTo(localAt);
    if (cmp != 0) return cmp > 0;
    final devCmp = incomingDevice.compareTo(localDevice);
    if (devCmp != 0) return devCmp > 0;
    return false; // identical row — nothing to change.
  }

  Future<List<Map<String, Object?>>> _selectAll(Transaction txn, String table) async {
    final rows = await txn.query(table);
    return rows.map((r) => Map<String, Object?>.from(r)).toList();
  }

  /// Match a row by uuid first, then by the table's natural unique key (so
  /// the same logical record created independently on both devices merges
  /// into one row instead of duplicating).
  Future<Map<String, Object?>?> _findByUuid(
    Transaction txn,
    String table,
    Map<String, int> tableUuids,
    String uuid,
    Map<String, Object?> remapped,
  ) async {
    final localId = tableUuids[uuid];
    if (localId != null) {
      final rows = await txn.query(table, where: 'id = ?', whereArgs: [localId]);
      return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
    }
    final rows = await txn.query(table,
        where: 'sync_uuid = ?', whereArgs: [uuid], limit: 1);
    if (rows.isNotEmpty) return Map<String, Object?>.from(rows.first);

    final natural = SyncCodec.naturalKeysFor(table);
    if (natural.isNotEmpty) {
      final conditions = <String>[];
      final args = <Object?>[];
      for (final key in natural) {
        conditions.add('$key = ?');
        args.add(remapped[key]);
      }
      conditions.add('deleted_at IS NULL');
      final nat = await txn.query(table,
          where: conditions.join(' AND '), whereArgs: args, limit: 1);
      if (nat.isNotEmpty) return Map<String, Object?>.from(nat.first);
    }
    return null;
  }

  /// Build the {parentTable: uuid} map for a row's foreign keys so the peer
  /// can resolve its local ids on the other side.
  Future<Map<String, Object?>> _fkUuids(
      Transaction txn, String table, Map<String, Object?> row) async {
    final out = <String, Object?>{};
    final fks = fkMap[table] ?? const <String, String>{};
    for (final entry in fks.entries) {
      final id = row[entry.key];
      if (id == null) continue;
      final parent = entry.value;
      final rows = await txn.query(parent,
          where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isNotEmpty) out[parent] = rows.first['sync_uuid'];
    }
    return out;
  }
}