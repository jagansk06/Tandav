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

  // Open the local SQLite database (creates schema on first run, seeds the
  // default admin account) and generate any missing monthly fee records
  // before the first frame — fully offline.
  await TandavDatabase.instance.open();
  final api = TandavApi();
  await api.ensureMonthlyFees();

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
