import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('ffi sqlite opens and queries', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 1),
    );
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
    await db.insert('t', {'name': 'hello'});
    final rows = await db.query('t');
    expect(rows.single['name'], 'hello');
    await db.close();
  });
}
