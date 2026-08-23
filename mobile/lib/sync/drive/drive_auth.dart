/// Resolves [DriveAuth] to the implementation the current build target
/// supports, so shared code can depend on the interface alone.
///
/// The conditional export is what keeps the two platforms genuinely isolated:
/// a `flutter build web` never compiles the Android sign-in plugin, and a
/// `flutter build apk` never compiles the JavaScript interop. Neither platform
/// can break the other's build.
library;

export 'drive_auth_base.dart';
export 'drive_auth_stub.dart'
    if (dart.library.js_interop) 'drive_auth_web.dart'
    if (dart.library.io) 'drive_auth_native.dart';
