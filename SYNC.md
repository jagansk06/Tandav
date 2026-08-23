# Tandav — Two-Master-Device Sync

Tandav is local-first: everything lives in the on-device SQLite database and
the app works with no internet at all. Two devices run the same database as
**two equal masters** and keep each other in sync.

There is exactly **one carrier**: a **Google Drive mailbox**. Both devices sign
into the same Google account and leave one small file each for the other to
pick up. It works anywhere in the world and needs internet only briefly, when
it actually syncs.

## Why there is only one carrier

A **Bluetooth LE** transport used to sit beside Drive as a "same room" fast
path (`bluetooth.dart`, `sync_manager.dart`, `protocol.dart`, and a vendored
`packages/ble_peripheral` plugin — about 3,000 lines). It was **deleted on
2026-08-23**, deliberately, and should not be reintroduced:

- **It could not carry the real requirement.** The two masters are in two
  different places. BLE needs both phones within ~10 m, so it could only ever
  handle the rare case, never the everyday one.
- **It doubled the number of routes into the merge engine.** Two carriers means
  two code paths that both have to be trusted with a paying studio's records.
  One is hard enough to prove correct.
- **The iPhone could never have used it.** iPhone ships as a **PWA**, and
  Safari has no Web Bluetooth.
- **It restricted which Androids could install the app at all.** The manifest
  carried `<uses-feature android:name="android.hardware.bluetooth_le"
  android:required="true" />`, which silently filters devices. Removing the BLE
  path *widened* hardware support as a side effect.

Nothing about the merge was carrier-specific, so the removal touched no merge
logic. What did move: `syncProtocolVersion` now lives in `sync_bundle.dart`
(same value, `1`).

## Architecture

| Piece            | File                                   | Role                                          |
| ---------------- | -------------------------------------- | --------------------------------------------- |
| **Merge engine** | `lib/sync/sync_engine.dart`            | outbound snapshots + inbound apply            |
| Wire format      | `lib/sync/sync_codec.dart`             | JSON encoding of table rows                   |
| Sync state store | `lib/sync/sync_state.dart`             | `sync_state` key/value persistence            |
| Record metadata  | `lib/sync/sync_meta.dart`              | `SyncStamp` (uuid / device / timestamp)       |
| Carrier          | `lib/sync/sync_mailbox.dart`           | abstract store-and-forward mailbox + file naming |
| Payload          | `lib/sync/sync_bundle.dart`            | one JSON document carrying all tables at once |
| Session          | `lib/sync/cloud_sync.dart`             | connect, upload, download, apply, throttling  |
| Backend          | `lib/sync/drive_mailbox.dart`          | Google Drive v3 implementation of the mailbox |
| UI               | `lib/screens/settings/device_sync_screen.dart` | Device & Sync settings screen      |
| Facade           | `lib/core/services.dart`               | exposes `syncEngine` / `syncState` / `mailbox` / `cloudSync` |

`SyncMailbox` stays an abstraction even with one implementation — that seam is
what lets `cloud_sync_test.dart` prove the whole exchange against an in-memory
`FakeMailbox`, with no network and no Google account.

## Device identity

- Each installation generates a persistent **device id** of the form
  `TANDAV-XXXX` (stored in `sync_state`, key `device_id`).
- The id is the identity and the conflict tie-breaker; it never changes for
  the life of the installation.
- Every synced row carries `sync_uuid` (stable UUID), `device_id`
  (last modifier) and `updated_at` (UTC ISO-8601).

## Google Drive sync

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

Do not bump `protocol` to tidy up. Bundles already sitting in customers' Drive
folders carry `1`, and `decode` rejects anything else, so a bump makes both
devices refuse the file the other one last wrote.

### When it runs

- **App open** and **app resume** → `cloudSync.autoSync()`.
- **Every 5 minutes while the app is in the foreground** → `autoSync()` again.
  Without this a phone left open all day never uploaded its own edits and never
  pulled the peer's, which is precisely the two-remote-locations case the whole
  design exists for. The timer starts on `resumed` and stops on every other
  lifecycle state, so a backgrounded app costs nothing.
- **Settings → Device & Sync → Sync now** → visible, with phase and counts.

`autoSync` is silent and throttled to once every 2 minutes: no spinner, no
error toast. With no internet, no connected account, or a sync already in
flight, a tick does nothing at all.

### Pairing over Drive

