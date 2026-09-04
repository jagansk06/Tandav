# The iPhone build (PWA)

The iPhone version is the same Flutter app compiled for the web and installed
from Safari with **Add to Home Screen**. No App Store, no store review, nothing
to renew. Everything below is one-time developer setup.

Google sign-in has its own page: see **OAUTH-SETUP.md §6, §6a, §6b**.

---

## The build command

```
cd D:\Projects\Tandav\mobile
flutter build web --release --pwa-strategy=none --no-web-resources-cdn --base-href /<repo>/
```

You do not normally type this — `tools\deploy-pwa.ps1` runs it, and then checks
in the output that the flags actually took effect. It is written out here because
the flags are the part worth understanding.

Every flag is load-bearing. Leaving any of them off produces an app that looks
fine on a desk with wifi and fails in a studio.

### `--pwa-strategy=none`

Stops Flutter generating a service worker **and** stops it registering one.

Flutter used to ship a caching service worker; it does not any more. With the
default `offline-first`, the `flutter_service_worker.js` in `build/web` is 815
bytes whose entire body unregisters itself, and `flutter_bootstrap.js` carries
the note *"Flutter's service worker is deprecated and will be removed in a
future Flutter release"*. Verified by reading the built output and
`flutter_tools/lib/src/web/file_generators/flutter_service_worker_js.dart`.

So Tandav brings its own: **`mobile/web/tandav_sw.js`**, registered from
`web/index.html`. `none` is what keeps Flutter from registering a second worker
for the same scope and fighting over it.

Without a service worker the app needs the network on every single launch. The
database would still be safe in the browser's storage — but the app could not
open to show it, which for the customer is the same thing as losing it.

### `--no-web-resources-cdn`

Serves CanvasKit from our own origin instead of `gstatic.com`.

CanvasKit is the graphics engine and the largest download in the app. Fetched
cross-origin it cannot be cached by our service worker, so the app still would
not start offline. This flag also makes Flutter bundle a local Roboto fallback
font, which is another thing that would otherwise be fetched from the network.

### `--base-href /<repo>/`

GitHub Pages serves the app from a subpath. Without this every asset request
404s and the page is blank. Use the actual repository name.

---

## What is in `web/`

| File | Why |
|---|---|
| `index.html` | iOS home-screen meta tags, the dark boot splash, the Google client id, and the service worker registration |
| `manifest.json` | App name, `standalone` display, Tandav's colours |
| `tandav_sw.js` | The offline cache. Read the header comment before changing it |
| `icons/` | Generated from the studio logo by `tools/make-web-icons.py` |
| `sqlite3.wasm` | The database engine, placed here by `dart run sqflite_common_ffi_web:setup`. Do not delete: without it the app opens and then has no database |

There is deliberately **no `sqflite_sw.js`**, although the setup command puts one
here. See *The database engine's two halves must be the same version* below.

The icons use only the circular medallion from the logo, not the wordmark — at
192 pixels "TANDAV DANCE STUDIO" is a smudge. Regenerate with
`python tools/make-web-icons.py` from the repo root.

---

## The database engine's two halves must be the same version

This one cost most of a day, presented as a hang on the splash screen, and the
browser's only clue was:

```
Unsupported operation: unsupported result null (null)
    at database_mixin.dart:981
```

WASM SQLite ships as **two** pieces that are built together: the binary
`sqlite3.wasm`, and the Dart package `sqlite3`, which supplies the JavaScript
functions that the binary imports. The names of those imports change between
major versions of the pair.

`sqflite_common_ffi_web` 0.4.5+4 declares `sqlite3: '>=2.4.6 <4.0.0'`, so pub
resolved **3.5.2** — while its setup script downloads the binary from a
hard-coded release, `sqlite3-2.4.6/sqlite3.wasm`
(`lib/src/setup/sqlite3_wasm_version.dart`). Reading the two artefacts:

