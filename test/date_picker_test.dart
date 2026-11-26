import 'package:expiry_app/db.dart';
import 'package:expiry_app/entry_page.dart';
import 'package:expiry_app/main.dart';
import 'package:expiry_app/tw_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  testWidgets('選擇到期日：繁體中文、顯示年份與週、一週從星期日開始', (tester) async {
    await tester.runAsync(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await databaseFactory.deleteDatabase(p.join(await getDatabasesPath(), 'test_picker.db'));
      await Repo.i.init(name: 'test_picker.db');
    });
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 400));
      }
    }

    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      locale: kAppLocale,
      supportedLocales: const [kAppLocale],
      localizationsDelegates: kLocalizationsDelegates,
      home: const EntryPage(product: {
        'barcode': '4710000000001', 'dept': 'A02', 'name': '洗髮精',
        'store_code': '2100000000001', 'ref_expiry': kNone,
      }),
    ));
    await settle();
    await tester.tap(find.text('點這裡選擇到期日'));
    await settle();

    expect(find.text('選取日期'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('確定'), findsOneWidget);
    final now = DateTime.now();
    final wk = ['日', '一', '二', '三', '四', '五', '六'][now.weekday % 7];
    expect(find.text('${now.year}年${now.month}月${now.day}日 週$wk'), findsOneWidget);
    expect(find.text('${now.year}年${now.month}月'), findsOneWidget);
    // 星期列：第一個是「日」
    final headers = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .where((s) => ['日', '一', '二', '三', '四', '五', '六'].contains(s))
        .toList();
    expect(headers.take(7), ['日', '一', '二', '三', '四', '五', '六']);

    // 右上角的筆切換成鍵盤輸入，用 年/月/日 格式
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await settle();
    expect(find.text('輸入日期'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '2027/3/15');
    await settle();
    await tester.tap(find.text('確定'));
    await settle();
    expect(find.text('2027-03-15'), findsOneWidget); // 登錄畫面顯示選好的日期
    expect(find.text('儲存'), findsOneWidget);
  });
}
