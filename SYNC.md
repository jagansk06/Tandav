# Tandav — Google Drive Sync

Tandav is **local-first**. Every student, batch, attendance mark and fee lives in
an on-device SQLite database, and the app works with no internet at all.
The internet is needed for exactly one thing: synchronizing with Google Drive.

There is no server. No Firebase, no Supabase, no PostgreSQL, no AWS, no paid
cloud storage, no payment gateway. Drive is used as a plain folder that the
studio already owns, and Bluetooth synchronization has been removed entirely.

## The two builds

The same Dart code produces both apps. Nothing is duplicated for the web.

| | Android | iPhone / iPad |
| --- | --- | --- |
| How it runs | installable APK | web app in Safari |
| Local storage | SQLite file in the app's data directory | the same SQLite engine compiled to WebAssembly, stored in IndexedDB |
| Photos | JPEG/PNG files on the device | inline `data:` URI in the row |
| Backup / Restore | yes (`.db` file copies) | hidden — Drive is the off-device copy |
| Xcode / Swift | not involved | not involved |

Only three things differ between the platforms, and all three are isolated
behind `lib/platform/tandav_platform.dart`: where the database lives, how a
photo is stored, and whether local backup files exist. Everything above that
line — models, repositories, screens, the sync engine — is literally shared.

## Files

| Piece | File | Role |
| --- | --- | --- |
| Platform isolation | `lib/platform/tandav_platform*.dart` | database factory, photos, backups per platform |
| Merge engine | `lib/sync/sync_engine.dart` | outbound snapshot + inbound apply, conflict rules |
| Wire format | `lib/sync/sync_codec.dart` | JSON encoding of table rows |
| Record metadata | `lib/sync/sync_meta.dart` | `SyncStamp` (uuid / device / timestamp) |
| Sync state store | `lib/sync/sync_state.dart` | `sync_state` key/value persistence |
| Drive orchestration | `lib/sync/drive/drive_sync_manager.dart` | the whole download → merge → upload run |
| Drive REST client | `lib/sync/drive/drive_client.dart` | folders, list, download, upload (Drive v3) |
| Payload format | `lib/sync/drive/sync_payload.dart` | shard/snapshot JSON, secret guard |
| Configuration | `lib/sync/drive/drive_config.dart` | scope, folder names, client id from `--dart-define` |
| Google auth | `lib/sync/drive/drive_auth_native.dart` (Android), `..._web.dart` (browser) | access token only |
| UI | `lib/screens/settings/device_sync_screen.dart` | the Google Drive Sync screen |
| Facade | `lib/core/services.dart` | exposes `sync`, `syncEngine`, `syncState` |

## Device identity

Each installation generates a persistent id of the form `TANDAV-XXXX`, stored in
`sync_state` under `device_id`. Every synced row carries `sync_uuid` (stable
identity), `device_id` (which device last edited it) and `updated_at` (UTC
ISO-8601).

The id is metadata, nothing more: it labels the last editor of each row and
breaks conflict ties so both devices reach the same answer. It grants no
permission and restricts nothing — it is not a pairing token, and Drive
synchronization is never limited to a particular pair of devices.

Both devices are equal masters. Either one can add and edit students, create
batches, mark attendance and mark fees paid or due, online or offline, and the
next sync reconciles the two.

## Layout inside your Drive

```
Google Drive
└── Tandav
    └── sync
        ├── tandav_sync_data.json      merged snapshot (convenience copy)
        └── devices
            ├── TANDAV-A7F3.json       written ONLY by the Android phone
            └── TANDAV-B291.json       written ONLY by the iPhone web app
```

Each device writes exactly one file and reads all the others. That single-writer
rule is the point: with one shared file, two devices syncing minutes apart would
have the later upload silently erase the earlier one, which is exactly the
"download, replace, upload" data loss this layout makes structurally impossible.

A device's file contains every row it currently *owns* (`device_id` = that
device), tombstones included. Ownership follows the last edit, so each row lives
in exactly one file, the union of the files is the whole dataset, and a stale
copy disappears from the previous owner's file on its next sync.

`tandav_sync_data.json` is a merged snapshot written for convenience — it is
never read in preference to the per-device files, so a race there can at worst
leave a momentarily stale copy and can never lose business data.

## What is synchronized

All nine business tables, in dependency order (parents before children):

