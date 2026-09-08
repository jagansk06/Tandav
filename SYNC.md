# Tandav — Multi-Master Device Sync

Tandav is local-first: everything lives in the on-device SQLite database and
the app works with no internet at all. Up to **ten devices** run the same
database as **equal masters** and keep each other in sync.

There is exactly **one carrier**: a **Google Drive mailbox**. Every device signs
into the same Google account and leaves one small file for the others to pick
up. It works anywhere in the world and needs internet only briefly, when it
actually syncs.

The third device is normally the studio's **attender**, whose build syncs a
subset of the tables. That scoping is described in `ATTENDER.md`; the merge
itself does not care how many tables a peer holds, which is why it needed no
special case here.

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
   transaction, together with the acknowledgements we owe each peer
   (`outboundAcks`).
2. **Upload** it as one JSON bundle, overwriting our own file. The bundle also
   carries an `acks` section — the newest `updated_at` of each peer's rows we
   have handled.
3. **Download** the peer's file and validate it.
4. **Process its acks** (`recordAcks`): this, and only this, advances our
   `sent.<peer>.<table>` marks.
5. **Apply** every table in **one** write transaction (`applyIncoming`), which
   at the same time records the acks we owe that peer next time.

Why snapshot before applying: applying **advances the watermarks**, and the
outbound delta is defined as *rows newer than the watermark*. Merge first and
our own older-but-unsent rows fall behind the new watermark and **would never
reach the peer**. Why upload before applying: a failed upload leaves the local
database completely untouched, so the retry recomputes an identical delta.

**Nothing marks a row "delivered" at upload time.** The file sits in the
account, but *delivered* is a claim about what another device **read**, and only
that device's acknowledgement can confirm it. This is the entire safety
guarantee against the single-file-overwrite hole — if the upload succeeded but
the peer never read it, the row is still on offer, which is exactly the honest
state. A bundle that fails to decode therefore changes nothing locally.

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
boundary — only someone signed into it can write to the folder. Peer files a
device reads are adopted and stored in `sync_state` under `cloud_peer_device_ids`
as a comma-separated list, up to `CloudSyncManager.maxPeers` (2) of them.

That key is deliberately **not** `paired_device_id`. That name belonged to the
deleted Bluetooth transport and may still hold a stale value in any database
written by an older build, so reusing it would let a fresh Drive pairing read
back an old BLE peer id on exactly the devices that have been in the field
longest. Three now-dead keys may linger for the same reason and are simply
ignored: `paired_device_id`, `pairing_secret`, `last_sync_at`.

The **single**-peer key `cloud_peer_device_id` is the previous version of this
one and is still read, never written: `knownPeers()` folds it into the list so a
phone that has been syncing since before three devices were supported keeps its
pairing across the upgrade instead of silently re-adopting.

**Ten devices total** (`maxDevices`), so nine peers each. An **eleventh** is
refused, not merged — the app stops and says so rather than guessing which of
eleven phones to drop. The message **names the files** and how long ago each was
written, because "delete one of these in Drive" is the remedy and a bare
`TANDAV-XXXX` is not something a customer can point at. The usual culprit is a
leftover bundle from `tools/fake-peer.html`, which is always the oldest, so the
dates do the choosing for them.

Adoption is **all or nothing per sync**: if more strangers are present than there
are free slots, *none* are adopted. Taking the newest two would be worse than
failing — it silently picks the studio's sync partners by upload time, and the
customer would never be told a choice had been made.

The order inside `_run()` is what makes three work: **list → snapshot (+ acks) →
upload → process peer acks → apply**. Listing first means a peer adopted on this
run is already in the peer set when the outbound delta is computed, so a newcomer
gets a full bundle on the *same* sync it is discovered, not the next one.

### Rebuilding a device that lost its data

**The files in Drive are deltas, not backups.** Each one holds only what its
device has not yet delivered, so once a device has sent everything to everyone,
its file is empty. That is fine while every device is healthy and fatal when one
is not: a phone that was wiped, replaced, or reinstalled comes back with an empty
database, reads the peers' near-empty files, and finds nothing to restore from.
There is no server to ask instead.

A phone that comes back with a **new** `TANDAV-XXXX` is not in this trouble — it
is a stranger with no sent mark, which drops the outbound floor to "everything",
so the others re-offer their whole database on the next sync by themselves. The
trap is the phone that comes back **with its old device id** (a restored
`app_settings`, or a database file copied across): the peers still hold marks
saying it has been told everything, so they send it nothing.

**Settings → Device & Sync → "Send everything again"** is the way out. It calls
`CloudSyncManager.resendEverything()`, which **deletes every sent mark** for
every peer (`SyncEngine.clearSentMarks`, matching the `sent.` prefix) and then
syncs, so the next upload is a full copy of the local database again.

