import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

const kDepts = ['A01','A02','A04','A07','A08','A09','A10','A12','A14','A15','A16','A20','B01','B04','POYA'];
const kUserId = 'local_user';   // 預留多人：單人版固定值
const kStoreId = 'local_store'; // 預留多人：單人版固定值
const kNone = 'NONE';

String fmtDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 到期日 - N 個月（日數超出時取該月最後一天）
DateTime subMonths(DateTime d, int m) {
  var y = d.year, mo = d.month - m;
  while (mo <= 0) { mo += 12; y--; }
  final last = DateTime(y, mo + 1, 0).day;
  return DateTime(y, mo, d.day > last ? last : d.day);
}

/// 短效期部門：剩不到 kShortDays 天才算即將過期（其他部門是不足 6 個月）
const kShortDepts = {'A12', 'POYA'};
const kShortDays = 45;

/// 提醒日：從這天起標成即將過期
/// - 短效期部門：剩餘天數 < 45 → 到期日前 44 天
/// - 其他：到期日前 6 個月
DateTime remindDateFor(String dept, DateTime expiry) => kShortDepts.contains(dept)
    ? DateTime(expiry.year, expiry.month, expiry.day - (kShortDays - 1))
    : subMonths(expiry, 6);

/// 給畫面用的規則說明
String remindRuleLabel(String dept) =>
    kShortDepts.contains(dept) ? '不足 $kShortDays 天' : '不足 6 個月';

/// 提醒日還沒到 → 正常；已到或已過 → 即將過期
String statusFor(String dept, DateTime expiry, DateTime now) {
  final t = DateTime(now.year, now.month, now.day);
  return remindDateFor(dept, expiry).isAfter(t) ? '正常' : '即將過期';
}

/// 匯入／匯出檔的欄位（順序同門市系統匯出的檔案）
const kExportHeader = ['國碼', '部門', '店內碼', '品名', '有效日期'];

/// 匯入後的登錄結果
class ImportStats {
  final int registered; // 依檔案日期新登錄的商品數
  final int kept;       // 已有到期日、保留原本日期的商品數
  final int due;        // 新登錄後已在提醒範圍內的商品數
  ImportStats(this.registered, this.kept, this.due);
}

/// 某一天進入「即將過期」的商品
class RemindDay {
  final DateTime date;
  final int count;
  final String sampleName;
  RemindDay(this.date, this.count, this.sampleName);
}

/// 資料存取層：之後改多人共用，只需替換這個類別（例如接 Supabase）
class Repo {
  Repo._();
  static final Repo i = Repo._();
  late Database _db;
  final _uuid = const Uuid();

