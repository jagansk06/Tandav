/// [SyncMailbox] backed by Google Drive.
///
/// ## How it works
///
/// Both master devices sign into the **same Google account**. The app creates
/// one folder (`Tandav Sync`) and each device keeps exactly one file in it:
///
/// ```
/// Tandav Sync/
///   tandav-TANDAV-4F2A.json   <- written by phone 1, read by phone 2
///   tandav-TANDAV-9B71.json   <- written by phone 2, read by phone 1
/// ```
///
/// Each file is overwritten in place on every sync, so the folder never grows
/// and Drive storage use stays in the kilobytes.
///
/// ## Why the `drive.file` scope and nothing wider
///
/// `drive.file` grants access **only to files this app itself created**. The
/// app cannot see, list or read anything else in the customer's Drive — not
/// their photos, not their documents. Beyond being the right thing to do, this
/// is also the scope that keeps Google's verification requirements light:
/// the broad `drive` scope is classed as *restricted* and drags in a recurring
/// third-party security assessment, which this project will not pay for.
///
/// ## Setup required once, by the developer (not the customer)
///
/// 1. Google Cloud console → new project → enable the **Google Drive API**.
/// 2. OAuth consent screen → External → fill in the app name and support
///    email → add ONLY the `.../auth/drive.file` scope → **Publish** it.
///    Leaving the consent screen in *Testing* makes every sign-in expire
///    after 7 days, which would break the "buy once, works forever" promise.
/// 3. Create an **Android OAuth client** with the release keystore's SHA-1 and
///    the app's package name. Both customer phones must run that same signed
///    APK; the Drive grant is per app, so a differently-signed build cannot
///    see the other phone's file.
///
/// Nothing here expires and nothing needs renewing.
library;

import 'dart:async';
import 'dart:convert';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart' show AuthClient;

import 'sync_mailbox.dart';

class DriveMailbox extends SyncMailbox {
  DriveMailbox({
    this.folderName = 'Tandav Sync',
    String? clientId,
    GoogleSignIn? signIn,
  }) : _signIn = signIn ??
            GoogleSignIn(
              clientId: clientId,
              scopes: _scopes,
            );

  /// Folder created in the account's My Drive. Visible to the customer so they
  /// can see their data is really there, but it holds only these two files.
  final String folderName;

  /// The one scope this app ever asks for.
  static const _scopes = [drive.DriveApi.driveFileScope];

  static const _folderMime = 'application/vnd.google-apps.folder';

  final GoogleSignIn _signIn;

  AuthClient? _client;
  drive.DriveApi? _api;
  String? _folderId;

  @override
  String? get accountLabel => _signIn.currentUser?.email;

  @override
  Future<bool> isConnected() async => _api != null;

  @override
  Future<void> connect() async {
    try {
      final account = await _signIn.signIn();
      if (account == null) {
        throw MailboxException(
          'Sign-in was cancelled. Sync needs a Google account to pass changes '
          'between the two devices.',
          isAuthFailure: true,
        );
      }
      await _attach(interactive: true);
    } on MailboxException {
      rethrow;
    } catch (e) {
      throw MailboxException(_friendly(e), isAuthFailure: true);
    }
  }

  @override
  Future<bool> connectSilently() async {
    try {
      final account = await _signIn.signInSilently();
      if (account == null) return false;
      await _attach(interactive: false);
      return _api != null;
    } catch (_) {
      // Silent restore must never surface an error or a dialog — the caller
      // falls back to asking the user to connect.
      return false;
    }
  }

  /// Turn a signed-in account into an authorised Drive client.
  Future<void> _attach({required bool interactive}) async {
    var granted = await _scopesGranted();
    if (!granted && interactive) {
      granted = await _signIn.requestScopes(_scopes);
    }
    if (!granted) {
      if (!interactive) return;
      throw MailboxException(
        'Tandav needs permission to store its own sync file in your Drive. '
        'It never reads anything else in your Drive.',
        isAuthFailure: true,
      );
    }
    final client = await _signIn.authenticatedClient();
    if (client == null) {
      if (!interactive) return;
      throw MailboxException(
        'Could not get permission from Google. Please try connecting again.',
        isAuthFailure: true,
      );
    }
    _client = client;
    _api = drive.DriveApi(client);
    _folderId = null;
  }

  /// Whether the signed-in account has already granted [_scopes].
  ///
  /// `canAccessScopes` is **web-only**. Neither the Android nor the iOS plugin
  /// implements it, so on a phone the call falls through to the default in
  /// `google_sign_in_platform_interface` and throws
  /// `UnimplementedError('canAccessScopes() has not been implemented.')`.
  /// Verified against google_sign_in_platform_interface 2.5.0 line 151.
  ///
  /// On mobile that question is moot: the scopes handed to the [GoogleSignIn]
  /// constructor are part of the sign-in request, so consent has already been
  /// given (or refused) by the time we get here. So an unimplemented answer is
  /// treated as "granted" and the first real Drive call becomes the test — its
  /// 401/403 is already turned into a "reconnect the account" message by
  /// [_friendly], which is a far better failure than crashing on connect.
  Future<bool> _scopesGranted() async {
    try {
      return await _signIn.canAccessScopes(_scopes);
    } on UnimplementedError {
      return true;
    }
  }

  @override
  Future<void> disconnect() async {
    _api = null;
    _folderId = null;
    _client?.close();
    _client = null;
    try {
      await _signIn.disconnect();
    } catch (_) {
      await _signIn.signOut();
    }
  }

