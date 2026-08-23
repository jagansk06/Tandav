// Google Identity Services option bags use snake_case property names
// (`client_id`, `error_callback`, `access_token`). For an `external` interop
// declaration the Dart member name *is* the JavaScript property name, so these
// cannot be renamed to lowerCamelCase without breaking the call. Keeping them
// identical to Google's documented API is also what makes this file checkable
// against those docs.
// ignore_for_file: non_constant_identifier_names

import 'dart:async';
import 'dart:js_interop';

import 'drive_auth_base.dart';
import 'drive_config.dart';

/// Browser implementation (this is what runs on iPhone/iPad, in Safari).
///
/// Uses the Google Identity Services **OAuth 2.0 token flow**, which is the
/// browser-native way to obtain an access token for a Google API. GIS is loaded
/// by a `<script>` tag in `web/index.html`; only the *public* OAuth client id
/// is involved, injected at build time (see [DriveConfig]). There is no client
/// secret — a browser could not keep one.
///
/// The token lives in a Dart field for the lifetime of the page and is never
/// written to storage.
class PlatformDriveAuth implements DriveAuth {
  PlatformDriveAuth();

  _TokenClient? _client;
  String? _token;
  DateTime? _obtainedAt;
  Completer<String>? _inFlight;

  /// GIS access tokens are valid for about an hour. Rather than reading
  /// `expires_in` back across the JS boundary, treat a token as stale well
  /// before that and refresh silently; a token rejected early is also handled,
  /// because [invalidate] is called on any 401 from Drive.
  static const _assumedLifetime = Duration(minutes: 50);

  @override
  bool get isConnected {
    final at = _obtainedAt;
    return _token != null &&
        at != null &&
        DateTime.now().difference(at) < _assumedLifetime;
  }

  @override
  Future<bool> restore() async {
    if (!DriveConfig.isConfiguredForWeb) return false;
    try {
      // `prompt: ''` asks GIS to reuse an existing grant without showing any
      // UI. It fails harmlessly when the user has not consented yet.
      await _requestToken(prompt: '');
      return true;
    } on DriveAuthException {
      return false;
    }
  }

  @override
  Future<void> connect() async {
    if (!DriveConfig.isConfiguredForWeb) {
      throw const DriveAuthException(
        'This web build has no Google OAuth client id compiled in. Rebuild '
        'with --dart-define=TANDAV_GOOGLE_WEB_CLIENT_ID=... (see SYNC.md).',
        misconfigured: true,
      );
    }
    // Default prompt: shows the account chooser / consent screen when needed.
    await _requestToken();
  }

  @override
  Future<String> accessToken() async {
    if (isConnected) return _token!;
    // Expired or never obtained: try silently first so a long session does not
    // interrupt the user mid-sync.
    try {
      return await _requestToken(prompt: '');
    } on DriveAuthException {
      throw const DriveAuthException(
        'Google Drive access has expired. Tap Connect Google Drive again.',
      );
    }
  }

  @override
  void invalidate() {
    _token = null;
    _obtainedAt = null;
  }

  @override
  Future<void> disconnect() async {
    final token = _token;
    invalidate();
    if (token == null) return;
    try {
      // Revoke the grant so "Disconnect" genuinely withdraws Drive access
      // rather than just forgetting the token locally.
      _revoke(token, (JSObject _) {}.toJS);
    } on Object catch (_) {
      // Revocation is best-effort: the token is already discarded locally.
    }
  }

  /// Ask GIS for a token. Resolves with the token or throws
  /// [DriveAuthException].
  Future<String> _requestToken({String? prompt}) {
    final existing = _inFlight;
    if (existing != null) return existing.future;

    final pending = Completer<String>();
    _inFlight = pending;

    // Not awaited: the token arrives through the GIS callbacks, so this only
    // has to get the request started and report a failure to start.
    _tokenClient().then(
      (client) => client.requestAccessToken(
        prompt == null ? null : _TokenRequestOverrides(prompt: prompt),
      ),
      onError: (Object e) => _fail(
        'Could not reach Google sign-in. Check your internet connection '
        'and that no content blocker is blocking accounts.google.com. ($e)',
      ),
    );

    return pending.future;
  }

