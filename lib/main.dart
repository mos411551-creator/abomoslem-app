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
      whereArgs.addAll(['%$search%', '%$search%']);
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
    );
  }

  Future<int> resetMonth() async {
    final db = await instance.database;
    return await db.update(
      'customers',
      {'paid_amount': 0.0, 'status': 'unpaid', 'last_paid_date': null},
    );
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

  void _sendWhatsApp(String phone, String name, double total, double remaining) async {
    String clean = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (clean.startsWith('0')) clean = '20${clean.substring(1)}';
    if (!clean.startsWith('20')) clean = '20$clean';
    String text = "السلام عليكم أ/ $name\nمعك محل *$storeName* للموبايلات 📱\nتذكير ودي بالحساب:\n━━━━━━━━━━━━━━\n💰 الإجمالي: ${total.toStringAsFixed(0)} ج.م\n✅ المدفوع: ${(total - remaining).toStringAsFixed(0)} ج.م\n🔴 المتبقي: ${remaining.toStringAsFixed(0)} ج.م\n━━━━━━━━━━━━━━\nبرجاء السداد في أقرب وقت، شكراً لثقتك 🙏\n$storePhone";
    final uri = Uri.parse("https://wa.me/$clean?text=${Uri.encodeComponent(text)}");
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر فتح تطبيق واتساب')));
      }
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
                        pw.Text('محل $storeName للموبايلات', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
                        pw.Text(storePhone, style: const pw.TextStyle(fontSize: 10, color: pdfLib.PdfColors.grey)),
                        pw.Text(date, style: const pw.TextStyle(fontSize: 9)),
                      ],
                    ),
                  ],
                ),
                pw.Divider(thickness: 2, color: pdfLib.PdfColors.indigo),
                pw.SizedBox(height: 12),
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.all(10),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: pdfLib.PdfColors.grey300),
                    borderRadius: pw.BorderRadius.circular(6),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('بيانات العميل:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      pw.SizedBox(height: 4),
                      pw.Text('الاسم: ${c['name']}', style: const pw.TextStyle(fontSize: 11)),
                      pw.Text('الموبايل: ${c['phone']}', style: const pw.TextStyle(fontSize: 11)),
                      if (c['notes'] != null && c['notes'].toString().isNotEmpty)
                        pw.Text('ملاحظة: ${c['notes']}', style: const pw.TextStyle(fontSize: 9)),
                    ],
                  ),
                ),
                pw.SizedBox(height: 14),
                pw.Table(
                  border: pw.TableBorder.all(color: pdfLib.PdfColors.grey300),
                  children: [
                    pw.TableRow(
                      decoration: const pw.BoxDecoration(color: pdfLib.PdfColors.indigo50),
                      children: [
                        pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('البيان', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11))),
                        pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('المبلغ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11))),
                      ],
                    ),
                    pw.TableRow(children: [
                      pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('الإجمالي', style: const pw.TextStyle(fontSize: 11))),
                      pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('${total.toStringAsFixed(0)} ج.م', style: const pw.TextStyle(fontSize: 11))),
                    ]),
                    pw.TableRow(children: [
                      pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('المدفوع', style: const pw.TextStyle(fontSize: 11))),
                      pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('${paid.toStringAsFixed(0)} ج.م', style: const pw.TextStyle(fontSize: 11, color: pdfLib.PdfColors.green))),
                    ]),
                    pw.TableRow(
                      decoration: const pw.BoxDecoration(color: pdfLib.PdfColors.red50),
                      children: [
                        pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('المتبقي', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11))),
                        pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('${remaining.toStringAsFixed(0)} ج.م', style: const pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12, color: pdfLib.PdfColors.red800))),
                      ],
                    ),
                  ],
                ),
                pw.Spacer(),
                pw.Center(
                  child: pw.Text('شكراً لتعاملكم معنا 🙏\nمحل $storeName', textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 9, color: pdfLib.PdfColors.grey600)),
                ),
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
      final sheet = excel['حسابات $storeName'];
      excel.setDefaultSheet('حسابات $storeName');
      sheet.appendRow([
        ex.TextCellValue('الاسم'),
        ex.TextCellValue('الموبايل'),
        ex.TextCellValue('المطلوب'),
        ex.TextCellValue('المدفوع'),
        ex.TextCellValue('المتبقي'),
        ex.TextCellValue('الحالة'),
        ex.TextCellValue('آخر سداد')
      ]);
      final allData = await DatabaseHelper.instance.queryAll();
      for (var c in allData) {
        double total = (c['total_amount'] as num).toDouble();
        double paid = (c['paid_amount'] as num).toDouble();
        sheet.appendRow([
          ex.TextCellValue(c['name']),
          ex.TextCellValue(c['phone']),
          ex.DoubleCellValue(total),
          ex.DoubleCellValue(paid),
          ex.DoubleCellValue(total - paid),
          ex.TextCellValue(c['status'] == 'paid' ? 'خالص' : 'عليه باقي'),
          ex.TextCellValue(c['last_paid_date'] ?? '-')
        ]);
      }
      final dir = await getApplicationDocumentsDirectory();
      final fileName = '${storeName}_كشف_${DateFormat('yyyy-MM-dd').format(DateTime.now())}.xlsx';
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(excel.encode()!);
      await Share.shareXFiles([XFile(file.path)], text: 'كشف حسابات محل $storeName');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ: $e')));
    }
  }

  Future<void> _importExcel() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
    if (result != null && result.files.single.path != null) {
      var bytes = File(result.files.single.path!).readAsBytesSync();
      var excel = ex.Excel.decodeBytes(bytes);
      int count = 0;
      for (var table in excel.tables.keys) {
        var rows = excel.tables[table]!.rows;
        for (int i = 1; i < rows.length; i++) {
          var row = rows[i];
          if (row.isEmpty || row[0]?.value == null) continue;
          String name = row[0]?.value?.toString().trim() ?? '';
          String phone = row.length > 1 ? (row[1]?.value?.toString().trim() ?? '') : '';
          double total = 0;
          if (row.length > 2 && row[2]?.value != null) total = double.tryParse(row[2]!.value.toString()) ?? 0;
          if (name.isNotEmpty && !(await DatabaseHelper.instance.isPhoneExists(phone))) {
            await DatabaseHelper.instance.insertCustomer({
              'name': name,
              'phone': phone,
              'total_amount': total,
              'paid_amount': 0.0,
              'status': 'unpaid'
            });
            count++;
          }
        }
      }
      _refreshData();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم استيراد $count مشترك جديد')));
    }
  }

  void _showAddDialog() {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final totalCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة مشترك جديد'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'اسم العميل')),
            TextField(controller: phoneCtrl, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الموبايل')),
            TextField(controller: totalCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ المطلوب')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          ElevatedButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty || totalCtrl.text.isEmpty) return;
              if (await DatabaseHelper.instance.isPhoneExists(phoneCtrl.text.trim())) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('الرقم مسجل مسبقاً!')));
                return;
              }
              await DatabaseHelper.instance.insertCustomer({
                'name': nameCtrl.text.trim(),
                'phone': phoneCtrl.text.trim(),
                'total_amount': double.tryParse(totalCtrl.text) ?? 0.0,
                'paid_amount': 0.0,
                'status': 'unpaid'
              });
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
    double total = (c['total_amount'] as num).toDouble();
    double paid = (c['paid_amount'] as num).toDouble();
    double remaining = total - paid;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('سداد: ${c['name']}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('المتبقي: ${remaining.toStringAsFixed(0)} ج.م', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
            const SizedBox(height: 12),
            TextField(controller: payCtrl, keyboardType: TextInputType.number, autofocus: true, decoration: const InputDecoration(labelText: 'المبلغ الآن', border: OutlineInputBorder())),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await DatabaseHelper.instance.updatePayment(c['id'], total, paid, remaining);
              if (mounted) Navigator.pop(ctx);
              _refreshData();
            },
            child: const Text('سداد كامل', style: TextStyle(color: Colors.green)),
          ),
          ElevatedButton(
            onPressed: () async {
              double addAmt = double.tryParse(payCtrl.text) ?? 0.0;
              if (addAmt > 0) {
                await DatabaseHelper.instance.updatePayment(c['id'], total, paid, addAmt);
                if (mounted) Navigator.pop(ctx);
                _refreshData();
              }
            },
            child: const Text('تأكيد'),
          ),
        ],
      ),
    );
  }

  void _confirmReset() {
    final confirmCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تصفير شهر جديد'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('هتصفر كل المدفوعات! اكتب كلمة "تصفير"'),
            const SizedBox(height: 8),
            TextField(controller: confirmCtrl, decoration: const InputDecoration(hintText: 'اكتب تصفير', border: OutlineInputBorder())),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () async {
              if (confirmCtrl.text.trim() == 'تصفير') {
                await DatabaseHelper.instance.resetMonth();
                if (mounted) Navigator.pop(ctx);
                _refreshData();
              }
            },
            child: const Text('تأكيد'),
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
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.phone_android, color: Colors.indigo),
            ),
            const SizedBox(width: 10),
            Text('محل $storeName', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.file_upload), tooltip: 'استيراد إكسيل', onPressed: _importExcel),
          IconButton(icon: const Icon(Icons.share), tooltip: 'تصدير إكسيل', onPressed: _exportExcel),
          IconButton(icon: const Icon(Icons.restart_alt), tooltip: 'شهر جديد', onPressed: _confirmReset),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.indigo.shade50,
            child: Row(
              children: [
                _buildStatCard('المطلوب', _totalReq.toStringAsFixed(0), Colors.blue),
                _buildStatCard('المحصل', _totalCollected.toStringAsFixed(0), Colors.green),
                _buildStatCard('المتبقي', _remainingDebt.toStringAsFixed(0), Colors.red),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'بحث بالاسم أو الرقم...',
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
                    DropdownMenuItem(value: 'unpaid', child: Text('مديون')),
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
                ? const Center(child: Text('لا توجد بيانات مسجلة'))
                : ListView.builder(
                    itemCount: _customers.length,
                    itemBuilder: (ctx, idx) {
                      final c = _customers[idx];
                      double total = (c['total_amount'] as num).toDouble();
                      double paid = (c['paid_amount'] as num).toDouble();
                      double remaining = total - paid;
                      bool isPaid = remaining <= 0;
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                        elevation: 1.5,
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: isPaid ? Colors.green : Colors.red,
                            child: Icon(isPaid ? Icons.check : Icons.person, color: Colors.white, size: 18),
                          ),
                          title: Text(c['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text('${c['phone']} | باقي: ${remaining.toStringAsFixed(0)} ج.م | مطلوب: ${total.toStringAsFixed(0)}'),
                          trailing: Wrap(
                            spacing: 0,
                            children: [
                              if (!isPaid)
                                IconButton(icon: const Icon(Icons.payment, color: Colors.blue, size: 22), tooltip: 'دفع', onPressed: () => _showPayDialog(c)),
                              IconButton(icon: const Icon(Icons.receipt_long, color: Colors.deepPurple, size: 22), tooltip: 'فاتورة PDF', onPressed: () => _generateInvoice(c)),
                              if (!isPaid)
                                IconButton(icon: const Icon(Icons.chat, color: Colors.green, size: 22), tooltip: 'واتساب', onPressed: () => _sendWhatsApp(c['phone'], c['name'], total, remaining)),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red, size: 22),
                                tooltip: 'حذف',
                                onPressed: () async {
                                  await DatabaseHelper.instance.deleteCustomer(c['id']);
                                  _refreshData();
                                },
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
        onPressed: _showAddDialog,
        backgroundColor: Colors.indigo,
        icon: const Icon(Icons.person_add, color: Colors.white),
        label: const Text('عميل جديد', style: TextStyle(color: Colors.white)),
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
