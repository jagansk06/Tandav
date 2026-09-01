import 'dart:convert';

import 'package:share_plus/share_plus.dart';

/// Share one or more CSV exports through the system share sheet (Android) or
/// as browser downloads (iPhone PWA).
///
/// Each entry is `(filename, csvBody)`. The CSV text is generated locally by
/// [ExportRepository]; this function only hands the resulting files to the
/// platform's sharing mechanism. There is no server and no subscription.
///
/// On Android the bytes are written to a cache file and the OS share sheet
/// opens (WhatsApp, email, Files, Google Drive…). On the web/PWA build the
/// browser downloads the file instead, which is how the iPhone installation
/// saves it to the Files app or opens it in Sheets.
Future<void> shareExports(
  List<(String filename, String csvBody)> namedCsv,
) async {
  final files = [
    for (final (name, body) in namedCsv)
      // `dart:convert` works on every platform this app ships on. The CSV
      // bodies carry a UTF-8 BOM (see ExportRepository) so ₹ and non-ASCII
      // names open correctly in Excel / Google Sheets.
      XFile.fromData(
        utf8.encode(body),
        mimeType: 'text/csv',
        name: name,
      ),
  ];
  await SharePlus.instance.share(
    ShareParams(
      files: files,
      text: 'Tandav Studio export',
      // The temp file share_plus writes on Android would otherwise use its own
      // generated name; keep the meaningful filename on screen.
      fileNameOverrides: [for (final (n, _) in namedCsv) n],
    ),
  );
}
