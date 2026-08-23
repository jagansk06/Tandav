import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show FileImage, ImageProvider;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import 'tandav_platform_base.dart';

/// Android (and the desktop/VM used by tests): real files on a real disk.
TandavPlatform createTandavPlatform() => NativeTandavPlatform();

class NativeTandavPlatform extends TandavPlatform {
  @override
  String get name => 'android';

  @override
  bool get isWeb => false;

  @override
  sqflite.DatabaseFactory get databaseFactory => sqflite.databaseFactory;

  @override
  Future<String> databasePath(String databaseName) async =>
      p.join(await sqflite.getDatabasesPath(), databaseName);

  @override
  Future<String> storePhoto({
    required int studentId,
    required Uint8List bytes,
    required String filename,
  }) async {
    final dir = await _dir('photos');
    final ext = p.extension(filename).isEmpty ? '.jpg' : p.extension(filename);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final dest = File(p.join(dir.path, 'student_${studentId}_$stamp$ext'));
    await dest.writeAsBytes(bytes, flush: true);
    return dest.path;
  }

  @override
  ImageProvider? photoImage(String? handle) {
    if (handle == null || handle.isEmpty) return null;
    if (TandavPlatform.isInlinePhoto(handle)) {
      return TandavPlatform.inlinePhotoImage(handle);
    }
    final file = File(handle);
    return file.existsSync() ? FileImage(file) : null;
  }

  @override
  bool get supportsLocalBackup => true;

  @override
  Future<BackupRef> createBackup({required String livePath}) async {
    final stamp =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final dir = await _dir('TandavBackups');
    final dest = File(p.join(dir.path, 'tandav-backup-$stamp.db'));
    await File(livePath).copy(dest.path);
    return _ref(dest);
  }

  @override
  Future<List<BackupRef>> listBackups() async {
    final dir = await _dir('TandavBackups');
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => p.extension(f.path) == '.db')
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    return files.map(_ref).toList();
  }

  @override
  Future<void> restoreBackup({
    required BackupRef backup,
    required String livePath,
    required Future<void> Function() closeDatabase,
  }) async {
    // Copy to a staging file first so a failed or partial copy can never
    // truncate the database the user is still using.
    final staging = '$livePath.restore.tmp';
    await File(backup.id).copy(staging);
    await closeDatabase();
    await File(staging).rename(livePath);
  }

  // ---------------------------------------------------------------- internals

  BackupRef _ref(File file) => BackupRef(
        id: file.path,
        name: p.basename(file.path),
        sizeBytes: file.existsSync() ? file.lengthSync() : 0,
      );

  Future<Directory> _dir(String name) async {
    final dir = Directory(p.join(await _documentsRoot(), name));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// The *parent* of the Flutter documents directory (`/data/user/0/<package>`
  /// on Android). Existing installations already hold absolute photo paths
  /// under it, so this must not change or their photos would disappear.
  Future<String> _documentsRoot() async {
    final override = documentsRootOverride;
    if (override != null) return override;
    return p.dirname((await getApplicationDocumentsDirectory()).path);
  }
}
