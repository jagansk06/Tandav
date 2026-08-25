import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/app_role.dart';
import 'core/auth_state.dart';
import 'core/services.dart';
import 'core/theme.dart';
import 'database/tandav_database.dart';
import 'platform/app_files.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'screens/signup_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Refuse to run a build whose role we cannot read, before the database is
  // even opened. `TANDAV_ROLE` decides which tables this install is allowed to
  // hold, and an unrecognised value falls back to the full app — so a one-letter
  // typo in the build command would hand the attender the entire studio, with a
  // successful build, a normal-looking app and nothing anywhere to say so. The
  // one direction this must never fail in is "quietly more access than
  // intended", so it fails loudly in the other direction instead. See
  // [hasInvalidRole].
  if (hasInvalidRole) {
    runApp(const _RoleErrorApp());
    return;
  }

  // Ask the browser to keep this app's storage. A no-op on Android; on the
  // iPhone build the studio's whole database lives in IndexedDB, which a
  // browser may otherwise clear when the phone runs low on space. Done before
  // the database is opened, and it can neither throw nor hang.
  await appFiles.keepDatabaseResident();

  // Open the local SQLite database (creates schema on first run, seeds the
  // default admin account) and generate any missing monthly fee records
  // before the first frame — fully offline.
  await TandavDatabase.instance.open();

  // Catch the one mistake two same-package APKs make possible: the attender's
  // build installed over the owner's app. See [_crossInstallProblem].
  final crossInstall = await _crossInstallProblem();
  if (crossInstall != null) {
    runApp(_CrossInstallApp(table: crossInstall));
    return;
  }

  final api = TandavApi();
  await api.ensureMonthlyFees();

  runApp(TandavApp(api: api));
}

/// Name of an owner-only table that has rows on a phone running the attender
/// build, or null when there is nothing wrong.
///
/// Both APKs share one package name and one signing key — deliberately, because
/// a second package would need its own Android OAuth client before Drive sign-in
/// worked. The cost is that either file installs over the other, so the owner
/// tapping the wrong attachment turns their own phone into an attendance-only
/// app. Nothing is deleted by that: the rows are all still in SQLite, the
/// attender build simply has no screen that reads them and no code that syncs
/// them onward.
///
/// Silence is the danger. The owner would see two tabs, assume the update broke
/// the app, and — reasonably — try uninstalling to fix it, which is the one
/// action that destroys the studio's only copy of its data. So this says what
/// happened and names the harmless fix before anyone reaches for the harmful
/// one.
///
/// No false positives are possible: the attender build never receives these
/// tables ([excludedTables] is filtered on the way in) and has no screen that
/// creates them, so on a phone that was always the attender's they are empty
/// forever. Tombstoned rows count too — a soft-deleted event is still an owner's
/// record sitting on the device.
Future<String?> _crossInstallProblem() async {
  if (!isAttenderBuild) return null;
  final db = await TandavDatabase.instance.open();
  for (final table in excludedTables) {
    final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM $table');
    final n = rows.isEmpty ? null : rows.first['n'];
    if (n is int && n > 0) return table;
  }
  return null;
}

/// Shown instead of the app when the attender build finds the owner's records on
/// the phone. Kept as plain as [_RoleErrorApp]: no providers, no theme, nothing
/// that could itself fail.
class _CrossInstallApp extends StatelessWidget {
  const _CrossInstallApp({required this.table});

  final String table;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tandav Studio',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF151515),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Wrong app for this phone',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFFD4AF37),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'This phone holds the studio owner\'s records, but the app '
                      'now installed on it is the attendance-only one. The '
                      'owner\'s APK was replaced by the attender\'s APK.\n\n'
                      'Nothing has been deleted. Every record is still here.\n\n'
                      'To put it right, install the owner\'s APK over the top '
                      'again. Do NOT uninstall the app first — uninstalling is '
                      'the one thing that would erase this phone\'s data.\n\n'
                      'If this phone is being given to the attender for good: '
                      'sync the owner\'s other phone first, then uninstall '
                      'Tandav here and install the attendance APK fresh.',
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.55,
                        color: Color(0xFFE9E9E9),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Found owner records in: $table',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF8A8A8A),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown instead of the app when the build was made with an unknown
/// `TANDAV_ROLE`. Deliberately plain: no theme, no database, no providers,
/// because none of those have been set up yet and this must render even if
/// everything else is broken.
class _RoleErrorApp extends StatelessWidget {
  const _RoleErrorApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tandav Studio',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF151515),
        body: Padding(
          padding: const EdgeInsets.all(28),
          child: Center(
            child: Text(
              invalidRoleMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                height: 1.5,
                color: Color(0xFFE9E9E9),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TandavApp extends StatelessWidget {
  final TandavApi api;
  const TandavApp({super.key, required this.api});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider.value(value: api),
        ChangeNotifierProvider(create: (_) => AuthState(api: api)..init()),
      ],
      child: MaterialApp(
        title: 'Tandav Studio',
        debugShowCheckedModeBanner: false,
        theme: TandavTheme.dark,
        home: const RootGate(),
      ),
    );
  }
}

class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    if (!auth.initialized) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/tandav_logo.jpeg',
                width: 120,
                height: 120,
              ),
              const SizedBox(height: 20),
              const SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ],
          ),
        ),
      );
    }
    // Setup comes before the login screen: while the device is still on the
    // credentials baked into every APK there is nothing worth logging in to.
    if (auth.needsSetup) return const SignupScreen();
    return auth.isLoggedIn
        ? HomeShell(key: ValueKey('shell-${auth.reloadToken}'))
        : const LoginScreen();
  }
}
