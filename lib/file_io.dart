import 'dart:convert';
import 'package:charset_converter/charset_converter.dart';
import 'package:csv/csv.dart';
import 'package:excel_plus/excel_plus.dart';
import 'package:flutter/foundation.dart';
import 'db.dart';

/// 匯入／匯出商品檔：支援 .csv（UTF-8 / Big5）、.xlsx、.xls（只能讀）

const _wanted = ['部門', '品名', '條碼', '店內碼', '有效日期'];
final _sci = RegExp(r'^\d+(\.\d+)?[eE]\+?\d+$'); // Excel 的科學記號，例如 4.71989E+12

class ImportResult {
  final int ok;
  final List<String> failed;   // 匯入失敗清單
  final List<String> warnings; // 日期無法辨識等提醒
  final ImportStats stats;     // 依檔案日期登錄的結果
  ImportResult(this.ok, this.failed, this.warnings, this.stats);
}

class ParsedCsv {
  final List<Map<String, String>> good;
  final List<String> failed;
  final List<String> warnings;
  ParsedCsv(this.good, this.failed, this.warnings);
}

enum FileKind { csv, xlsx, xls }

/// 依檔頭判斷格式（副檔名在 Android 上常拿不到或不可靠）
FileKind sniffKind(Uint8List b) {
  if (b.length >= 4 && b[0] == 0x50 && b[1] == 0x4B && b[2] == 0x03 && b[3] == 0x04) {
    return FileKind.xlsx; // ZIP
  }
  if (b.length >= 4 && b[0] == 0xD0 && b[1] == 0xCF && b[2] == 0x11 && b[3] == 0xE0) {
    return FileKind.xls; // OLE2（Excel 97-2003）
  }
  return FileKind.csv;
}

Future<String> _decode(Uint8List bytes) async {
  try {
    return utf8.decode(bytes); // 嚴格 UTF-8，失敗就改用 Big5
  } on FormatException {
    return await CharsetConverter.decode('big5', bytes);
  }
}

/// 支援 2026-01-31 / 2026/1/31 / 20260131 / 民國 115/1/31
String normDate(String v) {
  if (v == kNone) return kNone;
  final m = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})').firstMatch(v) ??
      RegExp(r'^(\d{4})(\d{2})(\d{2})$').firstMatch(v) ??
      RegExp(r'^(\d{2,3})[-/.](\d{1,2})[-/.](\d{1,2})$').firstMatch(v);
  if (m == null) return kNone;
  var y = int.parse(m[1]!);
  if (m[1]!.length < 4) y += 1911; // 民國年
  final mo = int.parse(m[2]!), d = int.parse(m[3]!);
  final dt = DateTime(y, mo, d);
  if (dt.month != mo || dt.day != d) return kNone;
  return fmtDate(dt);
}

/// 解析 CSV 文字（不碰資料庫，方便測試）
ParsedCsv parseCsv(String text) {
  if (text.startsWith('﻿')) text = text.substring(1);
  // 保留空白行，錯誤訊息的「第幾行」才會對得上檔案
  final rows = const CsvDecoder(fieldDelimiter: ',', skipEmptyLines: false).convert(text);
  return parseRows(rows);
}

/// Excel 儲存格轉成文字。數字型的條碼不能變成 4719892835893.0 或科學記號，
/// 日期儲存格轉成 2026-01-31。
String cellText(CellValue? v) {
  String intText(String s) {
    final d = double.tryParse(s);
    if (d != null && d == d.truncateToDouble() && d.abs() < 1e15) return d.toInt().toString();
    return s;
  }

  return switch (v) {
    null => '',
    IntCellValue(:final value) => '$value',
    DoubleCellValue(:final value) => intText('$value'),
    DateCellValue(:final year, :final month, :final day) => fmtDate(DateTime(year, month, day)),
    DateTimeCellValue(:final year, :final month, :final day) =>
      fmtDate(DateTime(year, month, day)),
    FormulaCellValue(:final cachedValue) => intText(cachedValue ?? ''),
    _ => v.toString(),
  };
}

/// 解析 .xlsx / .xls：用第一個含有必要欄位的工作表
ParsedCsv parseExcel(Uint8List bytes) {
  final Excel book;
  try {
    book = Excel.decodeBytes(bytes);
  } catch (e) {
    throw Exception('無法讀取 Excel 檔（$e）');
  }
  List<List<String>>? first;
  for (final sheet in book.tables.values) {
    final rows = [for (final r in sheet.rows) [for (final c in r) cellText(c?.value)]];
    first ??= rows;
    if (_findHeader(rows) != null) return parseRows(rows);
  }
  return parseRows(first ?? const []);
}

/// 「條碼」欄位在畫面上改叫「國碼」；檔案的表頭兩種寫法都接受（程式內部仍用「條碼」當 key）
List<String> _headerOf(List row) =>
    row.map((e) => e.toString().trim()).map((h) => h == '國碼' ? '條碼' : h).toList();

String _shown(String k) => k == '條碼' ? '國碼' : k;

