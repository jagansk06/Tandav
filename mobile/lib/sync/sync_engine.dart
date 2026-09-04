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
  /// This is the ceiling for [SyncEngine.markDeltaSent]. Rows merged from a
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

  int get totalApplied => applied.values.fold(0, (a, b) => a + b);
}

/// The incremental, conflict-resolving merge engine.
///
/// Strategy:
/// - **Incremental** – every table keeps TWO independent marks, and conflating
///   them was a data-loss bug, so keep them apart:
///     * `sent.<peerId>.<table>` – the newest `updated_at` we have actually
///       **delivered** to *that specific peer*. This, and only this, decides
///       what [computeOutbound] sends. It is advanced by [markDeltaSent] after a
///       *confirmed* send.
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

  /// Key holding the newest `updated_at` we have successfully delivered to
  /// [peerId] for [table]. Absent (== '') means "that peer has never had
  /// anything from us", which correctly forces a full send.
  static String sentKey(String peerId, String table) =>
      'sent.$peerId.$table';

  /// Prefix of every sent mark, used to clear them all without enumerating
  /// peers we may no longer know about.
  static const sentKeyPrefix = 'sent.';

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
  /// safe content is the whole database. [markDeltaSent] refuses to advance any
  /// mark in that state, which together fix a real hole in the two-device
  /// version: a first phone used for a week before the second one existed used
  /// to mark its rows delivered to nobody, and then overwrite its own file with
  /// an empty delta. The second phone arrived to find an empty mailbox and the
  /// first one insisting it had already sent everything.
  Future<SyncDelta> computeOutbound(
    Transaction txn, {
    Set<String> peers = const {},
  }) async {
    final delta = SyncDelta();
    // Read our clock BEFORE querying, so every row written after this point is
    // strictly above the mark markDeltaSent will set.
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

  /// Record that every row in [delta] has reached each of [peers], so the next
  /// [computeOutbound] does not send it again.
  ///
  /// **Only call this once delivery is confirmed.** Over the Drive mailbox that
  /// is a successful file write — the bundle now sits in the account and each
  /// peer will read it whenever it next syncs. Calling it merely because we
  /// *attempted* a send would drop rows whenever the upload failed; calling it
  /// late only costs a harmless re-send, so when in doubt, call it late.
  ///
  /// With no [peers] this does **nothing**, deliberately. A sent mark is a claim
  /// about a specific device's contents, so with no device to name there is no
  /// claim to record — and recording one anyway is how the first phone of a pair
  /// used to declare its data delivered before the second phone existed.
  ///
  /// ## Known limitation: a peer that stays offline across two uploads
  ///
  /// Each upload **overwrites** our single file, so rows from upload N are gone
  /// once upload N+1 lands. We mark them delivered at upload N because the file
  /// was readable then, which is a claim about reachability rather than about
  /// reading. A peer that is offline across both uploads therefore never sees
  /// the first batch, and nothing here can tell. The remedy is the one the app
  /// already has — **Send everything again** on a device that holds the data —
  /// and the honest fix is an acknowledgement in the bundle so marks advance on
  /// *confirmed read* instead. Until that exists, treat onboarding a device that
  /// has been away a long time as "resend, then sync".
  Future<void> markDeltaSent(
    Transaction txn,
    SyncDelta delta, {
    Set<String> peers = const {},
  }) async {
    if (peers.isEmpty) return;
    final ceiling = delta.snapshotAt;
    for (final entry in delta.tables.entries) {
      var max = '';
      for (final row in entry.value) {
        final at = (row['updated_at'] as String?) ?? '';
        if (at.compareTo(max) > 0) max = at;
      }
      // Never let a peer's clock set our mark. A row we merged from a fast
      // phone can be stamped in the future; if that became our mark, every
      // local edit until then would sort below it and never be sent again.
      // Such a row is simply re-offered each sync until our own clock passes
      // it, and the peer discards it as an unchanged echo — wasted bytes, in
      // exchange for never losing an edit.
      if (ceiling.isNotEmpty && max.compareTo(ceiling) > 0) max = ceiling;
      if (max.isEmpty) continue;
      for (final peer in peers) {
        final key = sentKey(peer, entry.key);
        final current = await state.readWithin(txn, key) ?? '';
        // Never move a mark backwards: a clock that jumped back would otherwise
        // re-send, and worse, a later correct value would be lost.
        if (max.compareTo(current) > 0) {
          await state.writeWithin(txn, key, max);
        }
      }
    }
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
  Future<int> clearSentMarks(SyncExecutor ex, {Set<String>? peers}) async {
    if (peers == null) {
      // Everything under the prefix, so an unknown or already-forgotten peer
      // cannot leave a mark behind claiming it holds our data.
      return state.deleteWithPrefix(ex, sentKeyPrefix);
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
        final key = sentKey(peer, table);
        if (await state.readWithin(ex, key) == null) continue;
        await state.writeWithin(ex, key, null); // null deletes the row
        cleared++;
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
      }
    }
    await state.writeWithin(txn, 'last_sync_at', DateTime.now().toUtc().toIso8601String());
    return result;
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