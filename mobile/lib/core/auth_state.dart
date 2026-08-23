import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user.dart';
import 'services.dart';

/// Local admin session management.
///
/// - Credentials are verified against the SQLite `users` table (salted
///   SHA-256 hashes — no plaintext storage).
/// - The session is remembered in shared_preferences so the admin stays
///   logged in across app closes, restarts and recent-apps removal until
///   they explicitly sign out.
class AuthState extends ChangeNotifier {
  static const _sessionKey = 'tandav_session';

  final TandavApi api;
  User? _user;
  bool _initialized = false;
  bool _needsSetup = false;
  int _reloadToken = 0;

  AuthState({required this.api});

  User? get user => _user;
  bool get isLoggedIn => _user != null;
  bool get initialized => _initialized;

  /// True while this device is still on the credentials every APK ships with,
  /// which is what puts the signup screen in front of everything else.
  bool get needsSetup => _needsSetup;

  /// Bumped when the database is restored from a backup so [RootGate]
  /// rebuilds the whole shell against the fresh data.
  int get reloadToken => _reloadToken;

  Future<void> init() async {
    if (_initialized) return;
    _needsSetup = await api.auth.isFactoryDefault();
    final prefs = await SharedPreferences.getInstance();
    final session = prefs.getString(_sessionKey);
    if (_needsSetup) {
      // A saved session from a factory-password install must not skip setup —
      // it would leave `admin123` in place on a phone that looks configured.
      await prefs.remove(_sessionKey);
      _initialized = true;
      notifyListeners();
      return;
    }
    if (session != null) {
      try {
        final map = jsonDecode(session) as Map<String, dynamic>;
        final saved = User.fromJson(map);
        // Confirm the account still exists locally before restoring the
        // session.
        final fresh = await api.auth.findUser(saved.username);
        if (fresh != null && fresh.isActive) {
          _user = fresh;
        }
      } catch (_) {
        _user = null;
      }
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> login(String username, String password) async {
    final user = await api.auth.verifyLogin(username, password);
    if (user == null) {
      throw const AuthException('Invalid username or password');
    }
    _user = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _sessionKey,
        jsonEncode({
          'id': user.id,
          'username': user.username,
          'full_name': user.fullName,
          'email': user.email,
          'is_active': user.isActive,
        }));
    notifyListeners();
  }

  Future<void> logout() async {
    _user = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionKey);
    notifyListeners();
  }

  Future<void> changePassword(String current, String next) async {
    final username = _user?.username;
    if (username == null) throw const AuthException('Not logged in');
    await api.auth.changePassword(username, current, next);
  }

  /// Write the studio's own account over the factory one and return the recovery
  /// code.
  ///
  /// Deliberately does **not** clear [needsSetup] or sign in. Both of those
  /// would make [RootGate] rebuild immediately and replace the signup screen
  /// before it ever got to show the recovery code — the one moment the owner is
  /// told it exists. [finishSetup] is what releases the gate, once they have
  /// acknowledged it.
  Future<String> completeSetup({
    required String username,
    required String fullName,
    required String password,
  }) =>
      api.auth.completeSetup(
        username: username,
        fullName: fullName,
        password: password,
      );

  /// Release the setup gate and sign in. Called after the recovery code has
  /// been acknowledged.
  Future<void> finishSetup(String username, String password) async {
    _needsSetup = false;
    await login(username.trim(), password);
  }

  /// Set a new password from the recovery code and sign straight in, so someone
  /// who has just proved ownership is not made to type the password again.
  Future<void> resetWithRecoveryCode(String code, String newPassword) async {
    final account = await api.auth.resetWithRecoveryCode(code, newPassword);
    await login(account.username, newPassword);
  }

  /// Called after a backup restore so the UI rebuilds from scratch.
  ///
  /// The setup gate is re-evaluated rather than assumed: a backup taken before
  /// this device was ever set up would put the factory password back, and
  /// carrying on with the old session would leave `admin123` live on a phone
  /// that looks configured.
  Future<void> notifyDatabaseRestored() async {
    _reloadToken++;
    _needsSetup = await api.auth.isFactoryDefault();
    if (_needsSetup) {
      _user = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sessionKey);
    }
    notifyListeners();
  }
}

class AuthException implements Exception {
  final String message;
  const AuthException(this.message);

  @override
  String toString() => message;
}