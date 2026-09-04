import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_role.dart';
import '../core/auth_state.dart';
import '../core/format.dart';
import '../core/services.dart';
import '../core/theme.dart';
import '../platform/app_files.dart';
import 'attendance/attendance_screen.dart';
import 'batches/batches_screen.dart';
import 'dashboard/dashboard_screen.dart';
import 'events/events_screen.dart';
import 'fees/fees_screen.dart';
import 'fees/fee_settings_screen.dart';
import 'reports/reports_screen.dart';
import 'reports/export_screen.dart';
import 'settings/account_screen.dart';
import 'settings/device_sync_screen.dart';
import 'settings/upi_settings_screen.dart';
import 'students/students_screen.dart';

/// The signed-in app: bottom navigation plus the overflow menu.
///
/// Which tabs exist is decided by [appRole] at **compile time**. On the
/// attender's build there are two — Attendance and Fees — and the other screens
/// are not merely hidden, they are absent from the widget tree. That distinction
/// matters because [IndexedStack] builds *every* child eagerly: a
/// hidden-but-constructed `EventsScreen` would still run its queries against
/// tables the attender's database does not contain. Leaving them out of the list
/// is what stops them running.
///
/// Hiding tabs is not the security boundary — see [syncTables] for the part that
/// is. This is the ergonomic half: the attender opens the app on the screen he
/// needs and never has to be told to ignore the rest.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  int _dashboardKey = 0;

  static const _ownerTitles = [
    'Dashboard',
    'Students',
    'Batches',
    'Attendance',
    'Fees',
    'Events',
  ];

  static const _attenderTitles = ['Attendance', 'Students', 'Batches', 'Fees'];

  static const _titles = isAttenderBuild ? _attenderTitles : _ownerTitles;

  /// How often the app syncs while it is simply sitting open.
  ///
  /// This closes the one case that had no trigger at all. Sync otherwise runs on
  /// app-open and on resume, so a studio that leaves Tandav in the foreground
  /// all day would never upload what it typed and never see what the other
  /// phone typed — which is precisely the two-locations scenario the whole sync
  /// design exists for.
  ///
  /// Five minutes trades promptness against waking the radio for nothing. The
  /// manager's `autoSync` is silent and throttled, so a tick with no internet,
  /// no connected account, or a sync already in flight costs nothing.
  static const _foregroundSyncInterval = Duration(minutes: 5);
  Timer? _syncTimer;

  void _startPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(_foregroundSyncInterval, (_) {
      if (!mounted) return;
      context.read<TandavApi>().cloudSync.autoSync();
    });
  }

  void _stopPeriodicSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Pull anything the other device left in Drive while this app was closed.
    // Silent by design — no spinner, no error if there is no internet.
    context.read<TandavApi>().cloudSync.autoSync();
    _startPeriodicSync();
  }

  @override
  void dispose() {
    _stopPeriodicSync();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // A new month may have started while the app was backgrounded —
      // generate any missing monthly fee records locally.
      final api = context.read<TandavApi>();
      api.ensureMonthlyFees().catchError((_) => 0);
      // …and pick up whatever the other master changed in the meantime.
      api.cloudSync.autoSync();
      _startPeriodicSync();
    } else {
      // Nothing useful happens off-screen, and a timer that survives into the
      // background only drains the battery.
      _stopPeriodicSync();
    }
  }

  Future<void> _backup() async {
    if (!mounted) return;
    final api = context.read<TandavApi>();
    if (!appFiles.supportsBackups) {
      Alert.show(context, appFiles.unavailableMessage, isError: true);
      return;
    }
    try {
      final entry = await api.createBackup();
      if (!mounted) return;
      Alert.show(context, 'Backup saved: ${entry.name}');
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
    if (!appFiles.supportsBackups) {
      Alert.show(context, appFiles.unavailableMessage, isError: true);
      return;
    }
    final List<BackupEntry> backups;
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
    final selected = await showModalBottomSheet<BackupEntry>(
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
            ...backups.map((b) => ListTile(
                  leading: const Icon(Icons.restore_rounded,
                      color: TandavColors.gold),
                  title: Text(
                    b.name,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    b.sizeLabel,
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  onTap: () => Navigator.pop(ctx, b),
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
            '${selected.name}. This cannot be undone.'),
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
      // Awaited because the restore may have reintroduced the factory password,
      // in which case this re-raises the setup gate and drops the session.
      await context.read<AuthState>().notifyDatabaseRestored();
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
        child: SingleChildScrollView(
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
              // Reports lead with the month's collections and revenue, so they
              // are an owner's view rather than a shared one. The attender needs
              // to record what is due and paid; he does not need the total.
              if (!isAttenderBuild)
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
              // Owner-only: pulling the studio's data into Excel/Sheets is an
              // owner's job, so the attender build never offers it.
              if (!isAttenderBuild)
                ListTile(
                  leading: const Icon(Icons.ios_share_rounded,
                      color: TandavColors.gold),
                  title: const Text('Export to Spreadsheet'),
                  subtitle: const Text('Students, fees, batches, attendance',
                      style: TextStyle(fontSize: 11.5)),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const ExportScreen()),
                    );
                  },
                ),
              // Withheld from the attender build: this configures how revenue is
              // calculated (late-fee increments), which is an owner decision.
              if (!isAttenderBuild)
                ListTile(
                  leading: const Icon(Icons.tune_rounded,
                      color: TandavColors.gold),
                  title: const Text('Fee Settings'),
                  subtitle: const Text('Late-fee increment for unpaid months',
                      style: TextStyle(fontSize: 11.5)),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const FeeSettingsScreen()),
                    );
                  },
                ),
              // UPI payment settings for the WhatsApp fee reminders — available
              // to both builds, since attenders also send reminders and confirm
              // student payments.
              ListTile(
                leading: const Icon(Icons.qr_code_2_rounded,
                    color: TandavColors.gold),
                title: const Text('UPI / Payments'),
                subtitle: const Text(
                    'UPI ID for fee pay links in reminders',
                    style: TextStyle(fontSize: 11.5)),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const UpiSettingsScreen()),
                  );
                },
              ),
              // Hidden rather than disabled in the iPhone build: a greyed-out
              // "Backup data" invites the customer to believe their data is
              // being backed up somewhere. Drive sync is not a backup, so the
              // honest thing is to not offer the menu item at all.
              //
              // Withheld from the attender build for two independent reasons. A
              // backup is the whole `.db` file, so it carries the password hash
              // and the account recovery code in plaintext — a copy of it on a
              // staff phone is a copy of the studio's credentials. And Restore
              // *replaces everything*, which on this device would overwrite a
              // day of attendance with whatever that file happens to hold.
              if (appFiles.supportsBackups && !isAttenderBuild) ...[
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
              ],
              ListTile(
                leading: const Icon(Icons.shield_outlined,
                    color: TandavColors.gold),
                title: const Text('Account'),
                subtitle: const Text('Password and recovery code',
                    style: TextStyle(fontSize: 11.5)),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AccountScreen()),
                  );
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
            if (roleBadge != null) ...[
              // Both builds are the same package with the same icon, so on a
              // phone in someone's hand they are indistinguishable. This label
              // is how "which app am I looking at?" gets answered during a
              // support call, without anyone opening a settings screen.
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  border: Border.all(color: TandavColors.gold, width: 1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  roleBadge!,
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                    color: TandavColors.gold,
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
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
        // Kept in the same order as _titles and the nav items below — three
        // parallel lists indexed by _index. Separate lists rather than one table
        // of records because the Dashboard needs a fresh key on every visit and
        // so cannot be const.
        children: isAttenderBuild
            ? const [AttendanceScreen(), StudentsScreen(), BatchesScreen(), FeesScreen()]
            : [
                // Rebuilt on every visit to Home so fee collection totals and
                // today's attendance reflect the latest SQLite state
                // immediately.
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
          // Index 0 is the Dashboard only on the owner build; on the attender's
          // it is Attendance, and there is no dashboard to re-key.
          if (!isAttenderBuild && i == 0 && i != _index) _dashboardKey++;
          _index = i;
        }),
        selectedFontSize: _navLabelSize,
        unselectedFontSize: _navLabelSize,
        items: isAttenderBuild ? _attenderNavItems : _ownerNavItems,
      ),
    );
  }

  static const _attenderNavItems = [
    BottomNavigationBarItem(
      icon: Icon(Icons.fact_check_outlined),
      activeIcon: Icon(Icons.fact_check_rounded),
      label: 'Attendance',
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
      icon: Icon(Icons.account_balance_wallet_outlined),
      activeIcon: Icon(Icons.account_balance_wallet_rounded),
      label: 'Fees',
    ),
  ];

  static const _ownerNavItems = [
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
  ];
}