Details that are easy to get wrong if this is ever rewritten:

- **Delete the keys; do not set them to `''`.** `computeOutbound` branches on
  `sent.isEmpty` and selects every row, but the other branch, `updated_at > ''`,
  skips a row whose `updated_at` is the empty string — representable in
  `attendance`, `fee_payments` and `event_participations`, which gained the
  column through `ALTER TABLE … NOT NULL DEFAULT ''`.
- **`_running` is held while the marks are cleared.** Otherwise a resume or the
  five-minute timer could start a sync in the gap, and its `recordAcks` —
  computing marks from a peer bundle it read *before* the clear — would write
  them straight back. The button would report success and have done nothing.
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

A device that came back with a **new** `TANDAV-XXXX` usually needs **nothing
pressed at all** now. If a slot is free it is adopted on the next sync, and
because a peer with no mark drops the outbound floor to "everything", it receives
the studio's full history on that same run. Its old file should still be deleted
from the Drive folder — otherwise a dead name holds a slot and the device that
fills the cap past ten is the one refused.

"Forget the other device" is for the case that cannot fix itself: **every** slot
held by devices that will never write again. It clears the peers and their marks,
so the next sync adopts whoever is actually there and re-offers everything.

### `sent.<peerId>.<table>` is a claim about **one named peer**

This is the single easiest thing to get wrong in this file, and getting it wrong
loses data silently.

A sent mark does **not** mean "we uploaded this". It means **"that specific
device already holds everything up to this timestamp"** — which is why it only
advances from the peer's own **acknowledgement** (`recordAcks`), never from our
upload, and why the peer id is part of the key. **So anything that forgets a
peer must clear that peer's marks in the same transaction**, because the next
device adopted is a different device and it holds nothing.

Both places that forget a peer do this: `forgetCloudPeer()` and `disconnect()`.
When only the first half was done, the failure looked like this:

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

#### Why the mark is per peer, and what the floor is

One file serves every reader, so the bundle has to satisfy **whoever is furthest
behind**. `computeOutbound` therefore takes the **minimum** mark across the
current peers, and:

- **a peer with no mark drops the floor to "send everything"** — which is exactly
  what makes a device joining an established studio receive its whole history;
- **an empty peer set also means "send everything"**, and `recordAcks` with no
  peers is a **no-op**. Nothing has been delivered to nobody. The single-mark
  version got this wrong in a way that cost data: a first phone used for a week
  alone marked its rows delivered, then overwrote its own file with an empty
  delta, and the second phone arrived to an empty mailbox and a first phone
  insisting it had already sent everything.

`pendingRowCount()` follows the same rule, so a device with no peer yet honestly
reports its **whole database** as pending rather than zero. That is not a bug to
tidy away: nothing has been delivered, and the count is the answer to "what would
the next sync send".

### How a row is delivered (and the overwrite hole)

One file per device, **overwritten in place** on every sync, makes a bundle a
**delta, not a snapshot**: a batch of rows that a peer was offline across two of
our uploads only ever lived in the first upload, and the second overwrote it. If
the `sent` mark advanced on upload, that batch would be gone forever. So delivery
is now **confirmed by the reader**:

- When we apply a peer's rows we remember, per peer and table, the newest
  `updated_at` we handled (`ack.<peerId>.<table>`), written in the **same
  transaction** as the apply.
- That watermark travels as an **`acks` section** in our next bundle, e.g.
  `"acks": { "TANDAV-91EF": { "students": "2026-09-01T08:00:00.000Z" } }` —
  peer id → table → newest `updated_at` of that peer's rows we saw. The field is
  **additive and optional**, so version-1 bundles still decode and an old build
  simply ignores it. That is safe: an old build never acks, so the new build
  keeps re-offering rows until the old build upgrades — re-offering everything
  to a device that never acks is the price of *not* losing data, and peers skip
  the echoes as unchanged.
- The peer reads our acks and feeds them into `recordAcks`, which advances its
  `sent.<peer>.<table>` marks — the **only** thing that may. Consequences:

  - Rows a peer never read are re-offered **every** sync until it acks, however
    often our upload overwrites its file — an offline peer's rows can no longer be
    lost to a second upload.
  - A table we applied but left **orphaned** is not acked, so the owner keeps
    re-offering it until the parents arrive too.
  - A table this build does **not** hold (the attender receiving `events`) is acked
    wholesale, so the owner does not re-offer the entire table to a device that
    will never store it.
  - Watermarks are **clamped**: never past our own `now`, never past the newest
    `updated_at` we actually hold, never backwards — so a fast or lying peer clock
    cannot rescue a `sent` mark into covering rows the peer never saw.