| | 2.4.6 `sqlite3.wasm` needs | `sqlite3` 3.5.2 provides |
|---|---|---|
| callbacks | `dart.function_xFunc`, `function_xStep`, `function_hook`, `function_compare`, … | `dart.dispatch_xFunc`, `dispatch_xStep`, `dispatch_update`, `dispatch_compare`, … |
| memory | imports `env.memory` | only installs a `dart` namespace |

So `WebAssembly.instantiateStreaming` throws a **LinkError**. Nothing is wrong
with the app's own code, and nothing shows up in `flutter analyze` or
`flutter build web`, because both halves compile perfectly — they simply do not
fit together at runtime.

**The fix is the pin in `mobile/pubspec.yaml`:** `sqlite3: 2.4.6`, exact, with a
comment pointing at the file to re-read if `sqflite_common_ffi_web` is ever
upgraded. Bump one and you must bump the other and re-run
`dart run sqflite_common_ffi_web:setup`.

### Why the error was invisible, and why we no longer use the worker

By default the package runs SQLite in a **shared worker** loaded from
`sqflite_sw.js`. Its message handler ends like this
(`lib/src/sw/shared_worker.dart`):

```dart
} catch (e, st) {
  _log('$_shw error caught $e $st');
  port.postMessage(null);
}
```

Any failure inside the worker — including the engine never loading — comes back
as an empty reply. `sqflite_common` then sees a null where a database id should
be and throws `unsupported result null (null)`. The real LinkError was printed
the whole time, in the *worker's* console, which is a separate inspector at
`chrome://inspect/#workers` and does not exist at all on iOS.

The app therefore uses `databaseFactoryFfiWebNoWebWorker`, which rethrows into
the page console. Two reasons, both standing on their own:

- **iOS Safari has never supported `SharedWorker`.** The iPhone is the entire
  reason this build exists, so the default would put the target device on a
  fallback code path that no other browser takes.
- **An error that cannot be seen will be paid for twice.**

The cost is that queries run on the main isolate instead of off it. For a
studio's few hundred rows that is not measurable. One thing it does give up:
two browser tabs of the app open at once would each hold the database, where a
shared worker would have arbitrated. A home-screen PWA is a single instance, so
this is theoretical, but it is the reason to think twice before telling someone
to "just open it in two tabs".

---

## Testing it locally

`flutter run -d chrome` is for ordinary development. It deliberately does **not**
register the service worker: a debug build's JavaScript changes on every hot
restart, and a cache-first worker would keep serving the previous version, which
looks exactly like hot reload being broken.

**It also throws the database away between runs.** `flutter run` launches Chrome
with a throwaway `--user-data-dir`, so the IndexedDB that holds the whole
database is empty at the start of every run: a new `TANDAV-XXXX` device id, no
students, the signup screen again, and one more orphan `tandav-*.json` left
behind in the Drive folder each time. Storage does persist *within* a run, so a
reload looks reassuringly fine and hides it. Anything about persistence, device
identity or sync has to be tested against a served build — the local
`python -m http.server` below, or the deployed Pages URL — opened in your own
browser.

Pin the port, because Google refuses to sign in from an origin that is not
listed on the OAuth client and `flutter run` otherwise picks a random one:

```
flutter run -d chrome --web-port=5555
```

To test the offline behaviour, serve the real build and opt in once with `?sw=1`:

```
cd D:\Projects\Tandav\mobile
flutter build web --release --pwa-strategy=none --no-web-resources-cdn
cd build\web
python -m http.server 5555
```

Note the missing `--base-href` — deliberate. A build made for GitHub Pages has
`<base href="/<repo>/">` baked in, and served from the root of a local server
every asset would 404 and the page would sit on the splash screen. Build without
it for local testing, and with it for deployment.

Then open `http://localhost:5555/?sw=1`, let it load fully, and in DevTools →
Application → Service Workers tick **Offline** and reload. The app must still
start and still show the students. Check DevTools → Application → IndexedDB for
the database, and confirm it survives a reload.

