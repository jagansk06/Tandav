import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services.dart';
import '../../core/theme.dart';
import '../../models/batch.dart';
import '../../models/student.dart';
import '../../widgets/states.dart';
import 'student_detail_screen.dart';
import 'student_form_screen.dart';

class StudentsScreen extends StatefulWidget {
  const StudentsScreen({super.key});

  @override
  State<StudentsScreen> createState() => _StudentsScreenState();
}

class _StudentsScreenState extends State<StudentsScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  int? _batchFilter;
  bool _activeOnly = true;
  List<Batch> _batches = [];

  late Future<StudentListResponse> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _loadBatches();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadBatches() async {
    try {
      final res = await context.read<TandavApi>().getBatches();
      if (mounted) setState(() => _batches = res.items);
    } catch (_) {}
  }

  Future<StudentListResponse> _load() {
    return context.read<TandavApi>().getStudents(
          q: _query,
          batchId: _batchFilter,
          activeOnly: _activeOnly,
        );
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _query = value.trim();
      _reload();
    });
  }

  Future<void> _openForm({Student? student}) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => StudentFormScreen(student: student)),
    );
    if (mounted) _reload();
  }

  Future<void> _openDetail(Student s) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => StudentDetailScreen(studentId: s.id)),
    );
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openForm,
        backgroundColor: TandavColors.gold,
        foregroundColor: const Color(0xFF141414),
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('Student'),
      ),
      body: Column(
        children: [
          Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: _onSearchChanged,
                  decoration: const InputDecoration(
                    hintText: 'Search name, phone, email…',
                    prefixIcon: Icon(Icons.search_rounded),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              PopupMenuButton<int?>(
                initialValue: _batchFilter,
                onSelected: (v) {
                  setState(() => _batchFilter = v);
                  _reload();
                },
                icon: const Icon(Icons.filter_list_rounded),
                tooltip: 'Filter by batch',
                itemBuilder: (ctx) => [
                  const PopupMenuItem<int?>(value: null, child: Text('All batches')),
                  ..._batches.map(
                    (b) => PopupMenuItem<int?>(
                      value: b.id,
                      child: Text(b.name),
                    ),
                  ),
                ],
              ),
              Switch(
                value: _activeOnly,
                activeTrackColor: TandavColors.gold.withValues(alpha: 0.4),
                onChanged: (v) {
                  setState(() => _activeOnly = v);
                  _reload();
                },
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, top: 2),
          child: Row(
            children: [
              const Icon(Icons.toggle_on_outlined,
                  size: 16, color: TandavColors.textMuted),
              const SizedBox(width: 6),
              const Text(
                'Active only',
                style: TextStyle(
                    fontSize: 12, color: TandavColors.textMuted),
              ),
              const Spacer(),
              Text(
                _batchFilter != null
                    ? (_batches
                            .where((b) => b.id == _batchFilter)
                            .firstOrNull
                            ?.name ??
                        'Filtered')
                    : 'All batches',
                style: const TextStyle(
                    fontSize: 12, color: TandavColors.gold),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<StudentListResponse>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const LoadingView(message: 'Loading students…');
              }
              if (snapshot.hasError) {
                return ErrorView(
                  message: snapshot.error.toString(),
                  onRetry: _reload,
                );
              }
              final list = snapshot.data!;
              if (list.items.isEmpty) {
                return EmptyView(
                  icon: Icons.groups_outlined,
                  title: _query.isEmpty && _batchFilter == null
                      ? 'No students yet'
                      : 'No students match your filters',
                  subtitle: _query.isEmpty && _batchFilter == null
                      ? 'Add your first student to get started.'
                      : 'Try clearing the search or filters.',
                  action: _query.isEmpty && _batchFilter == null
                      ? OutlinedButton.icon(
                          onPressed: () => _openForm(),
                          icon: const Icon(Icons.person_add_alt_1_rounded),
                          label: const Text('Add Student'),
                        )
                      : null,
                );
              }
              return RefreshIndicator(
                onRefresh: () async => _reload(),
                color: TandavColors.gold,
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                  itemCount: list.items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) => _studentCard(list.items[i]),
                ),
              );
            },
          ),
        ),
      ],
      ),
    );
  }

  Widget _studentCard(Student s) {
    final initials = s.firstName.isNotEmpty ? s.firstName[0].toUpperCase() : '?';
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openDetail(s),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: TandavColors.gold.withValues(alpha: 0.16),
                child: Text(
                  initials,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: TandavColors.gold,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            s.fullName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              color: TandavColors.textPrimary,
                            ),
                          ),
                        ),
                        if (!s.isActive) ...[
                          const SizedBox(width: 6),
                          const StatusBadge(status: 'inactive', label: 'Inactive'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(Icons.grid_view_outlined,
                            size: 13, color: TandavColors.textMuted),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            s.batchName ?? 'No batch',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12.5, color: TandavColors.textSecondary),
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Icon(Icons.phone_outlined,
                            size: 13, color: TandavColors.textMuted),
                        const SizedBox(width: 4),
                        Text(
                          s.phone,
                          style: const TextStyle(
                              fontSize: 12.5, color: TandavColors.textSecondary),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: TandavColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}