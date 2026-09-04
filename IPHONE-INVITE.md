# What to send the iPhone user

Two things go out: **a link** and **five lines of instructions**. There is no file
to send and nothing to install from a store.

The link is always the same for every customer:

```
https://jagansk06.github.io/tandav-app/
```

If it does not open yet, it has not been deployed — run `.\tools\deploy-pwa.ps1`
and do the one-time settings it prints. See `PWA.md`.

---

## Paste this into WhatsApp

Written in WhatsApp's own formatting (`*bold*`), so it arrives looking right.
Keep the *open it in Safari* line — it is the only step people get wrong.

```
Tandav is ready for your iPhone. It's not from the App Store, so it installs a
little differently — takes about a minute, once.

1. Tap this link, then tap the *Safari* icon at the bottom right to open it in
   Safari. (It won't install from inside WhatsApp.)
   https://jagansk06.github.io/tandav-app/

2. Wait for it to finish loading the first time — it's a big download, so use
   wifi.

3. Tap the *Share* button (square with an arrow going up), scroll down, and tap
   *Add to Home Screen*, then *Add*.

4. Close Safari. Open Tandav from the new icon on your home screen.

5. Set your own username and password. It'll show you a *recovery code* — take a
   screenshot of it. That code is the only way back in if you forget the
   password, and it's never shown again.

Then tell me and I'll connect it to the studio's data.
```

---

## Then, to connect them to the studio's data

**Clear a slot first.** Only **two** devices can share the Drive account, and the
count is one `tandav-*.json` file per device in the `Tandav Sync` folder. Any
browser you tested with still holds a slot, and the iPhone would be refused as a
third device.

1. In the Google account's Drive, open **Tandav Sync** and delete every
   `tandav-*.json` that is not the Android phone's. Also delete any stray
   `tandav-*.json` sitting in the root of My Drive.
2. On the **Android** phone: Settings → **Device & Sync** → **Forget the other
   device**. Safe — forgetting also clears the sent marks, so the next device to
   sync gets the whole database rather than nothing.
3. On the **iPhone**: Settings → **Device & Sync** → sign in with **the same
   Google account** as the Android phone. Not their personal Gmail — the same one.
4. On the **Android** phone: **Send everything again**. This is the step that
   actually fills the iPhone. The Drive files are changes in transit, not a copy
   of the studio, so without it the iPhone only ever receives what changes from
   here on.
5. On the **iPhone**: sync. The batches and students appear.

## Two things to say up front

Neither is a fault, and both get reported as one if nobody mentions them first.

- **One "Resume syncing" tap per launch.** Safari only keeps the Google
  permission in memory, so opening the app needs one tap before it syncs.
  Everything else — students, attendance, fees — needs no tap and no signal.
- **No photos and no Backup/Restore on iPhone.** Both are path-based and a
  browser has no file paths. The Android phone stays the one that holds real
  backup files.

## What they should know about their data

It lives on their phone, not on a server. It survives with no signal. It is
**deleted if they delete the app**, exactly like any other app — and the way back
from that is step 4 above on the Android phone, which rebuilds them from scratch.
Worth saying plainly once, because "it's a website" makes people assume the
opposite.
