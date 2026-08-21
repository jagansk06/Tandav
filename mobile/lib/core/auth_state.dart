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
  int _reloadToken = 0;

  AuthState({required this.api});

  User? get user => _user;
  bool get isLoggedIn => _user != null;
  bool get initialized => _initialized;

  /// Bumped when the database is restored from a backup so [RootGate]
  /// rebuilds the whole shell against the fresh data.
  int get reloadToken => _reloadToken;

  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final session = prefs.getString(_sessionKey);
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

  /// Called after a backup restore so the UI rebuilds from scratch.
  void notifyDatabaseRestored() {
    _reloadToken++;
    notifyListeners();
  }
}

class AuthException implements Exception {
  final String message;
  const AuthException(this.message);

  @override
  String toString() => message;
}