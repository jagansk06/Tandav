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

  /// The credentials baked into every copy of the app. The signup screen exists
  /// to replace them; [isFactoryDefault] is how the app knows it has not yet.
  static const factoryUsername = 'admin';
  static const factoryPassword = 'admin123';

  /// `app_settings` key holding this device's recovery code.
  static const _recoveryKey = 'account_recovery_code';

  /// Shortest password the app will accept. Low on purpose: this guards a phone
  /// that is already lock-screened, and a rule strict enough to be annoying is
  /// a rule that gets written on a sticky note next to the till.
  static const minPasswordLength = 4;

  /// True while this installation is still using the credentials that ship with
  /// every APK.
  ///
  /// Deliberately not "the users table is empty": the table is seeded on first
  /// open, so it is never empty and that test would never fire. Asking whether
  /// the factory password still works is better in two ways — a copy of the app
  /// already handed out gets prompted on its next launch instead of keeping
  /// `admin123` forever, and there is no separate flag that can drift out of
  /// step with the row it claims to describe.
  Future<bool> isFactoryDefault() async {
    final d = await _d;
    final rows = await d.query('users',
        where: 'username = ?', whereArgs: [factoryUsername], limit: 1);
    if (rows.isEmpty) return false;
    return TandavDatabase.verifyPassword(
        factoryPassword, rows.first['password_hash'] as String);
  }

  /// Turn the seeded factory account into the studio's own, and return the
  /// recovery code to show them once.
  ///
  /// The row is updated **in place** rather than deleted and re-inserted.
  /// `_seedAdminIfNeeded` recreates the factory account whenever `users` is
  /// empty, so a delete would simply race it back into existence; keeping one
  /// row also means the account id never shifts under a saved session.
  Future<String> completeSetup({
    required String username,
    required String fullName,
    required String password,
  }) async {
    final d = await _d;
    final name = username.trim();
    if (name.isEmpty) throw const RepoException('Choose a username');
    if (password.length < minPasswordLength) {
      throw const RepoException(
          'Use a password of at least $minPasswordLength characters');
    }
    // Rejected unconditionally, not just when the username stays `admin`.
    // Allowing it would leave the studio running the one password that is
    // identical in every copy of the app — and if the username were also
    // unchanged, [isFactoryDefault] would stay true and this screen would
    // reappear on every launch.
    if (password == factoryPassword) {
      throw const RepoException(
          'Pick a different password — that one ships with every copy of the '
          'app, so it is not a secret');
    }

    final rows = await d.query('users',
        where: 'username = ?', whereArgs: [factoryUsername], limit: 1);
    if (rows.isEmpty) {
      throw const RepoException('This device has already been set up');
    }

    // `username` is UNIQUE, so a clash would otherwise surface as a raw SQLite
    // constraint error in front of the customer.
    if (name != factoryUsername) {
      final clash = await d
          .query('users', where: 'username = ?', whereArgs: [name], limit: 1);
      if (clash.isNotEmpty) {
        throw RepoException('The username "$name" is already taken');
      }
    }

    final code = TandavDatabase.generateRecoveryCode();
    await d.transaction((txn) async {
      await txn.update(
        'users',
        {
          'username': name,
          'full_name': fullName.trim(),
          'password_hash': TandavDatabase.hashPassword(password),
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [rows.first['id']],
      );
      await txn.insert(
        'app_settings',
        {'key': _recoveryKey, 'value': code},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    return code;
  }

  /// This device's recovery code, or null if it was never set up.
  ///
  /// Stored in clear text on purpose. Hashing it would make it impossible to
  /// show again from Settings, and would buy nothing: the database file is not
  /// encrypted, so anyone who can read the code out of it could just as easily
  /// overwrite the password hash directly. The code defends against a forgotten
  /// password, not against someone who already holds the file.
  Future<String?> recoveryCode() async {
    final d = await _d;
    final rows = await d.query('app_settings',
        where: 'key = ?', whereArgs: [_recoveryKey], limit: 1);
    if (rows.isEmpty) return null;
    final value = rows.first['value'] as String?;
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Issue a recovery code for an account that has none.
  ///
  /// Reachable from Settings, and needed because [completeSetup] is not the only
  /// way to end up with a real password: an install that changed its password
  /// before recovery codes existed never passes through the signup screen, so it
  /// would otherwise have no way back in at all.
  ///
  /// Returns the existing code when there already is one. Never re-rolls, or it
  /// would silently invalidate a note somebody already wrote.
  Future<String> ensureRecoveryCode() async {
    final existing = await recoveryCode();
    if (existing != null) return existing;
    final d = await _d;
    final code = TandavDatabase.generateRecoveryCode();
    await d.insert(
      'app_settings',
      {'key': _recoveryKey, 'value': code},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return code;
  }

  /// Set a new password using the recovery code, and return the account it
  /// belongs to so the caller can sign straight in.
  ///
  /// The code is **not** rotated afterwards. Issuing a new one would silently
  /// invalidate the note the owner wrote months ago, at the exact moment they
  /// proved they still rely on it. It stays a permanent per-device secret,
  /// re-viewable from Settings while signed in.
  Future<User> resetWithRecoveryCode(String code, String newPassword) async {
    final stored = await recoveryCode();
    if (stored == null) {
      throw const RepoException(
          'This device has no recovery code yet — finish setting up the app '
          'first.');
    }
    final given = TandavDatabase.normalizeRecoveryCode(code);
    if (given.isEmpty ||
        given != TandavDatabase.normalizeRecoveryCode(stored)) {
      throw const RepoException(
          'That recovery code does not match this device.');
    }
    if (newPassword.length < minPasswordLength) {
      throw const RepoException(
          'Use a password of at least $minPasswordLength characters');
    }
    if (newPassword == factoryPassword) {
      throw const RepoException(
          'Pick a different password — that one ships with every copy of the '
          'app, so it is not a secret');
    }

    final d = await _d;
    final rows = await d.query('users',
        where: 'is_active = 1', orderBy: 'id', limit: 1);
    if (rows.isEmpty) {
      throw const RepoException('There is no account on this device.');
    }
    await d.update(
      'users',
      {
        'password_hash': TandavDatabase.hashPassword(newPassword),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [rows.first['id']],
    );
    return _userFromRow(rows.first);
  }

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
    if (next.length < minPasswordLength) {
      throw const RepoException(
          'Use a password of at least $minPasswordLength characters');
    }
    if (next == factoryPassword) {
      throw const RepoException(
          'Pick a different password — that one ships with every copy of the '
          'app, so it is not a secret');
    }
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