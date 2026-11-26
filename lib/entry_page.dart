import 'package:flutter/material.dart';
import 'db.dart';
import 'notify.dart';

/// 選到期日的月曆（登錄與編輯共用）
Future<DateTime?> pickExpiryDate(BuildContext context, DateTime? initial) {
  final now = DateTime.now();
  final first = DateTime(now.year - 1);
  final last = DateTime(now.year + 15, 12, 31);
  var init = initial ?? now;
  if (init.isBefore(first)) init = first;
  if (init.isAfter(last)) init = last;
  return showDatePicker(
    context: context,
    initialDate: init,
    firstDate: first,
    lastDate: last,
    // 預設用月曆點選；右上角的筆可切換成鍵盤輸入（幾年後的日期用打的比較快）
    initialEntryMode: DatePickerEntryMode.calendar,
    helpText: '選取日期',
    cancelText: '取消',
    confirmText: '確定',
  );
}

class EntryPage extends StatefulWidget {
  final Map<String, Object?> product;
  const EntryPage({super.key, required this.product});
  @override
  State<EntryPage> createState() => _EntryPageState();
}

class _EntryPageState extends State<EntryPage> {
  DateTime? _expiry;
  bool _saving = false;
  Map<String, Object?>? _current; // 這個商品目前登錄的批次

  @override
  void initState() {
    super.initState();
    Repo.i.currentBatch(widget.product['barcode'] as String).then((b) {
      if (mounted) setState(() => _current = b);
    });
  }

  Future<void> _pick() async {
    final d = await pickExpiryDate(context, _expiry);
    if (d != null) setState(() => _expiry = d);
  }

  Future<void> _save() async {
    if (_saving) return; // 防止連點存成兩筆
    setState(() => _saving = true);
    try {
      await _doSave();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _doSave() async {
    final p = widget.product;
    final dept = p['dept'] as String;
    final (id, status, replaced) =
        await Repo.i.saveBatch(p['barcode'] as String, dept, _expiry!);
    for (final old in replaced) {
      await Notifier.cancel(old); // 舊到期日的通知不再需要
    }
    final title = '商品即將過期';
    final body = '$dept ${p['name']}　到期日 ${fmtDate(_expiry!)}';
    // 已在提醒範圍內就立即通知；之後的提醒由主畫面重新整理時統一排程
    if (status == '即將過期') await Notifier.showNow(id, title, body);
    if (!mounted) return;
    final head = replaced.isEmpty ? '已儲存' : '已更新到期日';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(status == '即將過期' ? '$head：${remindRuleLabel(dept)}，標示即將過期' : head)));
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final ref = p['ref_expiry'];
    Widget info(String k, Object? v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            SizedBox(
                width: 64, child: Text(k, style: const TextStyle(color: Colors.grey, fontSize: 14))),
            Expanded(child: Text('$v', style: const TextStyle(fontSize: 16))),
          ]),
        );
    final pink = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(title: const Text('登錄效期')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('${p['name']}',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, height: 1.3)),
        const SizedBox(height: 10),
        info('部門', p['dept']),
        info('國碼', p['barcode']),
        info('店內碼', p['store_code']),
        if (ref != null && ref != kNone) info('參考日期', '$ref（僅供參考）'),
        if (_current != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: const Color(0xFFFFF4E5), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              const Icon(Icons.info_outline, color: Color(0xFFD84315)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    '目前登錄的到期日：${_current!['expiry_date']}\n同一商品只保留一筆，儲存後會以新的日期取代',
                    style: const TextStyle(fontSize: 14, color: Color(0xFF8A3A00))),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 20),
        // 選日期：整塊大按鈕，選好後日期用大字顯示
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(76),
            side: BorderSide(color: pink, width: 1.5),
          ),
          onPressed: _pick,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.calendar_month, size: 28, color: pink),
            const SizedBox(width: 10),
            Text(_expiry == null ? '點這裡選擇到期日' : fmtDate(_expiry!),
                style: TextStyle(
                    fontSize: _expiry == null ? 18 : 26, fontWeight: FontWeight.bold, color: pink)),
          ]),
        ),
      ]),
      // 儲存放在下方，單手按得到
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(58)),
            onPressed: _expiry == null || _saving ? null : _save,
            child: Text(_expiry == null ? '先選擇到期日' : '儲存', style: const TextStyle(fontSize: 19)),
          ),
        ),
      ),
    );
  }
}
