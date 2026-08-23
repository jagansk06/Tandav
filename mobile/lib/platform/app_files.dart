import 'package:sqflite/sqflite.dart' show DatabaseFactory;

import 'app_files_api.dart';
// The default (first) URI is the web one, so a platform that offers neither
// `dart:io` nor a browser fails loudly instead of silently picking a file
// system it does not have.
import 'app_files_web.dart' if (dart.library.io) 'app_files_io.dart' as impl;

export 'app_files_api.dart';

/// The file system, as this platform actually provides it.
///
/// Android gets the real thing; the web build gets a version that reports
/// photos and backups as unavailable. **Check `supportsPhotos` /
/// `supportsBackups` before calling anything**, and show
/// `unavailableMessage` when they are false — the web implementation throws
/// [UnsupportedOnThisPlatform] otherwise, and an uncaught exception in a
/// customer's hands is worse than an honest sentence.
final AppFiles appFiles = impl.createAppFiles();

/// The sqflite factory for this platform: the Android platform channel, or
/// WASM SQLite over IndexedDB in the browser.
///
/// Read through here rather than importing `databaseFactory` from
/// `package:sqflite` directly. That global is the *Android* factory, and
/// referencing it from shared code is exactly what makes a file impossible to
/// compile for the web.
DatabaseFactory get platformDatabaseFactory => impl.createDatabaseFactory();
