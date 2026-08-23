import 'drive_auth_base.dart';

/// Fallback for build targets with neither `dart:io` nor `dart:js_interop`.
///
/// Never selected by a real Android or web build; it exists so the conditional
/// export in `drive_auth.dart` always resolves and the analyzer stays happy.
class PlatformDriveAuth implements DriveAuth {
  @override
  bool get isConnected => false;

  @override
  Future<bool> restore() async => false;

  @override
  Future<void> connect() async => throw _unsupported;

  @override
  Future<String> accessToken() async => throw _unsupported;

  @override
  void invalidate() {}

  @override
  Future<void> disconnect() async {}

  static const _unsupported = DriveAuthException(
    'Google Drive sync is available in the Tandav Android app and in the '
    'Tandav web app. This platform is not supported.',
    misconfigured: true,
  );
}

DriveAuth createDriveAuth() => PlatformDriveAuth();
