# Tandav — Dance Studio Management System

A **dance studio management app** sold to studios as a one-time purchase.
Batches, students, attendance, fees, events and costumes, monthly progress,
reports. Dark black/gold theme.

**Local-first.** Everything lives in an on-device SQLite database and the whole
app works with no internet at all. There is **no Tandav server** and nothing to
renew. Up to **three devices** — two owners plus the studio's attender — run the
same data as **equal masters** and keep each other in sync through a shared
Google Drive account.

> **This file was rewritten on 2026-08-23.** Every earlier version described a
> FastAPI + PostgreSQL + JWT client-server app and referenced
> `lib/core/api_client.dart`, which no longer exists. If you find another doc
> claiming Tandav talks to an HTTP API, that doc is stale.

## `backend/` is dead code — deliberately kept

The repo still contains `backend/` (46 Python files: FastAPI, SQLAlchemy,
Alembic, Postgres) and `scripts/e2e_smoke.py`, which drives that API. **None of
it is used, built, tested or shipped.** The Flutter app has no `http`
dependency at all — verify with `mobile/pubspec.yaml` if you doubt it.

It is retained on purpose as history, not as a component. **Do not** try to run
it, migrate it, or "reconnect" the app to it. Reintroducing a server would break
the product promise: the studios own the app outright and nothing about it may
depend on infrastructure someone has to pay for and keep alive.

## Layout

```
Tandav/
├── SYNC.md                  # the sync design in depth — read this first
├── OAUTH-SETUP.md           # one-time Google Cloud Console setup
├── PWA.md                   # the iPhone build: flags, deploy, offline, limits
├── IPHONE-INVITE.md         # the link + paste-ready message for an iPhone user
├── ATTENDER.md              # the attendance-only APK: build it, send it, limits
├── ship.ps1                 # build (either role) + verify + name + install + logs
├── dist/                    # the named, verified APKs to send out (gitignored)
├── tools/
│   ├── verify-apk.ps1       # signature AND build-role gate, no cable needed
│   ├── deploy-pwa.ps1       # build + prune + stamp + publish the public site
│   ├── make-web-icons.py    # PWA icons from the studio logo
│   ├── fake-peer.html       # impersonate a 2nd device from a browser
│   └── drive-visibility-test.html
├── mobile/                  # THE APP
│   ├── lib/
│   │   ├── main.dart        # RootGate → Signup / Login / HomeShell
│   │   ├── core/            # services (TandavApi facade), auth_state, theme,
│   │   │                    # format, whatsapp (deep links), app_role (which
│   │   │                    # build this is — see ATTENDER.md)
│   │   ├── platform/        # the Android/web split — see below
│   │   ├── database/        # tandav_database.dart (schema, migrations, backups)
│   │   ├── models/          # plain data classes
│   │   ├── repositories/    # 8 repositories, all sqflite
│   │   ├── sync/            # 8 files — see SYNC.md
│   │   ├── screens/         # 24 screens
│   │   └── widgets/states.dart
│   ├── web/                 # PWA shell: index.html, manifest, tandav_sw.js,
│   │   │                    # icons/, sqlite3.wasm (no sqflite_sw.js — see PWA.md)
│   └── test/                # 7 files, 69 tests
├── backend/                 # DEAD (see above)
└── scripts/e2e_smoke.py     # DEAD (drives the dead API)
```

### `lib/platform/` — the one place that knows which platform this is

```
app_files_api.dart    the interface + UnsupportedOnThisPlatform
app_files_io.dart     Android: real paths, real files
app_files_web.dart    browser: photos and backups off, IndexedDB database
app_files.dart        picks one, and exposes platformDatabaseFactory
```

The pick is a conditional import whose **default is the web file**:

```dart
import 'app_files_web.dart' if (dart.library.io) 'app_files_io.dart' as impl;
```

That way a platform offering neither `dart:io` nor a browser fails loudly rather
than silently getting a file system it does not have. Shared code must read
`platformDatabaseFactory` from here and never import `databaseFactory` from
`package:sqflite` — that global is the Android one, and touching it from shared
code is what makes a file impossible to compile for the web.

