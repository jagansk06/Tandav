import 'package:sqflite/sqflite.dart';

import '../database/tandav_database.dart';
import '../database/db_helpers.dart';
import '../models/user.dart';

/// Local authentication: users live in SQLite (hashed passwords, no
/// plaintext). The "session" is persisted by [AuthState] using
/// shared_preferences; this repository only verifies credentials and
/// manages the account row.
class AuthRepository {
  final TandavDatabase db;
  AuthRepository(this.db);

  Future<Database> get _d => db.open();

  Future<User?> findUser(String username) async {
    final d = await _d;
    final rows = await d.query('users',
        where: 'username = ? AND is_active = 1',
        whereArgs: [username.trim()],
        limit: 1);
    if (rows.isEmpty) return null;
    return _userFromRow(rows.first);
  }

  Future<User?> verifyLogin(String username, String password) async {
    final d = await _d;
    final rows = await d.query('users',
        where: 'username = ? AND is_active = 1',
        whereArgs: [username.trim()],
        limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    final ok = TandavDatabase.verifyPassword(password, row['password_hash'] as String);
    return ok ? _userFromRow(row) : null;
  }

  Future<void> changePassword(String username, String current, String next) async {
    final d = await _d;
    final rows = await d.query('users',
        where: 'username = ?', whereArgs: [username.trim()], limit: 1);
    if (rows.isEmpty) throw const RepoException('User not found');
    final row = rows.first;
    if (!TandavDatabase.verifyPassword(
        current, row['password_hash'] as String)) {
      throw const RepoException('Current password is incorrect');
    }
    if (next.isEmpty) throw const RepoException('Password cannot be empty');
    await d.update('users', {
      'password_hash': TandavDatabase.hashPassword(next),
      'updated_at': DateTime.now().toIso8601String(),
    }, where: 'id = ?', whereArgs: [row['id']]);
  }

  User _userFromRow(Map<String, Object?> row) => User(
        id: row['id'] as int,
        username: row['username'] as String,
        fullName: (row['full_name'] as String?) ?? '',
        email: row['email'] as String?,
        isActive: (row['is_active'] as int? ?? 1) == 1,
      );
}