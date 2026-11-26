import 'dart:convert';
import 'dart:typed_data';
import 'package:excel_plus/excel_plus.dart';
import 'package:expiry_app/db.dart';
import 'package:expiry_app/file_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const rows = [
    kExportHeader,
    ['4719892835893', 'A01', '2100012318426', '&honey卸妝油180ml', '2030-01-01'],
    ['068060286727', 'A12', '2100012034746', '品名, 有逗號', '0'],
    ['42231264', 'POYA', '', '"引號"商品', '0'],
  ];

  void expectRoundTrip(ParsedCsv p) {
    expect(p.failed, isEmpty);
    expect(p.good.length, 3);
    expect(p.good[0]['條碼'], '4719892835893');
    expect(p.good[0]['有效日期'], '2030-01-01');
    expect(p.good[1]['條碼'], '068060286727'); // 開頭的 0 保留
    expect(p.good[1]['品名'], '品名, 有逗號');
    expect(p.good[1]['有效日期'], kNone);
    expect(p.good[2]['店內碼'], kNone);
    expect(p.good[2]['品名'], '"引號"商品');
  }

  test('xlsx 匯出再匯入，內容不變', () {
    final bytes = buildXlsx(rows);
    expect(sniffKind(bytes), FileKind.xlsx);
    expectRoundTrip(parseExcel(bytes));
  });

  test('csv 匯出再匯入，內容不變（含 BOM）', () {
    final bytes = buildCsv(rows);
    expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
    expect(sniffKind(bytes), FileKind.csv);
    expectRoundTrip(parseCsv(utf8.decode(bytes)));
  });

  test('判斷 xls 檔頭', () {
    expect(sniffKind(Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0, 0])), FileKind.xls);
  });

  test('Excel 數字、日期儲存格轉文字', () {
    expect(cellText(const IntCellValue(4719892835893)), '4719892835893');
    expect(cellText(const DoubleCellValue(4719892835893.0)), '4719892835893');
    expect(cellText(const DoubleCellValue(1.5)), '1.5');
    expect(cellText(const DateCellValue(year: 2030, month: 1, day: 5)), '2030-01-05');
    expect(cellText(const FormulaCellValue('A1', cachedValue: '4.719892835893E12')), '4719892835893');
    expect(cellText(TextCellValue('文字')), '文字');
    expect(cellText(null), '');
  });

  test('Excel 有標題列、數字型條碼與日期儲存格', () {
    final book = Excel.createExcel();
    final sheet = book[book.tables.keys.first];
    sheet.appendRow([TextCellValue('門市商品清單')]); // 標題列
    sheet.appendRow([for (final h in kExportHeader) TextCellValue(h)]);
    sheet.appendRow([
      const IntCellValue(4719892835893),
      TextCellValue('A02'),
      const DoubleCellValue(2100012318426),
      TextCellValue('數字條碼'),
      const DateCellValue(year: 2030, month: 2, day: 3),
    ]);
    sheet.appendRow([
      const IntCellValue(68060286727),
      TextCellValue('A02'),
      TextCellValue('S'),
      TextCellValue('日期是 0'),
      const IntCellValue(0),
    ]);
    final p = parseExcel(Uint8List.fromList(book.encode()!));
    expect(p.failed, isEmpty);
    expect(p.good[0]['條碼'], '4719892835893');
    expect(p.good[0]['店內碼'], '2100012318426');
    expect(p.good[0]['有效日期'], '2030-02-03');
    expect(p.good[1]['有效日期'], kNone);
  });

  test('Excel 缺欄位', () {
    final book = Excel.createExcel();
    book[book.tables.keys.first].appendRow([TextCellValue('條碼'), TextCellValue('品名')]);
    expect(() => parseExcel(Uint8List.fromList(book.encode()!)),
        throwsA(predicate((e) => '$e'.contains('缺少欄位'))));
  });
}
