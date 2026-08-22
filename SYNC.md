# Tandav — Two-Master-Device Sync

Tandav is local-first: everything lives in the on-device SQLite database and
the app works with no internet at all. Two devices run the same database as
**two equal masters** and keep each other in sync.

There are **two carriers**, and they share one merge engine:

| Carrier | When it is used | Distance | Needs internet |
| --- | --- | --- | --- |
| **Google Drive mailbox** | the everyday path | anywhere in the world | yes, briefly |
| **Bluetooth LE** | when both devices are together | ~10 m | no |

The merge logic — conflict resolution, tombstones, foreign-key remapping,
watermarks — lives in `sync_engine.dart` and is **identical either way**. The
carrier only moves bytes. Adding Drive did not change a single line of the
merge engine.

## Architecture

| Piece            | File                                   | Role                                          |
| ---------------- | -------------------------------------- | --------------------------------------------- |
| **Merge engine** | `lib/sync/sync_engine.dart`            | outbound snapshots + inbound apply — carrier-agnostic |
| Wire format      | `lib/sync/sync_codec.dart`             | JSON encoding of table rows                   |
| Sync state store | `lib/sync/sync_state.dart`             | `sync_state` key/value persistence            |
| Record metadata  | `lib/sync/sync_meta.dart`              | `SyncStamp` (uuid / device / timestamp)       |
| *Drive:* carrier | `lib/sync/sync_mailbox.dart`           | abstract store-and-forward mailbox + file naming |
| *Drive:* payload | `lib/sync/sync_bundle.dart`            | one JSON document carrying all tables at once |
| *Drive:* session | `lib/sync/cloud_sync.dart`             | connect, upload, download, apply, throttling  |
| *Drive:* backend | `lib/sync/drive_mailbox.dart`          | Google Drive v3 implementation of the mailbox |
| *BLE:* transport | `lib/sync/bluetooth.dart`              | BLE peripheral + central link, frame codec    |
| *BLE:* session   | `lib/sync/sync_manager.dart`           | pairing handshake, auth, sync exchange, phase |
| *BLE:* protocol  | `lib/sync/protocol.dart`               | envelope, frame codec, pairing code, auth     |
| UI               | `lib/screens/settings/device_sync_screen.dart` | Device & Sync settings screen      |
| Facade           | `lib/core/services.dart`               | exposes `syncEngine` / `syncState` / `sync` / `cloudSync` |

## Device identity

- Each installation generates a persistent **device id** of the form
  `TANDAV-XXXX` (stored in `sync_state`, key `device_id`).
- The id is the identity and the conflict tie-breaker; it never changes for
  the life of the installation.
- Every synced row carries `sync_uuid` (stable UUID), `device_id`
  (last modifier) and `updated_at` (UTC ISO-8601).

## Google Drive sync (the everyday path)

Both devices sign in to **one shared Google account**. The app creates a
folder called **Tandav Sync** and each device owns exactly one file in it:

```
Tandav Sync/
  tandav-TANDAV-4B7C.json     <- device A's outbox
  tandav-TANDAV-91EF.json     <- device B's outbox
```

This is a **mailbox**, not a conversation. A device writes its own file and
reads the other's; **neither waits for the other to be online**. Device A can
sync at 9am, device B at 6pm, and both end up correct.

### What happens on one sync

The order below is deliberate and is enforced by a regression test.

1. **Snapshot** the outbound delta (`computeOutbound`) in a read-only
   transaction.
2. **Upload** it as one JSON bundle, overwriting our own file.
3. **Download** the peer's file and validate it.
4. **Apply** every table in **one** write transaction (`applyIncoming`).

Why snapshot before applying: applying **advances the watermarks**, and the
outbound delta is defined as *rows newer than the watermark*. Merge first and
our own older-but-unsent rows fall behind the new watermark and **would never
reach the peer**. Why upload before applying: a failed upload leaves the local
database completely untouched, so the retry recomputes an identical delta.

### Bundle format

One JSON document carries **all nine tables together**, because foreign-key
remapping needs parents and children in the same delivery:

```json
{ "tandav": 1, "protocol": 1, "deviceId": "TANDAV-4B7C",
  "createdAt": "2026-08-21T04:10:22.113Z", "rows": 37,
  "tables": { "batches": [...], "students": [...] } }
```

`SyncBundle.decode` refuses a newer `tandav` format version, a mismatched
protocol, a missing device id, a file whose name and contents disagree, and
truncated/partly-uploaded JSON — each with a message a studio owner can read.
A rejected bundle applies **nothing**.

### When it runs

- **App open** and **app resume** → `cloudSync.autoSync()`, silent,
  throttled to once every 2 minutes. No spinner, no error toast: if there is
  no internet or no connected account it simply does nothing.
- **Settings → Device & Sync → Sync now** → visible, with phase and counts.

