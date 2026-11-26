import 'package:expiry_app/db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.deleteDatabase(p.join(await getDatabasesPath(), 'test_repo.db'));
    await Repo.i.init(name: 'test_repo.db');
  });

  test('同一商品只保留一筆，新的到期日取代舊的', () async {
    final (id1, _, replaced1) = await Repo.i.saveBatch('111', 'A01', DateTime(2030, 1, 1));
    expect(replaced1, isEmpty);

    final (id2, _, replaced2) = await Repo.i.saveBatch('111', 'A01', DateTime(2031, 5, 5));
    expect(replaced2, [id1]);

    final list = await Repo.i.listBatches(showDone: true);
    final mine = list.where((b) => b['barcode'] == '111').toList();
    expect(mine.length, 1);
    expect(mine.single['id'], id2);
    expect(mine.single['expiry_date'], '2031-05-05');
    expect((await Repo.i.currentBatch('111'))!['id'], id2);
  });

  test('已處理的舊紀錄也會被取代', () async {
    final (id1, _, _) = await Repo.i.saveBatch('222', 'A01', DateTime(2030, 1, 1));
    await Repo.i.markDone(id1);
    final (id2, status, replaced) = await Repo.i.saveBatch('222', 'A01', DateTime(2030, 2, 2));
    expect(replaced, [id1]);
    expect(status, '正常');
    final mine = (await Repo.i.listBatches(showDone: true)).where((b) => b['barcode'] == '222');
    expect(mine.map((b) => b['id']), [id2]);
  });

  test('待登錄：有效日期 0 的商品，登錄後移出、刪除後回來', () async {
    Map<String, String> prod(String code, String dept, String name, String date) =>
        {'條碼': code, '部門': dept, '品名': name, '店內碼': 'S', '有效日期': date};
    await Repo.i.importProducts([
      prod('p1', 'A02', '乙', kNone),
      prod('p2', 'A01', '甲', kNone),
      prod('p3', 'A01', '丙', '2027-01-01'), // 檔案有日期，匯入時就登錄，不算待登錄
      prod('p4', 'A04', '丁', kNone),
    ]);
    Future<List<Object?>> codes({String? dept}) async =>
        (await Repo.i.listPending(dept: dept)).map((p) => p['barcode']).toList();

    expect(await codes(), ['p2', 'p1', 'p4']); // 依部門、品名排序
    expect(await Repo.i.pendingCount(), 3);
    expect(await codes(dept: 'A01'), ['p2']);
    expect((await Repo.i.listPending(limit: 2, offset: 2)).map((p) => p['barcode']), ['p4']);

    final (id, _, _) = await Repo.i.saveBatch('p2', 'A01', DateTime(2030, 1, 1));
    expect(await codes(), ['p1', 'p4']);
    expect(await Repo.i.pendingCount(), 2);

    // 已處理仍算登錄過
    await Repo.i.markDone(id);
    expect(await Repo.i.pendingCount(), 2);

    // 刪除那筆紀錄後，又變回沒有到期日
    await Repo.i.softDelete(id);
    expect(await codes(), ['p2', 'p1', 'p4']);
  });

  test('匯入：檔案日期登錄成到期日，已有到期日的不覆蓋', () async {
    Map<String, String> prod(String code, String name, String date, {String dept = 'A01'}) =>
        {'條碼': code, '部門': dept, '品名': name, '店內碼': 'S', '有效日期': date};
    final soon = fmtDate(DateTime.now().add(const Duration(days: 10)));

    // 第一次匯入
    var s = await Repo.i.importProducts([
      prod('i1', '有日期', '2030-01-01'),
      prod('i2', '沒日期', kNone),
      prod('i3', '快到期', soon),
    ]);
    expect((s.registered, s.kept, s.due), (2, 0, 1));
    expect((await Repo.i.currentBatch('i1'))!['expiry_date'], '2030-01-01');
    expect(await Repo.i.currentBatch('i2'), isNull);

    // 手動登錄 i2
    await Repo.i.saveBatch('i2', 'A01', DateTime(2031, 3, 3));

    // 再匯入一份日期都不同的檔：已有到期日的全部保留
    s = await Repo.i.importProducts([
      prod('i1', '有日期-改名', '2099-09-09'),
      prod('i2', '沒日期', '2099-09-09'),
      prod('i3', '快到期', kNone),
      prod('i4', '新商品', '2032-02-02'),
    ]);
    expect((s.registered, s.kept), (1, 2));
    expect((await Repo.i.currentBatch('i1'))!['expiry_date'], '2030-01-01');
    expect((await Repo.i.currentBatch('i2'))!['expiry_date'], '2031-03-03');
    expect((await Repo.i.currentBatch('i3'))!['expiry_date'], soon);
    expect((await Repo.i.currentBatch('i4'))!['expiry_date'], '2032-02-02');
    // 品名照檔案更新，但參考有效日期不是 0 就不覆蓋
    final p1 = (await Repo.i.findProduct('i1'))!;
    expect(p1['name'], '有日期-改名');
    expect(p1['ref_expiry'], '2030-01-01');
    // 原本是 0 的參考日期可以被補上
    expect((await Repo.i.findProduct('i2'))!['ref_expiry'], '2099-09-09');
  });

  test('匯出：全部商品，有到期日填日期、沒有填 0，可以再匯入', () async {
    final rows = await Repo.i.exportRows();
    expect(rows.first, kExportHeader);
    final byCode = {for (final r in rows.skip(1)) r[0]: r};
    expect(byCode['i1']![4], '2030-01-01');
    expect(byCode['i4']![4], '2032-02-02');
    expect(byCode['p1']![4], '0');
    expect(byCode['i1']![3], '有日期-改名');
    expect(byCode['i1']![1], 'A01');
  });

  test('提醒通知依提醒日彙總', () async {
    final days = await Repo.i.upcomingRemindDays();
    expect(days, isNotEmpty);
    final dates = days.map((d) => d.date).toList();
    expect(dates, [...dates]..sort());
    expect(dates.toSet().length, dates.length); // 每天只有一則
    expect(days.every((d) => d.date.isAfter(DateTime.now())), isTrue);
  });

  test('掃描比對：完全相同優先，其次忽略開頭的 0', () async {
    Map<String, String> prod(String code, String name) =>
        {'條碼': code, '部門': 'A01', '品名': name, '店內碼': 'S', '有效日期': kNone};
    await Repo.i.upsertProducts([
      prod('68060286727', 'UPC 掉了 0'),
      prod('4719892835893', 'EAN-13'),
      prod('0012345', '本來就有 0'),
    ]);
    Future<Object?> name(String code) async => (await Repo.i.findProduct(code))?['name'];
    expect(await name('68060286727'), 'UPC 掉了 0');
    expect(await name('068060286727'), 'UPC 掉了 0'); // Android 讀成 UPC-A 12 碼
    expect(await name('0068060286727'), 'UPC 掉了 0'); // iOS 讀成 EAN-13
    expect(await name('4719892835893'), 'EAN-13');
    expect(await name('0012345'), '本來就有 0');
    expect(await name('12345'), '本來就有 0');
    expect(await name('719892835893'), isNull); // 不是開頭的 0，不能亂配
    expect(await name('000'), isNull);
  });

  test('掃描比對：條碼與店內碼都比對，條碼優先', () async {
    Map<String, String> prod(String code, String store, String name) =>
        {'條碼': code, '部門': 'A01', '品名': name, '店內碼': store, '有效日期': kNone};
    await Repo.i.upsertProducts([
      prod('4710000000001', '2100000000001', '商品甲'),
      prod('4710000000002', '2100000000002', '商品乙-1'),
      prod('4710000000003', '2100000000002', '商品乙-2'), // 共用店內碼
      prod('4710000000004', '4710000000001', '店內碼剛好等於甲的條碼'),
      prod('4710000000005', '0021000000005', '店內碼有開頭的 0'),
    ]);
    Future<List<Object?>> names(String code) async =>
        (await Repo.i.findProducts(code)).map((p) => p['name']).toList();

    expect(await names('4710000000001'), ['商品甲']); // 條碼優先於店內碼
    expect(await names('2100000000001'), ['商品甲']); // 用店內碼找到
    expect(await names('2100000000002'), ['商品乙-1', '商品乙-2']); // 共用店內碼回傳兩筆
    expect(await names('21000000005'), ['店內碼有開頭的 0']);
    expect(await names('2199999999999'), isEmpty);
  });

  test('搜尋：品名、店內碼、條碼部分比對，多個關鍵字都要符合', () async {
    Map<String, String> prod(String code, String store, String name, {String dept = 'A07'}) =>
        {'條碼': code, '部門': dept, '品名': name, '店內碼': store, '有效日期': kNone};
    await Repo.i.upsertProducts([
      prod('s1', '2100099000001', 'OLAY胜肽緊緻乳霜50g'),
      prod('s2', '2100099000002', 'OLAY 淨白精華 30ml'),
      prod('s3', '2100099000003', '蜂蜜卸妝油 100%純', dept: 'A08'),
      prod('s4', '2100099000004', 'a_b 特殊符號'),
    ]);
    await Repo.i.saveBatch('s1', 'A07', DateTime(2030, 1, 1));
    Future<List<Object?>> codes(String q, {String? dept}) async =>
        (await Repo.i.searchProducts(q, dept: dept)).map((p) => p['barcode']).toList();

    expect(await codes('olay'), unorderedEquals(['s1', 's2'])); // 英文不分大小寫
    expect(await codes('緊緻'), ['s1']);
    expect(await codes('OLAY 精華'), ['s2']); // 兩個關鍵字都要符合
    expect(await codes('9000003'), ['s3']); // 店內碼部分號碼
    expect(await codes('100%'), ['s3']); // % 當一般字元
    expect(await codes('a_b'), ['s4']); // _ 當一般字元
    expect(await codes('OLAY', dept: 'A08'), isEmpty); // 可搭配部門篩選
    expect(await Repo.i.searchCount('olay'), 2);

    // 已登錄的帶出到期日，未登錄的沒有
    final r = {for (final m in await Repo.i.searchProducts('OLAY')) m['barcode']: m};
    expect(r['s1']!['expiry_date'], '2030-01-01');
    expect(r['s1']!['status'], '正常');
    expect(r['s2']!['id'], isNull);
  });

  test('新增商品：國碼不可重複，新增後同時登錄到期日', () async {
    final (id, status) = await Repo.i.addProduct(
        barcode: 'n1', name: '新商品', dept: 'A02', storeCode: '', expiry: DateTime(2031, 1, 1));
    expect(status, '正常');
    final p = (await Repo.i.findProduct('n1'))!;
    expect((p['name'], p['dept'], p['store_code'], p['ref_expiry']), ('新商品', 'A02', kNone, kNone));
    expect((await Repo.i.currentBatch('n1'))!['id'], id);
    await expectLater(
        Repo.i.addProduct(barcode: 'n1', name: 'x', dept: 'A01', expiry: DateTime(2031)),
        throwsA(predicate((e) => '$e'.contains('已經在商品檔裡'))));
  });

  test('編輯商品：只改品名保留原紀錄；改日期或部門重新登錄；改國碼紀錄跟著走', () async {
    await Repo.i.addProduct(
        barcode: 'e1', name: '原名', dept: 'A01', storeCode: 'S1', expiry: DateTime(2031, 1, 1));
    final first = (await Repo.i.currentBatch('e1'))!;
    await Repo.i.markDone(first['id'] as String);

    // 只改品名、店內碼：不重新登錄，「已處理」保留
    var r = await Repo.i.updateProduct('e1',
        barcode: 'e1', name: '新名', dept: 'A01', storeCode: '', expiry: DateTime(2031, 1, 1));
    expect(r, isNull);
    var cur = (await Repo.i.currentBatch('e1'))!;
    expect((cur['id'], cur['status']), (first['id'], '已處理'));
    var p = (await Repo.i.findProduct('e1'))!;
    expect((p['name'], p['store_code']), ('新名', kNone));

    // 改到期日：重新登錄
    r = await Repo.i.updateProduct('e1',
        barcode: 'e1', name: '新名', dept: 'A01', expiry: DateTime(2032, 2, 2));
    expect(r, isNotNull);
    cur = (await Repo.i.currentBatch('e1'))!;
    expect((cur['expiry_date'], cur['status']), ('2032-02-02', '正常'));

    // 改部門成 A12：提醒日改用 45 天規則
    await Repo.i.updateProduct('e1',
        barcode: 'e1', name: '新名', dept: 'A12', expiry: DateTime(2032, 2, 2));
    cur = (await Repo.i.currentBatch('e1'))!;
    expect((cur['dept'], cur['remind_date']), ('A12', '2031-12-20'));

    // 改國碼：商品與紀錄都改到新國碼，舊國碼不見
    await Repo.i.updateProduct('e1',
        barcode: 'e2', name: '新名', dept: 'A12', expiry: DateTime(2032, 2, 2));
    expect(await Repo.i.barcodeExists('e1'), isFalse);
    expect((await Repo.i.currentBatch('e2'))!['expiry_date'], '2032-02-02');
    expect(await Repo.i.currentBatch('e1'), isNull);

    // 改成已存在的國碼：拒絕，資料不變
    await expectLater(
        Repo.i.updateProduct('e2',
            barcode: 'n1', name: '新名', dept: 'A12', expiry: DateTime(2032, 2, 2)),
        throwsA(predicate((e) => '$e'.contains('已經是其他商品'))));
    expect(await Repo.i.barcodeExists('e2'), isTrue);
  });

  test('A12 存入的提醒日與狀態', () async {
    final now = DateTime.now();
    final t = DateTime(now.year, now.month, now.day);
    final (_, s1, _) = await Repo.i.saveBatch('333', 'A12', DateTime(t.year, t.month, t.day + 60));
    expect(s1, '正常');
    final (_, s2, _) = await Repo.i.saveBatch('444', 'A12', DateTime(t.year, t.month, t.day + 30));
    expect(s2, '即將過期');
    final b = await Repo.i.currentBatch('333');
    expect(b!['remind_date'], fmtDate(DateTime(t.year, t.month, t.day + 16)));
  });
}
