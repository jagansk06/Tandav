# The attender's APK

The studio has a third person — the **attender** — whose whole job is marking
attendance and recording which fees are due and paid. He gets his own APK: same
app, two tabs, and a database that never receives the rest of the studio's
records.

Two files now come out of this repo:

| File (in `dist\`) | For | Built with |
|---|---|---|
| `Tandav-Owner-<version>.apk` | the two studio owners | `TANDAV_ROLE=full` (the default) |
| `Tandav-Attendance-<version>.apk` | the attender | `TANDAV_ROLE=attendance` |

Same package name, same version, same signing key. **One `--dart-define` is the
entire difference.** Everything below exists because of that.

## Build and send

```powershell
cd D:\Projects\Tandav
.\ship.ps1 -Both
```

That builds both, verifies both, and leaves them in `dist\` with names you can
read, next to a `.txt` recording what was built and when. No phone is touched.

```powershell
.\ship.ps1 -Role attender -BuildOnly    # just his file
.\ship.ps1 -BuildOnly                   # just the owners' file
.\ship.ps1 -Role attender               # …and install it on the cabled phone + log
```

Before any of it, on Windows:

```powershell
cd mobile
flutter analyze
flutter test
```

To re-check a file that has already been copied around — no cable needed, and it
works on a copy pulled back off WhatsApp:

```powershell
.\tools\verify-apk.ps1 -Apk dist\Tandav-Attendance-1.0.0-b2.apk -Role attender
```

## What he can see

Two tabs, **Attendance** and **Fees**, and that is the whole app. No Dashboard,
no Students list, no Batches, no Events, no Monthly Reports, no Backup or
Restore. The Fees tab keeps the per-student register — who owes what, one tap to
mark paid — and drops the month's Expected / Collected / Pending totals, because
those three numbers are the studio's takings rather than anything he does.

He still gets Account (his own password and recovery code) and Device & Sync
(so he can connect the Drive account and see whether it synced).

**The menus are ergonomics, not the boundary.** Anyone holding the phone could
sideload the owner APK over the top — same signature, so the data survives — and
see every screen. The boundary that matters is the next section.

## What reaches his phone

| Synced to his phone | Never sent, never stored |
|---|---|
| `batches`, `students` | `events` |
| `attendance`, `monthly_attendance` | `event_participations` |
| `fees`, `fee_payments` | `monthly_progress` |

Those three tables are **filtered on the way in**, so they are not hidden on his
phone — they are absent from it. Nothing can read them off the device, back them
up from it, or leak them with it. It works in both directions: a row that
somehow arrived anyway (a restored file, a hand-edited database) is still never
forwarded.

The six he does get are foreign-key closed: nothing in them points at anything in
the excluded three, so dropping those cannot orphan a record. And an absent table
in a sync bundle already means "no news about these", never "delete these" — so
the owners do not lose their events because his phone never mentions them.

He signs in to the **same Google account** as the owners; that shared Drive
folder is the only way changes travel. His **app login is his own** — passwords
and recovery codes never sync between devices, so his password is not the
owners' password and neither can see the other's.

## Three devices, no more

Two owner phones plus the attender is exactly three, which is the cap. If a
fourth ever writes to the account, Tandav refuses to guess which one to drop: it
names the files in the `Tandav Sync` folder and asks for one to be deleted.

A device joining an account that already has history gets **all of it** on its
first sync, without anyone pressing anything — the shared file has to satisfy
whichever device is furthest behind, so the newcomer is what it is built for.

## The two ways to get this wrong

**Sending the wrong file to the wrong phone.** The owner APK on the attender's
phone hands him every screen and syncs the whole studio onto his device — a
privacy problem, not a crash, so nothing would announce it. That is why
`verify-apk.ps1` reads the role out of the compiled binary instead of trusting
the file name, and why `ship.ps1` refuses to copy anything into `dist\` that
fails the check. Names get changed and files get re-downloaded; a string compiled
into the APK does not.

Installed the wrong way round — his APK onto an owner's phone — the app itself
says so on launch and tells them to install the owner APK over the top again.
Nothing is deleted in that state; the records are all still in SQLite with no
screen currently reading them.

**Uninstalling.** Never uninstall to "fix" an install. Uninstalling erases that
phone's database *and its backups*, and on Tandav that database is the studio's
only copy. Installing over the top always works as long as the signature matches,
which is the other half of what `verify-apk.ps1` checks.

## Known gaps

Attendance he marks recomputes `monthly_attendance` on his phone and that travels
to the owners. It does **not** refresh their `monthly_progress.attendance_percentage`
— that mirror is only written by the device that recorded the marks, which was
already true between the two owner phones and is not specific to his build.
