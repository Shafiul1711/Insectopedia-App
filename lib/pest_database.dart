import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/services.dart';
import 'dart:io';

class PestDatabase {
  static Database? _db;

  static Future<Database> get db async {
    if (_db != null) return _db!;

    final dbPath = await getDatabasesPath();
    final path = join(dbPath, "growliv.db");

    if (!File(path).existsSync()) {
      final data = await rootBundle.load("assets/database/growliv.db");
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      await File(path).writeAsBytes(bytes);
    }

    _db = await openDatabase(path);
    return _db!;
  }

  static Future<Map<String, dynamic>?> getPest(String name) async {
    final database = await db;

    final res = await database.query(
      "pests",
      where: "sql_name = ?",
      whereArgs: [name],
    );

    if (res.isEmpty) return null;
    return res.first;
  }
}