  /// The GIS token client, created on first use and reused afterwards.
  ///
  /// `index.html` loads the GIS script with `async defer` so that an
  /// unreachable or ad-blocked accounts.google.com can never hold up Tandav's
  /// own startup. The consequence is that `google.accounts.oauth2` may
  /// legitimately not exist yet on the first attempt — which is exactly the
  /// case for the silent reconnect that runs while the app is still starting.
  /// So retry briefly instead of reporting a failure the admin cannot act on.
  Future<_TokenClient> _tokenClient() async {
    final ready = _client;
    if (ready != null) return ready;

    // ~8 s of retries: long enough for the script on a slow phone connection,
    // short enough that a genuinely offline device gets a clear answer.
    for (var attempt = 0;; attempt++) {
      try {
        return _client = _initTokenClient(_TokenClientConfig(
          client_id: DriveConfig.webClientId,
          scope: DriveConfig.scope,
          // These callbacks resolve whichever request is currently in flight.
          // They must NOT capture one particular Completer: the client is
          // cached and outlives the request that created it, so a captured
          // completer would already be finished by the time the *next* sync
          // ran, and that sync would wait forever.
          callback: _onToken.toJS,
          error_callback: _onError.toJS,
        ));
      } on Object {
        // Thrown while `google.accounts.oauth2` is still undefined, i.e. the
        // GIS script has not loaded (yet, or at all).
        if (attempt >= 40) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  /// GIS handed us a token (or an in-band error).
  void _onToken(_TokenResponse response) {
    final token = response.access_token;
    if (token == null || token.isEmpty) {
      final err = response.error ?? 'unknown_error';
      _fail(
        err == 'access_denied'
            ? 'Drive permission was declined. Tandav can only sync once you '
                'allow it to save its own file in Drive.'
            : 'Google returned an error: $err',
        cancelled: err == 'access_denied',
      );
      return;
    }
    _token = token;
    _obtainedAt = DateTime.now();
    final pending = _inFlight;
    _inFlight = null;
    if (pending != null && !pending.isCompleted) pending.complete(token);
  }

  /// GIS reported that the flow itself failed (popup blocked, cancelled, ...).
  void _onError(_TokenError error) =>
      _fail(_friendly(error), cancelled: _isCancel(error));

  /// Fail the in-flight request. A no-op when nothing is pending, because GIS
  /// is free to invoke its error callback more than once.
  void _fail(String message, {bool cancelled = false}) {
    final pending = _inFlight;
    _inFlight = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(DriveAuthException(message, cancelled: cancelled));
    }
  }

  bool _isCancel(_TokenError error) {
    final type = error.type ?? '';
    return type == 'popup_closed' || type == 'user_cancel';
  }

  String _friendly(_TokenError error) {
    switch (error.type ?? '') {
      case 'popup_failed_to_open':
        // The usual cause on iOS Safari: the popup was not tied to a tap.
        return 'Safari blocked the Google sign-in window. Allow pop-ups for '
            'this site, then tap Connect Google Drive again.';
      case 'popup_closed':
      case 'user_cancel':
        return 'Google sign-in was cancelled.';
      default:
        return error.message ?? 'Google sign-in failed.';
    }
  }
}

DriveAuth createDriveAuth() => PlatformDriveAuth();

// ---------------------------------------------------------------------------
// Google Identity Services interop. Mirrors the documented shape of
// https://accounts.google.com/gsi/client (the OAuth 2.0 token client).
// ---------------------------------------------------------------------------

@JS('google.accounts.oauth2.initTokenClient')
external _TokenClient _initTokenClient(_TokenClientConfig config);

@JS('google.accounts.oauth2.revoke')
external void _revoke(String token, JSFunction done);

extension type _TokenClient._(JSObject _) implements JSObject {
  external void requestAccessToken([_TokenRequestOverrides? overrides]);
}

extension type _TokenClientConfig._(JSObject _) implements JSObject {
  external factory _TokenClientConfig({
    String client_id,
    String scope,
    JSFunction callback,
    JSFunction error_callback,
  });
}

extension type _TokenRequestOverrides._(JSObject _) implements JSObject {
  external factory _TokenRequestOverrides({String prompt});
}

extension type _TokenResponse._(JSObject _) implements JSObject {
  external String? get access_token;
  external String? get error;
}

extension type _TokenError._(JSObject _) implements JSObject {
  external String? get type;
  external String? get message;
}