## Tech stack

| Layer        | Stack |
|--------------|-------|
| App          | Flutter 3.47.1 / Dart 3.13.1 |
| Storage      | `sqflite` (on-device SQLite), `dbVersion = 2`, 12 tables |
| Storage (web)| `sqflite_common_ffi_web` — WASM SQLite persisted in IndexedDB, `sqlite3` pinned to **2.4.6** to match the binary |
| State        | `provider` — `TandavApi` facade in `core/services.dart` |
| Sync         | `google_sign_in`, `googleapis` (Drive v3), `uuid`, `crypto` |
| Other        | `intl`, `image_picker`, `path_provider`, `url_launcher`, `shared_preferences` |
| Tests        | `flutter_test` + `sqflite_common_ffi` (real SQLite on the desktop) |

`core/services.dart` deliberately kept the old remote-API method signatures when
storage moved local, so the screens never had to change. That is why it reads
like an API client and isn't one.

## Database (12 tables)

`users` · `app_settings` · `batches` · `students` · `attendance` ·
`monthly_attendance` · `fees` · `fee_payments` · `events` ·
`event_participations` · `monthly_progress` · `sync_state`

- The nine business tables carry `sync_uuid`, `device_id`, `updated_at` and
  `deleted_at`, added programmatically by `_addSyncColumns()` looping over
  `syncTables` — which is why they don't appear in the `CREATE TABLE` text.
- **`users`, `app_settings` and `sync_state` never sync.** This is a security
  boundary, not tidiness: the sync bundle is plain unencrypted JSON, `users`
  holds the password hash and `app_settings` holds the account recovery code.
- `students.batch_id` → `batches.id` is **SET NULL**, so deleting a batch leaves
  its students as "Unassigned" rather than destroying them. Student children
  (attendance, fees, participations, progress) **CASCADE**.
- `fees.amount_paid` is additive per recorded payment; `status` is derived
  (due / partial / paid). Same shape for `event_participations.costume_fee_paid`.
- Monthly attendance aggregates are recomputed after every daily save, and
  `monthly_progress.attendance_percentage` tracks the month's attendance.

## Accounts

Two different things called "account", and confusing them is the most common
mistake here:

- **App login — one per phone, different on each, never syncs.** The `users`
  table is still seeded with `admin` / `admin123` on first open, because
  `_seedAdminIfNeeded` recreates that row whenever the table is empty. What
  changed is that the app **refuses to let anyone in on it**:
  `isFactoryDefault()` asks whether the factory password still verifies, and
  while it does, an un-dismissable **signup** screen replaces the login screen.
  Signup updates that same row in place and issues a **recovery code**, shown
  once, which is the only way back in if the password is forgotten. The check is
  deliberately "does the factory password still work" rather than "is the table
  empty" (it never is) or a separate flag (which can drift out of step with the
  row) — so an APK already handed out gets prompted on its next launch instead
  of staying on `admin123` forever. `users` is not a synced table.
- **Google account — one, shared by every device, mandatory.** It *is* the sync
  mailbox. Two different Google accounts means two private Drives and sync can
  never work. Advise each studio to create a **fresh Google account used only
  for Tandav**, not either person's personal Gmail. App logins are **per device**
  and never sync, so sharing the Google account does not share a password.

## Two builds from one codebase

`--dart-define=TANDAV_ROLE=attendance` produces the **attender's APK**: two tabs
(Attendance, Fees), no money totals, and a database scoped to six of the nine
synced tables — `events`, `event_participations` and `monthly_progress` are
filtered on the way in and never forwarded out. `core/app_role.dart` is the only
place that decides, `flutter build` is the only thing that has to change, and
`tools/verify-apk.ps1` reads the role back out of the built file so the wrong APK
cannot reach the wrong phone unnoticed. **`ATTENDER.md` is the full account.**

## Sync, in one paragraph

