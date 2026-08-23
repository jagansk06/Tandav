import 'tandav_platform_base.dart';
// Only one of these is ever compiled, so Android never sees the web SQLite
// package and the browser never sees `dart:io`.
import 'tandav_platform_stub.dart'
    if (dart.library.js_interop) 'tandav_platform_web.dart'
    if (dart.library.io) 'tandav_platform_native.dart';

export 'tandav_platform_base.dart';

/// Local storage for this build: files on Android, IndexedDB in the browser.
///
/// Created on first use, so importing this file costs nothing.
final TandavPlatform tandavPlatform = createTandavPlatform();