There is **no 6-digit code**. The shared Google account *is* the trust
boundary — only someone signed into it can write to the folder. The first peer
file a device reads is adopted as its pair and stored in `sync_state` under
`cloud_peer_device_id`.

That key is deliberately **not** `paired_device_id`. That name belonged to the
deleted Bluetooth transport and may still hold a stale value in any database
written by an older build, so reusing it would let a fresh Drive pairing read
back an old BLE peer id on exactly the devices that have been in the field
longest. Three now-dead keys may linger for the same reason and are simply
ignored: `paired_device_id`, `pairing_secret`, `last_sync_at`.

A **third device** is refused, not merged — with two unknown peer files the
app stops and says so rather than guessing. The message **names the files** and
how long ago each was written, because "delete one of these in Drive" is the
remedy and a bare `TANDAV-XXXX` is not something a customer can point at. The
usual culprit is a leftover bundle from `tools/fake-peer.html`, which is always
the oldest, so the dates do the choosing for them.

### Rebuilding a device that lost its data

**The files in Drive are deltas, not backups.** Each one holds only what its
device has not yet delivered, so once a device has sent everything, its file is
empty. That is fine while both devices are healthy and fatal when one is not: a
phone that was wiped, replaced, or reinstalled comes back with an empty
database, reads the peer's near-empty file, and finds nothing to restore from.
There is no server to ask instead.

**Settings → Device & Sync → "Send everything again"** is the way out. It calls
`CloudSyncManager.resendEverything()`, which **deletes every `sent.<table>`
key** (`SyncEngine.clearSentMarks`) and then syncs, so the next upload is a full
copy of the local database again.

Details that are easy to get wrong if this is ever rewritten:

- **Delete the keys; do not set them to `''`.** `computeOutbound` branches on
  `sent.isEmpty` and selects every row, but the other branch, `updated_at > ''`,
  skips a row whose `updated_at` is the empty string — representable in
  `attendance`, `fee_payments` and `event_participations`, which gained the
  column through `ALTER TABLE … NOT NULL DEFAULT ''`.
- **`_running` is held while the marks are cleared.** Otherwise a resume or the
  five-minute timer could start a sync in the gap, and its `markDeltaSent` —
  computed from a delta snapshotted *before* the clear — would write the marks
  straight back. The button would report success and have done nothing.
- **Clearing survives a failed sync, on purpose.** The customer taps this when
  something is already wrong, which is when their internet is least reliable.
  The request lives in the database, so whichever sync succeeds next carries the
  full copy.
- **`watermark.<table>` is left alone.** Those record what we have *received*;
  lowering them would re-apply the peer's rows against our own for no gain.
- **It is safe to press at any time.** The peer matches rows by `sync_uuid`,
  skips what it already has, and keeps anything it edited more recently. The
  only cost is a larger upload. That property is load-bearing: a customer who
  cannot tell whether they need the button must be able to press it anyway.

If the other device came back with a **new** `TANDAV-XXXX`, "Forget the other
device" is what to press instead — it does the same full re-offer *and* re-pairs
(see below). Its old file still has to be deleted from the Drive folder, or the
account holds three files and sync refuses to guess.

### `sent.<table>` is a claim about a **specific** peer

This is the single easiest thing to get wrong in this file, and getting it wrong
loses data silently.

`sent.<table>` does **not** mean "we uploaded this". It means **"the peer we are
paired with already holds everything up to this timestamp"** — which is why
`markDeltaSent` may only run after a *confirmed* write. The claim is about one
named device. **So anything that clears `cloud_peer_device_id` must clear the
sent marks in the same transaction**, because the next device to be adopted is a
different device and it holds nothing.

Both places that forget a peer now do this: `forgetCloudPeer()` and
`disconnect()`. When only the first half was done, the failure looked like this:

- the replacement device was adopted normally;
- **both** devices reported a successful sync;
- the new device received only rows edited *after* the forget, and the studio's
  entire history was never offered to it;
- nothing on either screen suggested anything was wrong.

It also disguises itself as two separate faults — "the phone is not sending" and
"the iPhone is not sending" — because neither side is sending, for the same
reason. Cost: a full debugging session on real hardware.

The consequence for the UI is that **"Forget the other device" implies "Send
everything again"**, so the customer no longer has to know to press the second
button. Its dialog says the next sync will be a full copy and will take longer,
which is the only visible difference.

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

