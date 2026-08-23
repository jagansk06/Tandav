import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'drive_config.dart';

/// A Drive operation that failed, carrying a message fit to show a user.
class DriveException implements Exception {
  final String message;

  /// True when the access token was rejected, so the caller should re-auth and
  /// retry once rather than reporting a hard failure.
  final bool isUnauthorized;

  /// True when Drive says the file/folder no longer exists, so cached ids must
  /// be dropped and the path re-resolved.
  final bool isNotFound;

  const DriveException(
    this.message, {
    this.isUnauthorized = false,
    this.isNotFound = false,
  });

  @override
  String toString() => message;
}

/// A file entry as returned by Drive.
class DriveFile {
  final String id;
  final String name;
  final String? modifiedTime;

  const DriveFile({required this.id, required this.name, this.modifiedTime});
}

/// Minimal Google Drive v3 client covering exactly the five operations Tandav
/// needs: find a file, create a folder, list a folder, download a file and
/// upload/overwrite a file.
///
/// Written directly against the REST API with `package:http` rather than
/// pulling in the `googleapis` package: that package is very large, and this
/// surface is small, stable and identical on Android and in the browser.
///
/// Every request carries a short-lived OAuth access token supplied by the
/// caller. The client never stores it.
class DriveClient {
  final http.Client _http;

  /// Supplies a fresh OAuth access token for each request. Injected rather than
  /// stored so this client holds no credential of its own.
  final Future<String> Function() accessToken;

  DriveClient({
    required this.accessToken,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  static const _apiHost = 'www.googleapis.com';
  static const _filesPath = '/drive/v3/files';
  static const _uploadPath = '/upload/drive/v3/files';

  Future<Map<String, String>> _headers([Map<String, String>? extra]) async {
    final token = await accessToken();
    return {
      'Authorization': 'Bearer $token',
      ...?extra,
    };
  }

  /// Drive's `q` parameter is a string literal syntax, so embedded quotes and
  /// backslashes must be escaped or a name could alter the query.
  static String _escape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  Never _fail(http.Response response, String action) {
    final status = response.statusCode;
    String detail = '';
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['error'] is Map) {
        detail = (body['error']['message'] as String?) ?? '';
      }
    } catch (_) {
      // Non-JSON error body; the status code alone will have to do.
    }

    if (status == 401) {
      throw const DriveException(
        'Google sign-in has expired. Connect Google Drive again.',
        isUnauthorized: true,
      );
    }
    if (status == 403) {
      final friendly = detail.contains('storageQuota') ||
              detail.toLowerCase().contains('quota')
          ? 'Your Google Drive is full. Free up space and try again.'
          : detail.isNotEmpty
              ? detail
              : 'Google Drive refused the request. Check that Drive access was '
                  'granted when signing in.';
      throw DriveException(friendly);
    }
    if (status == 404) {
      throw DriveException(
        'The Tandav folder was not found in Google Drive. It will be recreated '
        'on the next sync.',
        isNotFound: true,
      );
    }
    if (status == 429 || status >= 500) {
      throw DriveException(
        'Google Drive is temporarily unavailable (error $status). Try again in '
        'a moment.',
      );
    }
    throw DriveException(
      detail.isNotEmpty
          ? 'Could not $action: $detail'
          : 'Could not $action (Google Drive error $status).',
    );
  }

  // --------------------------------------------------------------- folders

  /// Find a non-trashed child of [parentId] by exact name, or null.
  ///
  /// With the `drive.file` scope this only ever sees files Tandav created,
  /// which is precisely the intent — Tandav cannot enumerate the user's Drive.
  Future<DriveFile?> findChild(
    String name, {
    String? parentId,
    bool foldersOnly = false,
  }) async {
    final clauses = <String>[
      "name = '${_escape(name)}'",
      'trashed = false',
      if (parentId != null) "'${_escape(parentId)}' in parents",
      if (foldersOnly) "mimeType = '${DriveConfig.folderMimeType}'",
    ];
    final uri = Uri.https(_apiHost, _filesPath, {
      'q': clauses.join(' and '),
      'spaces': 'drive',
      'fields': 'files(id,name,modifiedTime)',
      'pageSize': '10',
    });
    final res = await _http.get(uri, headers: await _headers());
    if (res.statusCode != 200) _fail(res, 'look up "$name" in Google Drive');
    final files = (jsonDecode(res.body)['files'] as List?) ?? const [];
    if (files.isEmpty) return null;
    final first = files.first as Map<String, dynamic>;
    return DriveFile(
      id: first['id'] as String,
      name: first['name'] as String? ?? name,
      modifiedTime: first['modifiedTime'] as String?,
    );
  }

