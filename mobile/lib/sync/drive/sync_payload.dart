import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../sync_codec.dart';
import '../sync_engine.dart';
import 'drive_config.dart';

/// Serialisation for the JSON documents Tandav exchanges through Google Drive.
///
/// Two document shapes share one envelope:
///
/// - **A device shard** (`devices/TANDAV-XXXX.json`) — the rows one device
///   owns. Exactly one device ever writes a given shard, which is what makes
///   concurrent syncs safe without locking.
/// - **The merged snapshot** (`tandav_sync_data.json`) — the union of every
///   shard, written best-effort after a successful merge. It is informational
///   and a bootstrap for a brand-new device; the shards remain authoritative,
///   so a race on this file can never lose data.
///
/// ## What is deliberately never uploaded
///
/// Only the business rows the application needs to converge are written. In
/// particular:
///
/// - **No credentials.** The `users` table (which holds password hashes) is not
///   a syncable table, so account data cannot reach Drive by construction.
///   [_assertNoSecrets] additionally refuses to serialise any column whose name
///   looks like a secret, so a future schema change cannot quietly start
///   leaking one.
/// - **No local file paths.** `photo_url` holds an absolute path on the device
///   that wrote it, which is meaningless — and a small privacy leak — on any
///   other device. It is stripped. Because the column is then *absent* rather
///   than null, merging leaves each device's own photo path untouched.
/// - **No application files.** No APK, no source, no database file, no keys.
class SyncPayload {
  const SyncPayload._();

  /// Columns removed from every outbound row: device-local and useless (or
  /// harmful) anywhere else.
  static const Set<String> redactedColumns = {'photo_url'};

  /// Column names that must never be serialised. Matched defensively so a
  /// future schema addition cannot silently start syncing a credential.
  static final RegExp _secretish =
      RegExp(r'password|secret|token|credential|private_key', caseSensitive: false);

  // ------------------------------------------------------------- encoding

  /// Build this device's shard document from its owned-row snapshot.
  static Map<String, Object?> encodeShard({
    required String deviceId,
    required SyncDelta delta,
    required String uploadedAt,
  }) {
    final tables = encodeTables(delta);
    return {
      'formatVersion': DriveConfig.formatVersion,
      'deviceId': deviceId,
      'uploadedAt': uploadedAt,
      'rowCounts': {for (final e in tables.entries) e.key: e.value.length},
      'tables': tables,
    };
  }

  /// Encode a [SyncDelta] to JSON-safe `{table: [row, ...]}`.
  static Map<String, List<Map<String, Object?>>> encodeTables(SyncDelta delta) {
    final out = <String, List<Map<String, Object?>>>{};
    for (final table in SyncCodec.applyOrder) {
      final rows = delta.tables[table];
      if (rows == null || rows.isEmpty) continue;
      out[table] = rows.map(_encodeRow).toList();
    }
    return out;
  }

  static Map<String, Object?> _encodeRow(Map<String, Object?> row) {
    final encoded = SyncCodec.encodeRow(row);
    encoded.removeWhere((key, _) => redactedColumns.contains(key));
    _assertNoSecrets(encoded);
    return encoded;
  }

  static void _assertNoSecrets(Map<String, Object?> row) {
    for (final key in row.keys) {
      if (_secretish.hasMatch(key)) {
        throw StateError(
          'Refusing to upload column "$key": it looks like a credential. '
          'Add it to SyncPayload.redactedColumns or remove it from the '
          'table\'s SyncSchema before syncing.',
        );
      }
    }
  }

  /// The merged snapshot document, written after a successful merge.
  static Map<String, Object?> encodeMergedSnapshot({
    required String generatedBy,
    required String generatedAt,
    required Iterable<String> devices,
    required Map<String, List<Map<String, Object?>>> tables,
  }) {
    return {
      'formatVersion': DriveConfig.formatVersion,
      'generatedBy': generatedBy,
      'generatedAt': generatedAt,
      'devices': devices.toList()..sort(),
      'note':
          'Merged view of every device shard in ./devices. The shards are the '
          'source of truth; this file is a convenience snapshot.',
      'rowCounts': {for (final e in tables.entries) e.key: e.value.length},
      'tables': tables,
    };
  }

  static String toJsonString(Map<String, Object?> doc) =>
      const JsonEncoder.withIndent('  ').convert(doc);