There is now no "delivery on upload" path at all: rows stop being offered **only**
on a confirmed read. That is the fix for the old limitation. The residual cost is
one **one-sync lag** — a row A uploads is not marked delivered to B until B has
run its own sync and carried the ack back — which is a re-offer of a handful of
rows, never a loss.

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

On the **attender's build** that list stops after `fee_payments`: the last three
are filtered out of both the outbound delta and anything inbound, so his phone
neither sends nor stores them. The six he keeps are foreign-key closed, so the
short list is still a valid database. See `ATTENDER.md`.

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
  we transmit, and `sent.<table>` itself advances only from the peer's
  acknowledgement, never from our upload. Using the inbound mark (or the upload)
  for that was a real data-loss bug.
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
  transaction** together with the received-mark and acknowledgement advances; a
  failure rolls back and the local database is never half-updated.

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

Both test files simulate several devices by re-opening the database singleton
against different SQLite files, so a full three-master exchange — including the
attender's restricted build — is provable on one laptop with **no phones, no
network and no Google account**.

`test/sync_engine_test.dart` (merge engine):

- both-direction flow with FK remap, and confirmed-send suppression,
- LWW by `updated_at`, and the device-id tie-break (both sides converge),
- tombstone propagation for deletions,
- natural-key merge of independently created batches,
- acknowledgement clamping — a future or backwards watermark can neither
  strand our edits nor force re-sends,
- `SyncCodec` round trip including `_fk` metadata.

`test/cloud_sync_test.dart` (Drive path, against an in-memory `FakeMailbox`):

- mailbox file-name to device-id round trip,
- records travel through the mailbox with foreign keys remapped,
- **local edits are never swallowed when the peer is ahead** — the guard on
  the snapshot-before-apply ordering; it fails if the order is ever reversed,
- LWW when the same student is edited on both devices,
- tombstones propagate through the mailbox,
- **devices share the account until the cap is reached, then refuse** — the
  slots fill up to `maxDevices`, and the extra one is named rather than merged,
- **the attender build never puts owner-only rows in the mailbox** — `events`,
  `event_participations` and `monthly_progress` are filtered out even when they
  are somehow present in the local database (see `ATTENDER.md`),
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
- **rows a peer misses while offline are re-offered, not lost** — the core
  ack guarantee: a peer offline across two of our uploads still receives the
  row that only lived in the first,
- **first sync merges a large existing dataset with local data, no dupes** —
  A holding 300 students and B holding 3 converge to 303 on both, each row
  exactly once,
- the acks round trip with empty bundles: a peer that has nothing to send still
  acknowledges and un-sticks the other device's file.

Run everything with:

```
flutter pub get
flutter analyze
flutter test
```

## Remaining manual validation

1. Complete the one-time Cloud Console setup above, then build both roles with
   `.\ship.ps1 -Both` and install the *same release-signed* APK on each phone —
   `Tandav-Owner-*` on the two owner phones, `Tandav-Attendance-*` on the
   attender's. **Install over the top** (`adb install -r`, which is what
   `ship.ps1` does) — never uninstall first, because uninstalling erases the
   studio's only copy of its data.
2. Sign all three into the **same** Google account from Settings → Device &
   Sync → Connect Google Drive. Confirm the account email shows on each.
3. Add a student on A → Sync now. On B → Sync now → the student appears.
4. Airplane mode **on**, edit on both owner phones, airplane mode **off**, sync
   both → both databases match and nothing was lost.
5. Kill Wi-Fi mid-upload; confirm the error is friendly and the next sync
   recovers with no duplicates.
6. Leave the app open on both owner phones for ~10 minutes with no taps, and
   confirm an edit on A reaches B on its own (the foreground timer).
7. Check the Drive folder holds one `tandav-*.json` file per device.
8. Connect more than **ten** devices and verify the extra is refused, not
   merged, and that the message names the files it can see.
9. **The attender's phone.** Mark attendance and toggle a fee on it → sync →
   both changes reach the owners. Create an **event** on an owner phone, sync
   everything, then confirm the attender's phone still has no events (Settings →
   Device & Sync shows it synced, and no event screen exists there). Verify the
   Fees tab on his build shows the register and the paid/partial/due counts but
   **no Expected / Collected / Pending money row**.
10. **Recovery.** On phone B, uninstall Tandav (the one time doing that is
    correct) and reinstall, so it comes back empty with a new id. Delete B's old
    `tandav-*.json` from the Drive folder. Sync B — a free slot plus no sent mark
    should hand it the full studio with nothing pressed on A. If B came back with
    its **old** id instead, tap **Send everything again** on A. Then tap **Send
    everything again** on a healthy account and confirm nothing duplicates.

**iPhone**

11. Build the PWA, host it, and confirm a shared OAuth **Web** client can see
    the Android-created files (see the iPhone note above).
