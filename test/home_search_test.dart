import 'package:expiry_app/db.dart';
import 'package:expiry_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  testWidgets('主畫面搜尋：打幾個字就列出符合的商品', (tester) async {
    await tester.runAsync(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await databaseFactory.deleteDatabase(p.join(await getDatabasesPath(), 'test_home.db'));
      await Repo.i.init(name: 'test_home.db');
      Map<String, String> prod(String code, String store, String name) =>
          {'條碼': code, '部門': 'A01', '品名': name, '店內碼': store, '到期日期': kNone};
      await Repo.i.upsertProducts([
        prod('4710000000001', '2100012318426', '蜂蜜卸妝油180ml'),
        prod('4710000000002', '2100012318433', '蜂蜜潔顏膏90g'),
        prod('4710000000003', '2100000000003', '3M修護貼24入'),
      ]);
      await Repo.i.saveBatch('4710000000002', 'A01', DateTime(2030, 1, 1));
    });

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 150)));
        await tester.pump(const Duration(milliseconds: 400));
      }
    }

    await settle();
    expect(find.text('搜尋品名、店內碼、國碼（可只打幾個字）'), findsOneWidget);

    // 品名部分文字
    await tester.enterText(find.byType(TextField), '蜂蜜');
    await settle();
    expect(find.text('搜尋結果 共 2 筆'), findsOneWidget);
    expect(find.text('蜂蜜卸妝油180ml'), findsOneWidget);
    expect(find.text('蜂蜜潔顏膏90g'), findsOneWidget);
    expect(find.text('3M修護貼24入'), findsNothing);
    expect(find.text('待登錄'), findsWidgets); // 未登錄的顯示待登錄
    expect(find.text('A01・到期日 2030-01-01'), findsOneWidget); // 已登錄的顯示到期日

    // 店內碼部分號碼
    await tester.enterText(find.byType(TextField), '18426');
    await settle();
    expect(find.text('搜尋結果 共 1 筆'), findsOneWidget);
    expect(find.text('蜂蜜卸妝油180ml'), findsOneWidget);

    // 找不到
    await tester.enterText(find.byType(TextField), '不存在的商品');
    await settle();
    expect(find.text('找不到符合「不存在的商品」的商品'), findsOneWidget);

    // 清除後回到原本的清單
    await tester.tap(find.byIcon(Icons.clear));
    await settle();
    expect(find.textContaining('搜尋結果'), findsNothing);
    expect(find.textContaining('未處理'), findsOneWidget);
  });
}