### Pairing over Drive

There is **no 6-digit code** here. The shared Google account *is* the trust
boundary — only someone signed into it can write to the folder. The first peer
file a device reads is adopted as its pair and stored in `sync_state` under
`cloud_peer_device_id`.

That key is deliberately **separate from the Bluetooth `paired_device_id`**:
BLE pairing also stores an HMAC `pairing_secret`, and writing the BLE key
without a secret would leave the Bluetooth handshake unable to authenticate.

A **third device** is refused, not merged — with two unknown peer files the
app stops and says so rather than guessing.

### One-time developer setup (do this once, ever)

In Google Cloud Console, on the project that owns the app:

1. **Enable the Google Drive API.**
2. **OAuth consent screen** → User type *External*. Add **only** the scope
   `https://www.googleapis.com/auth/drive.file`. Narrow scope on purpose:
   the app can see only files it created itself, which keeps it out of
   Google's *restricted*-scope category and its recurring security review.
3. **Publish the app ("In production").** Leaving the consent screen in
   *Testing* expires every sign-in after **7 days**, which would break the
   buy-once-works-forever promise.
4. Create an **OAuth client** with the release keystore SHA-1 and the package
   name. Both phones must run that same signed APK — a debug build has a
   different SHA-1 and will not sign in.

### iPhone note

`drive.file` authorises files per *(user, OAuth client)*. Two installs of the
same signed APK share one client id, so **Android ↔ Android works**. The
iPhone build is a **PWA**, which uses a **Web** OAuth client — a *different*
client, which may not see files the Android app created. The fix, when the
PWA lands: point **both platforms at a single shared OAuth Web client** so
they are one app in Google's eyes. Verify this before shipping to a customer.

## BLE roles

- **Both devices are equal masters**; BLE roles are *temporary, per session*
  and assigned automatically — the user never sees or chooses them.
- The Tandav BLE service UUID `6d61726b-0001-4f64-4144-530000000001` and the
  two characteristic UUIDs are compiled constants, identical on every Tandav
  client (Android and iOS). Scans filter on this UUID, so no other Bluetooth
  product can pair with Tandav and vice versa.
- How a session starts (`lib/sync/bluetooth.dart` + `lib/sync/sync_manager.dart`):
  1. Every session begins with permissions + Bluetooth-state checks; any
     failure produces a friendly message, never a crash.
  2. **Both phones advertise** their Tandav identity (`Tandav TANDAV-XXXX`,
     GATT server armed) for as long as the session is open. There is
     therefore always a discoverable Tandav device whenever another Tandav
     device is scanning — it is impossible for both phones to sit in scan
     mode waiting for each other.
  3. **Both phones scan** for the Tandav service and list every found device
     (`flutter_blue_plus` as central/scanner + vendored `ble_peripheral` as
     GATT server). The lower device id automatically takes the central role
     (connects), the higher id keeps advertising and waits — or the human
     picks a device from the list and taps **Connect** and the same
     deterministic rule assigns the roles.
  4. Packets are chunked into 180-byte frames with a 4-byte length header
     (`FrameCodec` in `protocol.dart`); large payloads reassemble on the peer.
- The vendored plugin (`packages/ble_peripheral`) tracks every connected
  remote immediately so notifications flow over plain (unencrypted)
  characteristics without forcing an Android bond; authentication happens at
  the application layer with an HMAC-SHA256 shared secret.

## Pairing (Bluetooth)

1. Both devices open *Settings → Device & Sync → Pair*. Each phone becomes
   discoverable immediately (advertising `Tandav TANDAV-XXXX`) and lists the
   other nearby Tandav devices with their platform and signal strength.
2. With exactly one device nearby the connection starts automatically after
   a few seconds (roles decided from the device ids); with several, tap
   **Connect** on the one you want.
3. Both screens show the same **6-digit code** derived from both device ids
   (sorted, hashed, mod 10^6 — identical on both screens).
4. A human confirms on **both** screens — the shared secret is only exchanged
   after both confirmations arrive.
5. A shared secret is stored in `sync_state` (`pairing_secret`).
6. Every session thereafter is authenticated: a nonce is exchanged and each
   side proves possession of the secret with **HMAC-SHA256** before any data
   flows. The token is bound to the *authenticating* device's id.
7. A **third device** is rejected: pairing a device whose id is on the
   paired-device list returns `already_paired`. Only two masters are
   supported.
8. *Unpair* clears only the pairing metadata — **it never touches your
   local data**. The two databases stay independently usable.

## What syncs

All nine business tables, in dependency order (parents before children):

`batches → students → attendance → monthly_attendance → fees →
fee_payments → events → event_participations → monthly_progress`

Never synced: `users` and `app_settings` (admin login + local settings stay
local), and the `sync_state` table itself (except through the manager).

## How merge works

