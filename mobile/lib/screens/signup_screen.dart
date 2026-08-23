import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/auth_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../widgets/states.dart';

/// First-run account setup, shown instead of the login screen while the device
/// is still on the `admin` / `admin123` credentials that ship inside every APK.
///
/// Two stages, in one widget on purpose. Stage one collects the account; stage
/// two shows the recovery code and will not let go until it is acknowledged.
/// They cannot be separate routes, because releasing the setup gate is what
/// swaps this screen for the dashboard — so the gate is only released at the
/// very end, by [AuthState.finishSetup].
class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fullName = TextEditingController();
  final _username = TextEditingController(text: 'admin');
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;
  bool _busy = false;

  /// Non-null once the account exists. Its presence is what switches this
  /// screen to stage two.
  String? _code;
  bool _acknowledged = false;

  @override
  void dispose() {
    _fullName.dispose();
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _createAccount() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final auth = context.read<AuthState>();
    try {
      final code = await auth.completeSetup(
        username: _username.text,
        fullName: _fullName.text,
        password: _password.text,
      );
      if (!mounted) return;
      setState(() => _code = code);
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enter() async {
    setState(() => _busy = true);
    final auth = context.read<AuthState>();
    try {
      // This is the call that releases the gate, so it happens only after the
      // recovery code has been seen and acknowledged.
      await auth.finishSetup(_username.text, _password.text);
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
            isError: true);
      }
    }
    // No `finally`: on success this widget is already gone from the tree.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: _code == null ? _buildForm() : _buildRecoveryCode(),
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- stage one ---

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Crest(),
          const SizedBox(height: 22),
          const Text(
            'Set up your studio',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: TandavColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'This account stays on this phone. It is never uploaded and never '
            'shared with the other device.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: TandavColors.textSecondary,
              fontSize: 13,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 28),
          TextFormField(
            controller: _fullName,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Your name',
              prefixIcon: Icon(Icons.badge_outlined),
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Your name is required' : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _username,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Username',
              helperText: 'What you type to sign in',
              prefixIcon: Icon(Icons.person_outline_rounded),
            ),
            validator: (v) => (v == null || v.trim().isEmpty)
                ? 'Username is required'
                : null,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _password,
            obscureText: _obscure,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'New password',
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(
                icon: Icon(_obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            validator: (v) {
              if (v == null || v.length < 4) {
                return 'Use at least 4 characters';
              }
              if (v == 'admin123') {
                return 'Pick something else — every copy of the app ships '
                    'with this one';
              }
              return null;
            },
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _confirm,
            obscureText: _obscure,
            onFieldSubmitted: (_) => _createAccount(),
            decoration: const InputDecoration(
              labelText: 'Confirm password',
              prefixIcon: Icon(Icons.lock_outline_rounded),
            ),
            validator: (v) =>
                v == _password.text ? null : 'The two passwords do not match',
          ),
          const SizedBox(height: 26),
          _busy
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(child: CircularProgressIndicator()),
                )
              : GoldButton(
                  label: 'Create account',
                  icon: Icons.arrow_forward_rounded,
                  expanded: true,
                  onPressed: _createAccount,
                ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- stage two ---

  Widget _buildRecoveryCode() {
    final code = _code!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.vpn_key_rounded, color: TandavColors.gold, size: 46),
        const SizedBox(height: 18),
        const Text(
          'Write this down',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w900,
            color: TandavColors.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'This is your recovery code. It is the only way back in if you '
          'forget your password — there is no server to reset it for you.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: TandavColors.textSecondary,
            fontSize: 13.5,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
          decoration: BoxDecoration(
            color: TandavColors.surfaceLight,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: TandavColors.gold.withValues(alpha: 0.55)),
          ),
          child: Column(
            children: [
              SelectableText(
                code,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 25,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.5,
                  color: TandavColors.gold,
                ),
              ),
              const SizedBox(height: 14),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: code));
                  if (mounted) Alert.show(context, 'Recovery code copied');
                },
                icon: const Icon(Icons.copy_rounded, size: 17),
                label: const Text('Copy'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'Keep it somewhere that is not this phone. If the phone is lost, a '
          'code saved only on it is lost with it.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: TandavColors.textMuted,
            fontSize: 12.5,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'You can see it again any time under Settings → Account.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: TandavColors.textMuted,
            fontSize: 12.5,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 14),
        _AcknowledgeTile(
          value: _acknowledged,
          onChanged: (v) => setState(() => _acknowledged = v ?? false),
        ),        const SizedBox(height: 14),
        _busy
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator()),
              )
            : GoldButton(
                label: 'Start using Tandav',
                icon: Icons.login_rounded,
                expanded: true,
                onPressed: _acknowledged ? _enter : null,
              ),
      ],
    );
  }
}

/// The "I have written it down" gate. Unchecked by default on purpose, so
/// getting past this screen takes one conscious tap rather than a reflex.
class _AcknowledgeTile extends StatelessWidget {
  const _AcknowledgeTile({
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Checkbox(
              value: value,
              onChanged: onChanged,
              activeColor: TandavColors.gold,
              checkColor: const Color(0xFF151515),
            ),
            const Expanded(
              child: Text(
                'I have written my recovery code down',
                style: TextStyle(
                  color: TandavColors.textPrimary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The gold "T" badge, matching the login screen.
class _Crest extends StatelessWidget {
  const _Crest();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 76,
        height: 76,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: GoldGradient.linear,
          boxShadow: [
            BoxShadow(
              color: TandavColors.gold.withValues(alpha: 0.25),
              blurRadius: 30,
            ),
          ],
        ),
        child: const Text(
          'T',
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w900,
            color: Color(0xFF151515),
          ),
        ),
      ),
    );
  }
}
