import 'dart:typed_data';

import 'package:flutter/widgets.dart' show ImageProvider;
// `sqflite_ffi_web.dart` exports its own symbols with `show` clauses and does
// not re-export `DatabaseFactory`, so the type has to be imported separately.
// It comes from the same place the rest of the app gets it (sqflite re-exports
// sqflite_common's `sqlite_api.dart`), so it is the identical type that
// `TandavPlatform.databaseFactory` is declared with — and none of sqflite's
// Dart code touches `dart:io`, so it compiles for the browser.
import 'package:sqflite/sqflite.dart' show DatabaseFactory;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart'
    show databaseFactoryFfiWeb;

import 'tandav_platform_base.dart';

/// The browser build — how Tandav runs on iPhone.
TandavPlatform createTandavPlatform() => WebTandavPlatform();

class WebTandavPlatform extends TandavPlatform {
  @override
  String get name => 'web';

  @override
  bool get isWeb => true;

  /// The same SQLite engine the Android app uses, compiled to WebAssembly and
  /// persisted in the browser's IndexedDB. That is what lets every repository,
  /// query and migration run unchanged here — and it keeps working after the
  /// tab is closed, so the web app is offline-capable too.
  ///
  /// Requires `sqlite3.wasm` and `sqflite_sw.js` in `web/`; run
  /// `dart run sqflite_common_ffi_web:setup` once after `flutter pub get`.
  @override
  DatabaseFactory get databaseFactory => databaseFactoryFfiWeb;

  /// In the browser the "path" is just the IndexedDB key.
  @override
  Future<String> databasePath(String databaseName) async => databaseName;

  /// A web page has no filesystem, so the image bytes are kept inline in the
  /// database instead of on disk. `photo_url` is never uploaded to Drive, so
  /// these bytes stay on this device.
  @override
  Future<String> storePhoto({
    required int studentId,
    required Uint8List bytes,
    required String filename,
  }) async =>
      TandavPlatform.encodeInlinePhoto(bytes, filename);

  @override
  ImageProvider? photoImage(String? handle) {
    if (handle == null || handle.isEmpty) return null;
    if (TandavPlatform.isInlinePhoto(handle)) {
      return TandavPlatform.inlinePhotoImage(handle);
    }
    // An absolute Android file path arrived from the other device (or from a
    // restored database). There is no such file here, so fall back to the
    // student's initial rather than showing a broken image.
    return null;
  }

  /// There is no database *file* to copy in a browser. Google Drive sync is the
  /// off-device copy here, which is why the Backup/Restore actions are hidden
  /// in the web build rather than failing when tapped.
  @override
  bool get supportsLocalBackup => false;

  @override
  Future<BackupRef> createBackup({required String livePath}) =>
      throw UnsupportedError(_unsupported);

  @override
  Future<List<BackupRef>> listBackups() async => const [];

  @override
  Future<void> restoreBackup({
    required BackupRef backup,
    required String livePath,
    required Future<void> Function() closeDatabase,
  }) =>
      throw UnsupportedError(_unsupported);

  static const _unsupported =
      'Local backup files are not available in the browser. '
      'Use Google Drive Sync to keep a copy of your data off this device.';
}
