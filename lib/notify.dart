import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'db.dart';

class Notifier {
  static final _p = FlutterLocalNotificationsPlugin();
  static const _details = NotificationDetails(
    android: AndroidNotificationDetails('expiry', '商品效期提醒',
        importance: Importance.high, priority: Priority.high),
    iOS: DarwinNotificationDetails(),
  );

  static Future<void> init() async {
    tzdata.initializeTimeZones();
    try {
      final name = (await FlutterTimezone.getLocalTimezone()).identifier;
      tz.setLocalLocation(tz.getLocation(name));
    } catch (e) {
      // 取不到或時區資料庫沒有這個名稱時，避免 App 一啟動就當掉
      debugPrint('timezone fallback: $e');
      tz.setLocalLocation(tz.getLocation('Asia/Taipei'));
    }
    await _p.initialize(
        settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    ));
  }

  /// Android 13 以上需要使用者同意才能顯示通知（在畫面出現後再詢問）
  static Future<void> requestPermission() async {
    await _p
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  static Future<void> showNow(String id, String title, String body) =>
      _p.show(id: notificationId(id), title: title, body: body, notificationDetails: _details);

  static Future<void> cancel(String id) => _p.cancel(id: notificationId(id));

  static Future<void> _chain = Future.value();

  /// 重新排程：每個提醒日早上 9:00 一則彙總通知（只排接下來的幾天）。
  /// 不再每個商品各排一則：匯入幾千筆時會超過 Android 每個 App 約 500 個排程的上限而閃退。
  /// App 每次開啟、切回前景、資料變動時都會重排，所以排程會一直往後補。
  static Future<void> rescheduleDaily(List<RemindDay> days) =>
      _chain = _chain.then((_) => _reschedule(days)).catchError((Object e) {
        debugPrint('reschedule failed: $e');
      });

  static Future<void> _reschedule(List<RemindDay> days) async {
    for (final r in await _p.pendingNotificationRequests()) {
      await _p.cancel(id: r.id);
    }
    final now = tz.TZDateTime.now(tz.local);
    for (final d in days) {
      final at = tz.TZDateTime(tz.local, d.date.year, d.date.month, d.date.day, 9);
      if (at.isBefore(now)) continue;
      await _p.zonedSchedule(
          id: notificationId('day:${fmtDate(d.date)}'),
          title: '商品即將過期',
          body: dayBody(d),
          scheduledDate: at,
          notificationDetails: _details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle);
    }
  }
}

String dayBody(RemindDay d) => d.count == 1
    ? '${d.sampleName} 進入即將過期，請確認'
    : '${d.sampleName} 等 ${d.count} 項商品進入即將過期，請確認';

/// 由批次 id 算出固定的通知編號（FNV-1a）。
/// String.hashCode 不保證每次執行都相同，重開 App 後可能取消不到舊通知。
@visibleForTesting
int notificationId(String id) {
  var h = 0x811c9dc5;
  for (final c in id.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h & 0x7fffffff;
}
