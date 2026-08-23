import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../models/batch.dart';
import '../../models/event.dart';
import '../../models/student.dart';
import '../../widgets/states.dart';
import '../students/student_detail_screen.dart';
import 'costume_payment_sheet.dart';
import 'event_form_screen.dart';

class EventDetailScreen extends StatefulWidget {
  final int eventId;
  const EventDetailScreen({super.key, required this.eventId});

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  late Future<EventItem> _eventFuture;
  late Future<ParticipationListResponse> _participantsFuture;
  late Future<CostumeSummary> _costumeFuture;
  List<Batch> _batches = [];
  String? _costumeFilter;

  @override
  void initState() {
    super.initState();
    _reloadAll();
    _loadBatches();
  }

  void _reloadAll() {
    final api = context.read<TandavApi>();
    setState(() {
      _eventFuture = api.getEvent(widget.eventId);
      _participantsFuture = api.getParticipants(widget.eventId,
          costumeStatus: _costumeFilter);
      _costumeFuture = api.getCostumeSummary(widget.eventId);
    });
  }

  Future<void> _loadBatches() async {
    try {
      final batchesApi = context.read<TandavApi>();
      final res = await batchesApi.getBatches();
      if (mounted) setState(() => _batches = res.items);
    } catch (_) {}
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TandavColors.surface,
        title: const Text('Delete event?'),
        content: const Text(
            'This removes the event and all its participation records.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete',
                style: TextStyle(color: TandavColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final api = context.read<TandavApi>();
      await api.deleteEvent(widget.eventId);
      if (mounted) {
        Navigator.pop(context);
        Alert.show(context, 'Event deleted');
      }
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    }
  }

  Future<void> _addParticipantsDialog() async {
    final batches = _batches;
    List<Student> students = [];
    try {
      final studentsApi = context.read<TandavApi>();
      final res = await studentsApi.getStudents(activeOnly: true);
      students = res.items;
    } catch (_) {}

    if (!mounted) return;
    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: TandavColors.surface,
      isScrollControlled: true,
      builder: (_) => _AddParticipantsSheet(
        batches: batches,
        students: students,
      ),
    );
    if (selected == null || !mounted) return;
    try {
      final api = context.read<TandavApi>();
      if (selected['mode'] == 'batch') {
        await api.addBatchParticipants(
          widget.eventId,
          selected['batch_id'] as int,
          costumeFee: selected['costume_fee'] ?? '0',
        );
      } else {
        await api.addParticipants(
          widget.eventId,
          List<int>.from(selected['student_ids']),
          isCostumeRequired: selected['costume_required'] as bool? ?? false,
          costumeFee: selected['costume_fee'] ?? '0',
        );
      }
      if (!mounted) return;
      Alert.show(context, 'Participants added');
      _reloadAll();
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Event'),
        actions: [
          IconButton(
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline_rounded),
            color: TandavColors.danger,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addParticipantsDialog,
        backgroundColor: TandavColors.gold,
        foregroundColor: const Color(0xFF141414),
        icon: const Icon(Icons.group_add_rounded),
        label: const Text('Add Students'),
      ),
      body: FutureBuilder<EventItem>(
        future: _eventFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LoadingView(message: 'Loading event…');
          }
          if (snapshot.hasError) {
            return ErrorView(message: snapshot.error.toString());
          }
          final event = snapshot.data!;
          return RefreshIndicator(
            onRefresh: () async => _reloadAll(),
            color: TandavColors.gold,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 90),
              children: [
                _header(event),
                const SizedBox(height: 12),
                FutureBuilder<CostumeSummary>(
                  future: _costumeFuture,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) return const SizedBox.shrink();
                    return _costumeCard(snapshot.data!);
                  },
                ),
                const SectionHeader(title: 'Participants'),
                Row(
                  children: [
                    for (final (value, label) in [
                      (null, 'All'),
                      ('due', 'Costume due'),
                      ('partial', 'Partial'),
                      ('paid', 'Paid'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(label,
                              style: const TextStyle(fontSize: 11.5)),
                          selected: _costumeFilter == value,
                          onSelected: (_) {
                            setState(() => _costumeFilter = value);
                            _reloadAll();
                          },
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                FutureBuilder<ParticipationListResponse>(
                  future: _participantsFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const SizedBox(
                          height: 160, child: LoadingView());
                    }
                    if (snapshot.hasError) {
                      return ErrorView(
                          message: snapshot.error.toString());
                    }
                    final parts = snapshot.data!;
                    if (parts.items.isEmpty) {
                      return const EmptyView(
                        icon: Icons.group_outlined,
                        title: 'No participants yet',
                        subtitle:
                            'Add a whole batch or individual students to this event.',
                      );
                    }
                    return Column(
                      children: parts.items
                          .map((p) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _participantTile(p),
                              ))
                          .toList(),
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _header(EventItem e) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              e.name,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w900,
                color: TandavColors.textPrimary,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.event_outlined,
                    size: 16, color: TandavColors.gold),
                const SizedBox(width: 6),
                Text(Fmt.date(e.eventDate),
                    style: const TextStyle(color: TandavColors.textPrimary)),
                const SizedBox(width: 16),
                const Icon(Icons.location_on_outlined,
                    size: 16, color: TandavColors.gold),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    e.location ?? '—',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: TandavColors.textPrimary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (e.eventType.isNotEmpty)
                  StatusBadge(status: 'active', label: e.eventType),
                if (e.batchName != null)
                  Chip(
                    avatar: const Icon(Icons.grid_view_outlined, size: 15),
                    label: Text(e.batchName!),
                  ),
                StatusBadge(
                    status: 'partial', label: '${e.participantCount} participants'),
              ],
            ),
            if ((e.description ?? '').isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                e.description!,
                style: const TextStyle(
                    color: TandavColors.textSecondary, height: 1.4),
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => EventFormScreen(event: e)),
                );
                _reloadAll();
              },
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Edit Event'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _costumeCard(CostumeSummary c) {
    final due = double.tryParse(c.totalDue) ?? 0;
    final paid = double.tryParse(c.totalPaid) ?? 0;
    final pct = due == 0 ? 0.0 : (paid / due * 100).clamp(0, 100);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.checkroom_outlined,
                    color: TandavColors.gold, size: 20),
                SizedBox(width: 8),
                Text(
                  'Costume Fees',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: TandavColors.textPrimary,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _col('Due', Fmt.money(due)),
                ),
                Expanded(
                  child: _col('Collected', Fmt.money(paid),
                      color: TandavColors.success),
                ),
                Expanded(
                  child: _col('Outstanding',
                      Fmt.money(double.tryParse(c.outstanding) ?? 0),
                      color: TandavColors.danger),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct / 100,
                minHeight: 7,
                backgroundColor: TandavColors.surfaceBorder,
                valueColor: const AlwaysStoppedAnimation(TandavColors.gold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _col(String label, String value,
      {Color color = TandavColors.textPrimary}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: TandavColors.textMuted,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w900,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _participantTile(EventParticipation p) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) =>
                          StudentDetailScreen(studentId: p.studentId)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.studentName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                        color: TandavColors.textPrimary,
                      ),
                    ),
                    Text(
                      p.batchName ?? '',
                      style: const TextStyle(
                          fontSize: 11.5, color: TandavColors.textMuted),
                    ),
                  ],
                ),
              ),
            ),
            if (p.isCostumeRequired)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  StatusBadge(status: p.costumeStatus,
                      label: p.costumeStatus),
                  const SizedBox(height: 3),
                  Text(
                    '${Fmt.money(p.paidValue)} / ${Fmt.money(p.dueValue)}',
                    style: const TextStyle(
                        fontSize: 10.5, color: TandavColors.textMuted),
                  ),
                ],
              )
            else
              const StatusBadge(status: 'none', label: 'No costume'),
            const SizedBox(width: 6),
            IconButton(
              onPressed: () => _costumeSheet(p),
              icon: const Icon(Icons.payments_outlined,
                  color: TandavColors.gold, size: 20),
              tooltip: 'Manage costume fee',
            ),
            IconButton(
              onPressed: () => _removeParticipant(p),
              icon: const Icon(Icons.person_remove_outlined,
                  color: TandavColors.danger, size: 20),
              tooltip: 'Remove',
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _costumeSheet(EventParticipation p) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: TandavColors.surface,
      isScrollControlled: true,
      builder: (_) => CostumePaymentSheet(participation: p),
    );
    _reloadAll();
  }

  Future<void> _removeParticipant(EventParticipation p) async {
    try {
      final api = context.read<TandavApi>();
      await api.removeParticipant(p.id);
      Alert.show(context, 'Participant removed');
      _reloadAll();
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    }
  }
}

