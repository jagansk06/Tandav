import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/auth_state.dart';
import '../../core/format.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../widgets/states.dart';

/// Account and recovery settings for the one local sign-in on this phone.
///
/// Two jobs, both of which used to have no home in the UI at all: changing the
/// password, and showing the recovery code again. The second matters more than
/// it looks — the code is displayed exactly once during setup, and someone who
/// closed the app at that moment, or never wrote it down, would otherwise have
/// no second chance while they still know their password.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  String? _code;
  bool _loading = true;
  bool _reveal = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<TandavApi>();
    try {
      final code = await api.auth.recoveryCode();
      if (!mounted) return;
      setState(() {
        _code = code;
        _loading = false;
      });
    } on Exception {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createRecoveryCode() async {
    setState(() => _busy = true);
    final api = context.read<TandavApi>();
    try {
      final code = await api.auth.ensureRecoveryCode();
      if (!mounted) return;
      setState(() {
        _code = code;
        // Revealed straight away: the whole point of the tap was to see it.
        _reveal = true;
      });
      Alert.show(context, 'Recovery code created — write it down');
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePassword() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final auth = context.read<AuthState>();
    try {
      await auth.changePassword(_current.text, _next.text);
      if (!mounted) return;
      _current.clear();
      _next.clear();
      _confirm.clear();
      _formKey.currentState!.reset();
      Alert.show(context, 'Password changed');
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthState>().user;
    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: _loading
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 36),
              children: [
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(title: 'Signed in as'),
                      const SizedBox(height: 6),
                      Text(
                        user?.fullName.isNotEmpty == true
                            ? user!.fullName
                            : 'This device',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: TandavColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        user?.username ?? '—',
                        style: const TextStyle(
                          color: TandavColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'This login lives only on this phone. It is never '
                        'uploaded and never sent to the other device, so the '
                        'two phones can use different passwords.',
                        style: TextStyle(
                          color: TandavColors.textMuted,
                          fontSize: 12.5,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _card(child: _recoverySection()),
                const SizedBox(height: 14),
                _card(child: _passwordSection()),
              ],
            ),
    );
  }

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        decoration: BoxDecoration(
          color: TandavColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: TandavColors.surfaceBorder),
        ),
        child: child,
      );

  Widget _recoverySection() {
    final code = _code;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Recovery code'),
        const SizedBox(height: 6),
        if (code == null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This device has no recovery code yet, which happens on an '
                'install whose password was changed before recovery codes '
                'existed. Without one, a forgotten password cannot be reset by '
                'anyone — there is no server behind this app.',
                style: TextStyle(
                  color: TandavColors.textSecondary,
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 14),
              GoldButton(
                label: 'Create a recovery code',
                icon: Icons.vpn_key_rounded,
                onPressed: _busy ? null : _createRecoveryCode,
              ),
            ],
          )
        else ...[
          const Text(
            'The only way back in if you forget your password. There is no '
            'server, so nobody can reset it for you.',
            style: TextStyle(
              color: TandavColors.textSecondary,
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 14),
          if (!_reveal)
            OutlinedButton.icon(
              onPressed: () => setState(() => _reveal = true),
              icon: const Icon(Icons.visibility_outlined, size: 18),
              label: const Text('Show recovery code'),
            )
          else ...[
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
              decoration: BoxDecoration(
                color: TandavColors.surfaceLight,
                borderRadius: BorderRadius.circular(11),
                border:
                    Border.all(color: TandavColors.gold.withValues(alpha: 0.5)),
              ),
              child: SelectableText(
                code,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                  color: TandavColors.gold,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (mounted) Alert.show(context, 'Recovery code copied');
                  },
                  icon: const Icon(Icons.copy_rounded, size: 17),
                  label: const Text('Copy'),
                ),
                TextButton.icon(
                  onPressed: () => setState(() => _reveal = false),
                  icon: const Icon(Icons.visibility_off_outlined, size: 17),
                  label: const Text('Hide'),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }

  Widget _passwordSection() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(title: 'Change password'),
          const SizedBox(height: 10),
          TextFormField(
            controller: _current,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Current password',
              prefixIcon: Icon(Icons.lock_outline_rounded),
            ),
            validator: (v) => (v == null || v.isEmpty)
                ? 'Current password is required'
                : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _next,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'New password',
              prefixIcon: Icon(Icons.lock_reset_rounded),
            ),
            validator: (v) =>
                (v == null || v.length < 4) ? 'Use at least 4 characters' : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _confirm,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Confirm new password',
              prefixIcon: Icon(Icons.lock_reset_rounded),
            ),
            validator: (v) =>
                v == _next.text ? null : 'The two passwords do not match',
          ),
          const SizedBox(height: 18),
          _busy
              ? const Center(child: CircularProgressIndicator())
              : GoldButton(
                  label: 'Change password',
                  icon: Icons.check_rounded,
                  expanded: true,
                  onPressed: _changePassword,
                ),
        ],
      ),
    );
  }
}
