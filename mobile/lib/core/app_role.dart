/// Which build of Tandav this binary is — decided at **compile time**, never at
/// runtime.
///
/// The studio has a third person, the *attender*, whose whole job is marking
/// attendance and recording which fees are due and paid. He gets his own APK.
/// The owners get the full app. Same package name, same signing key, same
/// Google OAuth client — only this constant differs, and it is baked in by
/// `--dart-define=TANDAV_ROLE=attendance` at build time.
///
/// ## Why compile-time and not a setting
///
/// A runtime switch is a switch the attender can find. It would have to be
/// protected by something, that something would have to be recoverable, and the
/// recovery would have to be explained to a studio owner over the phone. A
/// second APK has none of that: the screens the attender must not reach are not
/// in his binary at all, so there is no lock to pick and nothing to
/// misconfigure. It also means `flutter build` is the only place the decision
/// can be made, which is auditable — `tools/ship.ps1` names the role on the
/// command line where anyone can read it.
///
/// ## What this is NOT
///
/// This is **not a security boundary against the phone's owner.** Anyone holding
/// the device could sideload the full APK over the top (same signature, so the
/// database survives) and see everything. The boundary that actually matters is
/// [syncTables]: rows the attender build never merges are rows that never exist
/// on that phone, so they cannot be read off it, backed up from it, or leaked by
/// it. Restricting the menus is ergonomics — keeping the data off the device is
/// the substance.
library;

import '../sync/sync_codec.dart';

/// The roles a Tandav build can have.
enum AppRole {
  /// The studio owner's build: every screen, every table.
  full,

  /// The attender's build: attendance and fees only.
  attendance,
}

/// Raw value of `--dart-define=TANDAV_ROLE=…`, defaulting to the owner build so
/// a plain `flutter build apk` keeps doing what it always did.
///
/// Must be `const`: `String.fromEnvironment` is only folded from `--dart-define`
/// in a const context. Assigned to a non-const variable it silently reads the
/// *process* environment instead and yields the default in every release build,
/// which would ship an unrestricted app to the attender and look like it worked.
const String _rawRole = String.fromEnvironment(
  'TANDAV_ROLE',
  defaultValue: 'full',
);

/// True when `TANDAV_ROLE` held something we do not recognise.
///
/// Deliberately surfaced instead of being swallowed. A typo
/// (`TANDAV_ROLE=attender`, say — the person is an attender, the role is
/// `attendance`) would otherwise fall back to [AppRole.full] and hand the
/// attender the whole studio, with a successful build and no warning anywhere.
/// The one direction this must never fail in is "quietly more access than
/// intended", so an unrecognised value is a hard error the build cannot hide:
/// `main()` refuses to start and shows [invalidRoleMessage].
const bool hasInvalidRole =
    _rawRole != 'full' && _rawRole != 'attendance' && _rawRole != '';

/// True in the attender's build.
///
/// Compares the raw string rather than [appRole]: Dart only permits `==` in a
/// const expression when both sides are null, bool, num or String, so
/// `appRole == AppRole.attendance` is not a compile-time constant and cannot
/// gate a `const` widget list.
const bool isAttenderBuild = _rawRole == 'attendance';

/// The role this binary was built with.
const AppRole appRole = isAttenderBuild ? AppRole.attendance : AppRole.full;

/// Shown full-screen instead of the app when [hasInvalidRole] is true.
const String invalidRoleMessage =
    'This copy of Tandav was built with an unknown role '
    '("$_rawRole").\n\nRebuild it with TANDAV_ROLE set to "full" or '
    '"attendance". Do not hand this build to anyone — it was not built the way '
    'it was meant to be.';

/// Short label shown next to the TANDAV wordmark so the two builds are
/// distinguishable on sight.
///
/// The owner build shows nothing, because a badge on the normal app is noise.
/// The attender build shows one, because "which APK is on this phone?" is
/// otherwise unanswerable without opening a settings screen — and it will be
/// asked over the phone, by someone holding the device, during support.
String? get roleBadge => isAttenderBuild ? 'ATTENDER' : null;

/// Plain-language name for this build, for screens and support calls.
String get roleLabel =>
    isAttenderBuild ? 'Attendance only' : 'Full studio app';

/// A marker compiled into the binary so a **built APK can be identified without
/// installing it**. `tools/verify-apk.ps1` unzips the APK and looks for exactly
/// this string.
///
/// ## Why a string in the binary rather than the file name
///
/// Two APKs now leave this machine, they are the same package signed with the
/// same key, and the only difference between them is one `--dart-define`. A file
/// name is a promise made by whoever typed it; renaming a file, re-downloading
/// it from WhatsApp, or a `-SkipBuild` run against a stale build directory all
/// break that promise silently. Handing the attender's phone the owner's build
/// is not a cosmetic mistake — it hands over the studio's finances — so the role
/// has to be checkable from the artefact itself, by a machine, the same way the
/// signature already is.
///
/// `_rawRole` is const, so this whole string is folded at compile time and lands
/// in the release snapshot's string table where `Select-String` can find it. It
/// carries the **raw** value, brackets and all: an empty or typo'd role shows up
/// as `[]` or `[attender]` rather than being normalised into something that
/// looks deliberate.
const String roleStamp = 'TANDAV-BUILD-ROLE=[$_rawRole]';

/// The tables this build is allowed to hold, in [SyncCodec.applyOrder] order.
///
/// This is the real restriction. [SyncEngine.applyIncoming] iterates exactly
/// this list, so a bundle arriving from an owner device with events in it has
/// those rows **skipped, not stored** — the attender's database never contains
/// them. [SyncEngine.computeOutbound] iterates it too, so the attender's phone
/// cannot send them either.
///
/// ## Why it is filtered on the receiving side
///
/// The mailbox holds **one file per device**, read by every peer, so a sender
/// cannot tailor what it writes to who will read it — the owners' two devices
/// need the events rows that the attender's must not keep. Filtering where the
/// rows land is the only place the decision can be made correctly, and it is
/// also the safer place: it holds even if a future build, a test bundle, or a
/// hand-edited file offers tables this device should not have.
///
/// ## The set is foreign-key closed
///
/// Every FK in [SyncEngine.fkMap] for these tables points at another table in
/// this list (`students`→`batches`, `attendance`→`students`+`batches`,
/// `monthly_attendance`→`students`, `fees`→`students`,
/// `fee_payments`→`fees`+`students`). Nothing here can be orphaned by the
/// exclusion, which is what makes dropping the other three safe rather than a
/// source of permanently unresolvable parents.
///
/// **Skipping is not deleting.** Absent tables in a bundle already mean "no news
/// about these", never "delete these" — the format has no way to express a table
/// deletion and tombstones are per row. So an owner device does not lose its
/// events because the attender's bundle omits them.
const List<String> _attendanceTables = [
  'batches',
  'students',
  'attendance',
  'monthly_attendance',
  'fees',
  'fee_payments',
];

/// Tables this build syncs and stores. See [_attendanceTables].
List<String> get syncTables =>
    isAttenderBuild ? _attendanceTables : SyncCodec.applyOrder;

/// Tables a build of [role] syncs. Exposed so tests can exercise the attender
/// scope without being compiled with `--dart-define`.
List<String> syncTablesFor(AppRole role) =>
    role == AppRole.attendance ? _attendanceTables : SyncCodec.applyOrder;

/// Tables the attender build must never hold, for assertions and diagnostics.
List<String> get excludedTables => SyncCodec.applyOrder
    .where((t) => !syncTables.contains(t))
    .toList(growable: false);
