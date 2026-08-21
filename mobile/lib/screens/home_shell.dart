import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/auth_state.dart';
import '../core/format.dart';
import '../core/services.dart';
import '../core/theme.dart';
import 'attendance/attendance_screen.dart';
import 'batches/batches_screen.dart';
import 'dashboard/dashboard_screen.dart';
import 'events/events_screen.dart';
import 'fees/fees_screen.dart';
import 'reports/reports_screen.dart';
import 'settings/device_sync_screen.dart';
import 'students/students_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  int _dashboardKey = 0;

  static const _titles = [
    'Dashboard',
    'Students',
    'Batches',
    'Attendance',
    'Fees',
    'Events',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // A new month may have started while the app was backgrounded —
      // generate any missing monthly fee records locally.
      context.read<TandavApi>().ensureMonthlyFees().catchError((_) => 0);
    }
  }

  Future<void> _backup() async {
    if (!mounted) return;
    final api = context.read<TandavApi>();
    try {
      final file = await api.createBackup();
      if (!mounted) return;
      Alert.show(context, 'Backup saved: ${file.uri.pathSegments.last}');
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    }
  }

  Future<void> _restore() async {
    if (!mounted) return;
    final api = context.read<TandavApi>();
    final List<File> backups;
    try {
      backups = await api.listBackups();
    } on Exception {
      if (mounted) Alert.show(context, 'Could not list backups', isError: true);
      return;
    }
    if (!mounted) return;
    if (backups.isEmpty) {
      Alert.show(context, 'No backups found yet', isError: true);
      return;
    }
    final selected = await showModalBottomSheet<File>(
      context: context,
      backgroundColor: TandavColors.surface,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text(
                'Restore from backup',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: TandavColors.textPrimary,
                ),
              ),
            ),
            ...backups.map((f) => ListTile(
                  leading: const Icon(Icons.restore_rounded,
                      color: TandavColors.gold),
                  title: Text(
                    f.uri.pathSegments.last,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    '${(f.lengthSync() / 1024).toStringAsFixed(1)} KB',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  onTap: () => Navigator.pop(ctx, f),
                )),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TandavColors.surface,
        title: const Text('Restore data?'),
        content: Text(
            'This replaces all current data with the backup\n'
            '${selected.uri.pathSegments.last}. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore',
                style: TextStyle(color: TandavColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final ok = await api.restoreFromBackup(selected);
      if (!ok) throw const FormatException('Restore failed');
      if (!mounted) return;
      Alert.show(context, 'Data restored');
      context.read<AuthState>().notifyDatabaseRestored();
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    }
  }

  double get _navLabelSize {
    final width = MediaQuery.sizeOf(context).width;
    if (width < 350) return 10;
    if (width < 400) return 10.5;
    return 11;
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TandavColors.surface,
        title: const Text('Sign out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Sign out',
              style: TextStyle(color: TandavColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final auth = context.read<AuthState>();
      await auth.logout();
    }
  }

  Future<void> _menu() async {
    if (!mounted) return;
    final auth = context.read<AuthState>();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: TandavColors.surface,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: TandavColors.surfaceLight,
                    child: const Icon(Icons.person_rounded,
                        color: TandavColors.gold),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          auth.user?.fullName ?? 'Admin',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: TandavColors.textPrimary,
                          ),
                        ),
                        Text(
                          '@${auth.user?.username ?? ''}',
                          style: const TextStyle(
                              color: TandavColors.textMuted, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Divider(height: 28),
              ListTile(
                leading: const Icon(Icons.bar_chart_rounded,
                    color: TandavColors.gold),
                title: const Text('Monthly Reports'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const ReportsScreen()),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.backup_outlined,
                    color: TandavColors.gold),
                title: const Text('Backup data'),
                onTap: () {
                  Navigator.pop(ctx);
                  _backup();
                },
              ),
              ListTile(
                leading: const Icon(Icons.restore_outlined,
                    color: TandavColors.gold),
                title: const Text('Restore data'),
                onTap: () {
                  Navigator.pop(ctx);
                  _restore();
                },
              ),
              ListTile(
                leading: const Icon(Icons.devices_rounded,
                    color: TandavColors.gold),
                title: const Text('Device & Sync'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const DeviceSyncScreen()),
                  );
                },
              ),
              const Divider(height: 4),
              ListTile(
                leading: const Icon(Icons.logout_rounded,
                    color: TandavColors.danger),
                title: const Text('Sign out'),
                onTap: () {
                  Navigator.pop(ctx);
                  _logout();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                gradient: GoldGradient.linear,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'TANDAV',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.8,
                  color: Color(0xFF151515),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(_titles[_index]),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _menu,
            icon: const Icon(Icons.more_vert_rounded),
          ),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: [
          // Rebuilt on every visit to Home so fee collection totals and
          // today's attendance reflect the latest SQLite state immediately.
          DashboardScreen(key: ValueKey('dash-$_dashboardKey')),
          const StudentsScreen(),
          const BatchesScreen(),
          const AttendanceScreen(),
          const FeesScreen(),
          const EventsScreen(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() {
          if (i == 0 && i != _index) _dashboardKey++;
          _index = i;
        }),
        selectedFontSize: _navLabelSize,
        unselectedFontSize: _navLabelSize,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard_outlined),
            activeIcon: Icon(Icons.dashboard_rounded),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.groups_outlined),
            activeIcon: Icon(Icons.groups_rounded),
            label: 'Students',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.grid_view_outlined),
            activeIcon: Icon(Icons.grid_view_rounded),
            label: 'Batches',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.fact_check_outlined),
            activeIcon: Icon(Icons.fact_check_rounded),
            label: 'Attendance',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.account_balance_wallet_outlined),
            activeIcon: Icon(Icons.account_balance_wallet_rounded),
            label: 'Fees',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.event_outlined),
            activeIcon: Icon(Icons.event_rounded),
            label: 'Events',
          ),
        ],
      ),
    );
  }
}