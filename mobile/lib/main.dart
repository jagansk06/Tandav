import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/auth_state.dart';
import 'core/services.dart';
import 'core/theme.dart';
import 'database/tandav_database.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Open the local database (creates the schema on first run, seeds the default
  // admin account, applies migrations) and generate any missing monthly fee
  // records before the first frame. Fully offline: on Android this is a SQLite
  // file, in the browser the same SQLite engine stored in IndexedDB.
  try {
    await TandavDatabase.instance.open();
  } on Object catch (error) {
    runApp(_StartupFailureApp(error: error));
    return;
  }

  final api = TandavApi();
  await api.ensureMonthlyFees();

  // Silently reconnect to Google Drive if this device was connected before, so
  // the Sync screen shows "Connected" without asking again. Never blocks
  // startup and never matters offline.
  api.sync.restore().ignore();

  runApp(TandavApp(api: api));
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

/// Shown instead of a blank screen when the local database cannot be opened.
/// In practice this only happens in the browser, when `sqlite3.wasm` and
/// `sqflite_sw.js` are missing from the deployed `web/` folder — or, more
/// subtly, when both are present but were produced for different versions of
/// the `sqlite3` package. The worker reports that second case as the unhelpful
/// `Unsupported operation: unsupported result null (null)`, because it loads
/// the wasm outside the try/catch that would have turned the real error into a
/// message. `tool/check_web_binaries.dart` diagnoses it directly.
class _StartupFailureApp extends StatelessWidget {
  final Object error;
  const _StartupFailureApp({required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: TandavTheme.dark,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.storage_rounded,
                    size: 44, color: TandavColors.danger),
                const SizedBox(height: 16),
                const Text(
                  'Tandav could not open its local database',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: TandavColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Your data has not been touched. In the browser this means '
                  'the SQLite engine could not start: sqlite3.wasm and '
                  'sqflite_sw.js are either missing from the deployment or '
                  'were built for different versions of the sqlite3 package. '
                  'Run tool/check_web_binaries.dart — see SYNC.md, '
                  '"Web SQLite binaries".',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: TandavColors.textMuted,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  error.toString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: TandavColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
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
    return auth.isLoggedIn
        ? HomeShell(key: ValueKey('shell-${auth.reloadToken}'))
        : const LoginScreen();
  }
}
