import 'dart:io';
import 'package:flutter/material.dart' hide TextDirection;
import 'dart:ui' as ui;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:excel/excel.dart' as ex;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart' as pdfLib;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

const String storeName = "أبو مسلم";
const String storePhone = "01119191729";

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MobileBillingApp());
}

class MobileBillingApp extends StatelessWidget {
  const MobileBillingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'محل $storeName',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const Directionality(
        textDirection: ui.TextDirection.rtl,
        child: HomeScreen(),
      ),
    );
  }
}

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('abomoslem_billing.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);
    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE customers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            phone TEXT NOT NULL,
            total_amount REAL NOT NULL,
            paid_amount REAL DEFAULT 0,
            status TEXT DEFAULT 'unpaid',
            last_paid_date TEXT,
            notes TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
          )
        ''');
      },
    );
  }

  Future<int> insertCustomer(Map<String, dynamic> row) async {
    final db = await instance.database;
    return await db.insert('customers', row);
  }

  Future<bool> isPhoneExists(String phone) async {
    final db = await instance.database;
    final res = await db.query(
      'customers',
      where: 'phone = ?',
      whereArgs: [phone.trim()],
    );
    return res.isNotEmpty;
  }

  Future<List<Map<String, dynamic>>> queryAll({String filter = 'all', String search = ''}) async {
    final db = await instance.database;
    String whereClause = '';
    List<dynamic> whereArgs = [];
    if (filter == 'paid') {
      whereClause += 'status = ?';
      whereArgs.add('paid');
    } else if (filter == 'unpaid') {
      whereClause += '(status = ? OR status = ?)';
      whereArgs.addAll(['unpaid', 'partial']);
    }
    if (search.isNotEmpty) {
      if (whereClause.isNotEmpty) whereClause += ' AND ';
      whereClause += '(name LIKE ? OR phone LIKE ?)';
      whereArgs.addAll(['%$search\%', '\%$search%']);
    }
    return await db.query(
      'customers',
      where: whereClause.isEmpty ? null : whereClause,
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: 'id DESC',
    );
  }

  Future<int> updatePayment(int id, double total, double currentPaid, double addAmount) async {
    final db = await instance.database;
    double newPaid = currentPaid + addAmount;
    if (newPaid > total) newPaid = total;
    String status = (newPaid >= total) ? 'paid' : (newPaid > 0 ? 'partial' : 'unpaid');
    String dateStr = DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now());
    return await db.update(
      'customers',
      {'paid_amount': newPaid, 'status': status, 'last_paid_date': dateStr},
      where: 'id = ?',
      whereArgs: [id],
      
