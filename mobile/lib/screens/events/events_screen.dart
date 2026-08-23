import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services.dart';
import '../../core/theme.dart';
import '../../models/event.dart';
import '../../widgets/states.dart';
import 'event_detail_screen.dart';
import 'event_form_screen.dart';

class EventsScreen extends StatefulWidget {
  const EventsScreen({super.key});

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  late Future<EventListResponse> _future;
  bool _upcomingOnly = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<EventListResponse> _load() {
    return context.read<TandavApi>().getEvents(
          q: _query,
          upcomingOnly: _upcomingOnly,
        );
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _openForm() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const EventFormScreen()),
    );
    if (mounted) _reload();
  }

  Future<void> _openDetail(EventItem e) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EventDetailScreen(eventId: e.id)),
    );
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: (v) {
                      _query = v.trim();
                      _reload();
                    },
                    decoration: const InputDecoration(
                      hintText: 'Search events…',
                      prefixIcon: Icon(Icons.search_rounded),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('Upcoming'),
                  selected: _upcomingOnly,
                  onSelected: (v) {
                    setState(() => _upcomingOnly = v);
                    _reload();
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<EventListResponse>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const LoadingView(message: 'Loading events…');
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
                    icon: Icons.event_busy_outlined,
                    title: _upcomingOnly
                        ? 'No upcoming events'
                        : 'No events yet',
                    subtitle: _upcomingOnly
                        ? 'All events have passed. Clear the filter to see them.'
                        : 'Create an event to manage performances, competitions and showcases.',
                    action: OutlinedButton.icon(
                      onPressed: _openForm,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Create Event'),
                    ),
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async => _reload(),
                  color: TandavColors.gold,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: list.items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (ctx, i) => _eventCard(list.items[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openForm,
        backgroundColor: TandavColors.gold,
        foregroundColor: const Color(0xFF141414),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Event'),
      ),
    );
  }

  Widget _eventCard(EventItem e) {
    final date = DateTime.tryParse(e.eventDate);
    final isUpcoming = date != null &&
        !date.isBefore(DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day));
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openDetail(e),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  gradient: GoldGradient.linear,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      date != null ? '${date.day}' : '—',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF242000),
                        height: 1,
                      ),
                    ),
                    Text(
                      date != null
                          ? const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                              'Jul', 'Aug', 'Sep', 'Oct', 'Nov',
                              'Dec'][date.month - 1]
                          : '',
                      style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF4A3A00),
                        height: 1.2,
                      ),
                    ),
                  ],
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
                            e.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              color: TandavColors.textPrimary,
                            ),
                          ),
                        ),
                        if (!isUpcoming) ...[
                          const SizedBox(width: 6),
                          const StatusBadge(status: 'inactive', label: 'Past'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      [
                        if (e.eventType.isNotEmpty) e.eventType,
                        if (e.location != null) e.location!,
                        '${e.participantCount} participants',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12.5, color: TandavColors.textSecondary),
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