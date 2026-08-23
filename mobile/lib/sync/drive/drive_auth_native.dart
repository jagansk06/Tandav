import 'package:google_sign_in/google_sign_in.dart';

import 'drive_auth_base.dart';
import 'drive_config.dart';

/// Android implementation, backed by the Google Play Services account picker.
///
/// No OAuth client id appears anywhere in the Android build. Google identifies
/// the app by its **package name plus signing-certificate SHA-1**, both
/// registered against an Android OAuth client in the Google Cloud console, so
/// there is no credential to hard-code and none to leak.
class PlatformDriveAuth implements DriveAuth {
  PlatformDriveAuth();

  final GoogleSignIn _signIn = GoogleSignIn(scopes: const [DriveConfig.scope]);

  String? _token;

  @override
  bool get isConnected => _token != null && _signIn.currentUser != null;

  @override
  Future<bool> restore() async {
    try {
      final account = await _signIn.signInSilently();
      if (account == null) return false;
      _token = await _tokenFor(account);
      return _token != null;
    } on Exception {
      // A silent attempt failing is normal (no cached account, no network).
      // It must never surface as an error — the user simply has to connect.
      return false;
    }
  }

  @override
  Future<void> connect() async {
    final GoogleSignInAccount? account;
    try {
      account = await _signIn.signIn();
    } on Exception catch (e) {
      throw DriveAuthException(_friendly(e));
    }
    if (account == null) throw const DriveAuthException.cancelled();

    // Signing in does not guarantee the Drive scope was granted — the user can
    // approve the account but decline the permission.
    if (!await _ensureScope()) {
      throw const DriveAuthException(
        'Tandav needs permission to save its sync file in your Google Drive. '
        'Connect again and allow Drive access.',
      );
    }
    _token = await _tokenFor(account);
    if (_token == null) {
      throw const DriveAuthException(
        'Google did not return an access token. Try connecting again.',
      );
    }
  }

  @override
  Future<String> accessToken() async {
    if (_token != null) return _token!;
    final account = _signIn.currentUser ?? await _signIn.signInSilently();
    if (account == null) {
      throw const DriveAuthException(
        'Google Drive is not connected on this device.',
      );
    }
    final token = await _tokenFor(account);
    if (token == null) {
      throw const DriveAuthException(
        'Google sign-in has expired. Connect Google Drive again.',
      );
    }
    return _token = token;
  }

  @override
  void invalidate() {
    _token = null;
    // Also drop Play Services' own cached token, otherwise the next request
    // would be handed back the same rejected one.
    _signIn.currentUser?.clearAuthCache();
  }

  @override
  Future<void> disconnect() async {
    _token = null;
    try {
      // `disconnect` revokes the grant as well as signing out, so "Disconnect"
      // in Tandav genuinely withdraws the app's Drive access.
      await _signIn.disconnect();
    } on Exception {
      await _signIn.signOut();
    }
  }

  Future<String?> _tokenFor(GoogleSignInAccount account) async {
    final auth = await account.authentication;
    return auth.accessToken;
  }

  Future<bool> _ensureScope() async {
    try {
      return await _signIn.requestScopes(const [DriveConfig.scope]);
    } on Exception {
      return false;
    }
  }

  String _friendly(Object error) {
    final text = error.toString();
    if (text.contains('network_error') || text.contains('7:')) {
      return 'No internet connection. Connect to a network and try again.';
    }
    if (text.contains('sign_in_canceled') || text.contains('12501')) {
      return 'Google sign-in was cancelled.';
    }
    if (text.contains('10:') || text.contains('DEVELOPER_ERROR')) {
      // By far the most common setup mistake, so name the fix precisely.
      return 'Google rejected this app build (DEVELOPER_ERROR). The signing '
          'certificate SHA-1 of this APK is not registered in the Google Cloud '
          'OAuth client. See SYNC.md for the exact steps.';
    }
    return 'Google sign-in failed: $text';
  }
}

DriveAuth createDriveAuth() => PlatformDriveAuth();
