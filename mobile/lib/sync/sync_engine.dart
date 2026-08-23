import 'package:sqflite/sqflite.dart';

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
/// - **Incremental** – every table keeps TWO independent per-table marks, and
///   conflating them was a data-loss bug, so keep them apart:
///     * `sent.<table>` – the newest `updated_at` we have actually **delivered**
///       to the peer. This, and only this, decides what [computeOutbound]
///       sends. It is advanced by [markDeltaSent] after a *confirmed* send.
///     * `watermark.<table>` – the newest `updated_at` we have **received** from
///       the peer. Bookkeeping/diagnostics only.
///   Filtering our own outbound rows by the *received* mark is wrong: the
///   peer's timestamps say nothing about which of OUR rows the peer has seen.
///   If the peer's clock ran even a minute ahead, every local edit we made in
///   that minute sorted below the mark and became permanently unsendable.
/// - **Conflict resolution** – last-write-wins by `updated_at` (UTC ISO-8601).
///   On equal timestamps the lexicographically higher `device_id` wins
///   (deterministic and stable across both devices).
/// - **Identity** – every record carries a stable `sync_uuid`; local integer
///   ids differ per device and are re-mapped on merge via FK->uuid resolution.
/// - **Deletions** – records are soft-deleted (tombstoned with `deleted_at`),
///   so a deletion reaches the peer instead of vanishing permanently.
/// - **Atomicity** – all inbound rows for all tables are applied inside one
///   transaction with the watermark advances; a failure rolls everything back
///   and the local database is never left half-updated.
class SyncEngine {
  final TandavDatabase db;
  final SyncState state;
  SyncEngine(this.db, this.state);

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

  /// Key holding the newest `updated_at` we have successfully delivered to the
  /// peer for [table]. Absent (== '') means "the peer has never had anything
  /// from us", which correctly forces a full send.
  static String sentKey(String table) => 'sent.$table';

  /// Key holding the newest `updated_at` we have received from the peer for
  /// [table]. Deliberately NOT used to filter outbound rows — see the class
  /// doc for why that was a bug.
  static String receivedKey(String table) => 'watermark.$table';

  /// Rows we must send to the peer: everything we have not already delivered.
  ///
  /// Called with a read-only transaction so the snapshot is consistent with
  /// the mark it is based on.
  Future<SyncDelta> computeOutbound(Transaction txn) async {
    final delta = SyncDelta();
    // Read our clock BEFORE querying, so every row written after this point is
    // strictly above the mark markDeltaSent will set.
    delta.snapshotAt = DateTime.now().toUtc().toIso8601String();
    for (final table in SyncCodec.applyOrder) {
      final sent = await state.readWithin(txn, sentKey(table)) ?? '';
      final rows = sent.isEmpty
          ? await _selectAll(txn, table)
          : await txn.query(table, where: 'updated_at > ?', whereArgs: [sent]);
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

  /// Record that every row in [delta] has reached the peer, so the next
  /// [computeOutbound] does not send it again.
  ///
  /// **Only call this once delivery is confirmed.** Over the Drive mailbox that
  /// is a successful file write — the bundle now sits in the account and the
  /// peer will read it whenever it next syncs. Calling it merely because we
  /// *attempted* a send would drop rows whenever the upload failed; calling it
  /// late only costs a harmless re-send, so when in doubt, call it late.
  Future<void> markDeltaSent(Transaction txn, SyncDelta delta) async {
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
      final key = sentKey(entry.key);
      final current = await state.readWithin(txn, key) ?? '';
      // Never move the mark backwards: a clock that jumped back would
      // otherwise re-send, and worse, a later correct value would be lost.
      if (max.compareTo(current) > 0) {
        await state.writeWithin(txn, key, max);
      }
    }
  }

  /// Forget which of our rows the peer has already received, so the next sync
  /// offers the **whole** local dataset again. Returns how many marks existed.
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
  /// `sent.isEmpty` and falls back to selecting every row, so an empty string
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
  /// have *received*, and lowering them would make us re-apply the peer's rows
  /// against our own — pointless work with real conflict-resolution risk.
  Future<int> clearSentMarks(SyncExecutor ex) async {
    var cleared = 0;
    for (final table in SyncCodec.applyOrder) {
      final key = sentKey(table);
      if (await state.readWithin(ex, key) == null) continue;
      await state.writeWithin(ex, key, null); // null deletes the row
      cleared++;
    }
    return cleared;
  }

  /// Apply rows received from the peer inside one transaction.
  Future<SyncApplyResult> applyIncoming(
    Transaction txn,
    Map<String, List<Map<String, Object?>>> incoming, {
    required String peerDeviceId,
  }) async {
    final result = SyncApplyResult();
    // uuid -> local id, built as parent tables are applied first so child
    // foreign keys can be resolved.
    final uuidMap = <String, Map<String, int>>{};

    for (final table in SyncCodec.applyOrder) {
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