Every device signs into the same Google account. The app makes a **Tandav Sync**
folder and each device owns exactly one file in it, `tandav-<deviceId>.json`. A
device writes its own file and reads the others', so **nobody waits for anybody
to be online** — one can sync at 9am and the next at 6pm and all end up correct.
Merging is last-write-wins on `updated_at` with the higher device id breaking
exact ties, soft-delete tombstones, and foreign keys remapped by UUID, all
applied in one transaction per peer. **Up to three devices** share an account
(two owners plus the attender); a fourth is refused by name rather than guessed
at. What a device offers is filtered by what it has *delivered to each peer
individually*, so a phone that joins late receives the studio's whole history on
its first sync with nobody pressing anything. Sync runs on app open, on resume,
every 5 minutes while the app is in the foreground, and on demand from Settings →
Device & Sync. **A Bluetooth transport existed and was deleted on 2026-08-23**;
Drive is the only carrier. Because each file is a **delta and not a backup**, a
device that lost its data is rebuilt with **Send everything again** on a
surviving one. Full detail, including why, is in `SYNC.md`.

## WhatsApp — deep links, not the Cloud API

`core/whatsapp.dart` opens a prewritten fee **receipt** or **reminder** through
`url_launcher`; the admin presses Send inside WhatsApp themselves. Indian number
normalization (+91, 6–9 prefix). **Zero cost, no Meta template approval, no BSP.**
Notes anywhere about Cloud API pricing or utility templates do not apply to this
codebase.

Two spellings of the same link, because a browser cannot use the first:
`whatsapp://send?phone=&text=` on Android, and `https://wa.me/<number>?text=` on
web. Safari will not hand an unknown URL scheme from a web page to another app, so
`whatsapp://` there does nothing at all — no chat and no error. On web the link is
also navigated with `webOnlyWindowName: '_self'`, because the default is
`window.open`, and a pop-up opened after an `await` has lost its user gesture and
gets blocked.

## Distribution

- **Android:** a direct, release-signed `.apk` handed to each studio. No Play
  Store. Run **`.\tools\verify-apk.ps1`** before copying one to a phone.
- **iPhone:** the same Flutter app compiled for the web and served at
  **`https://jagansk06.github.io/tandav-app/`**, installed from Safari with **Add
  to Home Screen**. Not a native app, and nothing to renew. The site lives in a
  **second, public** repo holding only build output, so the private source is
  never published — `PWA.md` covers that split, the mandatory build flags, the
  deploy script, the offline cache and the two honest limitations.
  **`IPHONE-INVITE.md`** is what to actually send a customer.
- **No store means no auto-update channel** on Android — a new release is
  redistributed by hand — and Play Protect will warn on install. The iPhone side
  is the opposite: it updates itself the next time it is opened online, because
  it is a website.

Two things the iPhone build does differently, both browser limits rather than
choices: **photos and Backup/Restore are hidden** (a browser has no file paths,
and half-working was worse than honest), and **sync needs one "Resume syncing"
tap per launch** (Safari keeps the Google permission in memory only). All the
local data — students, attendance, fees — needs no tap and no signal.

**The release keystore in `D:\Projects\tandav-signing\` must survive forever.**
Two reasons, both severe: a differently-signed APK cannot update an installed
one, and the only fix is uninstalling, which **destroys the studio's only copy
of its data**; and the Google **OAuth client is bound to that keystore's SHA-1**,
so a build signed with anything else cannot sign in to Drive at all. Never
commit it, never regenerate it, and keep it in two backup locations.
`mobile/android/key.properties` holds its password and must never be committed.

Backups (`TandavBackups` under app documents) are a copy of the whole `.db`, so
they contain the password hash and the recovery code. **Treat a backup file as a
secret.** Backup/restore is a hard requirement, not a nicety, precisely because
the database is the only copy.

## Build, install, test

```powershell
cd D:\Projects\Tandav\mobile
flutter pub get
flutter analyze
flutter test              # 64 tests

