import 'package:expiry_app/file_io.dart';
import 'package:expiry_app/db.dart';
import 'package:expiry_app/notify.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('subMonths', () {
    test('一般日期', () => expect(subMonths(DateTime(2026, 12, 15), 6), DateTime(2026, 6, 15)));
    test('跨年', () => expect(subMonths(DateTime(2027, 3, 10), 6), DateTime(2026, 9, 10)));
    test('月底超出取最後一天', () => expect(subMonths(DateTime(2026, 8, 31), 6), DateTime(2026, 2, 28)));
    test('閏年 2/29', () => expect(subMonths(DateTime(2028, 8, 31), 6), DateTime(2028, 2, 29)));
  });

  group('statusFor 一般部門（6 個月）', () {
    final today = DateTime(2026, 10, 27, 15, 30);
    test('超過 6 個月 → 正常', () => expect(statusFor('A01', DateTime(2027, 4, 28), today), '正常'));
    test('剛好 6 個月（提醒日是今天）→ 即將過期',
        () => expect(statusFor('A01', DateTime(2027, 4, 27), today), '即將過期'));
    test('已過期 → 即將過期', () => expect(statusFor('A01', DateTime(2026, 1, 1), today), '即將過期'));
    test('剩 60 天 → 即將過期', () => expect(statusFor('A01', DateTime(2026, 12, 26), today), '即將過期'));
  });

  group('statusFor A12（剩不到 45 天）', () {
    final today = DateTime(2026, 10, 27, 15, 30);
    test('剩 60 天 → 正常', () => expect(statusFor('A12', DateTime(2026, 12, 26), today), '正常'));
    test('剩 45 天 → 正常', () => expect(statusFor('A12', DateTime(2026, 12, 11), today), '正常'));
    test('剩 44 天 → 即將過期', () => expect(statusFor('A12', DateTime(2026, 12, 10), today), '即將過期'));
    test('已過期 → 即將過期', () => expect(statusFor('A12', DateTime(2026, 10, 1), today), '即將過期'));
    test('提醒日 = 到期前 44 天（跨月）',
        () => expect(remindDateFor('A12', DateTime(2027, 1, 10)), DateTime(2026, 11, 27)));
    test('POYA 跟 A12 一樣：剩 45 天正常、44 天即將過期', () {
      expect(statusFor('POYA', DateTime(2026, 12, 11), today), '正常');
      expect(statusFor('POYA', DateTime(2026, 12, 10), today), '即將過期');
      expect(remindDateFor('POYA', DateTime(2027, 1, 10)), DateTime(2026, 11, 27));
      expect(remindRuleLabel('POYA'), '不足 45 天');
    });
    test('B01、B04 仍是 6 個月',
        () => expect(statusFor('B04', DateTime(2026, 12, 26), today), '即將過期'));
    test('其他部門提醒日 = 到期前 6 個月',
        () => expect(remindDateFor('A02', DateTime(2027, 1, 10)), DateTime(2026, 7, 10)));
  });

  group('normDate', () {
    test('2026-01-31', () => expect(normDate('2026-01-31'), '2026-01-31'));
    test('2026/1/5', () => expect(normDate('2026/1/5'), '2026-01-05'));
    test('20260131', () => expect(normDate('20260131'), '2026-01-31'));
    test('含時間', () => expect(normDate('2026/1/5 00:00'), '2026-01-05'));
    test('民國年', () => expect(normDate('115/1/31'), '2026-01-31'));
    test('不存在的日期', () => expect(normDate('2026-02-30'), kNone));
    test('亂碼', () => expect(normDate('abc'), kNone));
  });

  test('通知編號固定且為正整數', () {
    const id = '3f2b6c1e-8d7a-4b1e-9c3a-2f1e0d9c8b7a';
    expect(notificationId(id), notificationId(id));
    expect(notificationId(id), greaterThanOrEqualTo(0));
    expect(notificationId(id), isNot(notificationId('another-id')));
  });

  group('parseCsv', () {
    test('欄位順序不限、BOM、CRLF、引號、空白行', () {
      const text = '﻿備註,條碼,品名,部門,店內碼,到期日期\r\n'
          'x,4710000000011,"鮮奶, 大",A01,S1,2026/12/31\r\n'
          '\r\n'
          ',4710000000028,餅乾,A02,S2,\r\n';
      final r = parseCsv(text);
      expect(r.failed, isEmpty);
      expect(r.warnings, isEmpty);
      expect(r.good.length, 2);
      expect(r.good[0]['品名'], '鮮奶, 大');
      expect(r.good[0]['到期日期'], '2026-12-31');
      expect(r.good[1]['到期日期'], kNone);
      expect(r.good[1]['店內碼'], 'S2');
    });

    test('缺欄位丟出例外', () {
      expect(() => parseCsv('條碼,品名\n1,a\n'), throwsException);
    // 缺少的欄位用畫面上的名稱「國碼」提示
    expect(() => parseCsv('品名,部門\n1,a\n'),
        throwsA(predicate((e) => '$e'.contains('國碼') && !'$e'.contains('條碼'))));
  });

  test('表頭寫「國碼」或「條碼」都可以匯入', () {
    for (final h in ['國碼', '條碼']) {
      final r = parseCsv('$h,部門,店內碼,品名,到期日期\n4719892835893,A01,2100012318426,商品,0\n');
      expect(r.failed, isEmpty, reason: h);
      expect(r.good.single['條碼'], '4719892835893', reason: h);
    }
    });

    test('失敗與提醒，行號對得上檔案', () {
      const text = '部門,品名,條碼,店內碼,到期日期\n'
          'A01,無條碼,,S,2026-01-01\n'
          'Z99,錯部門,111,S,2026-01-01\n'
          'A01,科學記號,4.71E+12,S,2026-01-01\n'
          '\n'
          'A01,壞日期,222,S,明年\n'
          'A01,重複,222,S,2026-05-05\n';
      final r = parseCsv(text);
      expect(r.failed.length, 3);
      expect(r.failed[0], startsWith('第2行'));
      expect(r.failed[1], contains('Z99'));
      expect(r.failed[2], contains('科學記號'));
      expect(r.warnings.length, 2);
      expect(r.warnings[0], startsWith('第6行'));
      expect(r.warnings[1], contains('同第6行'));
      expect(r.warnings[1], endsWith('國碼重複，以後面那一行為準'));
      expect(r.good.length, 1);
      expect(r.good.single['品名'], '重複');
    });

    test('B01、B04、POYA 部門可以匯入', () {
      const text = '條碼,部門,店內碼,品名,到期日期\n'
          '1,B01,S,雪肌精,0\n'
          '2,B04,S,資生堂,0\n'
          '3,POYA,S,寶雅購物袋,0\n';
      final r = parseCsv(text);
      expect(r.failed, isEmpty);
      expect(r.good.map((m) => m['部門']), ['B01', 'B04', 'POYA']);
    });

    test('到期日期 0 視為空白、店內碼科學記號只提醒', () {
      const text = '條碼,部門,店內碼,品名,到期日期\n'
          '68060286727,A01,2.10001E+12, 3M修護貼,0\n';
      final r = parseCsv(text);
      expect(r.good.single['到期日期'], kNone);
      expect(r.good.single['品名'], '3M修護貼');
      expect(r.warnings.single, endsWith('店內碼被 Excel 轉成科學記號'));
    });
  });

  group('summarizeIssues', () {
    test('幾萬筆也只輸出很短的摘要', () {
      final items = [
        for (var i = 0; i < 76000; i++) '第${i + 2}行 商品$i / 4.7E+12：條碼被 Excel 轉成科學記號',
        '第99999行 x / 1：部門「Z99」不在清單內',
      ];
      final s = summarizeIssues('失敗', items);
      expect(s, startsWith('【失敗 76001 筆】'));
      expect(s, contains('● 條碼被 Excel 轉成科學記號（76000 筆）'));
      expect(s, contains('…其餘 75990 筆省略'));
      expect(s, contains('● 部門「Z99」不在清單內（1 筆）'));
      expect(s.length, lessThan(2000));
    });
  });
}
