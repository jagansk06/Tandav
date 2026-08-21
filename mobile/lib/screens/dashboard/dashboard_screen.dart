import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../models/dashboard.dart';
import '../../widgets/states.dart';

import '../events/event_detail_screen.dart';

import '../students/student_detail_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<DashboardData> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<TandavApi>().getDashboard();
  }

  void _reload() {
    setState(() {
      _future = context.read<TandavApi>().getDashboard();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DashboardData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const LoadingView(message: 'Loading dashboard…');
        }
        if (snapshot.hasError) {
          return ErrorView(
            message: snapshot.error.toString(),
            onRetry: _reload,
          );
        }
        final data = snapshot.data!;
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          color: TandavColors.gold,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _todayCard(data.stats),
              const SizedBox(height: 12),
              _statGrid(data, data.stats),
              const SectionHeader(
                title: 'This Month Fees',
                trailing: Text(
                  '',
                  style: TextStyle(color: TandavColors.textMuted, fontSize: 12),
                ),
              ),
              _feeCard(data.feeSummary),
              if (data.upcomingEvents.isNotEmpty) ...[
                const SectionHeader(title: 'Upcoming Events'),
                ...data.upcomingEvents.take(4).map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _eventTile(e),
                    )),
              ],
              if (data.recentStudents.isNotEmpty) ...[
                const SectionHeader(title: 'Recently Joined'),
                ...data.recentStudents.take(4).map((s) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _studentTile(s),
                    )),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _todayCard(DashboardStats s) {
    final marked = s.todayPresent + s.todayAbsent + s.todayLate;
    final pct = s.activeStudents == 0
        ? 0.0
        : (marked / s.activeStudents * 100).clamp(0, 100);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: GoldGradient.linear,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'TODAY\'S ATTENDANCE',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
              color: Color(0xFF4A3A00),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _todayStat('PRESENT', s.todayPresent, Icons.check_circle_rounded),
              _todayStat('LATE', s.todayLate, Icons.schedule_rounded),
              _todayStat('ABSENT', s.todayAbsent, Icons.cancel_rounded),
              _todayStat('UNMARKED', s.todayUnmarked, Icons.help_outline_rounded),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct / 100,
              minHeight: 6,
              backgroundColor: const Color(0x334A3A00),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF3A2E00)),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${marked}/${s.activeStudents} active students marked (${pct.toStringAsFixed(0)}%)',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF4A3A00),
            ),
          ),
        ],
      ),
    );
  }

  Widget _todayStat(String label, int value, IconData icon) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 20, color: const Color(0xFF3A2E00)),
          const SizedBox(height: 4),
          Text(
            '$value',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              color: Color(0xFF242000),
            ),
          ),
          Text(
            label,
            style: const TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
              color: Color(0xFF4A3A00),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statGrid(DashboardData data, DashboardStats s) {
    final items = [
      ('Students', '${s.activeStudents}/${s.totalStudents}', Icons.groups_rounded),
      ('Batches', '${s.activeBatches}/${s.totalBatches}', Icons.grid_view_rounded),
      ('Events', '${s.upcomingEvents} upcoming', Icons.event_available_rounded),
      ('Fees', Fmt.money(data.feeSummary.collected), Icons.currency_rupee_rounded),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 2.1,
      children: items
          .map((e) => _statCard(e.$1, e.$2, e.$3))
          .toList(),
    );
  }

  Widget _statCard(String label, String value, IconData icon) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(icon, color: TandavColors.gold, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: TandavColors.textMuted,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                      color: TandavColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _feeCard(DashboardFeeSummary f) {
    final pct = f.due == 0 ? 0.0 : (f.collected / f.due * 100).clamp(0, 100);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.payments_outlined,
                    color: TandavColors.gold, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    Fmt.monthLabel(f.month),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: TandavColors.textPrimary,
                    ),
                  ),
                ),
                StatusBadge(
                  status: pct >= 100
                      ? 'paid'
                      : pct > 0
                          ? 'partial'
                          : 'due',
                  label: f.totalRecords == 0
                      ? 'No records'
                      : '${f.dueCount} pending',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _feeCol('Expected', Fmt.money(f.due)),
                ),
                Expanded(
                  child: _feeCol('Collected', Fmt.money(f.collected)),
                ),
                Expanded(
                  child: _feeCol('Pending',
                      Fmt.money(double.tryParse(f.outstanding) ?? 0)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct / 100,
                minHeight: 7,
                backgroundColor: TandavColors.surfaceBorder,
                valueColor: const AlwaysStoppedAnimation(TandavColors.gold),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  '${f.paidCount} paid · ${f.dueCount} pending',
                  style: const TextStyle(
                      fontSize: 12, color: TandavColors.textSecondary),
                ),
                const Spacer(),
                Text(
                  '${pct.toStringAsFixed(1)}% collected',
                  style: const TextStyle(
                      fontSize: 12, color: TandavColors.textSecondary),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _feeCol(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: TandavColors.textMuted,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w900,
            color: TandavColors.textPrimary,
          ),
        ),
      ],
    );
  }

  Widget _eventTile(UpcomingEvent e) {
    return Card(
      child: ListTile(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => EventDetailScreen(eventId: e.id)),
        ),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: TandavColors.surfaceLight,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: TandavColors.surfaceBorder),
          ),
          child: const Icon(Icons.star_rounded, color: TandavColors.yellow),
        ),
        title: Text(
          e.name,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: TandavColors.textPrimary,
          ),
        ),
        subtitle: Text(
          '${Fmt.date(e.eventDate)} · ${e.participantCount} participants',
          style: const TextStyle(color: TandavColors.textSecondary, fontSize: 12.5),
        ),
        trailing: const Icon(Icons.chevron_right_rounded,
            color: TandavColors.textMuted),
      ),
    );
  }

  Widget _studentTile(RecentStudent s) {
    return Card(
      child: ListTile(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => StudentDetailScreen(studentId: s.id)),
        ),
        leading: const CircleAvatar(
          backgroundColor: TandavColors.surfaceLight,
          child: Icon(Icons.person_rounded, color: TandavColors.gold),
        ),
        title: Text(
          s.fullName,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: TandavColors.textPrimary,
          ),
        ),
        subtitle: Text(
          s.batchName ?? 'No batch',
          style: const TextStyle(color: TandavColors.textSecondary, fontSize: 12.5),
        ),
        trailing: const Icon(Icons.chevron_right_rounded,
            color: TandavColors.textMuted),
      ),
    );
  }
}