# Tandav — Two-Master-Device Sync (BLE)

Tandav is local-first: everything lives in the on-device SQLite database and
the app never needs internet. Two Android or iOS devices can run the same
database as **two equal masters** and keep each other in sync over Bluetooth
Low Energy (BLE).

## Architecture

| Piece            | File                                   | Role                                          |
| ---------------- | -------------------------------------- | --------------------------------------------- |
| Transport        | `lib/sync/bluetooth.dart`              | BLE peripheral + central link, frame codec    |
| Session/state    | `lib/sync/sync_manager.dart`           | pairing handshake, auth, sync exchange, phase |
| Merge engine     | `lib/sync/sync_engine.dart`            | outbound snapshots + inbound apply            |
| Wire format      | `lib/sync/sync_codec.dart`             | JSON encoding of table rows                   |
| Protocol helpers | `lib/sync/protocol.dart`               | envelope, frame codec, pairing code, auth     |
| Sync state store | `lib/sync/sync_state.dart`             | `sync_state` key/value persistence            |
| Record metadata  | `lib/sync/sync_meta.dart`              | `SyncStamp` (uuid / device / timestamp)       |
| UI               | `lib/screens/settings/device_sync_screen.dart` | Device & Sync settings screen      |
| Facade           | `lib/core/services.dart`               | exposes `syncEngine` / `syncState` / `sync`   |

## Device identity

- Each installation generates a persistent **device id** of the form
  `TANDAV-XXXX` (stored in `sync_state`, key `device_id`).
- The id is the identity and the conflict tie-breaker; it never changes for
  the life of the installation.
- Every synced row carries `sync_uuid` (stable UUID), `device_id`
  (last modifier) and `updated_at` (UTC ISO-8601).

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

## Pairing

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
  android.hardware.bluetooth_le` required.
- iOS (`Info.plist`): `NSBluetoothAlwaysUsageDescription` and
  `NSBluetoothPeripheralUsageDescription` (plus `NSLocalNetworkUsageDescription`
  used by the BLE stack).
- Android 12+ / iOS 13+ grant Bluetooth at runtime via `permission_handler`;
  the UI shows a friendly message if the user denies it.

## Tests

`test/sync_engine_test.dart` simulates the two devices by re-opening the
database singleton against two different SQLite files and proves:

- both-direction flow with FK remap, and watermark-driven suppression,
- LWW by `updated_at`, and the device-id tie-break (both sides converge),
- tombstone propagation for deletions,
- natural-key merge of independently created batches,
- frame reassembly of a 5000-byte payload, pairing-code/auth helpers,
- `SyncCodec` round trip including `_fk` metadata.

Run everything with:

```
flutter test
flutter analyze          (baseline: only pre-existing info lints)
```

## Remaining manual validation

1. `flutter build apk --release` → install `app-release.apk` on both phones.
2. Grant Bluetooth + (on Android ≤11) location permission.
3. Settings → Device & Sync → Pair: same 6-digit code on both displays,
   press Confirm on both.
4. Sync, edit a student on A, sync again, verify it appears on B (and vice
   versa); verify concurrent same-time edits converge to one value.
5. Pair a third phone and verify it is rejected.
6. iOS: run the same codebase from a Mac (`flutter run` with an iPhone) —
   not buildable on Windows.