cd D:\Projects\Tandav
.\ship.ps1                # build + verify signature + install + capture logs
```

`ship.ps1` does `flutter build apk --release --split-per-abi`, then refuses to
continue unless the APK's SHA-1 matches the release key (catching the silent
debug-signing fallback, which produces an APK that installs fine but can never
reach Drive), then **`adb install -r`** and pulls a filtered logcat into
`device-log.txt`.

**Install over the top. Never uninstall first.** `adb install -r` keeps the
database; uninstalling erases it. `device-log.txt` is gitignored because it can
contain account details.

Useful flags: `.\ship.ps1 -SkipBuild` (install the existing APK, fast loop) and
`.\ship.ps1 -LogOnly` (capture only).

The iPhone build is a separate one-command path:

```powershell
cd D:\Projects\Tandav
.\tools\deploy-pwa.ps1    # build web + prune + stamp cache version + publish the public site
```

Read `PWA.md` before touching its flags. `flutter build web` on its own produces
an app that cannot open without a network.

Testing sync with only one phone: open `tools/fake-peer.html`, which plants a
valid bundle in the Drive folder as `TANDAV-WEB1` and reads back the phone's own
bundle. Clean up in this order — remove the planted file **first**, then tap
**Forget the other device** on the phone, or it stays pinned to the fake peer
and will refuse the real second device.

## Status

**Working and validated on hardware:** the full Drive round trip (OAuth, folder
creation, encode, upload, list, download, decode, protocol validation, merge,
peer adoption), first-run signup and recovery code, restore-from-backup without
cloning the sync identity, recoverable peer id, Drive call timeouts, foreground
periodic sync, and — confirmed 2026-08-23 — **two-way sync between the Android
app and the web build**, each picking up the other's edits, with no duplicates and
no echo.

**Not done yet:**

1. **Two real Android phones side by side.** Every stage has been proven, but
   one half was proven with a browser standing in for the second device.
2. **The PWA runs, but has never been on an iPhone.** As of 2026-08-23 the web
   build opens in Chrome on Windows, keeps its database in IndexedDB, signs in to
   Drive and **syncs both ways with the Android phone** — that half is done, and
   the Web client id is in `mobile/web/index.html`. What is left: **deploy**
   (`.\tools\deploy-pwa.ps1`, which needs the public `tandav-app` repo created
   first), the offline test against the served build, and a borrowed iPhone.
   Three prerequisites are still on the Google Cloud Console side and all three
   block sign-in from the deployed site: add `https://jagansk06.github.io` to the
   Web client's Authorized JavaScript origins, enable the **People API**, and add
   `userinfo.email` and `userinfo.profile` to the consent screen.
3. **Conflict resolution under a wrong clock.** LWW compares wall-clock
   `updated_at` with no hybrid logical clock, so a phone with a badly wrong
   clock still wins or loses every *conflict*. The *data-loss* half of this is
   already fixed (see the two-marks invariant in `SYNC.md`); the proper fix is a
   monotonic per-row `local_seq` at schema v3, deferred because `SyncStamp` is
   synchronous and used by every repository write.
4. **`students.photo_url` is a local absolute path in a synced table.** So a photo
   has never travelled between devices: the path arrives, points at nothing, and
   `imageAt` falls back to the initial-letter avatar because it checks
   `existsSync()`. It degrades quietly rather than breaking, which is why it went
   unnoticed. Fixing it properly means moving photo *bytes* into the bundle.
5. Cosmetic `flutter analyze` info lints. No errors, no warnings.

## Traps worth knowing before you change anything

- **`flutter test` compiles only test files and what they import.** No test
  imports the screens, so a screen can be broken and the suite still passes.
  `flutter analyze` is the only gate for UI files.
- **Unit tests use `FakeMailbox`**, so no test can catch a plugin method that is
  missing on one platform. That is exactly how `canAccessScopes()` — web-only —
  got to a real device before failing.
- **Seeing a file at drive.google.com proves nothing** about `drive.file` scope.
  The Drive website is Google's own client with full access; only a request
  bearing *our* client's token is restricted the way the app is. Use
  `tools/drive-visibility-test.html`.
- **Any `sync_state` key that is written once and auto-adopted needs a
  user-reachable reset.** On a local-first app "reinstall to fix it" is data
  destruction, not a workaround. This bug has been found three separate times.
