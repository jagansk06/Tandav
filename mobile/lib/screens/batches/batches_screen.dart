import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services.dart';
import '../../core/theme.dart';
import '../../models/batch.dart';
import '../../sync/cloud_sync.dart';
import '../../widgets/states.dart';
import 'batch_detail_screen.dart';
import 'batch_form_screen.dart';

class BatchesScreen extends StatefulWidget {
  const BatchesScreen({super.key});

  @override
  State<BatchesScreen> createState() => _BatchesScreenState();
}

class _BatchesScreenState extends State<BatchesScreen> {
  late Future<BatchListResponse> _future;
  StreamSubscription<CloudSyncStatus>? _syncSub;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _syncSub = context
        .read<TandavApi>()
        .cloudSync
        .status
        .listen((s) => _onSyncStatus(s));
  }

  void _onSyncStatus(CloudSyncStatus s) {
    if (s.phase == CloudSyncPhase.complete && mounted) {
      _reload();
    }
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    super.dispose();
  }

  Future<BatchListResponse> _load() =>
      context.read<TandavApi>().getBatches();

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _openForm() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const BatchFormScreen()),
    );
    if (mounted) _reload();
  }

  Future<void> _openDetail(Batch b) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BatchDetailScreen(batchId: b.id)),
    );
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Batches')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openForm,
        backgroundColor: TandavColors.gold,
        foregroundColor: const Color(0xFF141414),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Batch'),
      ),
      body: FutureBuilder<BatchListResponse>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LoadingView(message: 'Loading batches…');
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
              icon: Icons.grid_view_outlined,
              title: 'No batches yet',
              subtitle:
                  'Batches group students by style and level for attendance and reporting.',
              action: OutlinedButton.icon(
                onPressed: _openForm,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Create Batch'),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async => _reload(),
            color: TandavColors.gold,
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: list.items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (ctx, i) => _batchCard(list.items[i]),
            ),
          );
        },
      ),
    );
  }

  Widget _batchCard(Batch b) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openDetail(b),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  gradient: GoldGradient.linear,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.self_improvement_rounded,
                    color: Color(0xFF242000), size: 24),
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
                            b.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15.5,
                              color: TandavColors.textPrimary,
                            ),
                          ),
                        ),
                        if (!b.isActive) ...[
                          const SizedBox(width: 6),
                          const StatusBadge(
                              status: 'inactive', label: 'Inactive'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        if (b.danceStyle.isNotEmpty) b.danceStyle,
                        if (b.level.isNotEmpty) b.level,
                        if (b.schedule.isNotEmpty) b.schedule,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12.5, color: TandavColors.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${b.studentCount}',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: TandavColors.gold,
                    ),
                  ),
                  Text(
                    'students',
                    style: const TextStyle(
                        fontSize: 10.5, color: TandavColors.textMuted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}