import 'package:flutter/painting.dart' show ImageProvider;

/// The file-system operations Tandav needs, in a form that compiles everywhere.
///
/// **This is a thin-cut shim, not the intended design.** It is deliberately
/// path-shaped, mirroring the `dart:io` calls that were scattered through
/// `tandav_database.dart`, `student_repository.dart`, `home_shell.dart` and
/// `student_detail_screen.dart`, because the goal was to let the app *compile
/// for the web* — which is how the iPhone ships, as a PWA — without rewriting
/// features that already work on Android.
///
/// Two features live behind it and **neither works on the web build yet**:
/// student photos and whole-database backups. The web implementation reports
/// [supportsPhotos] / [supportsBackups] as false and throws
/// [UnsupportedOnThisPlatform] if called anyway; every caller is expected to
/// check first and show the message rather than let an exception surface.
///
/// When those features are properly ported, **re-cut this abstraction at the
/// feature level** — a `PhotoStore` that hands back an opaque handle, a
/// `BackupStore` that owns create/list/restore — rather than growing this one.
/// A path-shaped interface quietly assumes a hierarchical file system with
/// stable absolute paths, which a browser does not have.
abstract class AppFiles {
  /// Whether student photos can be saved and displayed.
  bool get supportsPhotos;

  /// Whether whole-database backups can be written, listed and restored.
  bool get supportsBackups;

  /// One sentence to show the user when a feature is unavailable here. Written
  /// for a studio owner, not a developer.
  String get unavailableMessage;

  /// Where the SQLite database for [dbName] lives.
  ///
  /// Available on **every** platform, unlike the rest of this interface — the
  /// database is the one thing the web build must have. On Android it is a real
  /// path under the app's databases directory; in the browser it is an opaque
  /// key into IndexedDB, and nothing may take it apart or join onto it.
  Future<String> databasePath(String dbName);

  /// Ask the platform to keep the database safe from automatic clean-up.
  ///
  /// Also available on every platform, and a no-op on Android, where an app's
  /// own storage is never reclaimed while the app is installed.
  ///
  /// It matters in the browser. The iPhone build keeps the studio's entire
  /// database in IndexedDB, which a browser is allowed to throw away when the
  /// device runs low on space — and that database is the customer's only copy on
  /// that device. This asks for it to be marked persistent instead.
  ///
  /// **Never throws, and the answer is not worth branching on.** Browsers decide
  /// this by their own rules, "no" is a normal answer, and there is nothing
  /// useful to tell the customer either way. If the storage is cleared anyway,
  /// the recovery path is the one that already exists: sign in again and use
  /// "Send everything again" on the Android phone.
  Future<void> keepDatabaseResident();

  /// Root directory for app-owned files (photos, backups).
  Future<String> documentsRoot();

  /// Create [path] if absent and return it.
  Future<String> ensureDirectory(String path);

  Future<void> copyFile(String from, String to);

  /// Move [from] onto [to], replacing it. Used for the final swap of a restore,
  /// which must not leave the live database half-written.
  Future<void> moveFile(String from, String to);

  /// Absolute form of [path]. A restore compares this against the live database
  /// path to refuse restoring a file over itself.
  String absolutePath(String path);

  /// `.db` files in [dir], newest first.
  Future<List<BackupEntry>> listDatabaseBackups(String dir);

  /// Image to render for a stored photo path, or null when there is nothing to
  /// show — a missing file, or a platform that cannot read one.
  ///
  /// **Never throws.** It is called from `build`, and an unavailable photo must
  /// degrade to the initial-letter avatar, not to a red screen.
  ImageProvider? imageAt(String path);
}

/// One locally stored backup, described without naming a `dart:io` `File`.
class BackupEntry {
  const BackupEntry({
    required this.path,
    required this.name,
    required this.sizeBytes,
    this.modifiedAt,
  });

  /// Opaque handle. A filesystem path on Android; nothing may assume that.
  final String path;

  /// What to show the user, e.g. `tandav-backup-2026-08-23T19-04-11.db`.
  final String name;

  final int sizeBytes;
  final DateTime? modifiedAt;

  String get sizeLabel => '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
}

/// Thrown when a caller reaches a file operation the current platform cannot
/// perform. [message] is safe to show to the user as-is.
class UnsupportedOnThisPlatform implements Exception {
  const UnsupportedOnThisPlatform(this.message);
  final String message;

  @override
  String toString() => message;
}
