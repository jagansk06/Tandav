// Verifies that the two files the web build needs in `web/` actually agree
// with each other. Run from `mobile/`:
//
//   dart run tool/check_web_binaries.dart
//
// ## Why this exists
//
// SQLite in the browser is two halves that must match:
//
//   web/sqflite_sw.js   the worker, compiled by `dart run
//                       sqflite_common_ffi_web:setup` from the `sqlite3`
//                       package version currently in pubspec.lock
//   web/sqlite3.wasm    the SQLite engine, *downloaded* by that same setup
//                       command from a GitHub release
//
// The release it downloads is hardcoded in sqflite_common_ffi_web (0.4.5+4
// pins `sqlite3-2.4.6/sqlite3.wasm`) and its `--sqlite3-wasm-url` option is
// silently ignored — `copyBinaries()` reads the package-level default instead
// of the value parsed from the command line. So whenever pub resolves a
// `sqlite3` newer than that pin, setup leaves behind a worker and an engine
// built to different ABIs.
//
// The symptom is not a helpful error. The worker loads the wasm on its first
// message, outside the try/catch that turns exceptions into error responses,
// so the failure escapes to a catch-all that posts `null`. sqflite_common then
// reports `Unsupported operation: unsupported result null (null)` and the app
// shows "Tandav could not open its local database".
//
// Exit code 0 = the two halves match. 1 = they do not, with the fix printed.

import 'dart:io';
import 'dart:typed_data';

/// Exports that exist only in the `sqlite3` 3.x WebAssembly ABI. The 2.x
/// builds expose a different surface (`dart_sqlite3_create_scalar_function`
/// rather than `dart_sqlite3_create_function_v2`, no `sqlite3_initialize`), so
/// the presence of these three separates a matching engine from a stale one.
const _abi3Sentinels = {
  'sqlite3_initialize',
  'sqlite3_error_offset',
  'dart_sqlite3_bind_text',
};

/// Export that only 2.x provides, kept so a mismatch can be named precisely
/// instead of merely reported.
const _abi2Sentinel = 'dart_sqlite3_create_scalar_function';

void main() {
  final wasm = File('web/sqlite3.wasm');
  final worker = File('web/sqflite_sw.js');

  var missing = false;
  for (final f in [wasm, worker]) {
    if (!f.existsSync()) {
      stderr.writeln('MISSING  ${f.path}');
      missing = true;
    }
  }
  if (missing) {
    stderr.writeln(
        '\nRun the setup command in SYNC.md → "Web SQLite binaries".');
    exit(1);
  }

  final wanted = _resolvedSqlite3Version();
  final exports = _wasmExports(wasm.readAsBytesSync());

  stdout.writeln('sqlite3 package in pubspec.lock : ${wanted ?? 'unknown'}');
  stdout.writeln('web/sqflite_sw.js               : '
      '${worker.lengthSync()} bytes');
  stdout.writeln('web/sqlite3.wasm                : '
      '${wasm.lengthSync()} bytes, ${exports.length} exports');

  final absent = _abi3Sentinels.difference(exports);
  if (absent.isEmpty) {
    stdout.writeln('\nOK — the engine exports the 3.x ABI the worker calls.');
    return;
  }

  stderr.writeln('\nMISMATCH — web/sqlite3.wasm is the wrong build.');
  stderr.writeln('  the worker calls, and the engine does not export: '
      '${absent.join(', ')}');
  if (exports.contains(_abi2Sentinel)) {
    stderr.writeln('  the engine exports $_abi2Sentinel, so it is a '
        'sqlite3 2.x build');
  }
  final tag = wanted == null ? 'sqlite3-<version from pubspec.lock>'
      : 'sqlite3-$wanted';
  stderr.writeln('\nReplace it with the matching release, then rebuild:');
  stderr.writeln('  curl -fL -o web/sqlite3.wasm '
      'https://github.com/simolus3/sqlite3.dart/releases/download/'
      '$tag/sqlite3.wasm');
  exit(1);
}

/// The `sqlite3` version pub actually resolved. Read with a regex rather than a
/// YAML parser so this script needs no dependencies.
String? _resolvedSqlite3Version() {
  final lock = File('pubspec.lock');
  if (!lock.existsSync()) return null;
  final match = RegExp(r'^  sqlite3:\n(?:.*\n)*?    version: "([^"]+)"',
          multiLine: true)
      .firstMatch(lock.readAsStringSync());
  return match?.group(1);
}

/// Names in a WebAssembly module's export section.
///
/// The binary format is a header followed by length-prefixed sections; section
/// 7 holds the exports as (name, kind, index) triples with LEB128-encoded
/// lengths. Only the names are needed here.
Set<String> _wasmExports(Uint8List bytes) {
  if (bytes.length < 8 ||
      bytes[0] != 0x00 ||
      bytes[1] != 0x61 ||
      bytes[2] != 0x73 ||
      bytes[3] != 0x6d) {
    stderr.writeln('web/sqlite3.wasm is not a WebAssembly binary.');
    exit(1);
  }

  var i = 8;
  final names = <String>{};

  int leb() {
    var result = 0, shift = 0;
    while (true) {
      final byte = bytes[i++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
    }
  }

  while (i < bytes.length) {
    final id = bytes[i++];
    final size = leb();
    final end = i + size;
    if (id == 7) {
      final count = leb();
      for (var n = 0; n < count; n++) {
        final length = leb();
        names.add(String.fromCharCodes(bytes, i, i + length));
        i += length;
        i++; // export kind
        leb(); // index into the corresponding space
      }
    }
    i = end;
  }
  return names;
}
