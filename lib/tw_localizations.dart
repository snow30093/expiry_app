import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

/// App 固定使用繁體中文（台灣）
const kAppLocale = Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant', countryCode: 'TW');

const kLocalizationsDelegates = <LocalizationsDelegate<Object>>[
  TwMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// Flutter 內建的台灣中文，再調整日期選擇器：
/// - 上方日期顯示年份與「週」：2027年3月15日 週一（內建是 3月15日周一）
/// - 月曆一週從星期日開始（內建從星期一開始）
class TwMaterialLocalizations extends MaterialLocalizationZhHantTw {
  TwMaterialLocalizations()
      : super(
          fullYearFormat: intl.DateFormat.y(_l),
          compactDateFormat: intl.DateFormat.yMd(_l),
          shortDateFormat: intl.DateFormat.yMMMd(_l),
          mediumDateFormat: intl.DateFormat('y年M月d日 EEE', _l),
          longDateFormat: intl.DateFormat.yMMMMEEEEd(_l),
          yearMonthFormat: intl.DateFormat.yMMMM(_l),
          shortMonthDayFormat: intl.DateFormat.MMMd(_l),
          decimalFormat: intl.NumberFormat.decimalPattern(_l),
          twoDigitZeroPaddedFormat: intl.NumberFormat('00', _l),
        );

  static const _l = 'zh_TW';

  @override
  int get firstDayOfWeekIndex => 0; // 星期日

  static const LocalizationsDelegate<MaterialLocalizations> delegate = _Delegate();
}

class _Delegate extends LocalizationsDelegate<MaterialLocalizations> {
  const _Delegate();

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'zh';

  @override
  Future<MaterialLocalizations> load(Locale locale) async {
    // 先讓內建的 delegate 載入中文日期資料，再建立調整過的版本
    await GlobalMaterialLocalizations.delegate.load(kAppLocale);
    return TwMaterialLocalizations();
  }

  @override
  bool shouldReload(_Delegate old) => false;
}