- **Incremental (watermarks):** each table has a stored watermark = the
  newest `updated_at` received from the peer (`watermark.<table>` in
  `sync_state`). We only send rows `updated_at > watermark`. Nothing is ever
  dumped in full.
- **Conflict resolution (LWW):** newer `updated_at` wins. On an exact
  timestamp tie the lexicographically **higher device id** wins, so both
  devices reach the same answer. The losing side keeps its watermark behind
  until the winner is re-transmitted (echoes are skipped), guaranteeing
  convergence.
- **Deletions (tombstones):** delete operations soft-delete (`deleted_at`);
  the tombstone row syncs like any other update and is never dropped from
  queries until the peer has seen it. Unpairs and reverts never lose data.
- **Identity + FK remap:** local integer ids differ per phone; rows are
  matched by `sync_uuid` and foreign keys are resolved through a
  uuid → local-id map built while applying parents first. Inbound records
  that match an existing row by natural business key (batch `name`,
  attendance `student_id`+`attendance_date`, `student_id`+`month` for
  attendance/fees/progress, `event_id`+`student_id` for participation) merge
  into that row instead of duplicating.
- **Atomicity:** all tables of one inbound payload apply inside a **single
  transaction** together with the watermark advances; a failure rolls back
  and the local database is never half-updated.

## Permissions / platform notes

- Android (`AndroidManifest.xml`): `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`,
  `BLUETOOTH_ADVERTISE`, `BLUETOOTH`, `BLUETOOTH_ADMIN` (legacy), and
  `ACCESS_FINE_LOCATION` for legacy scanning; `uses-feature
  android.hardware.bluetooth_le` required. Drive sync additionally needs
  `INTERNET` and `ACCESS_NETWORK_STATE`.
- iOS (`Info.plist`): `NSBluetoothAlwaysUsageDescription` and
  `NSBluetoothPeripheralUsageDescription` (plus `NSLocalNetworkUsageDescription`
  used by the BLE stack). **Still to add for Drive:** the reversed-client-id
  `CFBundleURLTypes` entry that `google_sign_in` needs.
- Android 12+ / iOS 13+ grant Bluetooth at runtime via `permission_handler`;
  the UI shows a friendly message if the user denies it.

## Tests

Both test files simulate two devices by re-opening the database singleton
against two different SQLite files, so a full two-master exchange is provable
on one laptop with **no phones, no network and no Google account**.

`test/sync_engine_test.dart` (merge engine + BLE):

- both-direction flow with FK remap, and watermark-driven suppression,
- LWW by `updated_at`, and the device-id tie-break (both sides converge),
- tombstone propagation for deletions,
- natural-key merge of independently created batches,
- frame reassembly of a 5000-byte payload, pairing-code/auth helpers,
- `SyncCodec` round trip including `_fk` metadata.

`test/cloud_sync_test.dart` (Drive path, against an in-memory `FakeMailbox`):

- mailbox file-name to device-id round trip,
- records travel through the mailbox with foreign keys remapped,
- **local edits are never swallowed when the peer is ahead** — the guard on
  the snapshot-before-apply ordering; it fails if the order is ever reversed,
- LWW when the same student is edited on both devices,
- tombstones propagate through the mailbox,
- a third device is refused instead of merged,
- a **failed upload changes nothing locally** and the retry resends the same
  rows,
- a damaged / half-uploaded file fails cleanly and applies nothing,
- bundle encode/decode validation (bad version, bad JSON, missing device id),
- pending-row counts, and a refusal to run with no connected account.

Run everything with:

```
flutter pub get
flutter analyze          (baseline: only pre-existing info lints)
flutter test
```

## Remaining manual validation

**Bluetooth**

1. `flutter build apk --release` → install `app-release.apk` on both phones.
2. Grant Bluetooth + (on Android ≤11) location permission.
3. Settings → Device & Sync → Pair: same 6-digit code on both displays,
   press Confirm on both.
4. Sync, edit a student on A, sync again, verify it appears on B (and vice
   versa); verify concurrent same-time edits converge to one value.
5. Pair a third phone and verify it is rejected.

**Google Drive**

6. Complete the one-time Cloud Console setup above, then install the *same
   release-signed* APK on both phones.
7. Sign both into the **same** Google account from Settings → Device & Sync →
   Connect Google Drive. Confirm the account email shows on both.
8. Add a student on A → Sync now. On B → Sync now → the student appears.
9. Airplane mode **on**, edit on both phones, airplane mode **off**, sync
   both → both databases match and nothing was lost.
10. Kill Wi-Fi mid-upload; confirm the error is friendly and the next sync
    recovers with no duplicates.
11. Check the Drive folder holds exactly **two** `tandav-*.json` files.

**iPhone**

12. Build the PWA, host it, and confirm a shared OAuth **Web** client can see
    the Android-created files (see the iPhone note above).
