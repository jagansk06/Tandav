# Tandav Studio — app

Flutter app for Tandav Dance Studio: students, batches, attendance, fees,
events and reports. All data lives in an on-device SQLite database and the app
works offline; the internet is used only to synchronize with Google Drive.

The same code runs as an installable **Android APK** and as a responsive **web
app** in Safari on an iPhone or iPad — no Xcode, no Swift, no Mac.

```
flutter pub get

# once, for the web build only — see ../SYNC.md, "Web SQLite binaries",
# before changing either command
dart run sqflite_common_ffi_web:setup --no-sqlite3-wasm
curl.exe -fL -o web/sqlite3.wasm https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.5.2/sqlite3.wasm
dart run tool/check_web_binaries.dart

flutter analyze
flutter test

flutter build apk --release
flutter build web --release --dart-define=TANDAV_GOOGLE_WEB_CLIENT_ID=xxxxx.apps.googleusercontent.com
```

Full documentation:

- [`../SUMMARY.md`](../SUMMARY.md) — architecture, database, screens.
- [`../SYNC.md`](../SYNC.md) — Google Drive sync, the one-time Google Cloud
  setup, hosting the web app for an iPhone, and troubleshooting.