class _AddParticipantsSheet extends StatefulWidget {
  final List<Batch> batches;
  final List<Student> students;
  const _AddParticipantsSheet({
    required this.batches,
    required this.students,
  });

  @override
  State<_AddParticipantsSheet> createState() => _AddParticipantsSheetState();
}

class _AddParticipantsSheetState extends State<_AddParticipantsSheet> {
  String _mode = 'batch';
  int? _batchId;
  final Set<int> _selectedStudents = {};
  String _costumeFee = '';
  bool _costumeRequired = false;
  final _feeController = TextEditingController();

  @override
  void dispose() {
    _feeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isBatchMode = _mode == 'batch';
    final selectedCount = isBatchMode
        ? 0
        : widget.students.where((s) => _selectedStudents.contains(s.id)).length;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Add Participants',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w900,
                color: TandavColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'batch',
                  label: Text('Whole batch'),
                  icon: Icon(Icons.grid_view_rounded),
                ),
                ButtonSegment(
                  value: 'individual',
                  label: Text('Select students'),
                  icon: Icon(Icons.person_add_alt_1_rounded),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 12),
            if (isBatchMode)
              DropdownButtonFormField<int?>(
                initialValue: _batchId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Batch *',
                  prefixIcon: Icon(Icons.grid_view_outlined),
                ),
                items: widget.batches
                    .map((b) => DropdownMenuItem<int?>(
                          value: b.id,
                          child: Text(b.name,
                              overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _batchId = v),
              )
            else
              Expanded(
                child: widget.students.isEmpty
                    ? const EmptyView(
                        icon: Icons.groups_outlined,
                        title: 'No students found',
                        subtitle: 'Add students first to select them.')
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: widget.students.length,
                        itemBuilder: (ctx, i) {
                          final s = widget.students[i];
                          final checked =
                              _selectedStudents.contains(s.id);
                          return CheckboxListTile(
                            value: checked,
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _selectedStudents.add(s.id);
                              } else {
                                _selectedStudents.remove(s.id);
                              }
                            }),
                            title: Text(s.fullName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 14)),
                            subtitle: Text(s.batchName ?? 'No batch',
                                style: const TextStyle(fontSize: 12)),
                            dense: true,
                            controlAffinity:
                                ListTileControlAffinity.leading,
                          );
                        },
                      ),
              ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _costumeRequired,
              title: const Text(
                'Costume required',
                style: TextStyle(color: TandavColors.textPrimary),
              ),
              onChanged: (v) => setState(() => _costumeRequired = v),
            ),
            if (_costumeRequired) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _feeController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Costume fee per student (\u20B9)',
                  prefixIcon: Icon(Icons.checkroom_outlined),
                ),
                onChanged: (v) => setState(() => _costumeFee = v.trim()),
              ),
            ],
            const SizedBox(height: 16),
            GoldButton(
              label: isBatchMode
                  ? 'Add batch (${
                      widget.batches
                              .where((b) => b.id == _batchId)
                              .firstOrNull
                              ?.studentCount ??
                          ''} students)'
                  : 'Add $selectedCount student${selectedCount == 1 ? '' : 's'}',
              icon: Icons.group_add_rounded,
              expanded: true,
              onPressed: () {
                if (isBatchMode) {
                  if (_batchId == null) {
                    Alert.show(context, 'Select a batch', isError: true);
                    return;
                  }
                  Navigator.pop(context, {
                    'mode': 'batch',
                    'batch_id': _batchId,
                    'costume_fee': _costumeRequired ? _costumeFee : '0',
                  });
                } else {
                  if (_selectedStudents.isEmpty) {
                    Alert.show(context, 'Select at least one student',
                        isError: true);
                    return;
                  }
                  Navigator.pop(context, {
                    'mode': 'individual',
                    'student_ids': _selectedStudents.toList(),
                    'costume_required': _costumeRequired,
                    'costume_fee':
                        _costumeRequired ? _costumeFee : '0',
                  });
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}