import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'db.dart';
import 'entry_page.dart';
import 'product_form_page.dart';

/// 只掃一維商品條碼；QR Code 等二維條碼一律忽略
const kLinearFormats = [
  BarcodeFormat.ean13,
  BarcodeFormat.ean8,
  BarcodeFormat.upcA,
  BarcodeFormat.upcE,
  BarcodeFormat.code128,
  BarcodeFormat.code39,
  BarcodeFormat.code93,
  BarcodeFormat.codabar,
  BarcodeFormat.itf14,
];

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  // 相機端只辨識一維格式，二維條碼不會觸發
  final _controller = MobileScannerController(formats: kLinearFormats);
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // 按「取消」後，鏡頭還對著同一個條碼會一直跳視窗；同一個號碼暫停 3 秒不處理
  String? _skipCode;
  DateTime _skipUntil = DateTime(0);

  Future<void> _onDetect(BarcodeCapture cap) async {
    if (_busy) return;
    // 有些平台會忽略 formats 設定，這裡再過濾一次
    final hit = cap.barcodes.where((b) => kLinearFormats.contains(b.format)).firstOrNull;
    final code = hit?.rawValue?.trim();
    if (code == null || code.isEmpty) return;
    if (code == _skipCode && DateTime.now().isBefore(_skipUntil)) return;
    _busy = true;
    final found = await Repo.i.findProducts(code); // 比對國碼與店內碼（只忽略開頭的 0）
    if (!mounted) return;
    if (found.isEmpty) {
      await _askAdd(code);
      return;
    }
    // 少數商品共用同一個店內碼，讓使用者選
    final product = found.length == 1 ? found.single : await _choose(code, found);
    if (!mounted) return;
    if (product == null) {
      _busy = false;
      return;
    }
    final saved = await Navigator.push<bool>(
        context, MaterialPageRoute(builder: (_) => EntryPage(product: product)));
    if (saved == true && mounted) {
      Navigator.pop(context, true);
    } else {
      _busy = false;
    }
  }

  /// 商品檔沒有這個國碼：詢問是否新增，新增時把掃到的條碼帶入國碼欄位
  Future<void> _askAdd(String code) async {
    final add = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              icon: const Icon(Icons.help_outline, size: 36),
              title: const Text('商品檔內查無此國碼'),
              content: Text('國碼 $code 不在商品檔內，\n是否新增這個商品？',
                  style: const TextStyle(fontSize: 16)),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(96, 44)),
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('新增商品')),
              ],
            ));
    if (!mounted) return;
    if (add == true) {
      final saved = await Navigator.push<bool>(context,
          MaterialPageRoute(builder: (_) => ProductFormPage(initialBarcode: code)));
      if (saved == true && mounted) {
        Navigator.pop(context, true);
        return;
      }
    }
    _skipCode = code;
    _skipUntil = DateTime.now().add(const Duration(seconds: 3));
    _busy = false;
  }

  Future<Map<String, Object?>?> _choose(String code, List<Map<String, Object?>> list) =>
      showModalBottomSheet<Map<String, Object?>>(
          context: context,
          builder: (c) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  ListTile(
                      title: Text('$code 對應 ${list.length} 個商品，請選擇',
                          style: const TextStyle(fontWeight: FontWeight.bold))),
                  for (final p in list)
                    ListTile(
                      title: Text('${p['name']}'),
                      subtitle: Text('${p['dept']}　國碼 ${p['barcode']}　店內碼 ${p['store_code']}'),
                      onTap: () => Navigator.pop(c, p),
                    ),
                ]),
              ));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('掃描條碼')),
        body: MobileScanner(controller: _controller, onDetect: _onDetect),
      );
}