A local build leaves the cache version as the literal `__TANDAV_SW_VERSION__`
string — only the deploy script stamps a real one — so every local build shares
one cache name. Tick **Update on reload** in DevTools → Application → Service
Workers while testing, or the second build will be served out of the first
build's cache.

---

## Deploying

```
cd D:\Projects\Tandav
.\tools\deploy-pwa.ps1
```

Builds, prunes, stamps the cache version, and publishes the result. Use `-NoPush`
to stop just before pushing, or `-NoBuild` to re-publish the build that is
already there.

### Two repositories, and why

The built site does **not** go into this repository. GitHub Pages on the free
plan will only serve a **public** repo, and Tandav's source stays private, so the
site is published to a second repo that holds nothing but build output:

| | Repo | Visibility | Holds |
|---|---|---|---|
| Source | `jagansk06/Tandav`, branch `Trial` | private | the app |
| Site | `jagansk06/tandav-app`, branch `main` | **public** | `build/web`, nothing else |

Served at **`https://jagansk06.github.io/tandav-app/`** — that URL *is* the
product on iPhone, and it is what you send a customer.

The site repo is assembled in `D:\Projects\tandav-site`, outside this repo, which
is **wiped and rebuilt on every deploy**. Never put anything there by hand. It
carries exactly **one commit**, replaced by a force push each time: a build-output
repo that accumulated 18 MB per deploy would eventually stop being clonable, and
there is no history worth keeping in generated files.

Only two strings decide all of this — `$GitHubUser` and `$SiteName` at the top of
the script. `$BaseHref`, `$SiteUrl` and `$Origin` are derived from them, so the
served path and `--base-href` cannot drift apart. That matters because when they
disagree the result is a blank white page with a 404 for every asset, which reads
like a broken build rather than a wrong string.

Note that the OAuth origin is `https://jagansk06.github.io` either way — an
origin is scheme + host with no path, so renaming the site repo never means
another trip to the Google console.

The script refuses to run if `mobile/web/index.html` still has the
`REPLACE_WITH_WEB_CLIENT_ID` placeholder, or if the sqflite WASM files are
missing. Both of those deploy perfectly happily and fail only later, in the
browser, in the customer's hands.

### What it prunes, and why that is safe

`build/web` is 42 MB, of which 37 MB is CanvasKit — but `flutter_bootstrap.js`
records this build as exactly one target:

```json
"builds":[{"compileTarget":"dart2js","renderer":"canvaskit","mainJsPath":"main.dart.js"}]
```

So three groups of files can never be requested: the `*.symbols` debug maps
(7.6 MB), `skwasm*` and `wimp*` (12.4 MB — loaded only when the renderer is
`skwasm`, which is a `--wasm` build), and `canvaskit/webparagraph/` (3.7 MB —
reached only when `flutterConfiguration.preferWebParagraph` is set, which the app
never sets). That leaves about 18 MB.

**Both remaining CanvasKit variants stay.** `canvaskit/chromium/` is picked when
the browser has Chromium's break iterators and image codecs; plain `canvaskit/`
is the fallback that Safari and Firefox get — which is the iPhone, the entire
point of this build. Deleting either breaks one of the two browsers that matter.

First load on an iPhone is then roughly 12 MB, once: `canvaskit.wasm` 7.3 MB,
`main.dart.js` 3.3 MB, `sqlite3.wasm` 0.7 MB, assets 1.4 MB. After that the
service worker serves everything from cache.

### One-time settings

**Create the site repo first.** `github.com/new` → name it `tandav-app` → **Public**
→ no README, no `.gitignore`, no licence. It must start completely empty; the
first deploy force-pushes over whatever is there.

**GitHub → `tandav-app` → Settings → Pages → Deploy from a branch → `main` /
root.** Give it a couple of minutes on the first deploy. Nothing here publishes
the source: the private repo is never pushed to, and the keystore,
`key.properties` and `device-log.txt` are gitignored and have never been
committed either way.