`batches → students → attendance → monthly_attendance → fees → fee_payments →
events → event_participations → monthly_progress`

**Never uploaded, by construction:**

- `users` — the admin login, including the password hash. Passwords are not
  synchronized in any form, hashed or otherwise.
- `app_settings` and `sync_state` — device-local settings and sync bookkeeping.
- `students.photo_url` — a device-local file path or inline image. It is omitted
  from the payload (absent, not null), so merging never overwrites the photo the
  other device already has.
- Anything else at all: no APK, no source code, no keystore, no device keys, no
  application files. Only the JSON that Tandav itself needs.

`SyncPayload` additionally refuses to encode any column whose name matches
`password`, `secret`, `token`, `credential` or `private_key`, and a unit test
asserts that guard, so a future schema change cannot quietly start leaking
credentials.

The OAuth access token lives in memory for the duration of a sync. It is never
written to the database, never written to disk and never uploaded.

## Conflict resolution

Deterministic, and identical on both devices:

1. **Last write wins** on `updated_at` (UTC). The newer edit is kept.
2. **Tie-break:** on an exact timestamp tie the lexicographically **higher**
   `device_id` wins. Both devices therefore compute the same winner without
   talking to each other.
3. **Deletions are tombstones.** Deleting sets `deleted_at`; the row syncs like
   any other update, so a delete on one device is applied on the other instead of
   the row reappearing from the peer.
4. **Identity is the UUID, not the local integer id.** Local ids differ per
   device; rows are matched on `sync_uuid` and foreign keys are remapped through
   a uuid → local-id map built while applying parents first.
5. **Natural business keys prevent duplicates.** A row that matches an existing
   one by natural key merges into it rather than duplicating: batch `name`,
   attendance `student_id` + `attendance_date`, `student_id` + `month` for
   monthly attendance / fees / progress, `event_id` + `student_id` for event
   participation. So a student, batch, fee or attendance record created on both
   devices ends up as one row.
6. **Watermarks make it incremental.** Each table stores the newest `updated_at`
   received (`watermark.<table>` in `sync_state`); only newer rows are sent.
7. **One transaction.** An inbound payload applies together with its watermark
   advances inside a single SQLite transaction. A failure rolls back; the local
   database is never left half-updated.

## What happens when you tap Sync Now

1. Google sign-in, if a valid access token is not already held.
2. Resolve (creating on first use) `Tandav/sync/devices` in your Drive.
3. List that folder and download every device file except this device's own.
4. Merge them into the local database through the rules above.
5. Read back the rows this device now owns — inside the same transaction, so the
   file that gets published can never disagree with what was just merged.
6. Upload this device's file, but only if its contents actually changed.
7. Refresh the merged snapshot, then record the sync time and the peer device.
8. Screens holding cached data (the Attendance batch list, the fee register, the
   dashboard) are told to reload, and the screen shows
   **Synchronization complete ✓**.

Nothing here asks you to upload or download a file by hand.

## The Google Drive Sync screen

Reached from the overflow menu (**⋮ → Google Drive Sync**). Four states:

```
Not connected            Connected                       Failed                    Offline
─────────────────        ──────────────────────────      ────────────────────      ──────────────────────
[Connect Google Drive]   Google Drive · Connected ✓      Synchronization failed    Offline
                         Account: you@gmail.com          <reason>                  Last synchronized:
                         Last Sync: 23 Aug 2026, 10:30 PM                          23 Aug 2026, 10:30 PM
                         Status: Up to date               [Try Again]
                         [Sync Now]
```

Drive being unavailable never blocks the app: login, students, batches,
attendance, fees, the dashboard and WhatsApp messages all keep working offline,
and the only thing you lose is the ability to sync until you are back online.

## One-time Google Cloud setup

You do this once, in your own Google account. It takes about ten minutes.
Nothing from it is committed to this repository: Android needs no client id at
all, and the web client id is passed on the build command line.

Tandav requests exactly one scope, `https://www.googleapis.com/auth/drive.file`.
That is the narrowest scope that can do the job — it grants access **only to
files Tandav itself creates**, and gives it no ability to read, list or touch
anything else in your Drive. It is also a non-sensitive scope, so Google does
not require app verification.

### A. Create the project