/// 表頭不一定在第一行（Excel 常有標題列），在前 10 行裡找
int? _findHeader(List<List<dynamic>> rows) {
  for (var i = 0; i < rows.length && i < 10; i++) {
    if (_wanted.every(_headerOf(rows[i]).contains)) return i;
  }
  return null;
}

ParsedCsv parseRows(List<List<dynamic>> rows) {
  if (rows.every((r) => r.every((c) => c.toString().trim().isEmpty))) {
    throw Exception('檔案是空的');
  }
  final h0 = _findHeader(rows);
  if (h0 == null) {
    final header = _headerOf(rows.first);
    final missing = _wanted.where((k) => !header.contains(k)).map(_shown).toList();
    throw Exception('缺少欄位：${missing.join('、')}');
  }
  final header = _headerOf(rows[h0]);
  final idx = {for (final k in _wanted) k: header.indexOf(k)};

  String cell(List r, String k) {
    final i = idx[k]!;
    if (i >= r.length) return kNone;
    final v = r[i].toString().trim();
    return v.isEmpty ? kNone : v;
  }

  final good = <String, Map<String, String>>{}; // 以條碼為 key，重複時後者覆蓋
  final firstLine = <String, int>{};
  final failed = <String>[];
  final warnings = <String>[];
  for (var n = h0 + 1; n < rows.length; n++) {
    final r = rows[n];
    if (r.every((c) => c.toString().trim().isEmpty)) continue;
    final m = {for (final k in _wanted) k: cell(r, k)};
    final line = '第${n + 1}行 ${m['品名']} / ${m['條碼']}';
    final code = m['條碼']!;
    if (code == kNone) { failed.add('$line：國碼空白'); continue; }
    if (_sci.hasMatch(code)) {
      failed.add('$line：國碼被 Excel 轉成科學記號，請把國碼欄設成「文字」再存檔');
      continue;
    }
    if (!kDepts.contains(m['部門'])) { failed.add('$line：部門「${m['部門']}」不在清單內'); continue; }
    if (_sci.hasMatch(m['店內碼']!)) warnings.add('$line：店內碼被 Excel 轉成科學記號');
    if (m['有效日期'] == '0') m['有效日期'] = kNone; // 0 代表沒有日期
    final raw = m['有效日期']!;
    m['有效日期'] = normDate(raw);
    if (raw != kNone && m['有效日期'] == kNone) warnings.add('$line：日期「$raw」無法辨識');
    if (good.containsKey(code)) {
      // 原因放固定文字，摘要時才能歸成同一組
      warnings.add('$line（同第${firstLine[code]}行）：國碼重複，以後面那一行為準');
    } else {
      firstLine[code] = n + 1;
    }
    good[code] = m;
  }
  return ParsedCsv(good.values.toList(), failed, warnings);
}

/// 匯入檔案（格式自動判斷），寫入資料庫並登錄檔案裡的有效日期
Future<ImportResult> importFile(Uint8List bytes) async {
  // 幾萬行的檔案在背景解析，避免畫面卡住
  final p = switch (sniffKind(bytes)) {
    FileKind.csv => await compute(parseCsv, await _decode(bytes)),
    _ => await compute(parseExcel, bytes),
  };
  final stats = await Repo.i.importProducts(p.good);
  return ImportResult(p.good.length, p.failed, p.warnings, stats);
}

/// 匯出成 CSV（UTF-8 含 BOM，Excel 開啟中文不會亂碼）
Uint8List buildCsv(List<List<String>> rows) =>
    utf8.encode(const CsvEncoder(addBom: true).convert(rows));

/// 匯出成 .xlsx。全部存成文字，條碼才不會被 Excel 變成科學記號或掉了開頭的 0
Uint8List buildXlsx(List<List<String>> rows) {
  final book = Excel.createExcel();
  final name = book.tables.keys.first;
  book.rename(name, '商品');
  final sheet = book['商品'];
  for (final r in rows) {
    sheet.appendRow([for (final v in r) TextCellValue(v)]);
  }
  return Uint8List.fromList(book.encode()!);
}

/// 把問題清單依原因分組，每組只列前 [sample] 筆。
/// 清單可能有幾萬行，整串塞進對話框會讓 App 閃退。
/// 每筆的格式是「第N行 品名 / 條碼：原因」。
String summarizeIssues(String title, List<String> items, {int sample = 10}) {
  final groups = <String, List<String>>{};
  for (final s in items) {
    final i = s.lastIndexOf('：');
    final reason = i < 0 ? s : s.substring(i + 1);
    groups.putIfAbsent(reason, () => []).add(i < 0 ? s : s.substring(0, i));
  }
  final out = StringBuffer('【$title ${items.length} 筆】');
  final sorted = groups.entries.toList()..sort((a, b) => b.value.length - a.value.length);
  for (final g in sorted) {
    out.write('\n\n● ${g.key}（${g.value.length} 筆）');
    for (final l in g.value.take(sample)) {
      out.write('\n  $l');
    }
    if (g.value.length > sample) out.write('\n  …其餘 ${g.value.length - sample} 筆省略');
  }
  return out.toString();
}
