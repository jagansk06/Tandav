import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show ImageProvider, MemoryImage;
import 'package:sqflite/sqflite.dart' show DatabaseFactory;

/// A locally stored database backup, described without any `dart:io` type so
/// screens can list backups on every platform.
class BackupRef {
  /// Opaque handle. An absolute file path in the Android app.
  final String id;

  /// Name shown to the user, e.g. `tandav-backup-2026-08-23T22-10-05.db`.
  final String name;

  final int sizeBytes;

  const BackupRef({
    required this.id,
    required this.name,
    required this.sizeBytes,
  });

  String get sizeLabel => '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
}

/// Everything that differs between the two ways Tandav runs.
///
/// The installable **Android app** has a real filesystem: SQLite is a file in
/// the app's database directory, student photos are images on disk, and a
/// backup is a copy of the database file.
///
/// The **browser build** (how Tandav runs on iPhone, since Apple does not allow
/// building an iOS app from Windows or Android) has none of that. It runs the
/// *same* SQLite engine compiled to WebAssembly, persisted in the browser's
/// IndexedDB, and stores photos inside the database itself.
///
/// Everything above this layer — models, repositories, screens, the sync
/// engine — is shared, unchanged, by both. Nothing here is required for Google
/// Drive sync; it is only about local storage.
abstract class TandavPlatform {
  TandavPlatform();

  /// Short name for diagnostics only.
  String get name;

  bool get isWeb;

  /// The sqflite factory used to open the Tandav database on this platform.
  DatabaseFactory get databaseFactory;

  /// Where to open [databaseName]. An absolute path on Android; in the browser
  /// the name is an IndexedDB key, so it is returned as-is.
  Future<String> databasePath(String databaseName);

  /// Test-only override for where photos and backups are kept, so unit tests
  /// never touch the real app documents directory. Ignored in the browser.
  String? documentsRootOverride;

  /// Persist a picked image and return the handle to store in
  /// `students.photo_url`. The handle is deliberately opaque: an absolute file
  /// path on Android, an inline `data:` URI in the browser.
  ///
  /// Photo handles are never synchronized — a path from one device is
  /// meaningless on the other — so each device keeps its own copy.
  Future<String> storePhoto({
    required int studentId,
    required Uint8List bytes,
    required String filename,
  });

  /// Resolve a stored handle for display, or null when there is nothing to
  /// show (no photo, or a file that has since been removed).
  ImageProvider? photoImage(String? handle);

  /// Whether on-device backup/restore is possible. False in the browser, where
  /// there is no file to copy — Google Drive sync is the safety net there.
  bool get supportsLocalBackup;

  Future<BackupRef> createBackup({required String livePath});

  Future<List<BackupRef>> listBackups();

  /// Replace the live database with [backup]. The implementation must stage the
  /// copy first, then call [closeDatabase] before swapping files in, so a
  /// failure can never leave the live database truncated. Reopening is the
  /// caller's job.
  Future<void> restoreBackup({
    required BackupRef backup,
    required String livePath,
    required Future<void> Function() closeDatabase,
  });

  // ------------------------------------------------------- inline photo bytes

  /// True when [handle] carries the image bytes itself rather than pointing at
  /// a file. Used by the browser build, and understood by both platforms so a
  /// database restored from the other one still renders.
  static bool isInlinePhoto(String handle) => handle.startsWith('data:');

  static String encodeInlinePhoto(Uint8List bytes, String filename) =>
      'data:${mimeForFilename(filename)};base64,${base64Encode(bytes)}';

  static ImageProvider? inlinePhotoImage(String handle) {
    final comma = handle.indexOf(',');
    if (comma < 0) return null;
    try {
      return MemoryImage(base64Decode(handle.substring(comma + 1)));
    } on FormatException {
      return null;
    }
  }

  static String mimeForFilename(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
    return 'image/jpeg';
  }
}
