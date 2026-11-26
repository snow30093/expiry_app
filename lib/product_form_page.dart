import 'package:flutter/material.dart';
import 'db.dart';
import 'entry_page.dart';
import 'file_io.dart';
import 'notify.dart';

/// 商品表單：新增（掃描到商品檔沒有的國碼）與編輯（長按卡片）共用。
/// 除了店內碼，其他欄位都必填。
class ProductFormPage extends StatefulWidget {
  /// 編輯時傳入卡片資料（含 barcode、name、dept、store_code、expiry_date）；新增時為 null
  final Map<String, Object?>? product;

  /// 新增時預先帶入的國碼（掃描到的條碼）
  final String? initialBarcode;

  const ProductFormPage({super.key, this.product, this.initialBarcode});

  bool get isEdit => product != null;

  @override
  State<ProductFormPage> createState() => _ProductFormPageState();
}

class _ProductFormPageState extends State<ProductFormPage> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _barcode, _name, _store, _expiry;
  String? _dept;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final p = widget.product ?? const {};
    String v(Object? x) => (x == null || x == kNone) ? '' : '$x';
    _barcode = TextEditingController(text: widget.isEdit ? v(p['barcode']) : widget.initialBarcode ?? '');
    _name = TextEditingController(text: v(p['name']));
    _store = TextEditingController(text: v(p['store_code']));
    _expiry = TextEditingController(text: v(p['expiry_date']));
    final d = p['dept'] as String?;
    _dept = kDepts.contains(d) ? d : null;
  }

  @override
  void dispose() {
    for (final c in [_barcode, _name, _store, _expiry]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _required(String? v, String label) =>
      (v == null || v.trim().isEmpty) ? '請輸入$label' : null;

  /// 到期日可直接打字（2027/3/15、2027-03-15、20270315、民國 116/3/15 都可以）
  String? _validateDate(String? v) {
    final r = _required(v, '到期日');
    if (r != null) return r;
    if (normDate(v!.trim()) == kNone) return '日期格式不正確，例如 2027/3/15';
    return null;
  }

  Future<void> _pickDate() async {
    final cur = normDate(_expiry.text.trim());
    final d = await pickExpiryDate(context, cur == kNone ? null : DateTime.parse(cur));
    if (d != null) {
      setState(() => _expiry.text = fmtDate(d));
      _form.currentState?.validate();
    }
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() => _saving = true);
    final barcode = _barcode.text.trim();
    final name = _name.text.trim();
    final dept = _dept!;
    final store = _store.text.trim();
    final expiry = DateTime.parse(normDate(_expiry.text.trim()));
    try {
      final (String, String)? r = widget.isEdit
          ? await Repo.i.updateProduct(widget.product!['barcode'] as String,
              barcode: barcode, name: name, dept: dept, storeCode: store, expiry: expiry)
          : await Repo.i.addProduct(
              barcode: barcode, name: name, dept: dept, storeCode: store, expiry: expiry);
      // 已在提醒範圍內就立即通知；之後的提醒由主畫面統一排程
      if (r != null && r.$2 == '即將過期') {
        await Notifier.showNow(r.$1, '商品即將過期', '$dept $name　到期日 ${fmtDate(expiry)}');
      }
      if (!mounted) return;
      final head = widget.isEdit ? '已儲存變更' : '已新增商品';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r?.$2 == '即將過期' ? '$head：${remindRuleLabel(dept)}，標示即將過期' : head)));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: Colors.red.shade700,
          content: Text(e.toString().replaceFirst('Exception: ', ''))));
      setState(() => _saving = false);
    }
  }

  InputDecoration _deco(String label, {bool required = true, String? hint, Widget? suffix}) =>
      InputDecoration(
        labelText: required ? '$label *' : '$label（選填）',
        hintText: hint,
        suffixIcon: suffix,
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      );

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 16);
    return Scaffold(
      appBar: AppBar(title: Text(widget.isEdit ? '編輯商品' : '新增商品')),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (!widget.isEdit)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                  color: const Color(0xFFFFF4E5), borderRadius: BorderRadius.circular(12)),
              child: const Text('這個國碼不在商品檔內，填好資料後會新增商品並登錄到期日。',
                  style: TextStyle(fontSize: 14, color: Color(0xFF8A3A00))),
            ),
          TextFormField(
            controller: _barcode,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 17),
            decoration: _deco('國碼'),
            validator: (v) => _required(v, '國碼'),
          ),
          gap,
          TextFormField(
            controller: _name,
            style: const TextStyle(fontSize: 17),
            decoration: _deco('品名'),
            validator: (v) => _required(v, '品名'),
          ),
          gap,
          DropdownButtonFormField<String>(
            initialValue: _dept,
            decoration: _deco('部門'),
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 17),
            items: [for (final d in kDepts) DropdownMenuItem(value: d, child: Text(d))],
            onChanged: (v) => setState(() => _dept = v),
            validator: (v) => v == null ? '請選擇部門' : null,
          ),
          gap,
          TextFormField(
            controller: _store,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 17),
            decoration: _deco('店內碼', required: false),
          ),
          gap,
          TextFormField(
            controller: _expiry,
            keyboardType: TextInputType.datetime,
            style: const TextStyle(fontSize: 17),
            decoration: _deco('到期日',
                hint: '例如 2027/3/15',
                suffix: IconButton(
                  tooltip: '用月曆選擇',
                  icon: const Icon(Icons.calendar_month, size: 28),
                  onPressed: _pickDate,
                )),
            validator: _validateDate,
          ),
          const SizedBox(height: 8),
          const Text('* 為必填', style: TextStyle(color: Colors.grey)),
        ]),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(58)),
            onPressed: _saving ? null : _save,
            child: Text(widget.isEdit ? '儲存變更' : '新增', style: const TextStyle(fontSize: 19)),
          ),
        ),
      ),
    );
  }
}
