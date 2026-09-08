/// The file format two Tandav devices exchange through a [SyncMailbox].
///
/// A bundle is a single JSON document holding one device's outbound delta for
/// *all* synced tables at once. Everything travels together and is applied in
/// one transaction, which is what makes foreign-key remapping work: parents and
/// children always arrive together and can never be split across two separate
/// deliveries. (The removed Bluetooth path sent one message per table, because
/// a live link is a conversation and a mailbox is not.)
library;

import 'dart:convert';

import 'sync_codec.dart';
import 'sync_engine.dart';

/// Version of the bundle format, carried in every file as `protocol`.
///
/// **Do not change this to tidy up.** Bundles already sitting in customers'
/// Drive folders carry `1`, and [SyncBundle.decode] rejects anything else, so
/// bumping it makes both devices refuse the file the other one last wrote.
/// Bump it only for a real, incompatible format change — and then only
/// alongside code that can still read `1`.
///
/// It previously lived in `protocol.dart` with the Bluetooth wire framing, and
/// moved here when that file was deleted. The value did not change.
const int syncProtocolVersion = 1;

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
    this.acks = const {},
  });

  /// `TANDAV-XXXX` of the device that produced this bundle.
  final String deviceId;

  /// When the producing device wrote it (UTC).
  final DateTime createdAt;

  /// Wire protocol version the producer spoke.
  final int protocol;

  /// table -> rows, ready to hand straight to [SyncEngine.applyIncoming].
  final Map<String, List<Map<String, Object?>>> tables;

  /// Acknowledgements the writer carries back to its peers: peer id -> table ->
  /// the newest `updated_at` of that peer's rows the writer has handled.
  ///
  /// This is how a `sent.<peer>.<table>` mark advances — only after the peer
  /// has actually *read* our rows and, on one of its own syncs, told us it did.
  /// See [SyncEngine.recordAcks]. Additive and optional, so old bundles decode
  /// to an empty map and old builds silently ignore the field — the round trip
  /// is what makes overwriting our single file safe instead of lossy.
  final Map<String, Map<String, String>> acks;

  /// Number of tables the writer acknowledges handling, for diagnostics.
  int get ackCount => acks.values.fold(0, (sum, t) => sum + t.length);

  int get rowCount => tables.values.fold(0, (sum, rows) => sum + rows.length);

  bool get isEmpty => rowCount == 0;

  /// Bundle container version. Bumped only for changes that an older app
  /// cannot read; [decode] refuses anything newer than it understands rather
  /// than silently mis-merging a paying customer's records.
  static const int formatVersion = 1;

  /// Serialise [delta] into the text written to the mailbox.
  ///
  /// [acks] is the writer's accumulated acknowledgements from [SyncEngine]
  /// (`peer -> table -> watermark`). It is optional and defaults to empty, so
  /// old callers and test helpers keep working unchanged.
  static String encode({
    required String deviceId,
    required SyncDelta delta,
    DateTime? createdAt,
    Map<String, Map<String, String>> acks = const {},
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
      'acks': acks,
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

    // Acknowledgements are optional (old bundles do not carry them), and a
    // malformed value is ignored rather than fatal — an ack that fails to parse
    // must not block the rows next to it, it only delays one delivery mark.
    final acks = <String, Map<String, String>>{};
    final acksRaw = raw['acks'];
    if (acksRaw is Map<String, Object?>) {
      for (final peerEntry in acksRaw.entries) {
        final perTable = peerEntry.value;
        if (perTable is! Map) continue;
        final peerAcks = <String, String>{};
        for (final entry in perTable.entries) {
          final v = entry.value;
          if (v is! String || v.isEmpty) continue;
          peerAcks[entry.key] = v;
        }
        if (peerAcks.isNotEmpty) acks[peerEntry.key] = peerAcks;
      }
    }

    return SyncBundle(
      deviceId: deviceId,
      createdAt: (created ?? DateTime.now()).toUtc(),
      protocol: protocol,
      tables: tables,
      acks: acks,
    );
  }
}
