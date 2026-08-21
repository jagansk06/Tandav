import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// Single source of truth for the local Tandav SQLite database.
///
/// - Versioned schema with forward migrations (`onUpgrade`).
/// - Foreign keys enforced via PRAGMA.
/// - Seeds the default admin account on first creation.
/// - Injectable [factory]/[overridePath] so tests can use an in-memory or
///   temp-file database via sqflite_common_ffi.
class TandavDatabase {
  TandavDatabase._();

  static final TandavDatabase instance = TandavDatabase._();

  static const dbName = 'tandav.db';
  static const dbVersion = 2;

  /// Business tables that participate in two-device synchronization.
  /// `users`, `app_settings` and `sync_state` are deliberately excluded.
  static const syncTables = [
    'batches',
    'students',
    'attendance',
    'monthly_attendance',
    'fees',
    'fee_payments',
    'events',
    'event_participations',
    'monthly_progress',
  ];

  /// Tables that existed at schema version 1 without an `updated_at` column
  /// (they relied on `marked_at` / `created_at` / `registered_at`).
  static const _tablesMissingUpdatedAt = [
    'attendance',
    'fee_payments',
    'event_participations',
  ];

  DatabaseFactory? _factory;
  String? _overridePath;
  Database? _db;
  bool _seeded = false;
  String? _deviceId;

  static final Uuid _uuid = Uuid();

  /// This installation's persistent device id (`TANDAV-XXXX`), resolved when
  /// the database is opened. Always non-null after [open].
  String get deviceId => _deviceId ?? 'TANDAV-????';

  /// New random UUID v4 used as the stable identity for a synchronized record.
  static String generateSyncUuid() => _uuid.v4();

  void configureForTest({DatabaseFactory? factory, String? overridePath}) {
    _factory = factory;
    _overridePath = overridePath;
  }

  DatabaseFactory get _databaseFactory => _factory ?? databaseFactory;

  Future<String> _resolvePath() async {
    if (_overridePath != null) return _overridePath!;
    final dir = await getDatabasesPath();
    return p.join(dir, dbName);
  }