- **`sent.<table>` means "the peer already holds this", not "we uploaded this".**
  So anything that clears `cloud_peer_device_id` must clear the sent marks in the
  same transaction — the next device adopted is a *different* device and holds
  nothing. When `forgetCloudPeer()` did only half of that, the replacement device
  was adopted, both sides reported a clean sync, and the studio's whole history
  was never offered to it, with nothing on screen to say so. It looks like two
  faults ("the phone isn't sending", "the iPhone isn't sending") and is one.
  Consequence: **"Forget the other device" now implies "Send everything again"**.
- **The Drive files are deltas, not backups.** A healthy pair's mailbox files
  are nearly empty, which is correct and also means the account is not a copy of
  the studio. Recovery goes through **Send everything again** on the surviving
  device; the real backup path is `TandavBackups`.
- **Anything that swaps the whole database file must be audited for the identity
  it drags along.** That is what made restore-from-backup clone `device_id`.
- **Never sideload an APK you have not signature-checked.** Android cannot
  update an installed app with an APK signed by a different key; the only way
  through is uninstall, which **erases the database and the backups with it**.
  The wrong signature is *silent* — a missing `key.properties` or keystore makes
  Gradle fall back to debug signing and the build still succeeds. Symptom on the
  phone: a brand-new `TANDAV-XXXX`, an empty studio, and `admin123` working
  again, all three at once, "every time I log in". Run
  **`.\tools\verify-apk.ps1`** (no cable needed) before copying any APK to a
  phone, or use `.\ship.ps1`, which gates on the same check.
- **`flutter run -d chrome` throws away IndexedDB between runs.** It launches
  Chrome with a throwaway `--user-data-dir`, so the web database is new on every
  run — new device id, empty studio, and a fresh orphan bundle in the Drive
  folder each time. Storage does persist *within* a run, so a reload looks fine.
  Test web persistence and sync against the deployed Pages URL in your own
  browser instead.
- **Flutter no longer ships a caching service worker.** On 3.47 the generated
  `flutter_service_worker.js` is 815 bytes whose whole body unregisters itself.
  So "it's a PWA, Flutter handles offline" is false, and the offline support is
  ours: `mobile/web/tandav_sw.js`, built with `--pwa-strategy=none` so Flutter
  does not register a second worker for the same scope. See `PWA.md`.
- **`flutter test` never compiles the web code.** The suite runs on the Dart VM,
  so the conditional import always resolves to `app_files_io.dart` and every
  `kIsWeb` branch takes the false path. `app_files_web.dart` and the web halves
  of `whatsapp.dart` and `drive_mailbox.dart` are reached only by
  `flutter build web`, which is therefore a required gate and not an optional one.
- **`kIsWeb` has to be imported explicitly.** `material.dart` re-exports
  `widgets.dart`, which re-exports `foundation.dart` with only
  `show Brightness, UniqueKey`. Importing material looks like it should be enough
  and is not; the failure is a plain "undefined name" at build time.
- **WASM SQLite is two artefacts that must be the same version**, and neither
  `flutter analyze` nor `flutter build web` can tell you they are not: the binary
  `sqlite3.wasm` and the `sqlite3` Dart package that supplies its imports.
  `sqflite_common_ffi_web` allows `sqlite3` up to 4.0.0 but downloads a
  hard-coded 2.4.6 binary, so pub happily resolves a version that cannot link.
  Hence the exact `sqlite3: 2.4.6` pin in `mobile/pubspec.yaml`. Symptom is a
  hang on the splash screen and `unsupported result null (null)`. Full story in
  `PWA.md`.
- **The web build does not use `sqflite_sw.js`.** The package's shared-worker
  handler answers *every* internal failure with `port.postMessage(null)`, so real
  errors never reach the page console — and iOS Safari has no `SharedWorker`
  anyway. `app_files_web.dart` uses `databaseFactoryFfiWebNoWebWorker`
  deliberately; do not "optimise" it back onto the worker.