1. Open <https://console.cloud.google.com/>.
2. Click the project picker in the top bar → **New project**.
3. Name it `Tandav` → **Create**, then make sure it is the selected project.

### B. Enable the Drive API

1. Left menu → **APIs & Services → Library**.
2. Search **Google Drive API** → open it → **Enable**.

### C. Configure the OAuth consent screen

1. **APIs & Services → OAuth consent screen**.
2. User type **External** → **Create**.
3. App name `Tandav`, your email as support email and developer contact →
   **Save and continue**.
4. **Scopes → Add or remove scopes**, filter for `drive.file`, tick
   `.../auth/drive.file` → **Update → Save and continue**.
5. **Test users → Add users**: add the Google account the studio will sync with
   (the same account is used on both devices) → **Save and continue**.

Leaving the app in *Testing* is fine — test users can use it indefinitely. You
do not need to publish it or submit anything for review.

The usual reason people are told to publish is that apps in Testing have their
**refresh tokens expire after seven days**. That does not apply to Tandav,
because Tandav never holds a refresh token: the browser build keeps a
GIS access token in memory for the life of the page, and the Android build asks
`google_sign_in` for an access token each time (`signInSilently()` →
`auth.accessToken`), leaving the long-lived credential inside Google Play
Services. So Testing costs nothing here.

Publishing is equally safe if you prefer it — `drive.file` is non-sensitive, so
**Publish app** does not trigger a verification review or a security assessment.
The only thing it changes for you is that any Google account can then sign in,
so you stop having to add test users. It is reversible either way. Worth doing if
you add staff accounts and tire of listing each one.

### D. Android OAuth client

1. **APIs & Services → Credentials → Create credentials → OAuth client ID**.
2. Application type **Android**.
3. Name `Tandav Android`.
4. Package name: `com.tandav.tandav_mobile`
5. SHA-1 certificate fingerprint — get it on Windows with:

   ```
   keytool -list -v -alias androiddebugkey ^
     -keystore %USERPROFILE%\.android\debug.keystore ^
     -storepass android -keypass android
   ```

   Copy the line beginning `SHA1:`.

   **Use the debug fingerprint.** `android/app/build.gradle.kts` currently signs
   the release build with the debug keystore, so both `flutter run` and
   `flutter build apk --release` produce APKs with that same fingerprint. If you
   later add a real release keystore, create a second Android client (or add the
   fingerprint) for it, otherwise sign-in on that build fails with
   `DEVELOPER_ERROR`.
6. **Create**. There is nothing to copy into the app — Google identifies the
   Android build by package name plus fingerprint, which is why no credential
   ever sits in the APK.

### E. Web OAuth client

1. **Create credentials → OAuth client ID → Web application**.
2. Name `Tandav Web`.
3. **Authorised JavaScript origins** — add the exact origin(s) you will serve
   the web app from, scheme and port included, no trailing slash:
   - `http://localhost:8080` for local testing
   - `https://your-site.example` (or e.g. `https://yourname.github.io`) for the
     copy your iPhone will load
4. **Create**, then copy the **Client ID** (`…apps.googleusercontent.com`).
   It is public by design — Google itself exposes it in the page — and there is
   no client secret to store anywhere.

### F. Give the client id to the build

The id is read by `String.fromEnvironment('TANDAV_GOOGLE_WEB_CLIENT_ID')`, which
is resolved **at compile time**. So it is a build argument, not a setting inside
the app — there is no field in the UI to paste it into, and adding one after the
fact would not work. Two equivalent ways to pass it:

```
--dart-define=TANDAV_GOOGLE_WEB_CLIENT_ID=xxxxx.apps.googleusercontent.com
--dart-define-from-file=tandav.env.json
```

The second reads `mobile/tandav.env.json`, which is gitignored;
`tandav.env.json.example` is the template to copy. Same result, but the id stops
being something to retype on every build.

Both work on `flutter run` as well as `flutter build web` — and for `flutter run`
add a **fixed port**, because Google matches the authorised origin exactly and
`flutter run` otherwise picks a new random port each launch, so sign-in would
fail with `redirect_uri_mismatch` on every run but the first:

```
flutter run -d chrome --web-port=8080 --dart-define-from-file=tandav.env.json
```

`http://localhost:8080` then matches the origin registered in step E. Rebuild
after changing the id; a hot reload will not pick it up, since the value is
compiled in.

