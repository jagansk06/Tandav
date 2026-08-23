/// Platform-neutral contract for obtaining a Google Drive access token.
///
/// Android and the browser need genuinely different mechanisms, and each one
/// pulls in code the other platform cannot compile:
///
/// - **Android** signs in through the Google Play Services account picker
///   (`google_sign_in`), which has no browser implementation.
/// - **The browser** uses Google Identity Services, a JavaScript library
///   reached through `dart:js_interop`, which has no native implementation.
///
/// Rather than duplicating the application, only this narrow seam is
/// platform-specific: `drive_auth.dart` conditionally exports the right
/// implementation, and everything above it — the merge engine, the Drive REST
/// client, the sync orchestration and the UI — is shared, single-source code.
///
/// ## Credentials
///
/// The only secret-like value in the system is a short-lived OAuth **access
/// token**, held in memory for the duration of a sync. No token, refresh token,
/// password or client secret is ever written to the database, to disk, or to
/// Google Drive.
library;

/// Something went wrong while connecting to Google.
class DriveAuthException implements Exception {
  final String message;

  /// True when the *user* dismissed the sign-in UI. Callers should treat this
  /// as a no-op rather than an error to report.
  final bool cancelled;

  /// True when this build is missing the configuration it needs (for example a
  /// web build with no OAuth client id compiled in).
  final bool misconfigured;

  const DriveAuthException(
    this.message, {
    this.cancelled = false,
    this.misconfigured = false,
  });

  const DriveAuthException.cancelled()
      : message = 'Google sign-in was cancelled.',
        cancelled = true,
        misconfigured = false;

  @override
  String toString() => message;
}

/// Obtains and caches OAuth access tokens for the Drive API.
abstract class DriveAuth {
  /// True when a token has been obtained and is believed to still be valid.
  bool get isConnected;

  /// Try to reconnect without showing any UI, using a session the user already
  /// approved. Returns false when an interactive [connect] is required.
  ///
  /// Safe to call on startup: it never prompts.
  Future<bool> restore();

  /// Connect interactively, showing Google's account picker / consent screen.
  ///
  /// Must be invoked directly from a user gesture — browsers block the popup
  /// otherwise.
  Future<void> connect();

  /// A currently valid access token, refreshed silently if possible.
  ///
  /// Throws [DriveAuthException] when the user must connect again.
  Future<String> accessToken();

  /// Drop the cached token after the API rejected it, so the next call fetches
  /// a fresh one.
  void invalidate();

  /// Forget the connection on this device. Local Tandav data is never touched.
  Future<void> disconnect();
}
