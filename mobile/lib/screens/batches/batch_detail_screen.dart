import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../models/batch.dart';
import '../../models/student.dart';
import '../../widgets/states.dart';
import '../students/student_detail_screen.dart';
import 'batch_form_screen.dart';

class BatchDetailScreen extends StatefulWidget {
  final int batchId;
  const BatchDetailScreen({super.key, required this.batchId});

  @override
  State<BatchDetailScreen> createState() => _BatchDetailScreenState();
}

class _BatchDetailScreenState extends State<BatchDetailScreen> {
  late Future<Batch> _batchFuture;
  late Future<StudentListResponse> _studentsFuture;

  @override
  void initState() {
    super.initState();
    _reloadAll();
  }

  void _reloadAll() {
    final api = context.read<TandavApi>();
    setState(() {
      _batchFuture = api.getBatch(widget.batchId);
      _studentsFuture = api.getStudents(
        batchId: widget.batchId,
        activeOnly: false,
      );
    });
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TandavColors.surface,
        title: const Text('Delete batch?'),
        content: const Text(
            'Students in this batch will be unassigned, not deleted.'),
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
      await api.deleteBatch(widget.batchId);
      if (mounted) {
        Navigator.pop(context);
        Alert.show(context, 'Batch deleted');
      }
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
        title: const Text('Batch'),
        actions: [
          IconButton(
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline_rounded),
            color: TandavColors.danger,
          ),
        ],
      ),
      body: FutureBuilder<Batch>(
        future: _batchFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LoadingView(message: 'Loading batch…');
          }
          if (snapshot.hasError) {
            return ErrorView(
              message: snapshot.error.toString(),
              onRetry: _reloadAll,
            );
          }
          final batch = snapshot.data!;
          return RefreshIndicator(
            onRefresh: () async => _reloadAll(),
            color: TandavColors.gold,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [
                _header(batch),
                const SizedBox(height: 12),
                const SectionHeader(title: 'Students in this batch'),
                FutureBuilder<StudentListResponse>(
                  future: _studentsFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const SizedBox(
                          height: 120, child: LoadingView());
                    }
                    if (snapshot.hasError) {
                      return ErrorView(message: snapshot.error.toString());
                    }
                    final students = snapshot.data!;
                    if (students.items.isEmpty) {
                      return const EmptyView(
                        icon: Icons.groups_outlined,
                        title: 'No students in this batch',
                        subtitle:
                            'Assign students to this batch from a student profile.',
                      );
                    }
                    return Column(
                      children: students.items
                          .map((s) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _studentTile(s),
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

  Widget _header(Batch b) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    b.name,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                      color: TandavColors.textPrimary,
                    ),
                  ),
                ),
                StatusBadge(
                    status: b.isActive ? 'active' : 'inactive',
                    label: b.isActive ? 'Active' : 'Inactive'),
              ],
            ),
            const SizedBox(height: 12),
            _info(Icons.self_improvement_rounded, 'Style',
                b.danceStyle.isEmpty ? '—' : b.danceStyle),
            _info(Icons.signal_cellular_alt_outlined, 'Level',
                b.level.isEmpty ? '—' : b.level),
            _info(Icons.schedule_outlined, 'Schedule',
                b.schedule.isEmpty ? '—' : b.schedule),
            _info(Icons.currency_rupee_rounded, 'Monthly fee',
                Fmt.money(double.tryParse(b.monthlyFee) ?? 0)),
            _info(Icons.groups_outlined, 'Students', '${b.studentCount}'),
            if ((b.notes ?? '').isNotEmpty)
              _info(Icons.notes_rounded, 'Notes', b.notes!),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => BatchFormScreen(batch: b)),
                );
                _reloadAll();
              },
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Edit Batch'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _info(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 17, color: TandavColors.gold),
          const SizedBox(width: 10),
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(
                color: TandavColors.textMuted,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: TandavColors.textPrimary,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _studentTile(Student s) {
    return Card(
      child: ListTile(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => StudentDetailScreen(studentId: s.id)),
        ),
        leading: CircleAvatar(
          backgroundColor: TandavColors.gold.withValues(alpha: 0.15),
          child: Text(
            s.firstName.isNotEmpty ? s.firstName[0].toUpperCase() : '?',
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: TandavColors.gold,
            ),
          ),
        ),
        title: Text(
          s.fullName,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: TandavColors.textPrimary,
          ),
        ),
        subtitle: Text(
          s.phone,
          style: const TextStyle(
              fontSize: 12.5, color: TandavColors.textSecondary),
        ),
        trailing: const Icon(Icons.chevron_right_rounded,
            color: TandavColors.textMuted),
      ),
    );
  }
}