## Building and running

All commands are run from the `mobile/` folder. On Windows, use your Flutter
path, e.g. `C:\Users\jagan\develop\flutter\bin\flutter.bat` in place of
`flutter`.

### First-time setup

```
flutter clean
flutter pub get
dart run sqflite_common_ffi_web:setup --no-sqlite3-wasm
curl.exe -fL -o web/sqlite3.wasm https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.5.2/sqlite3.wasm
dart run tool/check_web_binaries.dart
```

The `sqflite_common_ffi_web:setup` and `curl` commands are needed **once** (and
again after `flutter pub upgrade` moves the `sqlite3` version). They put
`sqflite_sw.js` and `sqlite3.wasm` in `web/`, which is how SQLite runs in the
browser. They need internet the first time and have no effect on the Android
build. Skip them and the web app opens with *"Tandav could not open its local
database"* — the deliberate, diagnosable failure instead of a blank page.

### Web SQLite binaries

Read this before changing anything in `web/`. The browser runs SQLite as two
halves that **must be built from the same version of the `sqlite3` package**:

| File | Where it comes from |
| --- | --- |
| `web/sqflite_sw.js` | compiled by `sqflite_common_ffi_web:setup` from the `sqlite3` version in `pubspec.lock` |
| `web/sqlite3.wasm` | downloaded by that same command from a GitHub release |

The catch is that the release it downloads is hardcoded in the package —
`sqflite_common_ffi_web` 0.4.5+4 pins `sqlite3-2.4.6/sqlite3.wasm` — and its
`--sqlite3-wasm-url` option does not work, because `copyBinaries()` reads the
package default instead of the value parsed from the command line. Meanwhile pub
resolves `sqlite3` to 3.5.2. Run the plain command and you get a worker calling
`sqlite3_initialize`, `sqlite3_error_offset` and `dart_sqlite3_bind_text`
against an engine that exports none of them: 30 of the 72 functions the worker
needs are simply absent from the binary.

That failure is unusually hard to read, which is why it is documented here. The
worker loads the wasm on its first message, at a point *outside* the try/catch
that turns exceptions into error responses, so the real error escapes to a
catch-all that replies `null`. `sqflite_common` then reports
`Unsupported operation: unsupported result null (null)` — no mention of
WebAssembly, versions, or which file is at fault.

Hence the two rules above: pass `--no-sqlite3-wasm` so the wrong engine is
never fetched, and fetch the one matching `pubspec.lock` yourself. The version
in the URL is not decorative — check it against `pubspec.lock` after any
dependency change:

```
dart run tool/check_web_binaries.dart
```

That reads the resolved version, parses the export table out of
`web/sqlite3.wasm`, and either confirms the two halves agree or prints the exact
`curl` command for the release you need. Worth running before every web build;
it costs a second and turns a silent breakage into a sentence.

In PowerShell, type `curl.exe` rather than `curl`: in PowerShell 5, which is
what Windows ships, `curl` is an alias for `Invoke-WebRequest` and does not
understand `-fL -o`. In `cmd.exe`, and in PowerShell 7 or later, plain `curl`
is already the real thing. The `-f` matters too — without it a 404 is written
into `web/sqlite3.wasm` as a page of HTML, and the next error you see is about
the database rather than the download.

The download is the step most likely to go wrong silently, so confirm it landed
rather than assuming: `dir web\sqlite3.wasm` should show a *new* timestamp and a
size different from the file you replaced. If curl is unavailable or blocked,
open the URL in a browser, save the file, and copy it over `mobile/web/sqlite3.wasm`
by hand — nothing about the file depends on how it arrived. Either way,
`check_web_binaries.dart` is the arbiter; it rejects an HTML error page as "not a
WebAssembly binary" and names any remaining version skew.

### Android APK

