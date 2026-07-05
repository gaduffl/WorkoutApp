import 'dart:convert';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// Simple JSON-blob-per-row schema: every table stores a stable text key
/// plus a JSON payload. This keeps the Flutter layer thin - all the real
/// logic (and its shape) lives in the pure `engine/` package and its
/// models, not in SQL.
class AppDatabase {
  Database? _db;

  Future<Database> open() async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    final path = join(dir, 'morningcoach.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('CREATE TABLE exercise_states (trackKey TEXT PRIMARY KEY, json TEXT NOT NULL)');
        await db.execute('CREATE TABLE check_ins (date TEXT PRIMARY KEY, json TEXT NOT NULL)');
        await db.execute('CREATE TABLE recovery_snapshots (date TEXT PRIMARY KEY, json TEXT NOT NULL)');
        await db.execute('CREATE TABLE session_logs (id TEXT PRIMARY KEY, date TEXT NOT NULL, json TEXT NOT NULL)');
        await db.execute('CREATE TABLE decision_traces (date TEXT PRIMARY KEY, json TEXT NOT NULL)');
        await db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, json TEXT NOT NULL)');
      },
    );
    return _db!;
  }

  Future<void> putJson(String table, String keyColumn, String key, Map<String, dynamic> json) async {
    final db = await open();
    await db.insert(
      table,
      {keyColumn: key, 'json': jsonEncode(json)},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> putJsonWithDate(String table, String key, DateTime date, Map<String, dynamic> json) async {
    final db = await open();
    await db.insert(
      table,
      {'id': key, 'date': date.toIso8601String(), 'json': jsonEncode(json)},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getJson(String table, String keyColumn, String key) async {
    final db = await open();
    final rows = await db.query(table, where: '$keyColumn = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['json'] as String) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> getAllJson(String table) async {
    final db = await open();
    final rows = await db.query(table);
    return rows.map((r) => jsonDecode(r['json'] as String) as Map<String, dynamic>).toList();
  }

  Future<void> delete(String table, String keyColumn, String key) async {
    final db = await open();
    await db.delete(table, where: '$keyColumn = ?', whereArgs: [key]);
  }

  Future<List<Map<String, dynamic>>> getJsonSince(String table, String dateColumn, DateTime since) async {
    final db = await open();
    final rows = await db.query(
      table,
      where: '$dateColumn >= ?',
      whereArgs: [since.toIso8601String()],
      orderBy: '$dateColumn ASC',
    );
    return rows.map((r) => jsonDecode(r['json'] as String) as Map<String, dynamic>).toList();
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
