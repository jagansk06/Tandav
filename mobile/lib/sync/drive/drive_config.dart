/// Google Drive synchronization configuration.
///
/// ## No credentials live in this repository
///
/// Nothing here is a secret and nothing is hard-coded. The OAuth **client id**
/// is supplied at build time with `--dart-define`, so the value lives in the
/// build command / CI configuration rather than in source control:
///
/// ```
/// flutter build web --dart-define=TANDAV_GOOGLE_WEB_CLIENT_ID=xxxx.apps.googleusercontent.com
/// ```
///
/// A **client secret is never used**. Tandav is a public client (an installed
/// app and a browser app), and public clients cannot keep a secret. Android
/// authenticates with the OAuth client that Google matches by *package name +
/// SHA-1 signing fingerprint*, so the Android build needs no client id in the
/// binary at all. The web build needs only the public client id above, which
/// Google itself exposes in the page.
///
/// The only token that ever exists is a short-lived OAuth **access token** held
/// in memory for the duration of a sync. It is never written to the database,
/// never written to disk and never uploaded.
library;

class DriveConfig {
  const DriveConfig._();

  /// OAuth 2.0 Web client id, used by the browser (iOS/iPadOS Safari) build.
  ///
  /// Empty on Android, where Google resolves the client from the package name
  /// and signing certificate instead.
  static const String webClientId =
      String.fromEnvironment('TANDAV_GOOGLE_WEB_CLIENT_ID');

  /// The single OAuth scope Tandav requests.
  ///
  /// `drive.file` is the *narrowest* scope that can do the job: it grants
  /// access only to files this application itself creates, and gives Tandav no
  /// ability whatsoever to read, list or modify any other file in the user's
  /// Drive. The broad `drive`/`drive.readonly` scopes are deliberately not
  /// requested — they would expose the user's entire Drive and require Google
  /// verification.
  static const String scope = 'https://www.googleapis.com/auth/drive.file';

  /// Folder layout created inside the user's Drive:
  ///
  /// ```
  /// Google Drive
  /// └── Tandav
  ///     └── sync
  ///         ├── tandav_sync_data.json      merged snapshot (all devices)
  ///         └── devices
  ///             ├── TANDAV-A7F3.json       written only by that device
  ///             └── TANDAV-B291.json       written only by that device
  /// ```
  static const String rootFolderName = 'Tandav';
  static const String syncFolderName = 'sync';
  static const String devicesFolderName = 'devices';
  static const String mergedFileName = 'tandav_sync_data.json';

  /// Per-device file name. Each device writes **only** its own file, which is
  /// what makes concurrent syncs safe: a file with a single writer can never
  /// lose another device's changes.
  static String shardFileName(String deviceId) => '$deviceId.json';

  /// Payload format version, so a future change can be detected rather than
  /// mis-parsed. Bump only for incompatible changes.
  static const int formatVersion = 1;

  static const String folderMimeType = 'application/vnd.google-apps.folder';
  static const String jsonMimeType = 'application/json';

  /// True when the current build has everything it needs to talk to Google.
  /// The Android build never needs a client id; the web build does.
  static bool get isConfiguredForWeb => webClientId.isNotEmpty;
}