  Future<DriveFile> createFolder(String name, {String? parentId}) async {
    final uri = Uri.https(_apiHost, _filesPath, {'fields': 'id,name'});
    final res = await _http.post(
      uri,
      headers: await _headers({'Content-Type': 'application/json'}),
      body: jsonEncode({
        'name': name,
        'mimeType': DriveConfig.folderMimeType,
        if (parentId != null) 'parents': [parentId],
      }),
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      _fail(res, 'create the "$name" folder in Google Drive');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return DriveFile(id: body['id'] as String, name: name);
  }

  /// Find [name] under [parentId], creating it if absent.
  Future<DriveFile> ensureFolder(String name, {String? parentId}) async {
    final found = await findChild(name, parentId: parentId, foldersOnly: true);
    if (found != null) return found;
    return createFolder(name, parentId: parentId);
  }

  /// Every non-trashed file directly inside [parentId].
  Future<List<DriveFile>> listChildren(String parentId) async {
    final out = <DriveFile>[];
    String? pageToken;
    do {
      final uri = Uri.https(_apiHost, _filesPath, {
        'q': "'${_escape(parentId)}' in parents and trashed = false",
        'spaces': 'drive',
        'fields': 'nextPageToken,files(id,name,modifiedTime)',
        'pageSize': '100',
        'pageToken': ?pageToken,
      });
      final res = await _http.get(uri, headers: await _headers());
      if (res.statusCode != 200) _fail(res, 'list the Tandav sync folder');
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      for (final f in (body['files'] as List?) ?? const []) {
        final map = f as Map<String, dynamic>;
        out.add(DriveFile(
          id: map['id'] as String,
          name: map['name'] as String? ?? '',
          modifiedTime: map['modifiedTime'] as String?,
        ));
      }
      pageToken = body['nextPageToken'] as String?;
    } while (pageToken != null);
    return out;
  }

  // ----------------------------------------------------------------- files

  /// The email address of the signed-in Google account.
  ///
  /// Read from Drive's own `about` endpoint, which the `drive.file` scope
  /// already covers. This avoids requesting an identity scope such as
  /// `userinfo.email` purely to label the UI, keeping the permission Tandav
  /// asks for at the documented minimum.
  Future<String?> accountEmail() async {
    final uri = Uri.https(_apiHost, '/drive/v3/about', {'fields': 'user'});
    final res = await _http.get(uri, headers: await _headers());
    if (res.statusCode != 200) _fail(res, 'read your Google account details');
    final user = (jsonDecode(res.body) as Map<String, dynamic>)['user'];
    return user is Map<String, dynamic>
        ? user['emailAddress'] as String?
        : null;
  }

  /// Download a file's contents as text.
  Future<String> downloadText(String fileId) async {
    final uri = Uri.https(_apiHost, '$_filesPath/$fileId', {'alt': 'media'});
    final res = await _http.get(uri, headers: await _headers());
    if (res.statusCode != 200) _fail(res, 'download the Tandav sync file');
    // Decode explicitly as UTF-8: student names are frequently non-ASCII and
    // `res.body` would otherwise fall back to latin-1 when Drive omits the
    // charset from the content type.
    return utf8.decode(res.bodyBytes);
  }

  /// Create a new text file inside [parentId] and return its id.
  ///
  /// Uses Drive's `multipart/related` upload, which sends the metadata and the
  /// content in one request. Note this is *not* `multipart/form-data`, so
  /// `http.MultipartRequest` cannot be used — the body is assembled here.
  Future<String> createTextFile({
    required String name,
    required String parentId,
    required String content,
    String mimeType = DriveConfig.jsonMimeType,
  }) async {
    const boundary = 'tandav-sync-boundary-7f3b291';
    final metadata = jsonEncode({'name': name, 'parents': [parentId]});

    final body = BytesBuilder()
      ..add(utf8.encode('--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '$metadata\r\n'
          '--$boundary\r\n'
          'Content-Type: $mimeType; charset=UTF-8\r\n\r\n'))
      ..add(utf8.encode(content))
      ..add(utf8.encode('\r\n--$boundary--\r\n'));

    final uri = Uri.https(_apiHost, _uploadPath, {
      'uploadType': 'multipart',
      'fields': 'id',
    });
    final request = http.Request('POST', uri)
      ..headers.addAll(await _headers(
          {'Content-Type': 'multipart/related; boundary=$boundary'}))
      ..bodyBytes = body.toBytes();

    final res = await http.Response.fromStream(await _http.send(request));
    if (res.statusCode != 200 && res.statusCode != 201) {
      _fail(res, 'upload "$name" to Google Drive');
    }
    return (jsonDecode(res.body) as Map<String, dynamic>)['id'] as String;
  }

  /// Replace an existing file's contents, leaving its name and location alone.
  Future<void> updateTextFile({
    required String fileId,
    required String content,
    String mimeType = DriveConfig.jsonMimeType,
  }) async {
    final uri = Uri.https(_apiHost, '$_uploadPath/$fileId', {
      'uploadType': 'media',
      'fields': 'id',
    });
    final request = http.Request('PATCH', uri)
      ..headers.addAll(
          await _headers({'Content-Type': '$mimeType; charset=UTF-8'}))
      ..bodyBytes = utf8.encode(content);

    final res = await http.Response.fromStream(await _http.send(request));
    if (res.statusCode != 200) _fail(res, 'update the Tandav sync file');
  }

  /// Create-or-replace by name inside [parentId]. Returns the file id.
  Future<String> writeTextFile({
    required String name,
    required String parentId,
    required String content,
    String? knownFileId,
  }) async {
    if (knownFileId != null) {
      await updateTextFile(fileId: knownFileId, content: content);
      return knownFileId;
    }
    final existing = await findChild(name, parentId: parentId);
    if (existing != null) {
      await updateTextFile(fileId: existing.id, content: content);
      return existing.id;
    }
    return createTextFile(name: name, parentId: parentId, content: content);
  }

  void close() => _http.close();
}
