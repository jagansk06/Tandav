# Tandav — Dance Studio Management System

One Flutter codebase, two ways to run it, and no server anywhere.

- **Android** — a normal installable APK. Admin login, students, batches,
  attendance, fees and monthly fee management, dashboard, events, WhatsApp
  messages, local storage, settings. Works completely offline.
- **iPhone / iPad** — the *same* app served as a responsive web app and opened in
  Safari. No Swift, no SwiftUI, no Xcode, no Apple developer account, no Mac.
- **Sync** — through a folder in the studio's own Google Drive. Internet is
  needed only for that.

Dark black-and-gold Tandav theme throughout. No Firebase, no Supabase, no
PostgreSQL server, no AWS, no paid hosting, no payment gateway, no WhatsApp
Business API, no Bluetooth.

## Folder structure

```
Tandav/
├── mobile/                     # the application (Android + web)
│   ├── lib/
│   │   ├── main.dart           # opens the DB, then RootGate → Login / HomeShell
│   │   ├── core/               # services (TandavApi facade), auth_state, theme,
│   │   │                       # format (Fmt/Alert), whatsapp
│   │   ├── database/           # tandav_database.dart — schema, migrations, backups
│   │   ├── platform/           # the ONLY Android-vs-web difference (see SYNC.md)
│   │   ├── models/             # user, batch, student, attendance, fee, event,
│   │   │                       # progress, dashboard
│   │   ├── repositories/       # all SQL: auth, batch, student, attendance, fee,
│   │   │                       # event, progress, dashboard
│   │   ├── sync/               # sync_engine, sync_codec, sync_meta, sync_state
│   │   │   └── drive/          # Google Drive transport (auth, REST, payload, manager)
│   │   ├── screens/            # login, home_shell (6 tabs + overflow), dashboard,
│   │   │                       # students, batches, attendance, fees, events,
│   │   │                       # progress, reports, settings/device_sync
│   │   └── widgets/states.dart # LoadingView, ErrorView, EmptyView, StatusBadge, GoldButton
│   ├── test/sync_engine_test.dart
│   ├── web/                    # the iPhone build's shell: index.html, manifest, icons
│   └── android/                # standard Flutter Android project
├── SYNC.md                     # Google Drive sync + all setup/build instructions
├── SUMMARY.md                  # this file
├── backend/  database/  scripts/   # legacy FastAPI/PostgreSQL prototype — NOT used
└── app-release.apk             # last built Android artifact
```

`backend/`, `database/` and `scripts/` are left over from an earlier
client-server prototype. Nothing in the app talks to them; the app is entirely
local plus Drive.

## Tech stack

| Layer | Stack |
| --- | --- |
| App | Flutter 3.44 / Dart 3.12, Material 3, `provider` |
| Local storage (Android) | `sqflite` — a SQLite file in the app's data directory |
| Local storage (web) | `sqflite_common_ffi_web` — the same SQLite engine as WebAssembly, persisted in IndexedDB |
| Sync transport | Google Drive v3 REST over `package:http`; `google_sign_in` on Android, Google Identity Services in the browser |
| Other packages | `intl`, `image_picker`, `url_launcher`, `path`, `path_provider`, `crypto`, `uuid`, `shared_preferences` |

`googleapis` is deliberately not used — a very large dependency for the five
Drive calls Tandav makes.

## Database (11 tables, schema version 2)

Business data: `batches` · `students` · `attendance` · `monthly_attendance` ·
`fees` · `fee_payments` · `events` · `event_participations` · `monthly_progress`

Local-only: `users` (admin login) · `app_settings` · `sync_state`

Key semantics:

- `students.batch_id` → `batches.id` **SET NULL**: deleting a batch leaves its
  students as "Unassigned" rather than losing them. A student's own children
  (attendance, monthly attendance, fees, participations, progress) cascade.
- `fees.amount_paid` is additive — each recorded payment increments it, and
  `status` is derived (due / partial / paid). Marking a fee paid or due is a
  single tap; there is no payment gateway.
- Monthly fee records are generated for every student for the current month at
  startup and on resume, idempotently, so a student added to a batch
  automatically participates in that month's fee register.
- `monthly_attendance` aggregates are recomputed after every daily save, and
  `monthly_progress.attendance_percentage` follows the month's attendance.
- Every business row also carries `sync_uuid`, `device_id`, `updated_at` and
  `deleted_at`. Deletes are tombstones, which is what lets two devices converge
  (see SYNC.md).

## Screens

Login · Dashboard (stats, monthly fee collection, attendance trend, upcoming
events) · Students (search, filters, form, detail with photo, fees, progress,
attendance) · Batches (list, form, detail with participants) · Attendance (pick
batch → pick date → mark present/absent/late; monthly summary) · Fees (monthly
register, payment sheet, WhatsApp receipt/reminder) · Events (participants and
costume fees) · Progress (monthly ratings and remarks) · Reports (monthly,
per batch) · Google Drive Sync.

Home shell: six tabs (Home, Students, Batches, Attendance, Fees, Events) plus an
overflow menu with Monthly Reports, Backup, Restore, Google Drive Sync and Sign
out. Backup and Restore are hidden in the browser, where there is no database
file to copy — Drive is the off-device copy there.

## Authentication

Local only. Credentials live in the `users` table of the on-device database and
are verified against a SHA-256 hash; the session is remembered through
`shared_preferences`. The seeded account is `admin` / `admin123` — change it
after first login. No JWT, no server, and the `users` table is never
synchronized, so no password material of any kind reaches Google Drive.

## WhatsApp

Unchanged behaviour, on both platforms: after marking a fee PAID or DUE, Tandav
offers to send a receipt or a reminder. It opens WhatsApp with the message
pre-filled (`whatsapp://send` in the Android app, the canonical
`https://wa.me/…` link in the browser) and the admin presses Send. Nothing is
ever sent automatically, and no WhatsApp Business or Meta Cloud API is involved.

## Build and run

Everything — including the one-time Google Cloud setup, the
`--dart-define` client id, the `sqflite_common_ffi_web` setup step, hosting the
web app for an iPhone, and troubleshooting — is in **[SYNC.md](SYNC.md)**.
The short version, from `mobile/`:

```
flutter pub get

# once, for the web build only — read SYNC.md, "Web SQLite binaries", first:
# the two files must come from the same sqlite3 version or the web app cannot
# open its database
dart run sqflite_common_ffi_web:setup --no-sqlite3-wasm
curl.exe -fL -o web/sqlite3.wasm https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.5.2/sqlite3.wasm
dart run tool/check_web_binaries.dart

flutter analyze
flutter test

flutter build apk --release                  # Android: build/app/outputs/flutter-apk/
flutter build web --release --dart-define=TANDAV_GOOGLE_WEB_CLIENT_ID=xxxxx.apps.googleusercontent.com
```

## Known limitations

- Deleting a batch keeps its students as "Unassigned" (intentional, and shown as
  its own row in the monthly report).
- `admin` / `admin123` is a seed credential; there is no password-strength
  policy yet.
- The web app needs HTTPS (or `localhost`) to reach Google sign-in. Over a plain
  LAN `http://` address it still runs, but cannot sync.
- Safari can evict an ordinary website's storage after roughly a week of no use.
  Add the web app to the Home Screen and sync regularly; Drive then holds the
  studio's data.
- Photos stay on the device that took them — they are deliberately excluded from
  sync, so the other device shows the student's initial instead.
- Release APKs are currently signed with the debug keystore
  (`android/app/build.gradle.kts`), which is also the SHA-1 that must be
  registered for Google sign-in.