```
flutter analyze
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

No client id, dart-define or web file is involved. The presence of the `web/`
folder does not affect the APK.

### Web app

```
flutter build web --release --dart-define=TANDAV_GOOGLE_WEB_CLIENT_ID=xxxxx.apps.googleusercontent.com
```

Output: the static site in `build/web/` (plain HTML/JS/WASM — no Node server, no
backend). Serving a sub-path needs `--base-href`, e.g.
`flutter build web --release --base-href /tandav/ --dart-define=...`.

Test it locally:

```
cd build\web
python -m http.server 8080
```

then open <http://localhost:8080> — matching an origin you authorised in step E.

Omitting `--dart-define` still builds and runs; the Sync screen then says the
build has no client id compiled in, and everything except Drive sync works.

### Getting it onto the iPhone

Any static HTTPS hosting works — the free tiers of GitHub Pages, Netlify,
Cloudflare Pages or Firebase Hosting all serve `build/web` as-is. Upload the
contents of `build/web` and add that origin to the web client in step E.

**HTTPS is required for sync.** Google sign-in only runs in a secure context, so
a plain `http://192.168.x.x` LAN address will load the app on the phone but
cannot connect to Drive. (`http://localhost` is exempt, which is why the local
test above works.)

On the iPhone, open the site in Safari and use **Share → Add to Home Screen**.
It then launches full-screen with the Tandav icon, and — importantly — its
storage is treated as an installed app's rather than an ordinary tab's. Safari
may evict a plain website's storage after about a week without interaction, so
treat the browser's database as a working copy and sync regularly; Drive then
always holds the studio's data.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Android: *"Google rejected this app build (DEVELOPER_ERROR)"* | The APK's signing SHA-1 is not on the Android OAuth client. Re-read step D and register the fingerprint of the keystore that actually signed this APK. |
| Web: *"This web build has no Google OAuth client id compiled in"* | Built without the client id. It is compile-time, so rebuild with `--dart-define=TANDAV_GOOGLE_WEB_CLIENT_ID=…` or `--dart-define-from-file=tandav.env.json` — see step F. A hot reload will not pick it up. |
| Web: `Error 400: redirect_uri_mismatch` / `origin_mismatch` | The origin you are browsing from is not in **Authorised JavaScript origins**. It must match scheme, host and port exactly. With `flutter run -d chrome`, pass `--web-port=8080` — without it the port changes every launch and can never stay authorised. |
| Web: *"Safari blocked the Google sign-in window"* | Allow pop-ups for the site, then tap **Connect Google Drive** again (the popup must come from your tap). |
| Web: *"Could not reach Google sign-in"* | `accounts.google.com` is unreachable or blocked by a content blocker. Sync needs it; the rest of the app does not. |
| Web: *"Tandav could not open its local database"*, ending `unsupported result null (null)` | `web/sqlite3.wasm` and `web/sqflite_sw.js` were built for different `sqlite3` versions. Run `dart run tool/check_web_binaries.dart` and follow it — see "Web SQLite binaries". |
| Web: *"Tandav could not open its local database"*, any other reason | `sqlite3.wasm` / `sqflite_sw.js` missing. Redo "First-time setup", rebuild, and make sure both files were uploaded. |
| *Drive permission was declined* | The Google account approved sign-in but not Drive access. Connect again and allow it. |
| Screen says **Offline** | No usable network. Expected, harmless: keep working and sync later. |
| Changes not appearing on the other device | Both devices must sync — the sender uploads, the receiver downloads. Check both are on the **same Google account** and that the Sync screen shows the peer device id. |

## Tests

`test/sync_engine_test.dart` simulates two devices by opening the database
singleton against two SQLite files, and covers:

- both directions with foreign-key remapping and watermark-driven suppression;
- last-write-wins by `updated_at` plus the device-id tie-break, from both
  orderings, so convergence is proved rather than assumed;
- tombstone propagation, including through a Drive shard;
- natural-key merge of the same batch created independently on both devices;
- the Drive payload round trip, and that ownership migration leaves each row in
  exactly one shard;
- that a shard never carries credentials or device-local file paths;
- that an unknown `formatVersion` is rejected instead of mis-parsed.

```
flutter test
flutter analyze
```

## Upgrading an existing installation

Nothing is deleted. The schema migration only *adds* the sync columns
(`sync_uuid`, `device_id`, `updated_at`, `deleted_at`) to the existing tables and
backfills them, so existing students, batches, attendance and fees are carried
forward untouched. Photos keep their current on-device location.

Removing Bluetooth changed only how devices talk: the BLE service, pairing
handshake, permissions and the "Pair Bluetooth Device" UI are gone, replaced by
**Google Drive Sync**. The record metadata that BLE sync introduced is the same
metadata Drive sync uses, which is why no re-import is needed.