**Google Cloud Console → Credentials → the Web client → Authorized JavaScript
origins**, add exactly:

```
https://jagansk06.github.io
```

An origin is scheme + host, with **no path** — `https://jagansk06.github.io/tandav-app/`
is rejected. Sign-in fails with `invalid_client` until this is added.

**Same console, two more, both required before sync can work on iPhone:** enable
the **People API**, and add `userinfo.email` and `userinfo.profile` to the consent
screen. Without them the app installs and runs offline perfectly and can never
reach Drive. See OAUTH-SETUP.md §6.

---

## Handing it to the iPhone user

There is no file to send. You send a **link**, and they install it from the link.

**Before you send it, make room for them.** Only **two** devices can share a Drive
account, and the count is one `tandav-*.json` per device in `Tandav Sync` — so a
Chrome tab you tested with still occupies a slot and the iPhone will be refused as
a third device. On the Google account, delete every bundle that is not the Android
phone's, then on the Android phone tap **Device & Sync → Forget the other device**.
That is safe: forgetting now also clears the sent marks, so the next device to
sync is offered the whole database.

Then send the URL. **They must open it in Safari.** Tapping a link inside WhatsApp
opens WhatsApp's own in-app browser, which has **no Add to Home Screen** at all —
so the one instruction that matters is *open it in Safari first*. In WhatsApp's
browser that is the Safari compass icon in the bottom right.

Their side, in order:

1. Safari → the link → **Share → Add to Home Screen** → open it from the icon.
2. Sign up: their own username and password, and they get **their own recovery
   code**, shown once. The app login is per-device and never syncs, so it does not
   have to match the Android phone's.
3. Settings → **Device & Sync** → sign in with **the same Google account** as the
   Android phone. A different Google account is a different Drive and sync can
   never work.
4. On the **Android** phone: Device & Sync → **Send everything again**. This is
   what fills the iPhone with the existing batches and students — the Drive files
   are changes in transit, not a copy of the studio, so without this the iPhone
   only ever receives what changes from now on.
5. Sync on the iPhone.

Two things to tell them up front so they do not read either as a fault: the app
asks for **one "Resume syncing" tap per launch**, and **photos and Backup/Restore
are not there** on iPhone. Both are explained below.

## What the customer sees on iPhone

They open a link once in Safari, tap Share → **Add to Home Screen**, and from
then on Tandav is an icon like any other app: no address bar, its own splash,
works with no signal.

Two honest limitations, both browser limitations rather than anything that can be
bought away:

**One "Resume syncing" tap per launch.** Safari keeps the Google permission in
memory only, so opening the app needs one tap to resume syncing. Everything else
— students, attendance, fees — works with no tap at all, because the data is
local. See OAUTH-SETUP.md §6b.

**Photos and Backup/Restore are Android-only.** Both are path-based and a browser
has no file paths, so rather than half-work they are hidden in this build and the
photo picker says so. The Android phone remains the one that holds real backup
files.

---

## Where the iPhone's data lives, and what to do if it is lost

The whole database sits in the browser's IndexedDB for this origin. On startup
the app calls `navigator.storage.persist()` to ask the browser to exempt it from
automatic clean-up, and adding the app to the home screen is itself part of what
earns that. Browsers decide by their own rules and a refusal is normal, so the
answer is not shown to the customer and nothing branches on it.

If the storage is ever cleared anyway, nothing needs inventing — the recovery
path is the one that already exists for a wiped phone:

1. Open Tandav on the iPhone, set up the account again, connect the same Google
   account.
2. On the **Android** phone: Device & Sync → **Send everything again**.
3. Sync on the iPhone. Everything comes back.

That works because the two devices are peers, not client and server. It is also
why the Android phone should keep taking regular backups: the files in Drive are
changes in transit, not a backup of the studio.
