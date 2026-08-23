import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../sync/drive/drive_auth.dart';
import '../../sync/drive/drive_config.dart';
import '../../sync/drive/drive_sync_manager.dart';
import '../../widgets/states.dart';

/// Google Drive Sync.
///
/// Shows whether this device is connected to Google Drive, which account, when
/// it last synchronized and whether it is up to date, and offers the single
/// action the user needs: **Sync Now**.
///
/// Both devices are equal — there is no master, no slave and no pairing step.
/// The TANDAV id shown at the bottom is only sync bookkeeping (it stamps each
/// record so conflicts resolve the same way on both devices); it never limits
/// who may synchronize.
class DeviceSyncScreen extends StatefulWidget {
  const DeviceSyncScreen({super.key});

  @override
  State<DeviceSyncScreen> createState() => _DeviceSyncScreenState();
}

class _DeviceSyncScreenState extends State<DeviceSyncScreen> {
  StreamSubscription<DriveSyncStatus>? _sub;
  late DriveSyncStatus _last;
  DriveSyncInfo? _info;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    final api = context.read<TandavApi>();
    _last = api.sync.lastStatus;
    _sub = api.sync.status.listen((s) {
      if (!mounted) return;
      setState(() => _last = s);
      // Every terminal phase changes something the cards display (the account,
      // the last-sync time, the stored failure reason), so re-read state.
      if (!s.isBusy) _refresh();
    });
    _refresh();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final api = context.read<TandavApi>();
    final info = await api.sync.info();
    if (mounted) setState(() => _info = info);
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await action();
    } on DriveAuthException catch (e) {
      if (mounted && !e.cancelled) Alert.show(context, e.message, isError: true);
    } catch (e) {
      if (mounted) Alert.show(context, '$e', isError: true);
    } finally {
      if (mounted) setState(() => _working = false);
      await _refresh();
    }
  }

  Future<void> _connect() =>
      _guard(() => context.read<TandavApi>().sync.connect());

  Future<void> _syncNow() =>
      _guard(() => context.read<TandavApi>().sync.syncNow());

  Future<void> _disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TandavColors.surface,
        title: const Text('Disconnect Google Drive?'),
        content: const Text(
          'Tandav will stop synchronizing on this device. All students, '
          'batches, attendance and fees stay exactly where they are — on this '
          'device and in Google Drive. You can reconnect any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Disconnect',
              style: TextStyle(color: TandavColors.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _guard(() => context.read<TandavApi>().sync.disconnect());
    if (mounted) Alert.show(context, 'Google Drive disconnected');
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final info = _info;
    final connected = info?.connected ?? false;
    final busy = _working || _last.isBusy;

    return Scaffold(
      backgroundColor: TandavColors.background,
      appBar: AppBar(title: const Text('Google Drive Sync')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        color: TandavColors.gold,
        backgroundColor: TandavColors.surface,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _statusCard(info, connected),
            if (kIsWeb && !DriveConfig.isConfiguredForWeb) ...[
              const SizedBox(height: 16),
              _noticeCard(
                icon: Icons.build_circle_outlined,
                color: TandavColors.yellow,
                title: 'This web build has no Google client id',
                body: 'Rebuild with --dart-define='
                    'TANDAV_GOOGLE_WEB_CLIENT_ID=<your id>. The exact steps '
                    'are in SYNC.md.',
              ),
            ],
            if (_last.phase != DriveSyncPhase.idle) ...[
              const SizedBox(height: 16),
              _activityCard(),
            ],
            const SizedBox(height: 20),
            if (!connected)
              GoldButton(
                label: 'Connect Google Drive',
                icon: Icons.cloud_outlined,
                expanded: true,
                onPressed: busy ? null : _connect,
              )
            else if (_last.phase == DriveSyncPhase.failed)
              GoldButton(
                label: 'Try Again',
                icon: Icons.refresh_rounded,
                expanded: true,
                onPressed: busy ? null : _syncNow,
              )
            else
              GoldButton(
                label: busy ? 'Synchronizing…' : 'Sync Now',
                icon: Icons.sync_rounded,
                expanded: true,
                onPressed: busy ? null : _syncNow,
              ),
            const SizedBox(height: 18),
            _devicesCard(info),
            const SizedBox(height: 18),
            _howItWorksCard(),
            if (connected) ...[
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  onPressed: busy ? null : _disconnect,
                  child: const Text(
                    'Disconnect Google Drive',
                    style: TextStyle(color: TandavColors.danger),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ cards

  Widget _statusCard(DriveSyncInfo? info, bool connected) {
    final lastSync = info?.lastSyncAt;
    final offline = _last.phase == DriveSyncPhase.offline;
    final failed = _last.phase == DriveSyncPhase.failed;

    final (String statusText, Color statusColor) = _statusLine(
      connected: connected,
      offline: offline,
      failed: failed,
      lastSync: lastSync,
    );

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                connected ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                color: connected ? TandavColors.gold : TandavColors.textMuted,
                size: 26,
              ),
              const SizedBox(width: 10),
              const Text(
                'Google Drive',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                  color: TandavColors.textPrimary,
                ),
              ),
              const Spacer(),
              if (connected)
                const Text(
                  'Connected ✓',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: TandavColors.success,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (connected && (info?.accountEmail ?? '').isNotEmpty)
            _row('Account', info!.accountEmail!),
          _row('Last Sync', _timestamp(lastSync)),
          _row('Status', statusText, valueColor: statusColor),
          if (offline) ...[
            const SizedBox(height: 10),
            Text(
              lastSync == null
                  ? 'Tandav works normally without the internet. Connect to a '
                      'network to synchronize.'
                  : 'Tandav works normally without the internet. Your changes '
                      'are saved on this device and will be sent to Google '
                      'Drive the next time you sync.',
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: TandavColors.textMuted,
              ),
            ),
          ],
          if (failed) ...[
            const SizedBox(height: 12),
            _reasonBox(info?.lastError ?? _last.message),
          ],
          if (!connected && !failed) ...[
            const SizedBox(height: 12),
            const Text(
              'Connect the same Google account on both devices. Tandav creates '
              'its own folder and keeps only its sync file there — nothing '
              'else in your Drive is read or changed.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: TandavColors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _activityCard() {
    final (icon, color) = switch (_last.phase) {
      DriveSyncPhase.idle => (Icons.circle_outlined, TandavColors.textMuted),
      DriveSyncPhase.connecting => (Icons.login_rounded, TandavColors.gold),
      DriveSyncPhase.preparing => (Icons.folder_open_rounded, TandavColors.gold),
      DriveSyncPhase.downloading =>
        (Icons.cloud_download_rounded, TandavColors.gold),
      DriveSyncPhase.merging => (Icons.merge_type_rounded, TandavColors.gold),
      DriveSyncPhase.uploading =>
        (Icons.cloud_upload_rounded, TandavColors.gold),
      DriveSyncPhase.complete =>
        (Icons.check_circle_rounded, TandavColors.success),
      DriveSyncPhase.failed => (Icons.error_rounded, TandavColors.danger),
      DriveSyncPhase.offline => (Icons.wifi_off_rounded, TandavColors.yellow),
    };

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('SYNC ACTIVITY'),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_last.isBusy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: TandavColors.gold,
                  ),
                )
              else
                Icon(icon, size: 18, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _last.message,
                  style: const TextStyle(
                    fontSize: 13.5,
                    height: 1.4,
                    color: TandavColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _devicesCard(DriveSyncInfo? info) {
    final peers = info?.peerDevices ?? const <String>[];
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('THIS DEVICE'),
          Text(
            info?.deviceId ?? 'TANDAV-····',
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.5,
              color: TandavColors.textPrimary,
            ),
          ),
          const SizedBox(height: 14),
          _label('OTHER DEVICES SHARING THIS DRIVE FOLDER'),
          if (peers.isEmpty)
            const Text(
              'None yet — sync on your other device to see it here.',
              style: TextStyle(fontSize: 13, color: TandavColors.textMuted),
            )
          else
            ...peers.map(
              (id) => Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    const Icon(Icons.smartphone_rounded,
                        size: 18, color: TandavColors.gold),
                    const SizedBox(width: 8),
                    Text(
                      id,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: TandavColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          const Text(
            'Both devices are equal. Whichever device edited a record most '
            'recently wins, so you can work on either one — even offline — and '
            'sync afterwards.',
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: TandavColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _howItWorksCard() {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('WHAT HAPPENS WHEN YOU SYNC'),
          const SizedBox(height: 6),
          const Text(
            'Tandav reads your other device\'s changes from Drive, merges them '
            'into this device record by record, then publishes this device\'s '
            'changes. Nothing is overwritten wholesale, and no duplicate '
            'students, batches, attendance or fee records are created.\n\n'
            'Only Tandav\'s own sync file is stored in Drive — never your '
            'password, the app itself, or any other file.',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.5,
              color: TandavColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _noticeCard({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
  }) {
    return _Card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: TandavColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- helpers

  (String, Color) _statusLine({
    required bool connected,
    required bool offline,
    required bool failed,
    required String? lastSync,
  }) {
    if (offline) return ('Offline', TandavColors.yellow);
    if (failed) return ('Synchronization failed', TandavColors.danger);
    if (!connected) return ('Not connected', TandavColors.textMuted);
    if (lastSync == null) {
      return ('Connected — not synchronized yet', TandavColors.yellow);
    }
    return ('Up to date', TandavColors.success);
  }

  Widget _row(String name, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              name,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: TandavColors.textMuted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: valueColor ?? TandavColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _reasonBox(String reason) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TandavColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TandavColors.surfaceLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('REASON'),
          Text(
            reason,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: TandavColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  /// Sync timestamps are stored as UTC ISO-8601 so both devices compare them
  /// consistently; they are shown in the phone's own timezone.
  String _timestamp(String? iso) {
    if (iso == null || iso.isEmpty) return 'Never';
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return Fmt.date(iso);
    return DateFormat('d MMM yyyy, h:mm a').format(parsed.toLocal());
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 10.5,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w700,
            color: TandavColors.textMuted,
          ),
        ),
      );
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TandavColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}
