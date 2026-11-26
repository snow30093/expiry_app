import 'package:expiry_app/db.dart';
import 'package:expiry_app/main.dart';
import 'package:expiry_app/product_form_page.dart';
import 'package:expiry_app/tw_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await databaseFactory.deleteDatabase(p.join(await getDatabasesPath(), 'test_form.db'));
    await Repo.i.init(name: 'test_form.db');
  });

  Future<void> pumpForm(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      locale: kAppLocale,
      supportedLocales: const [kAppLocale],
      localizationsDelegates: kLocalizationsDelegates,
      home: page,
    ));
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  testWidgets('新增商品：國碼預先帶入，店內碼以外都必填', (tester) async {
    await pumpForm(tester, const ProductFormPage(initialBarcode: '4719999000001'));
    expect(find.text('新增商品'), findsOneWidget);
    expect(find.text('4719999000001'), findsOneWidget); // 掃到的條碼帶入國碼欄

    // 什麼都不填就按新增：品名、部門、到期日顯示必填，店內碼不會
    await tester.tap(find.text('新增'));
    await tester.pumpAndSettle();
    expect(find.text('請輸入品名'), findsOneWidget);
    expect(find.text('請選擇部門'), findsOneWidget);
    expect(find.text('請輸入到期日'), findsOneWidget);
    expect(find.textContaining('店內碼').evaluate().length, 1); // 只有欄位名稱，沒有錯誤訊息

    // 國碼被清空也要擋
    await tester.enterText(field('國碼 *'), '');
    await tester.tap(find.text('新增'));
    await tester.pumpAndSettle();
    expect(find.text('請輸入國碼'), findsOneWidget);
    await tester.enterText(field('國碼 *'), '4719999000001');

    await tester.enterText(field('品名 *'), '測試新商品');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A07').last);
    await tester.pumpAndSettle();

    // 日期格式錯誤
    await tester.enterText(field('到期日 *'), '明年三月');
    await tester.tap(find.text('新增'));
    await tester.pumpAndSettle();
    expect(find.text('日期格式不正確，例如 2027/3/15'), findsOneWidget);

    // 直接打字輸入日期
    await tester.enterText(field('到期日 *'), '2027/3/15');
    await tester.tap(find.text('新增'));
    await settle(tester);

    final saved = await tester.runAsync(() => Repo.i.findProduct('4719999000001'));
    expect(saved!['name'], '測試新商品');
    expect(saved['dept'], 'A07');
    expect(saved['store_code'], kNone);
    final batch = await tester.runAsync(() => Repo.i.currentBatch('4719999000001'));
    expect(batch!['expiry_date'], '2027-03-15');
  });

  testWidgets('編輯商品：帶出原本內容，可用月曆圖示選日期', (tester) async {
    await tester.runAsync(() => Repo.i.addProduct(
        barcode: '4710000000777', name: '洗面乳', dept: 'A04', storeCode: '2100000000777',
        expiry: DateTime(2027, 5, 5)));
    final row = (await tester.runAsync(() => Repo.i.searchProducts('洗面乳')))!.single;
    await pumpForm(tester, ProductFormPage(product: row));

    expect(find.text('編輯商品'), findsOneWidget);
    expect(find.text('4710000000777'), findsOneWidget);
    expect(find.text('洗面乳'), findsOneWidget);
    expect(find.text('A04'), findsOneWidget);
    expect(find.text('2100000000777'), findsOneWidget);
    expect(find.text('2027-05-05'), findsOneWidget);

    // 月曆圖示打開日期選擇器，選 20 號
    await tester.tap(find.byIcon(Icons.calendar_month));
    await tester.pumpAndSettle();
    expect(find.text('選取日期'), findsOneWidget);
    await tester.tap(find.text('20'));
    await tester.tap(find.text('確定'));
    await tester.pumpAndSettle();
    expect(find.text('2027-05-20'), findsOneWidget);

    await tester.enterText(field('品名 *'), '洗面乳-改名');
    await tester.tap(find.text('儲存變更'));
    await settle(tester);
    final saved = await tester.runAsync(() => Repo.i.findProduct('4710000000777'));
    expect(saved!['name'], '洗面乳-改名');
    final batch = await tester.runAsync(() => Repo.i.currentBatch('4710000000777'));
    expect(batch!['expiry_date'], '2027-05-20');
  });
}
