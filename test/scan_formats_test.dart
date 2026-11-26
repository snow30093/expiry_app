import 'package:expiry_app/scan_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() {
  test('只接受一維條碼', () {
    expect(kLinearFormats, containsAll([BarcodeFormat.ean13, BarcodeFormat.upcA, BarcodeFormat.ean8]));
    for (final f in [
      BarcodeFormat.qrCode,
      BarcodeFormat.microQrCode,
      BarcodeFormat.dataMatrix,
      BarcodeFormat.pdf417,
      BarcodeFormat.aztec,
      BarcodeFormat.maxiCode,
      BarcodeFormat.all,
      BarcodeFormat.unknown,
    ]) {
      expect(kLinearFormats, isNot(contains(f)), reason: '$f 不應該被接受');
    }
  });
}
