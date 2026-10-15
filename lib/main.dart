import 'dart:io';
import 'package:flutter/material.dart';
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
        fontFamily: 'Roboto',
      ),
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        );
      },
      home: const HomeScreen(),
    );
  }
}

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('abomoslem_billing_v2.db');
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
            plan_name TEXT DEFAULT 'باقة أساسية',
            monthly_fee REAL NOT NULL,
            total_amount REAL NOT NULL,
            paid_amount REAL DEFAULT 0,
            status TEXT DEFAULT 'unpaid',
            payment_method TEXT DEFAULT 'كاش',
            due_day INTEGER DEFAULT 1,
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

  Future<int> updateCustomer(int id, Map<String, dynamic> row) async {
    final db = await instance.database;
    return await db.update('customers', row, where: 'id = ?', whereArgs: [id]);
  }

  Future<bool> isPhoneExists(String phone, {int? excludeId}) async {
    final db = await instance.database;
    final res = await db.query(
      'customers',
      where: excludeId != null ? 'phone = ? AND id != ?' : 'phone = ?',
      whereArgs: excludeId != null ? [phone.trim(), excludeId] : [phone.trim()],
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
      whereArgs.addAll(['%$search%', '%$search%']);
    }
    return await db.query(
      'customers',
      where: whereClause.isEmpty ? null : whereClause,
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: 'id DESC',
    );
  }

  Future<int> recordPayment(int id, double total, double currentPaid, double addAmount, String method) async {
    final db = await instance.database;
    double newPaid = currentPaid + addAmount;
    if (newPaid > total) newPaid = total;
    String status = (newPaid >= total) ? 'paid' : (newPaid > 0 ? 'partial' : 'unpaid');
    String dateStr = DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now());
    return await db.update(
      'customers',
      {
        'paid_amount': newPaid,
        'status': status,
        'payment_method': method,
        'last_paid_date': dateStr,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> renewMonthlyCycle() async {
    final db = await instance.database;
    final customers = await db.query('customers');
    int count = 0;
    for (var c in customers) {
      int id = c['id'] as int;
      double total = (c['total_amount'] as num).toDouble();
      double paid = (c['paid_amount'] as num).toDouble();
      double monthlyFee = (c['monthly_fee'] as num).toDouble();
      double debt = total - paid;
      double newTotal = debt + monthlyFee;

      await db.update(
        'customers',
        {
          'total_amount': newTotal,
          'paid_amount': 0.0,
          'status': 'unpaid',
          'last_paid_date': null,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      count++;
    }
    return count;
  }

  Future<int> deleteCustomer(int id) async {
    final db = await instance.database;
    return await db.delete('customers', where: 'id = ?', whereArgs: [id]);
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, dynamic>> _customers = [];
  String _filter = 'all';
  String _searchQuery = '';
  double _totalReq = 0;
  double _totalCollected = 0;
  double _remainingDebt = 0;

  @override
  void initState() {
    super.initState();
    _refreshData();
  }

  Future<void> _refreshData() async {
    final data = await DatabaseHelper.instance.queryAll(filter: _filter, search: _searchQuery);
    final allData = await DatabaseHelper.instance.queryAll();
    double req = 0;
    double collected = 0;
    for (var row in allData) {
      req += (row['total_amount'] as num).toDouble();
      collected += (row['paid_amount'] as num).toDouble();
    }
    setState(() {
      _customers = data;
      _totalReq = req;
      _totalCollected = collected;
      _remainingDebt = req - collected;
    });
  }

  void _sendWhatsApp(String phone, String name, String plan, double total, double remaining) async {
    String clean = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (clean.startsWith('0')) clean = '20${clean.substring(1)}';
    if (!clean.startsWith('20')) clean = '20$clean';
    String text = "السلام عليكم أ/ $name\nمعك محل *$storeName* 📱\n"
        "بخصوص اشتراك: *$plan*\n"
        "━━━━━━━━━━━━━━\n"
        "💰 إجمالي المطلوب: ${total.toStringAsFixed(0)} ج.م\n"
        "✅ المسدد: ${(total - remaining).toStringAsFixed(0)} ج.م\n"
        "🔴 المتبقي: ${remaining.toStringAsFixed(0)} ج.م\n"
        "━━━━━━━━━━━━━━\n"
        "برجاء سرعة السداد، شكراً لثقتك بنا 🙏\n$storePhone";
    final uri = Uri.parse("https://wa.me/$clean?text=${Uri.encodeComponent(text)}");
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر فتح واتساب')));
    }
  }

  Future<void> _generateInvoice(Map<String, dynamic> c) async {
    try {
      final pdf = pw.Document();
      final font = await PdfGoogleFonts.cairoRegular();
      final boldFont = await PdfGoogleFonts.cairoBold();

      double total = (c['total_amount'] as num).toDouble();
      double paid = (c['paid_amount'] as num).toDouble();
      double remaining = total - paid;
      String date = DateFormat('yyyy/MM/dd - hh:mm a').format(DateTime.now());

      pdf.addPage(
        pw.Page(
          pageFormat: pdfLib.PdfPageFormat.a5,
          textDirection: pw.TextDirection.rtl,
          theme: pw.ThemeData.withFont(base: font, bold: boldFont),
          build: (pw.Context context) {
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(storeName, style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, color: pdfLib.PdfColors.indigo)),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text('محل $storeName للخدمات والاتصالات', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                        pw.Text(storePhone, style: const pw.TextStyle(fontSize: 10, color: pdfLib.PdfColors.grey)),
                        pw.Text(date, style: const pw.TextStyle(fontSize: 9)),
                      ],
                    ),
                  ],
                ),
                pw.Divider(thickness: 2, color: pdfLib.PdfColors.indigo),
                pw.SizedBox(height: 10),
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.all(8),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: pdfLib.PdfColors.grey300),
                    borderRadius: pw.BorderRadius.circular(6),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('اسم المشترك: ${c['name']}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12)),
                      pw.Text('رقم الموبايل: ${c['phone']}', style: const pw.TextStyle(fontSize: 10)),
                      pw.Text('نوع الباقة: ${c['plan_name']}', style: const pw.TextStyle(fontSize: 10)),
                      pw.Text('طريقة السداد: ${c['payment_method'] ?? "كاش"}', style: const pw.TextStyle(fontSize: 10)),
                    ],
                  ),
                ),
                pw.SizedBox(height: 12),
                pw.Table(
                  border: pw.TableBorder.all(color: pdfLib.PdfColors.grey300),
                  children: [
                    pw.TableRow(
                      decoration: const pw.BoxDecoration(color: pdfLib.PdfColors.indigo50),
                      children: [
                        pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('البيان', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11))),
                        pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('القيمة', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11))),
                      ],
                    ),
                    pw.TableRow(children: [
                      pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('قيمة الباقة الشهرية', style: const pw.TextStyle(fontSize: 10))),
                      pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('${c['monthly_fee']} ج.م', style: const pw.TextStyle(fontSize: 10))),
                    ]),
                    pw.TableRow(children: [
                      pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('إجمالي المطلوب (شامل المتأخرات)', style: const pw.TextStyle(fontSize: 10))),
                      pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('${total.toStringAsFixed(0)} ج.م', style: const pw.TextStyle(fontSize: 10))),
                    ]),
                    pw.TableRow(children: [
                      pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('المبلغ المسدد', style: const pw.TextStyle(fontSize: 10))),
                      pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('${paid.toStringAsFixed(0)} ج.م', style: const pw.TextStyle(fontSize: 10, color: pdfLib.PdfColors.green))),
                    ]),
                    pw.TableRow(
                      decoration: const pw.BoxDecoration(color: pdfLib.PdfColors.red50),
                      children: [
                        pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('المتبقي للتسديد', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11))),
                        pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('${remaining.toStringAsFixed(0)} ج.م', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11, color: pdfLib.PdfColors.red800))),
                      ],
                    ),
                  ],
                ),
                pw.Spacer(),
                pw.Center(child: pw.Text('شكراً لتعاملكم مع محل $storeName', style: const pw.TextStyle(fontSize: 10, color: pdfLib.PdfColors.grey700))),
              ],
            );
          },
        ),
      );
      await Printing.sharePdf(bytes: await pdf.save(), filename: 'فاتورة_${c['name']}.pdf');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ: $e')));
    }
  }

  Future<void> _exportExcel() async {
    try {
      final excel = ex.Excel.createExcel();
      final sheet = excel['حسابات المشتركين'];
      excel.setDefaultSheet('حسابات المشتركين');
      sheet.appendRow([
        ex.TextCellValue('الاسم'),
        ex.TextCellValue('الموبايل'),
        ex.TextCellValue('نوع الباقة'),
        ex.TextCellValue('سعر الباقة'),
        ex.TextCellValue('المطلوب الكلي'),
        ex.TextCellValue('المدفوع'),
        ex.TextCellValue('المتبقي'),
        ex.TextCellValue('طريقة الدفع'),
        ex.TextCellValue('يوم التجديد'),
      ]);
      final allData = await DatabaseHelper.instance.queryAll();
      for (var c in allData) {
        double total = (c['total_amount'] as num).toDouble();
        double paid = (c['paid_amount'] as num).toDouble();
        sheet.appendRow([
          ex.TextCellValue(c['name']),
          ex.TextCellValue(c['phone']),
          ex.TextCellValue(c['plan_name'] ?? 'أساسية'),
          ex.DoubleCellValue((c['monthly_fee'] as num).toDouble()),
          ex.DoubleCellValue(total),
          ex.DoubleCellValue(paid),
          ex.DoubleCellValue(total - paid),
          ex.TextCellValue(c['payment_method'] ?? 'كاش'),
          ex.IntCellValue(c['due_day'] ?? 1),
        ]);
      }
      final dir = await getApplicationDocumentsDirectory();
      final fileName = '${storeName}_حسابات_${DateFormat('yyyy-MM-dd').format(DateTime.now())}.xlsx';
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(excel.encode()!);
      await Share.shareXFiles([XFile(file.path)], text: 'كشف حسابات المشتركين محل $storeName');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ: $e')));
    }
  }

  void _showCustomerDialog({Map<String, dynamic>? customer}) {
    final isEdit = customer != null;
    final nameCtrl = TextEditingController(text: isEdit ? customer['name'] : '');
    final phoneCtrl = TextEditingController(text: isEdit ? customer['phone'] : '');
    final planCtrl = TextEditingController(text: isEdit ? (customer['plan_name'] ?? 'باقة 100') : 'باقة 100');
    final feeCtrl = TextEditingController(text: isEdit ? customer['monthly_fee'].toString() : '100');
    final debtCtrl = TextEditingController(text: isEdit ? ((customer['total_amount'] as num) - (customer['paid_amount'] as num)).toString() : '0');
    final dayCtrl = TextEditingController(text: isEdit ? customer['due_day'].toString() : '1');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEdit ? 'تعديل بيانات المشترك والباقة' : 'إضافة مشترك وباقة جديدة'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'اسم العميل / المشترك')),
              TextField(controller: phoneCtrl, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الموبايل')),
              TextField(controller: planCtrl, decoration: const InputDecoration(labelText: 'اسم / نوع الباقة (مثلاً: 140 جيجا)')),
              TextField(controller: feeCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'سعر الباقة الشهري (ج.م)')),
              TextField(controller: debtCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: isEdit ? 'المتبقي الحالي (ج.م)' : 'متأخرات قديمة إن وجدت (ج.م)')),
              TextField(controller: dayCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'يوم التجديد من كل شهر (مثلاً: 1)')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          ElevatedButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty || feeCtrl.text.isEmpty) return;
              double fee = double.tryParse(feeCtrl.text) ?? 0.0;
              double debt = double.tryParse(debtCtrl.text) ?? 0.0;
              int day = int.tryParse(dayCtrl.text) ?? 1;

              if (await DatabaseHelper.instance.isPhoneExists(phoneCtrl.text.trim(), excludeId: isEdit ? customer['id'] : null)) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('رقم الموبايل مسجل لمشترك آخر!')));
                return;
              }

              if (isEdit) {
                await DatabaseHelper.instance.updateCustomer(customer['id'], {
                  'name': nameCtrl.text.trim(),
                  'phone': phoneCtrl.text.trim(),
                  'plan_name': planCtrl.text.trim(),
                  'monthly_fee': fee,
                  'total_amount': debt,
                  'paid_amount': 0.0,
                  'status': debt <= 0 ? 'paid' : 'unpaid',
                  'due_day': day,
                });
              } else {
                await DatabaseHelper.instance.insertCustomer({
                  'name': nameCtrl.text.trim(),
                  'phone': phoneCtrl.text.trim(),
                  'plan_name': planCtrl.text.trim(),
                  'monthly_fee': fee,
                  'total_amount': fee + debt,
                  'paid_amount': 0.0,
                  'status': 'unpaid',
                  'payment_method': 'كاش',
                  'due_day': day,
                });
              }
              if (mounted) Navigator.pop(ctx);
              _refreshData();
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  void _showPayDialog(Map<String, dynamic> c) {
    final payCtrl = TextEditingController();
    String selectedMethod = 'كاش';
    double total = (c['total_amount'] as num).toDouble();
    double paid = (c['paid_amount'] as num).toDouble();
    double remaining = total - paid;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('تحصيل سداد: ${c['name']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('نوع الباقة: ${c['plan_name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('المتبقي المطلوب: ${remaining.toStringAsFixed(0)} ج.م', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red, fontSize: 16)),
              const SizedBox(height: 12),
              TextField(
                controller: payCtrl,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'المبلغ المدفوع الآن', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              const Text('طريقة السداد:'),
              DropdownButton<String>(
                value: selectedMethod,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'كاش', child: Text('💵 نقداً (كاش)')),
                  DropdownMenuItem(value: 'فودافون كاش', child: Text('📱 فودافون كاش')),
                  DropdownMenuItem(value: 'محفظة بنكية / فوري', child: Text('💳 محفظة إلكترونية / فوري')),
                ],
                onChanged: (val) {
                  if (val != null) setDialogState(() => selectedMethod = val);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await DatabaseHelper.instance.recordPayment(c['id'], total, paid, remaining, selectedMethod);
                if (mounted) Navigator.pop(ctx);
                _refreshData();
              },
              child: const Text('سداد كامل المبلغ', style: TextStyle(color: Colors.green)),
            ),
            ElevatedButton(
              onPressed: () async {
                double addAmt = double.tryParse(payCtrl.text) ?? 0.0;
                if (addAmt > 0) {
                  await DatabaseHelper.instance.recordPayment(c['id'], total, paid, addAmt, selectedMethod);
                  if (mounted) Navigator.pop(ctx);
                  _refreshData();
                }
              },
              child: const Text('تأكيد التحصيل'),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmAutoMonthlyRenewal() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('بدء دورة اشتراكات شهر جديد 🔄'),
        content: const Text(
          'سيقوم النظام تلقائياً بإضافة قيمة الباقة الشهرية لكل المشتركين مع ترحيل أي مبالغ متأخرة لم يتم سدادها إلى حسابهم الجديد.\n\nهل تريد المتابعة؟',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
            onPressed: () async {
              int count = await DatabaseHelper.instance.renewMonthlyCycle();
              if (mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم تجديد وترحيل حسابات $count مشترك بنجاح!')));
              }
              _refreshData();
            },
            child: const Text('تأكيد التجديد الشهري'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.storefront, color: Colors.white),
            const SizedBox(width: 8),
            Text('محل $storeName للحسابات', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.autorenew), tooltip: 'تجديد الدورة الشهرية', onPressed: _confirmAutoMonthlyRenewal),
          IconButton(icon: const Icon(Icons.share), tooltip: 'تصدير إكسيل', onPressed: _exportExcel),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            color: Colors.indigo.shade50,
            child: Row(
              children: [
                _buildStatCard('إجمالي المطلوب', _totalReq.toStringAsFixed(0), Colors.blue),
                _buildStatCard('المحصل', _totalCollected.toStringAsFixed(0), Colors.green),
                _buildStatCard('المتأخرات والديون', _remainingDebt.toStringAsFixed(0), Colors.red),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'بحث باسم العميل أو الرقم...',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (val) {
                      _searchQuery = val;
                      _refreshData();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: _filter,
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('الكل')),
                    DropdownMenuItem(value: 'unpaid', child: Text('عليه ديون')),
                    DropdownMenuItem(value: 'paid', child: Text('خالص')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _filter = val);
                      _refreshData();
                    }
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: _customers.isEmpty
                ? const Center(child: Text('لا توجد اشتراكات مسجلة حالياً'))
                : ListView.builder(
                    itemCount: _customers.length,
                    itemBuilder: (ctx, idx) {
                      final c = _customers[idx];
                      double total = (c['total_amount'] as num).toDouble();
                      double paid = (c['paid_amount'] as num).toDouble();
                      double remaining = total - paid;
                      bool isPaid = remaining <= 0;

                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        elevation: 2,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  CircleAvatar(
                                    backgroundColor: isPaid ? Colors.green : Colors.red,
                                    radius: 18,
                                    child: Icon(isPaid ? Icons.check : Icons.person, color: Colors.white, size: 20),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          c['name'],
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                        ),
                                        Text(
                                          '${c['phone']} • ${c['plan_name']}',
                                          style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: isPaid ? Colors.green.shade50 : Colors.red.shade50,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: isPaid ? Colors.green : Colors.red),
                                    ),
                                    child: Text(
                                      isPaid ? 'خالص' : 'باقي: ${remaining.toStringAsFixed(0)} ج.م',
                                      style: TextStyle(
                                        color: isPaid ? Colors.green.shade900 : Colors.red.shade900,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const Divider(height: 16),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('الباقة: ${c['monthly_fee']} ج.م | السداد: ${c['payment_method'] ?? "كاش"}', style: const TextStyle(fontSize: 12)),
                                  Text('تجديد يوم: ${c['due_day'] ?? 1}', style: const TextStyle(fontSize: 12, color: Colors.blueGrey)),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  if (!isPaid)
                                    IconButton(
                                      icon: const Icon(Icons.payment, color: Colors.blue),
                                      tooltip: 'سداد',
                                      onPressed: () => _showPayDialog(c),
                                    ),
                                  IconButton(
                                    icon: const Icon(Icons.edit, color: Colors.orange),
                                    tooltip: 'تعديل الباقة والبيانات',
                                    onPressed: () => _showCustomerDialog(customer: c),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.receipt_long, color: Colors.purple),
                                    tooltip: 'فاتورة PDF',
                                    onPressed: () => _generateInvoice(c),
                                  ),
                                  if (!isPaid)
                                    IconButton(
                                      icon: const Icon(Icons.chat, color: Colors.green),
                                      tooltip: 'إشعار واتساب',
                                      onPressed: () => _sendWhatsApp(c['phone'], c['name'], c['plan_name'] ?? 'الاشتراك', total, remaining),
                                    ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                                    tooltip: 'حذف',
                                    onPressed: () async {
                                      await DatabaseHelper.instance.deleteCustomer(c['id']);
                                      _refreshData();
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCustomerDialog(),
        backgroundColor: Colors.indigo,
        icon: const Icon(Icons.person_add, color: Colors.white),
        label: const Text('مشترك جديد', style: TextStyle(color: Colors.white)),
      ),
    );
  }

  Widget _buildStatCard(String title, String val, MaterialColor color) {
    return Expanded(
      child: Card(
        color: color.shade50,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
          child: Column(
            children: [
              Text(title, style: TextStyle(fontSize: 11, color: color.shade900)),
              const SizedBox(height: 2),
              Text('$val ج.م', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color.shade900)),
            ],
          ),
        ),
      ),
    );
  }
}