  /// [name] 只在測試時更改，讓同時執行的測試各用各的資料庫檔
  Future<void> init({String name = 'expiry.db'}) async {
    _db = await openDatabase(
      p.join(await getDatabasesPath(), name),
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''CREATE TABLE products(
          barcode TEXT PRIMARY KEY, name TEXT NOT NULL, dept TEXT NOT NULL,
          store_code TEXT NOT NULL, ref_expiry TEXT NOT NULL, updated_at TEXT NOT NULL)''');
        await db.execute('''CREATE TABLE batches(
          id TEXT PRIMARY KEY, barcode TEXT NOT NULL, dept TEXT NOT NULL,
          expiry_date TEXT NOT NULL, remind_date TEXT NOT NULL, status TEXT NOT NULL,
          user_id TEXT NOT NULL, store_id TEXT NOT NULL,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT)''');
      },
      // 商品可能有幾萬筆，查「待登錄」需要用條碼對批次，沒有索引會很慢
      onOpen: (db) async {
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_batches_barcode ON batches(barcode, deleted_at)');
        // 掃描時也用店內碼比對
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_products_store_code ON products(store_code)');
      },
    );
  }

  String _now() => DateTime.now().toIso8601String();

  Future<int> productCount() async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM products')) ?? 0;

  /// 掃描比對：同時比對「條碼」與「店內碼」，依序找到就停：
  /// 1. 條碼完全相同  2. 店內碼完全相同
  /// 3. 條碼忽略開頭的 0  4. 店內碼忽略開頭的 0
  /// 忽略開頭的 0：UPC-A 條碼匯出時常掉了開頭的 0（068060286727 → 68060286727），
  /// 而相機可能讀成 12 碼或補成 13 碼（0068060286727）。
  /// 可能回傳多筆：少數商品共用同一個店內碼，由使用者選擇。
  Future<List<Map<String, Object?>>> findProducts(String code) async {
    final key = code.replaceFirst(RegExp(r'^0+'), '');
    final tries = [
      ('barcode = ?', code),
      ('store_code = ?', code),
      if (key.isNotEmpty) ("ltrim(barcode, '0') = ?", key),
      if (key.isNotEmpty) ("ltrim(store_code, '0') = ?", key),
    ];
    for (final (where, arg) in tries) {
      final r = await _db.query('products', where: where, whereArgs: [arg], orderBy: 'name, barcode');
      if (r.isNotEmpty) return r;
    }
    return [];
  }

  Future<Map<String, Object?>?> findProduct(String code) async =>
      (await findProducts(code)).firstOrNull;

  /// 國碼是否已被商品使用（完全相同才算）
  Future<bool> barcodeExists(String code) async => (await _db.query('products',
          columns: ['barcode'], where: 'barcode = ?', whereArgs: [code], limit: 1))
      .isNotEmpty;

  /// 手動新增商品並登錄到期日（掃描到商品檔沒有的國碼時用）。
  /// 回傳 (批次 id, 狀態)；國碼已存在時丟出例外。
  Future<(String, String)> addProduct({
    required String barcode,
    required String name,
    required String dept,
    String? storeCode,
    required DateTime expiry,
  }) async {
    if (await barcodeExists(barcode)) throw Exception('國碼 $barcode 已經在商品檔裡');
    await _db.insert('products', {
      'barcode': barcode, 'name': name, 'dept': dept,
      'store_code': (storeCode == null || storeCode.isEmpty) ? kNone : storeCode,
      'ref_expiry': kNone, 'updated_at': _now(),
    });
    final (id, status, _) = await saveBatch(barcode, dept, expiry);
    return (id, status);
  }

  /// 編輯商品與到期日。國碼也可以改，效期紀錄會一起改到新國碼。
  /// 部門或到期日有變動時重新登錄（重算提醒日與狀態）；
  /// 只改品名、店內碼或國碼時保留原本的紀錄（例如「已處理」不會被重置）。
  /// 回傳重新登錄時的 (批次 id, 狀態)，沒有重新登錄則回傳 null。
  Future<(String, String)?> updateProduct(
    String oldBarcode, {
    required String barcode,
    required String name,
    required String dept,
    String? storeCode,
    required DateTime expiry,
  }) async {
    final now = _now();
    await _db.transaction((tx) async {
      if (barcode != oldBarcode) {
        final dup = await tx.query('products',
            columns: ['barcode'], where: 'barcode = ?', whereArgs: [barcode], limit: 1);
        if (dup.isNotEmpty) throw Exception('國碼 $barcode 已經是其他商品');
        await tx.update('batches', {'barcode': barcode, 'updated_at': now},
            where: 'barcode = ?', whereArgs: [oldBarcode]);
      }
      await tx.update('products', {
        'barcode': barcode, 'name': name, 'dept': dept,
        'store_code': (storeCode == null || storeCode.isEmpty) ? kNone : storeCode,
        'updated_at': now,
      }, where: 'barcode = ?', whereArgs: [oldBarcode]);
    });
    final cur = await currentBatch(barcode);
    if (cur != null && cur['expiry_date'] == fmtDate(expiry) && cur['dept'] == dept) return null;
    final (id, status, _) = await saveBatch(barcode, dept, expiry);
    return (id, status);
  }

  /// 新增或更新商品資料。同條碼已存在時更新品名、部門、店內碼，
  /// 但原本的參考有效日期不是 0 就保留，不被檔案覆蓋。
  /// （不用 SQLite 的 UPSERT 語法：Android 7~10 內建的 SQLite 太舊不支援）
  Future<void> upsertProducts(List<Map<String, String>> rows) async {
    final b = _db.batch();
    final now = _now();
    for (final r in rows) {
      b.insert('products', {
        'barcode': r['條碼'], 'name': r['品名'], 'dept': r['部門'],
        'store_code': r['店內碼'], 'ref_expiry': r['有效日期'], 'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      b.rawUpdate(
          'UPDATE products SET name=?, dept=?, store_code=?, updated_at=?, '
          "ref_expiry = CASE WHEN ref_expiry = '$kNone' THEN ? ELSE ref_expiry END "
          'WHERE barcode=?',
          [r['品名'], r['部門'], r['店內碼'], now, r['有效日期'], r['條碼']]);
    }
    await b.commit(noResult: true);
  }

  /// 匯入：寫入商品，並把檔案裡的有效日期（不是 0）登錄成到期日。
  /// 商品已經有登錄的到期日時保留原本日期，不被檔案覆蓋。
  Future<ImportStats> importProducts(List<Map<String, String>> rows) async {
    await upsertProducts(rows);
    final registered = <String>{};
    final now = DateTime.now();
    final nowStr = _now();
    var kept = 0, due = 0;
    await _db.transaction((tx) async {
      final active = (await tx.rawQuery(
              'SELECT DISTINCT barcode FROM batches WHERE deleted_at IS NULL'))
          .map((r) => r['barcode'] as String)
          .toSet();
      final b = tx.batch();
      for (final r in rows) {
        final date = r['有效日期']!;
        if (date == kNone) continue;
        final code = r['條碼']!;
        if (active.contains(code) || registered.contains(code)) {
          kept++;
          continue;
        }
        final dept = r['部門']!;
        final expiry = DateTime.parse(date);
        final status = statusFor(dept, expiry, now);
        if (status == '即將過期') due++;
        b.insert('batches', {
          'id': _uuid.v4(), 'barcode': code, 'dept': dept,
          'expiry_date': date, 'remind_date': fmtDate(remindDateFor(dept, expiry)),
          'status': status, 'user_id': kUserId, 'store_id': kStoreId,
          'created_at': nowStr, 'updated_at': nowStr,
        });
        registered.add(code);
      }
      await b.commit(noResult: true);
    });
    return ImportStats(registered.length, kept, due);
  }

  /// 匯出：全部商品，格式同匯入檔。有登錄到期日的填登錄的日期，沒有的填 0。
  Future<List<List<String>>> exportRows() async {
    final r = await _db.rawQuery(
        'SELECT p.barcode, p.dept, p.store_code, p.name, b.expiry_date FROM products p '
        'LEFT JOIN batches b ON b.barcode = p.barcode AND b.deleted_at IS NULL '
        'ORDER BY p.dept, p.name');
    String s(Object? v) => v == null || v == kNone ? '' : '$v';
    return [
      kExportHeader,
      for (final m in r)
        [s(m['barcode']), s(m['dept']), s(m['store_code']), s(m['name']),
         (m['expiry_date'] as String?) ?? '0'],
    ];
  }

  /// 接下來幾個提醒日（每天一則通知），給 Notifier 排程用
  Future<List<RemindDay>> upcomingRemindDays({int limit = 60}) async {
    final r = await _db.rawQuery(
        'SELECT b.remind_date AS d, COUNT(*) AS n, MIN(p.name) AS name FROM batches b '
        'LEFT JOIN products p ON p.barcode = b.barcode '
        "WHERE b.deleted_at IS NULL AND b.status = '正常' AND b.remind_date > ? "
        'GROUP BY b.remind_date ORDER BY b.remind_date LIMIT ?',
        [fmtDate(DateTime.now()), limit]);
    return [
      for (final m in r)
        RemindDay(DateTime.parse(m['d'] as String), m['n'] as int, (m['name'] as String?) ?? '')
    ];
  }

  /// 待登錄：還沒登錄到期日的商品（匯入時有效日期是 0 或空白的商品）。
  /// 登錄後就有批次，自動離開待登錄；批次被刪除則會回到待登錄。
  (String, List<Object?>) _pendingWhere(String? dept) {
    final w = StringBuffer('NOT EXISTS ('
        'SELECT 1 FROM batches b WHERE b.barcode = p.barcode AND b.deleted_at IS NULL)');
    final args = <Object?>[];
    if (dept != null) { w.write(' AND p.dept = ?'); args.add(dept); }
    return (w.toString(), args);
  }

  Future<int> pendingCount({String? dept}) async {
    final (w, args) = _pendingWhere(dept);
    return Sqflite.firstIntValue(
            await _db.rawQuery('SELECT COUNT(*) FROM products p WHERE $w', args)) ?? 0;
  }

  /// 分頁讀取，避免一次把幾萬筆商品載入記憶體
  Future<List<Map<String, Object?>>> listPending(
      {String? dept, bool byName = false, int limit = 300, int offset = 0}) {
    final (w, args) = _pendingWhere(dept);
    final order = byName ? 'p.name, p.dept' : 'p.dept, p.name';
    return _db.rawQuery(
        'SELECT p.* FROM products p WHERE $w ORDER BY $order LIMIT ? OFFSET ?',
        [...args, limit, offset]);
  }

  /// 搜尋：輸入幾個字，比對品名、店內碼、條碼中任一處（部分相同即可）。
  /// 用空白隔開多個關鍵字時，每個關鍵字都要符合。
  /// 搜尋全部商品（已登錄與待登錄），已登錄的會帶出批次的 id、狀態、到期日。
  (String, List<Object?>) _searchWhere(String query, String? dept) {
    final terms = query.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    final w = <String>[];
    final args = <Object?>[];
    for (final t in terms) {
      // % 和 _ 在 LIKE 裡有特殊意義，要跳脫
      final like = '%${t.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
      w.add(r"(p.name LIKE ? ESCAPE '\' OR p.store_code LIKE ? ESCAPE '\' OR p.barcode LIKE ? ESCAPE '\')");
      args.addAll([like, like, like]);
    }
    if (dept != null) { w.add('p.dept = ?'); args.add(dept); }
    return (w.isEmpty ? '1' : w.join(' AND '), args);
  }

  Future<int> searchCount(String query, {String? dept}) async {
    final (w, args) = _searchWhere(query, dept);
    return Sqflite.firstIntValue(
            await _db.rawQuery('SELECT COUNT(*) FROM products p WHERE $w', args)) ?? 0;
  }

  Future<List<Map<String, Object?>>> searchProducts(String query,
      {String? dept, int limit = 300, int offset = 0}) {
    final (w, args) = _searchWhere(query, dept);
    return _db.rawQuery(
        'SELECT p.*, b.id, b.status, b.expiry_date FROM products p '
        'LEFT JOIN batches b ON b.barcode = p.barcode AND b.deleted_at IS NULL '
        'WHERE $w ORDER BY p.dept, p.name LIMIT ? OFFSET ?',
        [...args, limit, offset]);
  }

  /// 這個商品目前登錄的批次（未刪除），沒有則回傳 null
  Future<Map<String, Object?>?> currentBatch(String barcode) async {
    final r = await _db.query('batches',
        where: 'barcode = ? AND deleted_at IS NULL',
        whereArgs: [barcode], orderBy: 'created_at DESC', limit: 1);
    return r.isEmpty ? null : r.first;
  }

  /// 同一商品只保留一筆：舊的批次標成刪除，再新增這一筆。
  /// 回傳 (新批次 id, 狀態, 被取代的舊批次 id)，舊 id 用來取消通知。
  Future<(String, String, List<String>)> saveBatch(
      String barcode, String dept, DateTime expiry) async {
    final id = _uuid.v4();
    final remind = remindDateFor(dept, expiry);
    final status = statusFor(dept, expiry, DateTime.now());
    final now = _now();
    final replaced = <String>[];
    await _db.transaction((tx) async {
      final old = await tx.query('batches',
          columns: ['id'], where: 'barcode = ? AND deleted_at IS NULL', whereArgs: [barcode]);
      replaced.addAll(old.map((r) => r['id'] as String));
      await tx.update('batches', {'deleted_at': now, 'updated_at': now},
          where: 'barcode = ? AND deleted_at IS NULL', whereArgs: [barcode]);
      await tx.insert('batches', {
        'id': id, 'barcode': barcode, 'dept': dept,
        'expiry_date': fmtDate(expiry), 'remind_date': fmtDate(remind),
        'status': status, 'user_id': kUserId, 'store_id': kStoreId,
        'created_at': now, 'updated_at': now,
      });
    });
    return (id, status, replaced);
  }

  /// 每次開啟 App 時：已到提醒日的「正常」批次 → 「即將過期」
  Future<void> refreshStatuses() async {
    await _db.rawUpdate(
      "UPDATE batches SET status='即將過期', updated_at=? "
      "WHERE status='正常' AND remind_date<=? AND deleted_at IS NULL",
      [_now(), fmtDate(DateTime.now())]);
  }

  Future<List<Map<String, Object?>>> listBatches({String? dept, bool showDone = false}) {
    final where = StringBuffer('b.deleted_at IS NULL');
    final args = <Object?>[];
    if (dept != null) { where.write(' AND b.dept = ?'); args.add(dept); }
    if (!showDone) where.write(" AND b.status != '已處理'");
    return _db.rawQuery(
      'SELECT b.*, p.name, p.store_code FROM batches b '
      'LEFT JOIN products p ON p.barcode = b.barcode '
      'WHERE $where ORDER BY b.expiry_date ASC', args);
  }

  Future<void> markDone(String id) => _db.update('batches',
      {'status': '已處理', 'updated_at': _now()}, where: 'id = ?', whereArgs: [id]);

  Future<void> softDelete(String id) => _db.update('batches',
      {'deleted_at': _now(), 'updated_at': _now()}, where: 'id = ?', whereArgs: [id]);
}
