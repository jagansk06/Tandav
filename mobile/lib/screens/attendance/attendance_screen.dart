import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../models/attendance.dart';
import '../../models/batch.dart';
import '../../widgets/states.dart';

class AttendanceScreen extends StatefulWidget {
  /// Bumped by [HomeShell] each time the Attendance tab is (re)entered so the
  /// batch dropdown and roster pick up batches/students created on other tabs.
  final int refreshTick;
  const AttendanceScreen({super.key, this.refreshTick = 0});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  /// The batch list is held as plain state rather than a `Future` handed to a
  /// `FutureBuilder`: a reassigned future briefly rebuilds with no data, and
  /// any load error used to leave the previous (stale) list on screen.
  List<Batch> _batches = [];
  bool _batchesLoading = true;
  String? _batchesError;

  int? _selectedBatchId;
  DateTime _date = DateTime.now();

  late Future<AttendanceDay> _dayFuture;
  Map<int, String> _liveStatuses = {};
  int _resetToken = 0;

  TandavApi? _api;

  @override
  void initState() {
    super.initState();
    _dayFuture = Future.value(_emptyDay);
    _api = context.read<TandavApi>();
    // Reload whenever business data changes anywhere in the app — a batch
    // created on the Batches tab, a student reassigned, or rows arriving from
    // the other device via a Google Drive sync. Without this the dropdown only
    // refreshed when the Attendance tab was re-entered, so newly created and
    // freshly synced batches were missing from it.
    _api!.revision.addListener(_onDataChanged);
    _loadBatches();
  }

  @override
  void dispose() {
    _api?.revision.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (mounted) _loadBatches();
  }

  @override
  void didUpdateWidget(AttendanceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-entering the tab (tick changed) reloads batches + roster too, so the
    // screen is correct even if a write bypassed the revision notifier.
    if (oldWidget.refreshTick != widget.refreshTick) {
      _loadBatches();
    }
  }

  static const AttendanceDay _emptyDay = AttendanceDay(
      date: '',
      batchId: 0,
      batchName: '',
      total: 0,
      present: 0,
      absent: 0,
      late: 0,
      unmarked: 0,
      percentage: 0,
      records: []);

