/// The file format two Tandav devices exchange through a [SyncMailbox].
///
/// A bundle is a single JSON document holding one device's outbound delta for
/// *all* synced tables at once. The BLE path sends one message per table
/// because a Bluetooth link is a live conversation; a mailbox is not, so
/// everything travels together and is applied in one transaction. That is what
/// makes foreign-key remapping work: parents and children always arrive
/// together and can never be split across two separate deliveries.
library;

import 'dart:convert';

import 'protocol.dart';
import 'sync_codec.dart';
import 'sync_engine.dart';

/// Thrown when a file in the mailbox is not a bundle we can apply.
class SyncBundleException implements Exception {
  SyncBundleException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A decoded bundle: who wrote it, when, and the rows to merge.
class SyncBundle {
  SyncBundle({
    required this.deviceId,
    required this.createdAt,
    required this.tables,
    required this.protocol,
  });

  /// `TANDAV-XXXX` of the device that produced this bundle.
  final String deviceId;

  /// When the producing device wrote it (UTC).
  final DateTime createdAt;

  /// Wire protocol version the producer spoke.
  final int protocol;

  /// table -> rows, ready to hand straight to [SyncEngine.applyIncoming].
  final Map<String, List<Map<String, Object?>>> tables;

  int get rowCount => tables.values.fold(0, (sum, rows) => sum + rows.length);

  bool get isEmpty => rowCount == 0;

  /// Bundle container version. Bumped only for changes that an older app
  /// cannot read; [decode] refuses anything newer than it understands rather
  /// than silently mis-merging a paying customer's records.
  static const int formatVersion = 1;

  /// Serialise [delta] into the text written to the mailbox.
  static String encode({
    required String deviceId,
    required SyncDelta delta,
    DateTime? createdAt,
  }) {
    final tables = <String, List<Map<String, Object?>>>{};
    for (final table in SyncCodec.applyOrder) {
      final rows = delta.tables[table];
      if (rows == null || rows.isEmpty) continue;
      tables[table] = rows.map(SyncCodec.encodeRow).toList();
    }
    return jsonEncode({
      'tandav': formatVersion,
      'protocol': syncProtocolVersion,
      'deviceId': deviceId,
      'createdAt': (createdAt ?? DateTime.now().toUtc()).toIso8601String(),
      'rows': tables.values.fold<int>(0, (sum, rows) => sum + rows.length),
      'tables': tables,
    });
  }

  /// Parse a bundle read out of the mailbox.
  ///
  /// Every failure mode is turned into a [SyncBundleException] with a message
  /// fit to show the user, so a corrupt or truncated upload can never crash
  /// the app or half-apply a payload.
  static SyncBundle decode(String contents) {
    final Object? raw;
    try {
      raw = jsonDecode(contents);
    } catch (_) {
      throw SyncBundleException(
        'The sync file is damaged or was only partly uploaded.',
      );
    }
    if (raw is! Map<String, Object?>) {
      throw SyncBundleException('The sync file is not in Tandav format.');
    }

    final version = raw['tandav'];
    if (version is! int) {
      throw SyncBundleException('The sync file is not in Tandav format.');
    }
    if (version > formatVersion) {
      throw SyncBundleException(
        'That device is running a newer version of Tandav. '
        'Update this device to sync with it.',
      );
    }

    final deviceId = raw['deviceId'];
    if (deviceId is! String || deviceId.isEmpty) {
      throw SyncBundleException('The sync file does not say which device '
          'produced it.');
    }

    final protocol = raw['protocol'];
    if (protocol is! int || protocol != syncProtocolVersion) {
      throw SyncBundleException(
        'The other device uses an incompatible Tandav app version.',
      );
    }

    final created = DateTime.tryParse(raw['createdAt'] as String? ?? '');

    final tablesRaw = raw['tables'];
    if (tablesRaw is! Map<String, Object?>) {
      throw SyncBundleException('The sync file contains no records.');
    }

    final tables = <String, List<Map<String, Object?>>>{};
    for (final table in SyncCodec.applyOrder) {
      final rows = tablesRaw[table];
      if (rows == null) continue;
      if (rows is! List) {
        throw SyncBundleException('The "$table" records are damaged.');
      }
      final parsed = <Map<String, Object?>>[];
      for (final row in rows) {
        if (row is! Map) {
          throw SyncBundleException('The "$table" records are damaged.');
        }
        parsed.add(Map<String, Object?>.from(row));
      }
      if (parsed.isNotEmpty) tables[table] = parsed;
    }

    return SyncBundle(
      deviceId: deviceId,
      createdAt: (created ?? DateTime.now()).toUtc(),
      protocol: protocol,
      tables: tables,
    );
  }
}