  /// Stable hash of a shard's *content*, ignoring the upload timestamp, so an
  /// unchanged database costs no upload at all.
  static String contentHash(Map<String, List<Map<String, Object?>>> tables) =>
      sha256.convert(utf8.encode(jsonEncode(tables))).toString();

  // ------------------------------------------------------------- decoding

  /// Parse a shard or snapshot document into `{table: [row, ...]}`.
  ///
  /// Unknown tables and malformed rows are ignored rather than throwing: a
  /// newer Tandav version writing an extra table must not break an older one.
  static ParsedPayload decode(String jsonString) {
    final Object? root = jsonDecode(jsonString);
    if (root is! Map<String, dynamic>) {
      throw const FormatException('Sync file is not a JSON object.');
    }
    final version = root['formatVersion'];
    if (version is int && version > DriveConfig.formatVersion) {
      throw FormatException(
        'This sync file was written by a newer version of Tandav '
        '(format $version, this app understands ${DriveConfig.formatVersion}). '
        'Update Tandav on this device before syncing.',
      );
    }
    final tables = <String, List<Map<String, Object?>>>{};
    final rawTables = root['tables'];
    if (rawTables is Map<String, dynamic>) {
      for (final table in SyncCodec.applyOrder) {
        final rows = rawTables[table];
        if (rows is! List) continue;
        final parsed = <Map<String, Object?>>[];
        for (final row in rows) {
          if (row is Map<String, dynamic>) {
            parsed.add(Map<String, Object?>.from(row));
          }
        }
        if (parsed.isNotEmpty) tables[table] = parsed;
      }
    }
    return ParsedPayload(
      deviceId: root['deviceId'] as String? ?? '',
      uploadedAt: root['uploadedAt'] as String? ?? '',
      tables: tables,
    );
  }

  /// Combine several shards into one inbound batch.
  ///
  /// The same record can legitimately appear in more than one shard: a row
  /// migrates to the shard of whichever device edited it last, and the previous
  /// owner's shard still holds its stale copy until that device next syncs.
  /// Duplicates are collapsed here using exactly the engine's rule — newest
  /// `updated_at`, ties broken by the higher `device_id` — so the merge does
  /// less work and the outcome is order-independent.
  static Map<String, List<Map<String, Object?>>> combine(
    Iterable<ParsedPayload> payloads,
  ) {
    final byTable = <String, Map<String, Map<String, Object?>>>{};
    final positional = <String, List<Map<String, Object?>>>{};

    for (final payload in payloads) {
      for (final entry in payload.tables.entries) {
        for (final row in entry.value) {
          final uuid = row['sync_uuid'] as String? ?? '';
          if (uuid.isEmpty) {
            // No stable identity: cannot dedupe, pass through untouched and
            // let the engine's natural-key matching handle it.
            positional.putIfAbsent(entry.key, () => []).add(row);
            continue;
          }
          final slot = byTable.putIfAbsent(entry.key, () => {});
          final existing = slot[uuid];
          if (existing == null || _wins(row, existing)) {
            slot[uuid] = row;
          }
        }
      }
    }

    final out = <String, List<Map<String, Object?>>>{};
    for (final table in SyncCodec.applyOrder) {
      final rows = <Map<String, Object?>>[
        ...?byTable[table]?.values,
        ...?positional[table],
      ];
      if (rows.isNotEmpty) out[table] = rows;
    }
    return out;
  }

  /// Last-write-wins, matching [SyncEngine]'s comparison exactly.
  static bool _wins(Map<String, Object?> a, Map<String, Object?> b) {
    final at = a['updated_at'] as String? ?? '';
    final bt = b['updated_at'] as String? ?? '';
    final cmp = at.compareTo(bt);
    if (cmp != 0) return cmp > 0;
    final ad = a['device_id'] as String? ?? '';
    final bd = b['device_id'] as String? ?? '';
    return ad.compareTo(bd) > 0;
  }
}

/// A decoded shard or snapshot document.
class ParsedPayload {
  final String deviceId;
  final String uploadedAt;
  final Map<String, List<Map<String, Object?>>> tables;

  const ParsedPayload({
    required this.deviceId,
    required this.uploadedAt,
    required this.tables,
  });

  int get rowCount => tables.values.fold(0, (sum, rows) => sum + rows.length);

  bool get isEmpty => rowCount == 0;
}