  Future<Directory> get photosDir async {
    final dir = Directory(p.join(await _docsRoot, 'photos'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> get backupsDir async {
    final dir = Directory(p.join(await _docsRoot, 'TandavBackups'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// App documents root; falls back to the test database directory when a
  /// test override path is configured (path_provider is unavailable there).
  Future<String> get _docsRoot async => _overridePath != null
      ? p.dirname(_overridePath!)
      : p.dirname((await getApplicationDocumentsDirectory()).path);

  Future<Database> open() async {
    if (_db != null && _db!.isOpen) return _db!;
    final path = await _resolvePath();
    _db = await _databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: dbVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    await _seedAdminIfNeeded();
    _deviceId = await _ensureSyncState(_db!);
    return _db!;
  }

  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();
    batch.execute('''
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT NOT NULL UNIQUE,
        full_name TEXT NOT NULL DEFAULT '',
        email TEXT,
        password_hash TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      )
    ''');
    batch.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
    batch.execute('''
      CREATE TABLE batches (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        dance_style TEXT NOT NULL DEFAULT '',
        level TEXT NOT NULL DEFAULT '',
        schedule TEXT NOT NULL DEFAULT '',
        monthly_fee REAL NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 1,
        notes TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now'))
      )
    ''');
    batch.execute('''
      CREATE TABLE students (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        first_name TEXT NOT NULL,
        last_name TEXT NOT NULL DEFAULT '',
        gender TEXT NOT NULL DEFAULT '',
        dob TEXT,
        phone TEXT NOT NULL DEFAULT '',
        email TEXT,
        address TEXT,
        emergency_contact_name TEXT,
        emergency_contact_phone TEXT,
        batch_id INTEGER,
        monthly_fee REAL NOT NULL DEFAULT 0,
        join_date TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        photo_url TEXT,
        notes TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now')),
        FOREIGN KEY (batch_id) REFERENCES batches(id) ON DELETE SET NULL
      )
    ''');
    batch.execute('CREATE INDEX idx_students_batch ON students(batch_id)');
    batch.execute('CREATE INDEX idx_students_active ON students(is_active)');
    batch.execute('''
      CREATE TABLE attendance (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        student_id INTEGER NOT NULL,
        batch_id INTEGER,
        attendance_date TEXT NOT NULL,
        status TEXT NOT NULL,
        notes TEXT,
        marked_at TEXT NOT NULL DEFAULT (datetime('now')),
        UNIQUE (student_id, attendance_date),
        FOREIGN KEY (student_id) REFERENCES students(id) ON DELETE CASCADE,
        FOREIGN KEY (batch_id) REFERENCES batches(id) ON DELETE CASCADE
      )
    ''');
    batch.execute('CREATE INDEX idx_attendance_student ON attendance(student_id)');
    batch.execute('CREATE INDEX idx_attendance_date ON attendance(attendance_date)');
    batch.execute('''
      CREATE TABLE monthly_attendance (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        student_id INTEGER NOT NULL,
        month TEXT NOT NULL,
        total_classes INTEGER NOT NULL DEFAULT 0,
        presents INTEGER NOT NULL DEFAULT 0,
        absents INTEGER NOT NULL DEFAULT 0,
        lates INTEGER NOT NULL DEFAULT 0,
        percentage REAL NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL DEFAULT (datetime('now')),
        UNIQUE (student_id, month),
        FOREIGN KEY (student_id) REFERENCES students(id) ON DELETE CASCADE
      )
    ''');
    batch.execute('CREATE INDEX idx_monthly_att_student ON monthly_attendance(student_id)');
    batch.execute('''
      CREATE TABLE fees (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        student_id INTEGER NOT NULL,
        month TEXT NOT NULL,
        amount_due REAL NOT NULL DEFAULT 0,
        amount_paid REAL NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'due',
        payment_date TEXT,
        payment_method TEXT,
        notes TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now')),
        UNIQUE (student_id, month),
        FOREIGN KEY (student_id) REFERENCES students(id) ON DELETE CASCADE
      )
    ''');
    batch.execute('CREATE INDEX idx_fees_student ON fees(student_id)');
    batch.execute('CREATE INDEX idx_fees_month ON fees(month)');
    batch.execute('''
      CREATE TABLE fee_payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        fee_id INTEGER NOT NULL,
        student_id INTEGER NOT NULL,
        amount REAL NOT NULL,
        payment_date TEXT NOT NULL,
        payment_method TEXT NOT NULL DEFAULT 'cash',
        notes TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        FOREIGN KEY (fee_id) REFERENCES fees(id) ON DELETE CASCADE,
        FOREIGN KEY (student_id) REFERENCES students(id) ON DELETE CASCADE
      )
    ''');
    batch.execute('CREATE INDEX idx_fee_payments_fee ON fee_payments(fee_id)');
    batch.execute('''
      CREATE TABLE events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        description TEXT,
        event_type TEXT NOT NULL DEFAULT '',
        event_date TEXT NOT NULL,
        location TEXT,
        batch_id INTEGER,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at TEXT NOT NULL DEFAULT (datetime('now')),
        FOREIGN KEY (batch_id) REFERENCES batches(id) ON DELETE SET NULL
      )
    ''');
    batch.execute('CREATE INDEX idx_events_date ON events(event_date)');
    batch.execute('''
      CREATE TABLE event_participations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        event_id INTEGER NOT NULL,
        student_id INTEGER NOT NULL,
        source TEXT NOT NULL DEFAULT 'individual',
        is_costume_required INTEGER NOT NULL DEFAULT 0,
        costume_fee_due REAL NOT NULL DEFAULT 0,
        costume_fee_paid REAL NOT NULL DEFAULT 0,
        costume_status TEXT NOT NULL DEFAULT 'none',
        costume_paid_date TEXT,
        costume_payment_method TEXT,
        notes TEXT,
        registered_at TEXT NOT NULL DEFAULT (datetime('now')),
        UNIQUE (event_id, student_id),
        FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE,
        FOREIGN KEY (student_id) REFERENCES students(id) ON DELETE CASCADE
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_participations_event ON event_participations(event_id)');
    batch.execute(
        'CREATE INDEX idx_participations_student ON event_participations(student_id)');
    batch.execute('''
      CREATE TABLE monthly_progress (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        student_id INTEGER NOT NULL,
        month TEXT NOT NULL,
        skill_rating INTEGER NOT NULL DEFAULT 0,
        performance_rating INTEGER NOT NULL DEFAULT 0,
        discipline_rating INTEGER NOT NULL DEFAULT 0,
        attendance_percentage REAL,
        remarks TEXT,
        updated_at TEXT NOT NULL DEFAULT (datetime('now')),
        UNIQUE (student_id, month),
        FOREIGN KEY (student_id) REFERENCES students(id) ON DELETE CASCADE
      )
    ''');
    batch.execute(
        'CREATE INDEX idx_progress_student ON monthly_progress(student_id)');
    batch.execute('''
      CREATE TABLE sync_state (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
    await batch.commit(noResult: true);

    // The business tables were created above at schema v2 without sync
    // columns; add them now (same helper used by the v1->v2 migration).
    for (final table in syncTables) {
      await _addSyncColumns(db, table);
    }
    await _ensureSyncState(db);
  }

  /// Add synchronization metadata columns to a business table. Used both when
  /// the schema is created fresh (v2) and when an existing v1 database is
  /// upgraded, so the upgrade path and the fresh path stay byte-identical.
  static Future<void> _addSyncColumns(DatabaseExecutor db, String table) async {
    await db.execute(
        "ALTER TABLE $table ADD COLUMN sync_uuid TEXT NOT NULL DEFAULT ''");
    await db.execute(
        "ALTER TABLE $table ADD COLUMN device_id TEXT NOT NULL DEFAULT ''");
    await db.execute('ALTER TABLE $table ADD COLUMN deleted_at TEXT');
    if (_tablesMissingUpdatedAt.contains(table)) {
      await db.execute("ALTER TABLE $table ADD COLUMN updated_at TEXT NOT NULL DEFAULT ''");
    }
    await db
        .execute('CREATE INDEX IF NOT EXISTS idx_${table}_sync_uuid ON $table(sync_uuid)');
    await db
        .execute('CREATE INDEX IF NOT EXISTS idx_${table}_deleted ON $table(deleted_at)');
  }

  /// Ensure the `sync_state` table exists and that this installation has a
  /// persistent `device_id` (TANDAV-XXXX). Returns the device id.
  static Future<String> _ensureSyncState(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
    final rows = await db
        .query('sync_state', where: 'key = ?', whereArgs: ['device_id'], limit: 1);
    if (rows.isNotEmpty) return rows.first['value'] as String;
    final deviceId = generateDeviceId();
    await db.insert('sync_state', {'key': 'device_id', 'value': deviceId});
    return deviceId;
  }

  /// Generate a persistent device id of the form `TANDAV-XXXX`. The suffix is
  /// four random characters drawn from an unambiguous uppercase alphabet (no
  /// 0/O/1/I), giving ~1M combinations — plenty for a two-device pairing, and
  /// never derived from a phone number.
  static String generateDeviceId() {
    const chars = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
    final rng = Random.secure();
    final suffix = List.generate(4, (_) => chars[rng.nextInt(chars.length)]);
    return 'TANDAV-${suffix.join()}';
  }

  /// Forward migrations. Add a new branch for every future schema change;
  /// never edit an already-shipped migration branch.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v1 -> v2: add per-record sync metadata (sync_uuid, origin device_id,
      // tombstone deleted_at, unified updated_at) to every business table and
      // create the sync_state store. Existing rows are stamped in place with
      // the device's persistent id so nothing is lost.
      final deviceId = await _ensureSyncState(db);
      for (final table in syncTables) {
        await _addSyncColumns(db, table);
        await db.execute(
            "UPDATE $table SET device_id = ? WHERE device_id = ''", [deviceId]);
        final rows = await db.query(table,
            columns: ['id'], where: "sync_uuid = '' OR sync_uuid IS NULL");
        for (final row in rows) {
          await db.update(table, {
            'sync_uuid': generateSyncUuid(),
          }, where: 'id = ?', whereArgs: [row['id']]);
        }
        if (_tablesMissingUpdatedAt.contains(table)) {
          await db.execute(
              "UPDATE $table SET updated_at = datetime('now') WHERE updated_at = ''");
        }
      }
      await db.execute('''
        CREATE TABLE IF NOT EXISTS sync_state (
          key TEXT PRIMARY KEY,
          value TEXT
        )
      ''');
    }
  }

  bool get isAdminSeeded => _seeded;

  Future<void> _seedAdminIfNeeded() async {
    if (_seeded) return;
    final db = _db!;
    final count = Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM users')) ??
        0;
    if (count == 0) {
      await db.insert('users', {
        'username': 'admin',
        'full_name': 'Tandav Admin',
        'password_hash': hashPassword('admin123'),
        'is_active': 1,
      });
    }
    _seeded = true;
  }

  /// Create a salted SHA-256 password hash. Plaintext passwords are never
  /// stored.
  static String hashPassword(String password) {
    final salt = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    return encodeHash(salt, password);
  }

  static String encodeHash(List<int> salt, String password) {
    final digest = sha256.convert([...salt, ...utf8.encode(password)]);
    return '${base64Url.encode(salt)}:${digest.toString()}';
  }

  static bool verifyPassword(String password, String stored) {
    try {
      final parts = stored.split(':');
      if (parts.length != 2) return false;
      final salt = base64Url.decode(parts[0]);
      return encodeHash(salt, password) == stored;
    } catch (_) {
      return false;
    }
  }

  /// Close the current database handle (used before restore operations).
  Future<void> close() async {
    if (_db != null && _db!.isOpen) {
      await _db!.close();
    }
    _db = null;
    _seeded = false;
  }

  /// Copy the live database file as a backup inside app documents.
  Future<File> createBackup() async {
    final db = await open();
    final path = db.path;
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final dir = await backupsDir;
    final dest = File(p.join(dir.path, 'tandav-backup-$stamp.db'));
    await File(path).copy(dest.path);
    return dest;
  }

  /// List locally stored backups (newest first).
  Future<List<File>> listBackups() async {
    final dir = await backupsDir;
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => p.extension(f.path) == '.db')
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  /// Replace the live database with a backup file. Returns true on success.
  Future<bool> restoreFromBackup(File backup) async {
    final db = await open();
    final livePath = db.path;
    final backupPath = await backup.absolute.path;
    if (backupPath == livePath) return false;

    // Copy backup to a staging path first so a failed copy never truncates
    // the live database.
    final staging = '$livePath.restore.tmp';
    await File(backupPath).copy(staging);

    await close();
    await File(staging).rename(livePath);
    await open();
    return true;
  }
}