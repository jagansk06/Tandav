'use strict';

/*
  Tandav's own service worker — the thing that makes the iPhone version work
  with no internet.

  ## Why this file exists at all

  Flutter used to generate a caching service worker for you. As of this version
  it does not: `flutter build web --pwa-strategy=offline-first` now writes a
  `flutter_service_worker.js` whose entire body unregisters itself, and
  `flutter_bootstrap.js` carries the note "Flutter's service worker is
  deprecated and will be removed in a future Flutter release". Verified by
  reading the built output and the tool source
  (`flutter_tools/lib/src/web/file_generators/flutter_service_worker_js.dart`),
  not inferred from documentation.

  So out of the box the PWA needs the network every single launch. For a studio
  taking attendance in a basement with no signal, that is the app being broken.
  The data would still be safe in IndexedDB — but the app could not open to show
  it, which amounts to the same thing for the customer.

  ## How it is wired up

  The app is built with `--pwa-strategy=none`, which stops Flutter both from
  generating its self-unregistering worker AND from registering one — see the
  `includeServiceWorkerSettings` check in the tool. `web/index.html` then
  registers *this* file instead. Nothing fights over the scope.

  ## Strategy: eager shell, lazy everything else, cache first

  On install, the small stable files the app cannot start without are fetched up
  front. Everything else — CanvasKit above all, which is the single biggest
  download — is cached the first time it is actually used. So the first launch
  must be online (it has to be anyway, to sign into Google), and every launch
  after that works with no network at all.

  Cache-first, not network-first: a phone with one bar of signal is worse than a
  phone with none, because a request that will eventually time out blocks the
  app for as long as it takes. Reading from the cache is instant and cannot
  fail. The cost is that a newly deployed version appears on the second launch
  rather than the first, which for an app sold once and used daily is the right
  trade.

  ## Two things that must never be interfered with

  Google sign-in and the Drive API are on other origins, so the check in
  `fetch` below returns without touching them. Caching an OAuth response or a
  Drive read would be somewhere between useless and dangerous, and an
  intercepted sign-in pop-up would break sync outright.

  CanvasKit is only same-origin — and therefore only cacheable — if the app is
  built with `--no-web-resources-cdn`. Without that flag it is fetched from
  gstatic.com, this worker leaves it alone as third-party, and the app still
  cannot start offline. That flag is not optional; see PWA.md.
*/

// Replaced with the build's content hash by tools/deploy-pwa.ps1. Left as the
// literal placeholder in a hand-run build, which is harmless — it just means
// the cache is not invalidated automatically.
const VERSION = '__TANDAV_SW_VERSION__';
const CACHE = 'tandav-' + VERSION;

// The page served for any navigation, so launching offline works from the
// home-screen icon.
const SHELL = 'index.html';

/*
  Fetched on install. Deliberately small and boring: files whose names never
  change and which the app cannot boot without.

  CanvasKit is NOT here on purpose. It is about 7 MB, and which of the several
  variants gets used depends on the browser — Safari and Chrome pick different
  ones. Guessing wrong would mean downloading 7 MB that is never read, so it is
  left to be cached on first real use, where the browser has already chosen.
*/
const CORE = [
  './',
  SHELL,
  'flutter_bootstrap.js',
  'flutter.js',
  'main.dart.js',
  'manifest.json',
  'version.json',
  'favicon.png',
  'icons/Icon-192.png',
  'icons/Icon-512.png',
  'icons/Icon-maskable-192.png',
  'icons/Icon-maskable-512.png',
  // The SQLite engine. Without this the app opens and then has no database at
  // all, which is the worst possible way for it to fail. There is deliberately
  // no `sqflite_sw.js` here — see lib/platform/app_files_web.dart for why the
  // worker-free factory is used, and PWA.md for what went wrong when it wasn't.
  'sqlite3.wasm',
  'assets/AssetManifest.bin',
  'assets/AssetManifest.bin.json',
  'assets/FontManifest.json',
  'assets/fonts/MaterialIcons-Regular.otf',
  'assets/packages/cupertino_icons/assets/CupertinoIcons.ttf',
  'assets/assets/images/tandav_logo.jpeg',
  // 16 KB between them, and Flutter fetches them the first time something
  // overscrolls or an ink ripple is drawn — which offline would be a failed
  // request in the middle of an ordinary tap.
  'assets/shaders/ink_sparkle.frag',
  'assets/shaders/stretch_effect.frag',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE);
      // Fetched and stored one at a time, rather than with `cache.addAll`, which
      // rejects the whole batch if any single request fails. One missing icon
      // must not be able to leave the customer with no offline app.
      //
      // Written out as fetch + put rather than `cache.add` so it depends only on
      // APIs Safari has had for years — this whole file exists for Safari.
      // `cache: 'reload'` bypasses the HTTP cache, so an install triggered by a
      // new deploy cannot store a stale copy of a file it just replaced.
      await Promise.all(
        CORE.map(async (path) => {
          try {
            const response = await fetch(new Request(path, { cache: 'reload' }));
            if (!response.ok) throw new Error('HTTP ' + response.status);
            await cache.put(path, response);
          } catch (e) {
            console.warn('Tandav SW: could not pre-cache', path, e);
          }
        })
      );
      await self.skipWaiting();
    })()
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      // Drop the previous build's cache. Names are versioned, so this is what
      // stops old JavaScript being served after an update.
      const names = await caches.keys();
      await Promise.all(
        names
          .filter((n) => n.startsWith('tandav-') && n !== CACHE)
          .map((n) => caches.delete(n))
      );
      await self.clients.claim();
    })()
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  let url;
  try {
    url = new URL(request.url);
  } catch (e) {
    return;
  }

  // Google sign-in, the Drive API, and anything else off this origin: pass
  // straight through, uncached and untouched.
  if (url.origin !== self.location.origin) return;

  if (request.mode === 'navigate') {
    event.respondWith(serveShell(request));
    return;
  }
  event.respondWith(cacheFirst(request));
});

async function cacheFirst(request) {
  const cache = await caches.open(CACHE);
  // `ignoreSearch` because the loader appends cache-busting query strings to
  // some requests, and a cached copy should still count as a hit.
  const hit = await cache.match(request, { ignoreSearch: true });
  if (hit) return hit;
  try {
    const response = await fetch(request);
    // Only same-origin, genuinely successful responses. `type === 'basic'`
    // keeps opaque cross-origin responses and redirects out of the cache.
    if (response && response.ok && response.type === 'basic') {
      cache.put(request, response.clone());
    }
    return response;
  } catch (e) {
    // Offline, and never seen before. Nothing useful to give back.
    return new Response('', {
      status: 504,
      statusText: 'Offline, and this file was never downloaded',
    });
  }
}

async function serveShell(request) {
  const cache = await caches.open(CACHE);
  const hit = await cache.match(SHELL, { ignoreSearch: true });
  if (hit) return hit;
  try {
    const response = await fetch(request);
    if (response && response.ok && response.type === 'basic') {
      cache.put(SHELL, response.clone());
    }
    return response;
  } catch (e) {
    return new Response(
      '<!DOCTYPE html><html><body style="background:#0B0B0E;color:#F7F3E8;' +
        'font-family:-apple-system,sans-serif;padding:2rem">' +
        '<h2>Tandav needs the internet once</h2>' +
        '<p>Open Tandav while online just once, and after that it will work ' +
        'with no internet at all.</p></body></html>',
      { status: 200, headers: { 'Content-Type': 'text/html' } }
    );
  }
}