  /// Load every batch registered in Tandav. Uses the shared batch data (no
  /// separate attendance-only batch list) so Attendance always agrees with the
  /// Batches tab.
  Future<void> _loadBatches() async {
    final api = _api;
    if (api == null) return;
    try {
      final res = (await api.getBatches()).items;
      if (!mounted) return;
      final ids = res.map((b) => b.id).toSet();
      setState(() {
        _batches = res;
        _batchesLoading = false;
        _batchesError = null;
        // Preserve the current selection if it still exists; otherwise fall
        // back to the first batch (or none if there are no batches).
        if (_selectedBatchId == null || !ids.contains(_selectedBatchId)) {
          _selectedBatchId = res.isNotEmpty ? res.first.id : null;
        }
      });
      // Refetch the roster as well: the trigger for a reload is always either
      // first load, re-entering the tab, or an external data change (a new
      // student, a reassignment, a Drive sync), any of which can change who
      // belongs in this batch. Marking attendance deliberately does not bump
      // the revision notifier, so this cannot clobber an in-progress edit.
      _reloadDay();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _batchesLoading = false;
        _batchesError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  String get _iso =>
      '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';

  void _reloadDay() {
    if (_selectedBatchId == null) {
      setState(() {
        _dayFuture = Future.value(_emptyDay);
      });
      return;
    }
    setState(() {
      _dayFuture = (_api ?? context.read<TandavApi>())
          .getAttendanceDay(_iso, batchId: _selectedBatchId);
    });
  }

  Future<void> _pickDate() async {
    final d = await pickDate(context, initial: _date);
    if (d != null) {
      setState(() {
        _date = d;
        _liveStatuses = {};
      });
      _reloadDay();
    }
  }

  ({int present, int late, int absent, int unmarked}) _counts(
      AttendanceDay day) {
    var present = 0, late = 0, absent = 0, unmarked = 0;
    for (final r in day.records) {
      final s = _liveStatuses[r.studentId] ?? r.status ?? 'unmarked';
      if (s == 'present') {
        present++;
      } else if (s == 'late') {
        late++;
      } else if (s == 'absent') {
        absent++;
      } else {
        unmarked++;
      }
    }
    return (present: present, late: late, absent: absent, unmarked: unmarked);
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final isToday = _date.year == today.year &&
        _date.month == today.month &&
        _date.day == today.day;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int?>(
                  // `_batches` is the single source of truth, so the list can
                  // never momentarily render empty while a future resolves.
                  initialValue: _batches.any((b) => b.id == _selectedBatchId)
                      ? _selectedBatchId
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Batch',
                    prefixIcon: const Icon(Icons.grid_view_outlined),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    hintText: _batchesLoading
                        ? 'Loading batches…'
                        : (_batches.isEmpty ? 'No batches yet' : 'Select batch'),
                  ),
                  items: _batches
                      .map((b) => DropdownMenuItem<int?>(
                            value: b.id,
                            child: Text(b.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (v) {
                    setState(() {
                      _selectedBatchId = v;
                      _liveStatuses = {};
                    });
                    _reloadDay();
                  },
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.calendar_month_outlined, size: 18),
                label: Text(isToday ? 'Today' : Fmt.date(_iso)),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<AttendanceDay>(
            future: _dayFuture,
            builder: (context, snapshot) {
              // Distinguish the three reasons no roster is showing, instead of
              // always claiming "No batches yet" (which was misleading while
              // batches were still loading or had failed to load).
              if (_batchesLoading) {
                return const LoadingView(message: 'Loading batches…');
              }
              if (_batchesError != null) {
                return ErrorView(
                  message: _batchesError!,
                  onRetry: _loadBatches,
                );
              }
              if (_batches.isEmpty) {
                return const EmptyView(
                  icon: Icons.fact_check_outlined,
                  title: 'No batches yet',
                  subtitle:
                      'Create a batch first, then mark attendance for its students.',
                );
              }
              if (_selectedBatchId == null) {
                return const EmptyView(
                  icon: Icons.grid_view_outlined,
                  title: 'Select a batch',
                  subtitle:
                      'Choose a batch above to mark attendance for its students.',
                );
              }
              if (snapshot.connectionState != ConnectionState.done) {
                return const LoadingView(message: 'Loading attendance…');
              }
              if (snapshot.hasError) {
                return ErrorView(
                  message: snapshot.error.toString(),
                  onRetry: _reloadDay,
                );
              }
              final day = snapshot.data!;
              final counts = _counts(day);
              if (day.records.isEmpty) {
                return const EmptyView(
                  icon: Icons.fact_check_outlined,
                  title: 'No students in this batch',
                  subtitle: 'Add students to the batch to mark attendance.',
                );
              }
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                    child: Row(
                      children: [
                        _chip('Present', counts.present, TandavColors.success),
                        const SizedBox(width: 8),
                        _chip('Late', counts.late, TandavColors.yellow),
                        const SizedBox(width: 8),
                        _chip('Absent', counts.absent, TandavColors.danger),
                        const SizedBox(width: 8),
                        _chip('Unmarked', counts.unmarked,
                            TandavColors.textMuted),
                        const Spacer(),
                        if (counts.unmarked > 0)
                          TextButton.icon(
                            onPressed: () =>
                                _quickMarkAll(day, 'present'),
                            icon: const Icon(Icons.done_all_rounded,
                                size: 16),
                            label: const Text('Mark all present'),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: AttendanceDayEditor(
                      key: ValueKey(
                          '$_iso|$_selectedBatchId|$_resetToken'),
                      day: day,
                      onSaved: () {
                        _reloadDay();
                        Alert.show(context, 'Attendance saved');
                      },
                      onStatusChanged: (statuses) {
                        if (!mounted) return;
                        setState(() => _liveStatuses = Map.of(statuses));
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _chip(String label, int value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$value',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: 14,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color.withValues(alpha: 0.9),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _quickMarkAll(AttendanceDay day, String status) async {
    try {
      final api = context.read<TandavApi>();
      final records = day.records
          .map((r) => {'student_id': r.studentId, 'status': status})
          .toList();
      await api.saveAttendanceDay(
        date: day.date,
        batchId: _selectedBatchId!,
        records: records,
      );
      setState(() {
        _resetToken++;
        _liveStatuses = {};
      });
      _reloadDay();
      if (!mounted) return;
      Alert.show(context, 'All marked $status');
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    }
  }
}

class AttendanceDayEditor extends StatefulWidget {
  final AttendanceDay day;
  final VoidCallback onSaved;
  final ValueChanged<Map<int, String>> onStatusChanged;
  const AttendanceDayEditor({
    super.key,
    required this.day,
    required this.onSaved,
    required this.onStatusChanged,
  });

  @override
  State<AttendanceDayEditor> createState() => _AttendanceDayEditorState();
}

class _AttendanceDayEditorState extends State<AttendanceDayEditor> {
  late Map<int, String> _statuses;
  Map<int, String> _notes = {};
  bool _saving = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _applyDay(widget.day);
  }

  @override
  void didUpdateWidget(AttendanceDayEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.day.date != widget.day.date ||
        oldWidget.day.batchId != widget.day.batchId) {
      _applyDay(widget.day);
    }
  }

  void _applyDay(AttendanceDay day) {
    _statuses = {
      for (final r in day.records) r.studentId: r.status ?? 'unmarked'
    };
    _notes = {
      for (final r in day.records) if (r.notes != null) r.studentId: r.notes!
    };
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final api = context.read<TandavApi>();
      final records = widget.day.records.map((r) {
        final status = _statuses[r.studentId] ?? 'unmarked';
        if (status == 'unmarked') return null;
        return {
          'student_id': r.studentId,
          'status': status,
          if (_notes[r.studentId] != null) 'notes': _notes[r.studentId],
        };
      }).whereType<Map<String, dynamic>>().toList();
      await api.saveAttendanceDay(
        date: widget.day.date,
        batchId: widget.day.batchId,
        records: records,
      );
      widget.onSaved();
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final grouped = <String?, List<AttendanceStudentRow>>{};
    for (final r in widget.day.records) {
      grouped.putIfAbsent(r.batchName, () => []).add(r);
    }
    final keys = grouped.keys.toList()
      ..sort((a, b) => (a ?? '').compareTo(b ?? ''));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
      children: [
        for (final group in keys) ...[
          if (grouped.length > 1 && group != null)
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 4),
              child: Text(
                group,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  color: TandavColors.gold,
                ),
              ),
            ),
          for (final r in grouped[group]!)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _row(r),
            ),
        ],
        const SizedBox(height: 8),
        _saving
            ? const Center(child: CircularProgressIndicator())
            : GoldButton(
                label: 'Save Attendance',
                icon: Icons.save_outlined,
                expanded: true,
                onPressed: _save,
              ),
      ],
    );
  }

  Widget _row(AttendanceStudentRow r) {
    final status = _statuses[r.studentId] ?? 'unmarked';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.studentName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14.5,
                      color: TandavColors.textPrimary,
                    ),
                  ),
                  if (r.batchName != null &&
                      r.batchName != widget.day.batchName)
                    Text(
                      r.batchName!,
                      style: const TextStyle(
                          fontSize: 11.5, color: TandavColors.textMuted),
                    ),
                ],
              ),
            ),
            _statusButton(r, 'present', Icons.check_rounded, TandavColors.success, status),
            const SizedBox(width: 6),
            _statusButton(r, 'late', Icons.schedule_rounded, TandavColors.yellow, status),
            const SizedBox(width: 6),
            _statusButton(r, 'absent', Icons.close_rounded, TandavColors.danger, status),
          ],
        ),
      ),
    );
  }

  Widget _statusButton(
    AttendanceStudentRow r,
    String value,
    IconData icon,
    Color color,
    String current,
  ) {
    final selected = current == value;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        setState(() => _statuses[r.studentId] = value);
        widget.onStatusChanged(_statuses);
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 600), _save);
      },
      child: Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: selected ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? color : TandavColors.surfaceBorder,
          ),
        ),
        child: Icon(
          icon,
          size: 18,
          color: selected ? const Color(0xFF141414) : color,
        ),
      ),
    );
  }
}