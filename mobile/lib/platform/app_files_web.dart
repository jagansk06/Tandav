import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/painting.dart' show ImageProvider;
// `DatabaseFactory` comes from here, not from `sqflite_ffi_web.dart`, which
// exports only the factory instance. Importing `package:sqflite` in a
// web-only file is safe: it is the platform *channel* behind these types that
// is Android-only, and tree-shaking drops it.
import 'package:sqflite/sqflite.dart' show DatabaseFactory;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import 'app_files_api.dart';

/// Web (iPhone PWA) implementation: there is no file system to speak of.
///
/// A browser gives a web app an origin-scoped sandbox, not paths — so student
/// photos and whole-database backups, both of which are path-based on Android,
/// are **switched off here** rather than half-implemented. This is the agreed
/// thin cut: get the app running on iPhone first, with the parts that do not
/// translate saying so plainly.
///
/// What a proper port would look like, when it is worth doing: photo bytes
/// stored in a table or in the origin-private file system and rendered from
/// `MemoryImage`, and backups exported as a download rather than written to a
/// directory the user cannot see. Both change the *shape* of the feature, which
/// is why neither was faked behind this shim.
class WebAppFiles implements AppFiles {
  const WebAppFiles();

  @override
  bool get supportsPhotos => false;

  @override
  bool get supportsBackups => false;

  @override
  String get unavailableMessage =>
      'This is not available in the iPhone version yet. Use the Android phone '
      'for it — everything else, including sync, works here.';

  /// The bare name. `sqflite_common_ffi_web` uses it as an IndexedDB key, so
  /// there is no directory to join it onto — and calling the factory's
  /// `getDatabasesPath()` here would only invent one.
  @override
  Future<String> databasePath(String dbName) async => dbName;

  /// `navigator.storage.persist()` — ask the browser to exempt this app's
  /// storage from automatic clean-up.
  ///
  /// Worth doing because the whole database lives in IndexedDB here, and a
  /// browser may clear "best effort" storage when the device runs short of
  /// space. Marked persistent, it is kept until the customer deletes it
  /// themselves. On iPhone, adding Tandav to the home screen is itself part of
  /// what earns that grant.
  ///
  /// Reached through untyped interop, and every step checked, because this is
  /// only a *request*: an older Safari has no `navigator.storage` at all, and
  /// reaching blindly through it would throw during startup — turning a missing
  /// nicety into an app that will not open. A refusal is also perfectly normal
  /// and nothing is done about it, so the result is not even read.
  @override
  Future<void> keepDatabaseResident() async {
    try {
      final navigator = globalContext.getProperty<JSObject?>('navigator'.toJS);
      if (navigator == null || !navigator.has('storage')) return;
      final storage = navigator.getProperty<JSObject?>('storage'.toJS);
      if (storage == null || !storage.has('persist')) return;
      await storage
          .callMethod<JSPromise<JSAny?>>('persist'.toJS)
          .toDart
          // Startup waits on this, so it must not be able to hang. A browser
          // that never settles the promise would leave the customer looking at
          // the splash screen forever.
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // Never let this stop the app starting.
    }
  }

  @override
  Future<String> documentsRoot() async => throw _no();

  @override
  Future<String> ensureDirectory(String path) async => throw _no();

  @override
  Future<void> copyFile(String from, String to) async => throw _no();

  @override
  Future<void> moveFile(String from, String to) async => throw _no();

  @override
  String absolutePath(String path) => path;

  @override
  Future<List<BackupEntry>> listDatabaseBackups(String dir) async => const [];

  /// Always null: photo paths written by the Android phone point at that
  /// phone's storage and mean nothing in a browser. The avatar falls back to
  /// the student's initial.
  @override
  ImageProvider? imageAt(String path) => null;

  UnsupportedOnThisPlatform _no() => UnsupportedOnThisPlatform(
        unavailableMessage,
      );
}

AppFiles createAppFiles() => const WebAppFiles();

/// WASM SQLite persisted in IndexedDB.
///
/// Needs **one** file served alongside the app, `sqlite3.wasm`, placed in `web/`
/// by `dart run sqflite_common_ffi_web:setup`. Without it the app loads and then
/// fails on the first query, which looks like a database bug rather than a
/// missing asset, so check for it first if the web build cannot open its
/// database.
///
/// ## Why the no-web-worker factory, and not the default one
///
/// The package's default (`databaseFactoryFfiWeb`) runs SQLite inside a
/// **shared worker** loaded from `sqflite_sw.js`. Two reasons not to:
///
/// 1. **iOS Safari has never supported `SharedWorker`.** The iPhone is the
///    entire reason this build exists, so the worker would fall back to a basic
///    `Worker` there — a second code path that only the target device takes,
///    which is the worst possible place for one.
/// 2. **The worker swallows its own errors.** In `shared_worker.dart` the
///    handler's outer `catch` ends in `port.postMessage(null)`, so *any* failure
///    inside the worker — including the wasm not loading at all — comes back to
///    the app as an empty reply and surfaces as
///    `Unsupported operation: unsupported result null (null)` from
///    `sqflite_common`, with the real message printed only in the worker's own
///    console. That cost most of a day. On this path the exception is rethrown
///    and lands in the page console where it belongs.
///
/// The cost is that queries run on the main isolate rather than off it. For a
/// studio's few hundred rows that is not measurable, and it is the right trade
/// for a failure mode that is visible.
DatabaseFactory createDatabaseFactory() => databaseFactoryFfiWebNoWebWorker;
