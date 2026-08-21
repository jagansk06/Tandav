import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../core/whatsapp.dart';
import '../../models/batch.dart';
import '../../models/fee.dart';
import '../../widgets/states.dart';
import '../attendance/monthly_attendance_screen.dart';
import 'fee_payment_sheet.dart';

/// Monthly fee register: every active student with their current month's
/// fee status and one-tap Mark Paid / Mark Due actions.
class FeesScreen extends StatefulWidget {
  const FeesScreen({super.key});

  @override
  State<FeesScreen> createState() => _FeesScreenState();
}

class _FeesScreenState extends State<FeesScreen> {
  List<Batch> _batches = [];
  int? _batchId;
  DateTime _month = DateTime.now();
  String? _statusFilter;
  final _searchCtrl = TextEditingController();
  String _query = '';
  int? _busyFeeId;
  late Future<FeeListResponse> _feesFuture;
  late Future<FeeSummary> _summaryFuture;

  @override
  void initState() {
    super.initState();
    _loadBatches();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  String get _iso =>
      '${_month.year.toString().padLeft(4, '0')}-${_month.month.toString().padLeft(2, '0')}-01';

  Future<void> _loadBatches() async {
    try {
      final res = await context.read<TandavApi>().getBatches();
      if (mounted) setState(() => _batches = res.items);
    } catch (_) {}
    _reload();
  }

  void _reload() {
    final api = context.read<TandavApi>();
    setState(() {
      _feesFuture = api.getFees(
        month: _iso,
        batchId: _batchId,
        status: _statusFilter,
        q: _query,
      );
      _summaryFuture = api.getFeeSummary(_iso, batchId: _batchId);
    });
  }

  Future<void> _pickMonth() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _month,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      helpText: 'Select month',
    );
    if (picked != null) {
      setState(() => _month = picked);
      _reload();
    }
  }

  Future<void> _toggleFee(Fee f) async {
    final api = context.read<TandavApi>();
    final isPaid = f.status == 'paid';
    setState(() => _busyFeeId = f.id);
    try {
      if (isPaid) {
        await api.markFeeDue(f.id);
        if (!mounted) return;
        Alert.show(context, '${f.studentName} — fee marked DUE');
      } else {
        await api.markFeePaid(f.id);
        if (!mounted) return;
        Alert.show(context, '${f.studentName} — fee marked PAID');
      }
      _reload();
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _busyFeeId = null);
    }
  }

  /// Open WhatsApp with a pre-filled receipt/reminder for this fee. This
  /// action is completely separate from the database status update — the fee
  /// record is never touched here, so the admin can send (or re-send) the
  /// message later without changing the status.
  Future<void> _sendWhatsApp(Fee f) async {
    final api = context.read<TandavApi>();
    setState(() => _busyFeeId = f.id);
    try {
      final student = await api.getStudent(f.studentId);
      final isPaid = f.status == 'paid';
      final message = isPaid
          ? WhatsAppService.receiptMessage(
              studentName: student.fullName,
              monthLabel: Fmt.monthLabel(f.month),
              amount: f.paidValue,
            )
          : WhatsAppService.reminderMessage(
              studentName: student.fullName,
              monthLabel: Fmt.monthLabel(f.month),
              amountDue: f.outstanding,
            );
      final result =
          await WhatsAppService.openChat(number: student.phone, message: message);
      if (!mounted) return;
      switch (result) {
        case WhatsAppOpenResult.invalidNumber:
          Alert.show(
            context,
            'Student does not have a valid mobile number for WhatsApp.',
            isError: true,
          );
        case WhatsAppOpenResult.notInstalled:
          Alert.show(
            context,
            'Unable to open WhatsApp. Please make sure WhatsApp is installed.',
            isError: true,
          );
        case WhatsAppOpenResult.launched:
          break;
      }
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _busyFeeId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      color: TandavColors.gold,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int?>(
                  value: _batchId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Batch',
                    prefixIcon: Icon(Icons.grid_view_outlined),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                  items: [
                    const DropdownMenuItem<int?>(
                        value: null, child: Text('All batches')),
                    ..._batches.map(
                      (b) => DropdownMenuItem<int?>(
                        value: b.id,
                        child:
                            Text(b.name, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() => _batchId = v);
                    _reload();
                  },
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _pickMonth,
                icon: const Icon(Icons.calendar_month_outlined, size: 18),
                label: Text(Fmt.monthLabel(_iso)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _searchCtrl,
            onChanged: (v) {
              _query = v.trim();
              _reload();
            },
            decoration: InputDecoration(
              hintText: 'Search student…',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        _searchCtrl.clear();
                        _query = '';
                        _reload();
                      },
                    ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 8,
                  children: [
                    for (final (value, label) in [
                      (null, 'All'),
                      ('due', 'Due'),
                      ('partial', 'Partial'),
                      ('paid', 'Paid'),
                    ])
                      ChoiceChip(
                        label: Text(label),
                        selected: _statusFilter == value,
                        onSelected: (_) {
                          setState(() => _statusFilter = value);
                          _reload();
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const MonthlyAttendanceScreen()),
                ),
                icon: const Icon(Icons.calculate_outlined, size: 17),
                label: const Text('Monthly Attendance'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FutureBuilder<FeeSummary>(
            future: _summaryFuture,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const SizedBox(height: 120, child: LoadingView());
              }
              return _summaryCard(snapshot.data!);
            },
          ),
          const SectionHeader(title: 'Student Fee Register'),
          FutureBuilder<FeeListResponse>(
            future: _feesFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SizedBox(height: 200, child: LoadingView());
              }
              if (snapshot.hasError) {
                return ErrorView(
                  message: snapshot.error.toString(),
                  onRetry: _reload,
                );
              }
              final list = snapshot.data!;
              if (list.items.isEmpty) {
                return const EmptyView(
                  icon: Icons.receipt_long_outlined,
                  title: 'No students in this list',
                  subtitle: 'Add students or pick another month.',
                );
              }
              return Column(
                children: list.items
                    .map((f) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _feeTile(f),
                        ))
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(FeeSummary s) {
    final pct = s.dueValue == 0 ? 0.0 : (s.collectionRate);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _sum('Expected',
                      Fmt.money(double.tryParse(s.totalDue) ?? 0)),
                ),
                Expanded(
                  child:
                      _sum('Collected', Fmt.money(double.tryParse(s.totalPaid) ?? 0)),
                ),
                Expanded(
                  child: _sum('Pending',
                      Fmt.money(double.tryParse(s.outstanding) ?? 0),
                      color: TandavColors.danger),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (pct / 100).clamp(0, 1),
                minHeight: 8,
                backgroundColor: TandavColors.surfaceBorder,
                valueColor: const AlwaysStoppedAnimation(TandavColors.gold),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  '${s.paidCount} paid · ${s.partialCount} partial · ${s.dueCount} due'
                  '${s.totalRecords > 0 ? ' · ${s.totalRecords} students' : ''}',
                  style: const TextStyle(
                      fontSize: 12, color: TandavColors.textSecondary),
                ),
                const Spacer(),
                Text(
                  '${pct.toStringAsFixed(1)}% collected',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: TandavColors.gold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sum(String label, String value, {Color color = TandavColors.textPrimary}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: TandavColors.textMuted,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w900,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _feeTile(Fee f) {
    final isPaid = f.status == 'paid';
    return Card(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            onTap: isPaid
                ? null
                : () => _openPayment(f),
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: TandavColors.surfaceLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.currency_rupee_rounded,
                  color: TandavColors.gold, size: 20),
            ),
            title: Text(
              f.studentName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14.5,
                color: TandavColors.textPrimary,
              ),
            ),
            subtitle: Text(
              '${Fmt.money(f.dueValue)} monthly'
              '${isPaid && f.paymentDate != null ? ' · Paid on ${Fmt.date(f.paymentDate)}' : ''}',
              style: const TextStyle(
                  fontSize: 12.5, color: TandavColors.textSecondary),
            ),
            trailing: _busyFeeId == f.id
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StatusBadge(status: f.status),
                      const SizedBox(width: 8),
                      isPaid
                          ? OutlinedButton.icon(
                              onPressed: () => _toggleFee(f),
                              icon: const Icon(Icons.rotate_left_rounded, size: 16),
                              label: const Text('Mark Due'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: TandavColors.danger,
                                side: const BorderSide(color: TandavColors.danger),
                                visualDensity: VisualDensity.compact,
                              ),
                            )
                          : OutlinedButton.icon(
                              onPressed: () => _toggleFee(f),
                              icon: const Icon(Icons.check_rounded, size: 16),
                              label: const Text('Mark Paid'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: TandavColors.gold,
                                side: const BorderSide(color: TandavColors.gold),
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                    ],
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busyFeeId == f.id ? null : () => _sendWhatsApp(f),
                icon: Icon(Icons.chat_outlined,
                    size: 16, color: WhatsAppService.accent),
                label: Text(
                  isPaid ? 'Send WhatsApp Receipt' : 'Send WhatsApp Reminder',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: WhatsAppService.accent,
                  side: const BorderSide(color: WhatsAppService.accent),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openPayment(Fee f) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: TandavColors.surface,
      isScrollControlled: true,
      builder: (_) => FeePaymentSheet(fee: f),
    );
    _reload();
  }
}