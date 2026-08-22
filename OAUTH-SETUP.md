# Google Drive sync — one-time OAuth setup

Do this once, as the developer. **Nothing here expires and nothing needs renewing** —
that is the whole point, and step 4 is what guarantees it.

## Values you will need

| Field | Value |
|---|---|
| Android package name | `com.tandav.tandav_mobile` |
| Release keystore SHA-1 | `50:9F:E4:A2:A5:2C:80:81:A2:F3:F9:BB:F4:98:35:0B:CB:98:1A:70` |
| Scope, and only this scope | `https://www.googleapis.com/auth/drive.file` |

The SHA-1 comes from `D:\Projects\tandav-signing\tandav-release.jks`. If you ever
rebuild with a different key, sign-in stops working and this has to be redone.

---

## 1. Create the project

<https://console.cloud.google.com> → project picker → **New Project** → name it
`Tandav` → Create. Make sure it is selected before continuing.

## 2. Enable the Drive API

**APIs & Services → Library** → search *Google Drive API* → **Enable**.

Without this every call fails with `accessNotConfigured`, which reads like an auth
problem and wastes an hour.

> **Menu names changed.** Google replaced "APIs & Services → OAuth consent
> screen" with **Google Auth Platform**, and split it across the left nav:
>
> | What you want | Old menu | Where it is now |
> |---|---|---|
> | App name, emails | OAuth consent screen | **Branding** |
> | Scopes | OAuth consent screen → Scopes | **Data access** |
> | Publish / test users | OAuth consent screen → Publishing status | **Audience** |
> | OAuth client IDs | Credentials | **Clients** |

## 3. Configure branding

**Google Auth Platform → Branding**

- User type: **External**
- App name `Tandav`, your support email, your developer contact email

Leave **Application home page**, **privacy policy**, **Terms of Service** and
**Authorised domains** empty. They are only needed to pass verification, which
this app does not need (see step 4).

## 3b. Add the scope

**Google Auth Platform → Data access → Add or remove scopes**

Tick only `.../auth/drive.file` — *"See, edit, create and delete only the
specific Google Drive files you use with this app"* → **Update** → **Save**.

If it is not in the list, the picker is only showing scopes for **enabled APIs**
(do step 2 first). Otherwise use **Manually add scopes** in the same panel and
paste `https://www.googleapis.com/auth/drive.file`, then **Add to table**.

Do **not** add `.../auth/drive`. The broad scope is classed *restricted* and drags
in a recurring third-party security assessment. `drive.file` avoids it entirely,
and is also the honest choice: the app genuinely cannot see the customer's photos
or documents.

## 4. PUBLISH the app — do not skip this

**Google Auth Platform → Audience → PUBLISH APP** → confirm.
It should read **In production**.

While it says *Testing*, every refresh token **expires after 7 days**. Sync would
work for a week at each customer and then silently stop, forever, needing a
re-login you cannot perform remotely. That directly breaks "buy once, works
forever".

You will see a warning about verification. Ignore it, and ignore the
**Verification centre** in the left nav: verification is only required to remove
the "Google hasn't verified this app" screen. With `drive.file` and an unverified
app the customer sees an **Advanced → Go to Tandav (unsafe)** link once, at first
sign-in, and it works fine after that. Nothing expires.

## 5. Create the Android OAuth client

**Google Auth Platform → Clients → Create client**

- Type: **Android**
- Name: `Tandav Android`
- Package name: `com.tandav.tandav_mobile`
- SHA-1: the fingerprint from the table above

**Nothing to paste into the app.** `google_sign_in` on Android identifies itself
by package name + signing certificate, so `DriveMailbox()` in
`lib/core/services.dart` needs no client id. That is also why only the
**release-signed** APK can sign in — a debug build has a different fingerprint.

## 6. Create the Web OAuth client (for the iPhone PWA, and for the test in step 7)

Same menu → **Clients → Create client**

- Type: **Web application**
- Name: `Tandav Web`
- **Authorized JavaScript origins**: add `http://localhost:8080` now (needed for
  step 7). Add the real PWA hosting URL later, when it exists.

Copy the **Client ID** (`…apps.googleusercontent.com`). For the PWA it goes in
`mobile/web/index.html` as:

```html
<meta name="google-signin-client_id" content="YOUR_WEB_CLIENT_ID.apps.googleusercontent.com">
```

---

## 7. Settle the visibility question BEFORE building the PWA

`drive.file` only lets an app see files **it created**. Whether "app" means the
Cloud *project* or the individual *client ID* decides whether an Android-created
file is readable by the web client. Google's docs do not state it unambiguously,
and the whole iPhone story depends on the answer, so measure it rather than
assume it.

**Cost if we get this wrong and find out late: the PWA is built and cannot sync.**
Cost of the test: about twenty minutes.

1. Install `app-arm64-v8a-release.apk` on the Android phone. Sign in, sync once.
   Confirm a **Tandav Sync** folder with `tandav-XXXX.json` appears in that
   account's Drive.
2. Serve the test page from the repo root:

   ```
   cd D:\Projects\Tandav\tools
   python -m http.server 8080
   ```

3. Open <http://localhost:8080/drive-visibility-test.html>, paste the **Web**
   client ID, sign in with **the same Google account**, and press
   **List what this client can see**.

### Reading the result

- **The Android file is listed** → authorization is per *project*. Two clients are
  fine. Proceed with the PWA as planned.
- **The list is empty** (or shows only files the web page itself created) →
  authorization is per *client ID*. Android and the PWA cannot see each other's
  files, and the plan changes: both platforms must share **one Web client**, which
  means replacing native `google_sign_in` on Android with a browser PKCE flow and
  storing the refresh token ourselves.

Also press **Create a file from this client**, then sync on Android and check
whether the phone sees that file. The two directions are not guaranteed to behave
the same, and the reverse direction is the one the PWA actually depends on.
