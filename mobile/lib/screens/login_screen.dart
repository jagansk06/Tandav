import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/auth_state.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../widgets/states.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await context.read<AuthState>().login(
        _username.text.trim(),
        _password.text,
      );
    } on Exception catch (e) {
      if (mounted) {
        Alert.show(
          context,
          e.toString().replaceFirst('Exception: ', ''),
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgotPassword() async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => const _RecoveryDialog(),
    );
    if (done == true && mounted) {
      Alert.show(context, 'Password changed. You are signed in.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 84,
                      height: 84,
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
                          fontSize: 32,
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF151515),
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    const Text(
                      'TANDAV',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 9,
                        color: TandavColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Studio Management',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: TandavColors.gold,
                        fontSize: 14,
                        letterSpacing: 3,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 36),
                    TextFormField(
                      controller: _username,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Username',
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
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) => (v == null || v.isEmpty)
                          ? 'Password is required'
                          : null,
                    ),
                    const SizedBox(height: 26),
                    _busy
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        : GoldButton(
                            label: 'Sign In',
                            icon: Icons.login_rounded,
                            expanded: true,
                            onPressed: _submit,
                          ),
                    const SizedBox(height: 6),
                    TextButton(
                      onPressed: _busy ? null : _forgotPassword,
                      child: const Text(
                        'Forgot password?',
                        style: TextStyle(
                          color: TandavColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Password reset by recovery code.
///
/// There is no server, so this is the entire reset story: no email, no SMS, no
/// support queue. The code was shown once at signup and stays visible under
/// Settings → Account, and it is matched loosely — case, spaces and dashes are
/// all ignored — because being pedantic about punctuation would only ever
/// punish someone who is already locked out.
class _RecoveryDialog extends StatefulWidget {
  const _RecoveryDialog();

  @override
  State<_RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<_RecoveryDialog> {
  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    // Captured before the await so nothing reaches for a BuildContext that may
    // already have been torn down.
    final auth = context.read<AuthState>();
    final navigator = Navigator.of(context);
    try {
      await auth.resetWithRecoveryCode(_code.text, _password.text);
      navigator.pop(true);
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      Alert.show(context, e.toString().replaceFirst('Exception: ', ''),
          isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: TandavColors.surface,
      title: const Text('Reset with recovery code'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Enter the recovery code you saved when you set up this phone.',
                style: TextStyle(
                  color: TandavColors.textSecondary,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _code,
                autocorrect: false,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Recovery code',
                  hintText: 'TNDV-XXXX-XXXX',
                  prefixIcon: Icon(Icons.vpn_key_outlined),
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Recovery code is required'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'New password',
                  prefixIcon: Icon(Icons.lock_outline_rounded),
                ),
                validator: (v) => (v == null || v.length < 4)
                    ? 'Use at least 4 characters'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirm,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Confirm new password',
                  prefixIcon: Icon(Icons.lock_outline_rounded),
                ),
                validator: (v) => v == _password.text
                    ? null
                    : 'The two passwords do not match',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _busy ? null : _submit,
          child: Text(
            _busy ? 'Working…' : 'Reset',
            style: const TextStyle(color: TandavColors.gold),
          ),
        ),
      ],
    );
  }
}