## What syncs

All nine business tables, in dependency order (parents before children):

`batches → students → attendance → monthly_attendance → fees →
fee_payments → events → event_participations → monthly_progress`

Never synced: `users` and `app_settings`, and the `sync_state` table itself
(except through the manager). This matters for more than tidiness — the bundle
is **plain, unencrypted JSON**, and `users` holds the password hash while
`app_settings` holds the account recovery code. Neither may ever enter a
bundle. (A *backup file* is the whole `.db`, so it does contain both; treat
backups as secrets.)

## How merge works

- **Incremental (watermarks):** each table has a stored watermark = the
  newest `updated_at` received from the peer (`watermark.<table>` in
  `sync_state`). Nothing is ever dumped in full. Note there are **two** marks
  per table and they are not interchangeable: only `sent.<table>` may gate what
  we transmit. Using the inbound mark for that was a real data-loss bug.
- **Conflict resolution (LWW):** newer `updated_at` wins. On an exact
  timestamp tie the lexicographically **higher device id** wins, so both
  devices reach the same answer. The losing side keeps its watermark behind
  until the winner is re-transmitted (echoes are skipped), guaranteeing
  convergence.
- **Deletions (tombstones):** delete operations soft-delete (`deleted_at`);
  the tombstone row syncs like any other update and is never dropped from
  queries until the peer has seen it. Disconnecting and reverting never lose
  data.
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

- Android (`AndroidManifest.xml`): `INTERNET` and `ACCESS_NETWORK_STATE`. That
  is the whole list. Six Bluetooth/location permissions and the
  `uses-feature bluetooth_le required="true"` tag were removed with the BLE
  path.
- No runtime permission prompt exists anywhere in the app any more —
  `permission_handler` was dropped as a dependency.
- iOS: the native iOS target is **not** the shipping path; iPhone is a PWA, so
  `Info.plist` work (including the `google_sign_in` reversed-client-id
  `CFBundleURLTypes` entry) is not on the critical path.

## Tests

Both test files simulate two devices by re-opening the database singleton
against two different SQLite files, so a full two-master exchange is provable
on one laptop with **no phones, no network and no Google account**.

`test/sync_engine_test.dart` (merge engine):

- both-direction flow with FK remap, and confirmed-send suppression,
- LWW by `updated_at`, and the device-id tie-break (both sides converge),
- tombstone propagation for deletions,
- natural-key merge of independently created batches,
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
- pending-row counts, and a refusal to run with no connected account,
- **"Send everything again"** — that a wiped device really is rebuilt from the
  peer (and that the pre-resend mailbox file is provably empty, which is the
  whole reason the action exists), that re-offering rows cannot duplicate them
  or overwrite a newer edit on the peer, and that a resend requested with no
  internet is still honoured by the next successful sync.

Run everything with:

```
flutter pub get
flutter analyze
flutter test
```

## Remaining manual validation

1. Complete the one-time Cloud Console setup above, then install the *same
   release-signed* APK on both phones. **Install over the top**
   (`adb install -r`, which is what `ship.ps1` does) — never uninstall first,
   because uninstalling erases the studio's only copy of its data.
2. Sign both into the **same** Google account from Settings → Device & Sync →
   Connect Google Drive. Confirm the account email shows on both.
3. Add a student on A → Sync now. On B → Sync now → the student appears.
4. Airplane mode **on**, edit on both phones, airplane mode **off**, sync
   both → both databases match and nothing was lost.
5. Kill Wi-Fi mid-upload; confirm the error is friendly and the next sync
   recovers with no duplicates.
6. Leave the app open on both phones for ~10 minutes with no taps, and confirm
   an edit on A reaches B on its own (the foreground timer).
7. Check the Drive folder holds exactly **two** `tandav-*.json` files.
8. Connect a third device and verify it is refused, not merged.
9. **Recovery.** On phone B, uninstall Tandav (the one time doing that is
   correct) and reinstall, so it comes back empty with a new id. Delete B's old
   `tandav-*.json` from the Drive folder. On phone A tap **Forget the other
   device**, then **Send everything again**, then sync B — B must come back with
   the full studio. Then tap **Send everything again** on a healthy pair and
   confirm nothing duplicates.

**iPhone**

10. Build the PWA, host it, and confirm a shared OAuth **Web** client can see
    the Android-created files (see the iPhone note above).
