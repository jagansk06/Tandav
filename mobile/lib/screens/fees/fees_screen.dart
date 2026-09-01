import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_role.dart';
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
  ///
  /// For an unpaid fee with a studio UPI ID configured, the reminder embeds a
  /// tap-to-pay `upi://pay` link so the student can settle from their own
  /// phone. Because a local app gets no payment callback, the admin is then
  /// asked whether the payment went through — choosing "yes" marks the fee paid
  /// rather than trusting the UPI app blindly.
  Future<void> _sendWhatsApp(Fee f) async {
    final api = context.read<TandavApi>();
    setState(() => _busyFeeId = f.id);
    try {
      final student = await api.getStudent(f.studentId);
      final isPaid = f.status == 'paid';
      String? upiLink;
      if (!isPaid) {
        final vpa = await api.getUpiVpa();
        if (vpa != null) {
          upiLink = WhatsAppService.upiPayLink(
            vpa: vpa,
            payee: await api.getUpiPayee(),
            amount: f.outstanding,
            note: '${student.fullName} · fee ${Fmt.monthLabel(f.month)}',
          );
        }
      }
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
              upiLink: upiLink,
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
      // For an unpaid fee sent with a UPI pay link, offer to mark the fee paid
      // once the student confirms. Never offered for receipts or when the fee
      // is already paid.
      if (!isPaid && upiLink != null) {
        await _confirmUpiPayment(f, student.fullName, api);
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

  /// Ask the owner whether the student paid after the UPI reminder went out.
  /// Marking it paid here updates the fee record to `paid` (the check-mark on
  /// the student's fee details), optionally followed by a WhatsApp receipt.
  Future<void> _confirmUpiPayment(
      Fee f, String studentName, TandavApi api) async {
    final mark = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: TandavColors.surface,
      isScrollControlled: true,
      builder: (_) => _UpiFlowSheet(fee: f, studentName: studentName),
    );
    if (!mounted || mark == null || !mark) return;
    setState(() => _busyFeeId = f.id);
    try {
      await api.markFeePaid(f.id);
      if (!mounted) return;
      Alert.show(context, '${f.studentName} — fee marked PAID');
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
                  initialValue: _batchId,
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
            // The month's expected, collected and outstanding money — the
            // studio's takings in three numbers. Withheld from the attender
            // build for the same reason the Dashboard and Monthly Reports are:
            // his job is recording what each student owes and has paid, one
            // student at a time, and the register below gives him exactly that.
            // The totals are the owners' business.
            //
            // The counts row survives on both builds. "5 due" is how he knows
            // there is still work in this month; it says nothing about revenue.
            if (!isAttenderBuild) ...[
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
            ],
            Row(
              children: [
                Text(
                  '${s.paidCount} paid · ${s.partialCount} partial · ${s.dueCount} due'
                  '${s.totalRecords > 0 ? ' · ${s.totalRecords} students' : ''}',
                  style: const TextStyle(
                      fontSize: 12, color: TandavColors.textSecondary),
                ),
                const Spacer(),
                if (!isAttenderBuild)
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

/// Bottom sheet shown right after a reminder with a UPI pay link is sent. It
/// asks the owner to confirm whether the student actually paid, because the
/// app can't hear back from the UPI app. "Mark as paid" pops true (which marks
/// the fee paid in the student's fee details); "Not paid yet" pops false.
class _UpiFlowSheet extends StatelessWidget {
  final Fee fee;
  final String studentName;
  const _UpiFlowSheet({required this.fee, required this.studentName});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.qr_code_2_rounded,
                    color: TandavColors.gold, size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'UPI payment sent to $studentName',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                          color: TandavColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${Fmt.money(fee.outstanding)} due · '
                        '${Fmt.monthLabel(fee.month)}',
                        style: const TextStyle(
                          fontSize: 13,
                          color: TandavColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'The reminder opened WhatsApp with a tap-to-pay UPI link for the '
              'student. Did they complete the payment?',
              style: TextStyle(
                color: TandavColors.textSecondary,
                fontSize: 13,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: const Text('Not paid yet'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: TandavColors.textSecondary,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GoldButton(
                    label: 'Mark as paid',
                    icon: Icons.check_rounded,
                    onPressed: () => Navigator.pop(context, true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}