  drive.DriveApi get _drive {
    final api = _api;
    if (api == null) {
      throw MailboxException(
        'Connect a Google account first (Settings → Device & Sync).',
        isAuthFailure: true,
      );
    }
    return api;
  }

  /// Find the sync folder, creating it on first use.
  ///
  /// Under `drive.file` the listing only ever returns folders this app itself
  /// created, so this cannot accidentally latch onto an unrelated folder that
  /// happens to share the name.
  Future<String> _folder() async {
    final cached = _folderId;
    if (cached != null) return cached;
    try {
      final escaped = folderName.replaceAll("'", r"\'");
      final found = await _drive.files.list(
        q: "name = '$escaped' and mimeType = '$_folderMime' and trashed = false",
        spaces: 'drive',
        $fields: 'files(id,name)',
        pageSize: 10,
      );
      final existing = found.files;
      if (existing != null && existing.isNotEmpty) {
        return _folderId = existing.first.id!;
      }
      final created = await _drive.files.create(
        drive.File()
          ..name = folderName
          ..mimeType = _folderMime,
        $fields: 'id',
      );
      return _folderId = created.id!;
    } on MailboxException {
      rethrow;
    } catch (e) {
      throw MailboxException(_friendly(e));
    }
  }

  @override
  Future<List<MailboxEntry>> list() async {
    final folderId = await _folder();
    try {
      final entries = <MailboxEntry>[];
      String? pageToken;
      do {
        final page = await _drive.files.list(
          q: "'$folderId' in parents and trashed = false",
          spaces: 'drive',
          $fields: 'nextPageToken, files(id,name,modifiedTime,size)',
          pageSize: 50,
          pageToken: pageToken,
        );
        for (final f in page.files ?? const <drive.File>[]) {
          final id = f.id;
          final name = f.name;
          if (id == null || name == null) continue;
          entries.add(MailboxEntry(
            id: id,
            name: name,
            modifiedAt: f.modifiedTime?.toUtc(),
            sizeBytes: int.tryParse(f.size ?? ''),
          ));
        }
        pageToken = page.nextPageToken;
      } while (pageToken != null);
      return entries;
    } on MailboxException {
      rethrow;
    } catch (e) {
      throw MailboxException(_friendly(e));
    }
  }

  @override
  Future<String> read(MailboxEntry entry) async {
    try {
      final media = await _drive.files.get(
        entry.id,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;
      final chunks = await media.stream.toList();
      final bytes = <int>[for (final c in chunks) ...c];
      return utf8.decode(bytes);
    } on MailboxException {
      rethrow;
    } catch (e) {
      throw MailboxException(_friendly(e));
    }
  }

  @override
  Future<void> writeOwn(String deviceId, String contents) async {
    final folderId = await _folder();
    final name = SyncMailbox.fileNameFor(deviceId);
    final bytes = utf8.encode(contents);
    try {
      final existingId = await _findFileId(folderId, name);
      final media = drive.Media(
        Stream<List<int>>.value(bytes),
        bytes.length,
        contentType: 'application/json',
      );
      if (existingId == null) {
        await _drive.files.create(
          drive.File()
            ..name = name
            ..parents = [folderId]
            ..mimeType = 'application/json',
          uploadMedia: media,
          $fields: 'id',
        );
      } else {
        // Update in place so the folder always holds exactly one file per
        // device and the peer's file id never changes underneath it.
        await _drive.files.update(
          drive.File(),
          existingId,
          uploadMedia: media,
          $fields: 'id',
        );
      }
    } on MailboxException {
      rethrow;
    } catch (e) {
      throw MailboxException(_friendly(e));
    }
  }

  @override
  Future<void> delete(MailboxEntry entry) async {
    try {
      await _drive.files.delete(entry.id);
    } on MailboxException {
      rethrow;
    } catch (e) {
      throw MailboxException(_friendly(e));
    }
  }

  Future<String?> _findFileId(String folderId, String name) async {
    final escaped = name.replaceAll("'", r"\'");
    final found = await _drive.files.list(
      q: "name = '$escaped' and '$folderId' in parents and trashed = false",
      spaces: 'drive',
      $fields: 'files(id)',
      pageSize: 2,
    );
    final files = found.files;
    return (files == null || files.isEmpty) ? null : files.first.id;
  }

  /// Turn Drive and network failures into something a studio owner can act on.
  String _friendly(Object error) {
    if (error is drive.DetailedApiRequestError) {
      final code = error.status;
      if (code == 401 || code == 403) {
        final msg = error.message ?? '';
        if (msg.contains('storageQuotaExceeded')) {
          return 'The Google account is out of storage. Free up some space '
              'and sync again.';
        }
        if (code == 401) {
          return 'Google signed you out. Connect the account again.';
        }
        return 'Google refused the request. Reconnect the account and make '
            'sure Tandav still has Drive permission.';
      }
      if (code == 404) {
        return 'The sync file is no longer in Drive. The next sync will '
            'recreate it.';
      }
      if (code == 429 || (code != null && code >= 500)) {
        return 'Google Drive is busy. Try syncing again in a moment.';
      }
      return 'Google Drive error: ${error.message ?? code}';
    }
    final text = error.toString();
    if (text.contains('SocketException') ||
        text.contains('Failed host lookup') ||
        text.contains('ClientException')) {
      return 'No internet connection. Sync will run next time you are online.';
    }
    return 'Could not reach Google Drive: $text';
  }
}
