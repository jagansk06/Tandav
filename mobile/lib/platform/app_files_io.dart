import 'dart:io';

import 'package:flutter/painting.dart' show FileImage, ImageProvider;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart'
    show DatabaseFactory, databaseFactory, getDatabasesPath;

import 'app_files_api.dart';

/// Android / desktop implementation: a real file system.
///
/// This is the only place in `lib/` that may import `dart:io` or
/// `path_provider`. Both are absent from the web SDK, and an import of either
/// anywhere else fails `flutter build web` — which is the iPhone build.
class IoAppFiles implements AppFiles {
  const IoAppFiles();

  @override
  bool get supportsPhotos => true;

  @override
  bool get supportsBackups => true;

  @override
  String get unavailableMessage => '';

  @override
  Future<String> databasePath(String dbName) async =>
      p.join(await getDatabasesPath(), dbName);

  /// Nothing to do. Android does not reclaim an installed app's own storage —
  /// the only thing that removes this database is uninstalling Tandav.
  @override
  Future<void> keepDatabaseResident() async {}

  /// Note this returns the *parent* of the documents directory, which is what
  /// the original code did; photos and backups then sit beside it rather than
  /// inside it. Preserved exactly, because changing it would orphan the photos
  /// and backups already on every phone in the field.
  @override
  Future<String> documentsRoot() async =>
      p.dirname((await getApplicationDocumentsDirectory()).path);

  @override
  Future<String> ensureDirectory(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<void> copyFile(String from, String to) async {
    await File(from).copy(to);
  }

  @override
  Future<void> moveFile(String from, String to) async {
    await File(from).rename(to);
  }

  @override
  String absolutePath(String path) => File(path).absolute.path;

  @override
  Future<List<BackupEntry>> listDatabaseBackups(String dir) async {
    final entries = Directory(dir)
        .listSync()
        .whereType<File>()
        .where((f) => p.extension(f.path) == '.db')
        .map((f) {
          final stat = f.statSync();
          return BackupEntry(
            path: f.path,
            name: p.basename(f.path),
            sizeBytes: stat.size,
            modifiedAt: stat.modified,
          );
        })
        .toList()
      // Backup names are timestamped, so a plain reverse name sort is
      // newest-first and does not depend on file mtimes surviving a copy.
      ..sort((a, b) => b.name.compareTo(a.name));
    return entries;
  }

  @override
  ImageProvider? imageAt(String path) {
    if (path.isEmpty) return null;
    // `existsSync` rather than a try/catch: a student whose photo was taken on
    // the *other* phone has a path that is meaningless here, and that must show
    // the letter avatar instead of throwing during build.
    return File(path).existsSync() ? FileImage(File(path)) : null;
  }
}

AppFiles createAppFiles() => const IoAppFiles();

/// sqflite's own factory, which talks to the Android platform channel.
DatabaseFactory createDatabaseFactory() => databaseFactory;
