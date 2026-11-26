import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'tw_localizations.dart';
import 'file_io.dart';
import 'db.dart';
import 'entry_page.dart';
import 'notify.dart';
import 'product_form_page.dart';
import 'scan_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Repo.i.init();
  await Notifier.init();
  await Repo.i.refreshStatuses(); // 每次開啟都重新檢查狀態
  runApp(MaterialApp(
    title: '效期提醒',
    debugShowCheckedModeBanner: false,
    theme: appTheme(),
    // 日期選擇器、取消／確定等內建文字固定用繁體中文（不跟手機語言設定）
    locale: kAppLocale,
    supportedLocales: const [kAppLocale],
    localizationsDelegates: kLocalizationsDelegates,
    home: const HomePage(),
  ));
  // 畫面出來後再詢問通知權限，避免啟動時卡在空白畫面
  Notifier.requestPermission();
}

// 品牌色（參考寶雅的粉紅）只用在標題列、主要按鈕與選取狀態；
// 商品狀態另用紅／橘／綠／紫，避免粉紅和「快過期」的紅色混淆。
const kPink = Color(0xFFE4007F);
const _pinkLight = Color(0xFFFFF0F7);
const _pinkBorder = Color(0xFFF3B6D6);

/// 版本 A「單手作業版」：大按鈕、大字，主要操作放在拇指按得到的下方
/// [fontFamily] 只在測試截圖時指定；手機上用系統字型
ThemeData appTheme({String? fontFamily}) {
  const big = Size.fromHeight(52);
  return ThemeData(
    useMaterial3: true,
    fontFamily: fontFamily,
    colorScheme: ColorScheme.fromSeed(seedColor: kPink).copyWith(
      primary: kPink,
      onPrimary: Colors.white,
    ),
    scaffoldBackgroundColor: const Color(0xFFFAFAFA),
    appBarTheme: AppBarTheme(
      backgroundColor: kPink,
      foregroundColor: Colors.white,
      titleTextStyle: TextStyle(
          fontFamily: fontFamily, color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: big,
        textStyle: TextStyle(fontFamily: fontFamily, fontSize: 17, fontWeight: FontWeight.bold),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: big,
        textStyle: TextStyle(fontFamily: fontFamily, fontSize: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}

enum SortMode { expiryAsc, expiryDesc, dept, name }

const _sortLabels = {
  SortMode.expiryAsc: '到期日：近 → 遠',
  SortMode.expiryDesc: '到期日：遠 → 近',
  SortMode.dept: '部門',
  SortMode.name: '品名',
};

const _pendingTab = '待登錄'; // 匯入時沒有有效日期、還沒登錄到期日的商品
const _statusFilters = ['未處理', _pendingTab, '即將過期', '正常', '已處理', '全部'];
const _pageSize = 300;

// 狀態色（文字用深色，放在淺色底上也清楚）
const _red = Color(0xFFC62828);
const _orange = Color(0xFFD84315);
const _green = Color(0xFF2E7D32);
const _purple = Color(0xFF6A1B9A);
const _grey = Color(0xFF757575);

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  String? _dept;
  String _status = '未處理';
  SortMode _sort = SortMode.expiryAsc;
  List<Map<String, Object?>> _all = [];
  List<Map<String, Object?>> _pending = []; // 只在「待登錄」分頁載入，分頁讀取
  int _pendingTotal = 0;
  bool _loadingMore = false;

  // 搜尋：有輸入文字時，清單改顯示全部商品中符合的結果
  final _searchCtl = TextEditingController();
  Timer? _debounce;
  String _query = '';
  List<Map<String, Object?>> _results = [];
  int _resultTotal = 0;
  bool get _searching => _query.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  // 打字時等 0.3 秒沒有再輸入才查，避免每打一個字就查一次
  void _onSearchChanged(String v) {
    setState(() {}); // 更新清除按鈕
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _query = v;
      _search();
    });
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchCtl.clear();
    setState(() => _query = '');
  }

  Future<void> _search() async {
    if (!_searching) {
      setState(() {});
      return;
    }
    final q = _query;
    final total = await Repo.i.searchCount(q, dept: _dept);
    final r = await Repo.i.searchProducts(q, dept: _dept, limit: _pageSize);
    if (mounted && q == _query) { // 忽略已過時的查詢結果
      setState(() {
        _resultTotal = total;
        _results = r;
      });
    }
  }

  Future<void> _loadMoreResults() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    final more = await Repo.i.searchProducts(_query,
        dept: _dept, limit: _pageSize, offset: _results.length);
    if (mounted) {
      setState(() {
        _results = [..._results, ...more];
        _loadingMore = false;
      });
    }
  }

  // App 放在背景隔天再切回來時，也要重新檢查狀態與剩餘天數
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    await Repo.i.refreshStatuses();
    final r = await Repo.i.listBatches(dept: _dept, showDone: true);
    final total = await Repo.i.pendingCount(dept: _dept);
    final pending = _status == _pendingTab
        ? await Repo.i.listPending(dept: _dept, byName: _sort == SortMode.name, limit: _pageSize)
        : <Map<String, Object?>>[];
    if (mounted) {
      setState(() {
        _all = r;
        _pendingTotal = total;
        _pending = pending;
      });
    }
    if (_searching) await _search(); // 登錄或部門變動後，搜尋結果也要更新
    // 每次重新整理都重排接下來的提醒通知
    Notifier.rescheduleDaily(await Repo.i.upcomingRemindDays());
  }

  Future<void> _loadMorePending() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    final more = await Repo.i.listPending(
        dept: _dept, byName: _sort == SortMode.name, limit: _pageSize, offset: _pending.length);
    if (mounted) {
      setState(() {
        _pending = [..._pending, ...more];
        _loadingMore = false;
      });
    }
  }

  /// 從清單直接登錄到期日（不用掃描）
  Future<void> _register(Map<String, Object?> product) async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => EntryPage(product: product)));
    _load();
  }

  List<Map<String, Object?>> get _view {
    final l = _all.where((b) {
      final s = b['status'];
      switch (_status) {
        case '未處理': return s != '已處理';
        case '全部': return true;
        default: return s == _status;
      }
    }).toList();
    int cmpS(String k, Map a, Map b) => '${a[k] ?? ''}'.compareTo('${b[k] ?? ''}');
    l.sort((a, b) {
      switch (_sort) {
        case SortMode.expiryAsc: return cmpS('expiry_date', a, b);
        case SortMode.expiryDesc: return cmpS('expiry_date', b, a);
        case SortMode.dept:
          final c = cmpS('dept', a, b);
          return c != 0 ? c : cmpS('expiry_date', a, b);
        case SortMode.name:
          final c = cmpS('name', a, b);
          return c != 0 ? c : cmpS('expiry_date', a, b);
      }
    });
    return l;
  }

  void _msg(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _scan() async {
    if (await Repo.i.productCount() == 0) {
      _msg('商品資料庫是空的，請先匯入商品檔');
      return;
    }
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const ScanPage()));
    _load();
  }

  /// 大檔案要跑幾秒，先顯示處理中，避免使用者以為當掉。
  /// 回傳 (結果, 錯誤)，兩者只有一個不是 null。
  Future<(T?, Object?)> _withProgress<T>(String text, Future<T> Function() job) async {
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
              canPop: false,
              child: AlertDialog(
                  content: Row(children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Text(text),
              ])),
            ));
    T? r;
    Object? err;
    try {
      r = await job();
    } catch (e) {
      err = e;
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop(); // 關掉處理中
    return (r, err);
  }

  String _errText(Object? e) => e.toString().replaceFirst('Exception: ', '');

  Future<void> _import() async {
    final f = await FilePicker.pickFiles(type: FileType.any);
    if (f.isEmpty || !mounted) return;
    // 用 readAsBytes：Android 選到的常是 content:// 而不是檔案路徑
    final (r, err) =
        await _withProgress('匯入中，請稍候…', () async => importFile(await f.single.readAsBytes()));
    if (!mounted) return;
    if (r == null) {
      _msg('匯入中止：${_errText(err)}');
      return;
    }
    _load(); // 品名、待登錄可能變動
    final s = r.stats;
    if (s.due > 0) {
      Notifier.showNow('import-due', '商品即將過期', '匯入後有 ${s.due} 項商品已在提醒範圍內，請確認');
    }
    showDialog(
        context: context,
        builder: (c) => AlertDialog(
              title: Text('匯入完成：成功 ${r.ok} 筆'),
              content: SingleChildScrollView(
                  child: Text([
                [
                  '依檔案日期登錄到期日：${s.registered} 筆',
                  if (s.due > 0) '　其中已在提醒範圍內：${s.due} 筆',
                  if (s.kept > 0) '已有到期日、保留原本日期：${s.kept} 筆',
                ].join('\n'),
                if (r.failed.isNotEmpty) summarizeIssues('失敗', r.failed),
                if (r.warnings.isNotEmpty) summarizeIssues('提醒', r.warnings),
              ].join('\n\n'))),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c), child: const Text('確定'))
              ],
            ));
  }

  Future<void> _export() async {
    final xlsx = await showModalBottomSheet<bool>(
        context: context,
        builder: (c) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const ListTile(title: Text('匯出全部商品', style: TextStyle(fontWeight: FontWeight.bold))),
                ListTile(
                    leading: const Icon(Icons.grid_on, color: _green),
                    title: const Text('Excel（.xlsx）'),
                    subtitle: const Text('建議：用 Excel 開啟時國碼不會變成科學記號'),
                    onTap: () => Navigator.pop(c, true)),
                ListTile(
                    leading: const Icon(Icons.description),
                    title: const Text('CSV（.csv）'),
                    subtitle: const Text('可再匯入本 App；直接用 Excel 開啟國碼可能變形'),
                    onTap: () => Navigator.pop(c, false)),
              ]),
            ));
    if (xlsx == null || !mounted) return;
    final (bytes, err) = await _withProgress('匯出中，請稍候…', () async {
      final rows = await Repo.i.exportRows();
      return xlsx ? compute(buildXlsx, rows) : compute(buildCsv, rows);
    });
    if (!mounted) return;
    if (bytes == null) {
      _msg('匯出失敗：${_errText(err)}');
      return;
    }
    final d = DateTime.now();
    final stamp = fmtDate(d).replaceAll('-', '');
    try {
      final uri = await FilePicker.saveFile(
          fileName: '效期資料_$stamp.${xlsx ? 'xlsx' : 'csv'}',
          bytes: bytes,
          mimeType: xlsx
              ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
              : 'text/csv');
      if (uri != null) _msg('已匯出');
    } catch (e) {
      _msg('匯出失敗：${_errText(e)}');
    }
  }

  /// 狀態按鈕：同時顯示數量；搜尋中點一下會清除搜尋並切到那一類
  void _selectStatus(String s) {
    if (_searching) _clearSearch();
    setState(() => _status = s);
    if (s == _pendingTab) _load();
  }

  @override
  Widget build(BuildContext context) {
    final searching = _searching;
    final isPending = !searching && _status == _pendingTab;
    final list = searching ? _results : isPending ? _pending : _view;
    final total = searching ? _resultTotal : isPending ? _pendingTotal : list.length;
    int count(bool Function(String s) f) => _all.where((b) => f(b['status'] as String)).length;
    final counts = {
      '未處理': count((s) => s != '已處理'),
      _pendingTab: _pendingTotal,
      '即將過期': count((s) => s == '即將過期'),
      '正常': count((s) => s == '正常'),
      '已處理': count((s) => s == '已處理'),
      '全部': _all.length,
    };
    const statusColor = {_pendingTab: _orange, '即將過期': _red, '正常': _green};

    return Scaffold(
      appBar: AppBar(
        title: const Text('效期提醒'),
        actions: [
          // 匯入、匯出不常用，收進選單；最常用的掃描放在畫面下方
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert, size: 28),
            onSelected: (v) => v == 'import' ? _import() : _export(),
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'import',
                  child: ListTile(leading: Icon(Icons.upload_file), title: Text('匯入商品檔'))),
              PopupMenuItem(
                  value: 'export',
                  child: ListTile(leading: Icon(Icons.save_alt), title: Text('匯出'))),
            ],
          ),
        ],
      ),
      body: Column(children: [
        Container(
          color: _pinkLight,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(children: [
            // 搜尋
            TextField(
              controller: _searchCtl,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 16),
              decoration: InputDecoration(
                hintText: '搜尋品名、店內碼、國碼（可只打幾個字）',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchCtl.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除', icon: const Icon(Icons.clear), onPressed: _clearSearch),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _pinkBorder)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: kPink, width: 2)),
              ),
            ),
            const SizedBox(height: 8),
            // 狀態按鈕（含數量）
            SizedBox(
              height: 44,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final s in _statusFilters)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      showCheckmark: false,
                      selected: !searching && _status == s,
                      selectedColor: kPink,
                      backgroundColor: Colors.white,
                      side: BorderSide(
                          color: !searching && _status == s ? kPink : _pinkBorder),
                      label: Text.rich(TextSpan(children: [
                        TextSpan(text: '$s '),
                        TextSpan(
                            text: '${counts[s]}',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: !searching && _status == s
                                    ? Colors.white
                                    : statusColor[s] ?? Colors.black87)),
                      ])),
                      labelStyle: TextStyle(
                          fontSize: 15,
                          color: !searching && _status == s ? Colors.white : Colors.black87),
                      onSelected: (_) => _selectStatus(s),
                    ),
                  ),
              ]),
            ),
          ]),
        ),
        // 筆數、部門、排序
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
          child: Row(children: [
            Expanded(
              child: Text(searching ? '搜尋結果 共 $total 筆' : '共 $total 筆',
                  style: const TextStyle(color: _grey, fontSize: 14)),
            ),
            // 部門：用下拉選單，比一整排按鈕省空間
            PopupMenuButton<String>(
              tooltip: '部門',
              onSelected: (v) {
                _dept = v.isEmpty ? null : v;
                _load();
              },
              itemBuilder: (_) => [
                for (final d in ['', ...kDepts])
                  CheckedPopupMenuItem(
                      value: d, checked: (_dept ?? '') == d, child: Text(d.isEmpty ? '全部部門' : d)),
              ],
              child: _menuLabel(Icons.store, _dept ?? '全部部門', highlight: _dept != null),
            ),
            // 搜尋結果固定依部門、品名排列
            if (!searching)
              PopupMenuButton<SortMode>(
                tooltip: '排序',
                initialValue: _sort,
                onSelected: (v) {
                  setState(() => _sort = v);
                  if (isPending) _load(); // 待登錄在資料庫端排序
                },
                itemBuilder: (_) => [
                  for (final e in _sortLabels.entries)
                    PopupMenuItem(value: e.key, child: Text(e.value)),
                ],
                child: _menuLabel(Icons.sort, _sortLabels[_sort]!),
              ),
          ]),
        ),
        // 清單
        Expanded(
          child: list.isEmpty
              ? Center(
                  child: Text(
                      searching
                          ? '找不到符合「${_query.trim()}」的商品'
                          : isPending ? '沒有待登錄的商品' : '沒有符合的商品\n按下方「掃描條碼」開始登錄',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: _grey, fontSize: 16)))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  // 最後多一格放「載入更多」
                  itemCount: list.length + (list.length < total ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i >= list.length) {
                      return Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: OutlinedButton(
                          onPressed: _loadingMore
                              ? null
                              : searching ? _loadMoreResults : _loadMorePending,
                          child: Text('再載入 $_pageSize 筆（還有 ${total - list.length} 筆）'),
                        ),
                      );
                    }
                    final row = list[i];
                    // 搜尋結果混有已登錄（有批次 id）與待登錄的商品
                    if (isPending || (searching && row['id'] == null)) return _pendingCard(row);
                    return _card(row, onTap: searching ? () => _register(row) : null);
                  },
                ),
        ),
      ]),
      // 單手就按得到的掃描大按鈕
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          decoration: const BoxDecoration(
              color: Colors.white, border: Border(top: BorderSide(color: Color(0xFFEEEEEE)))),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(58)),
            onPressed: _scan,
            icon: const Icon(Icons.qr_code_scanner, size: 26),
            label: const Text('掃描條碼', style: TextStyle(fontSize: 19)),
          ),
        ),
      ),
    );
  }

  Widget _menuLabel(IconData icon, String text, {bool highlight = false}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 20, color: highlight ? kPink : _grey),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(
                  fontSize: 14,
                  color: highlight ? kPink : Colors.black87,
                  fontWeight: highlight ? FontWeight.bold : null)),
          Icon(Icons.arrow_drop_down, color: highlight ? kPink : _grey),
        ]),
      );

  /// 卡片共用外框：左邊大字狀態區、中間品名，右邊可放按鈕
  Widget _shell({
    required Widget lead,
    required Color color,
    required Widget body,
    Widget? trailing,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) =>
      Card(
        elevation: 0,
        margin: const EdgeInsets.only(top: 8),
        clipBehavior: Clip.antiAlias,
        color: Colors.white,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFFEAEAEA))),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                width: 76,
                color: color.withValues(alpha: 0.08),
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Center(child: lead),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                  child: body,
                ),
              ),
              if (trailing != null) Center(child: trailing),
            ]),
          ),
        ),
      );

  Widget _nameAndInfo(String name, List<String> lines, {bool struck = false}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  height: 1.3,
                  decoration: struck ? TextDecoration.lineThrough : null)),
          for (final l in lines) ...[
            const SizedBox(height: 3),
            Text(l, style: const TextStyle(fontSize: 13, color: _grey)),
          ],
        ],
      );

  /// 待登錄的商品：點一下打開登錄畫面
  Widget _pendingCard(Map<String, Object?> p) => _shell(
        color: _orange,
        onTap: () => _register(p),
        lead: const Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.edit_calendar, size: 30, color: _orange),
          SizedBox(height: 2),
          Text('待登錄', style: TextStyle(fontSize: 13, color: _orange, fontWeight: FontWeight.bold)),
        ]),
        body: _nameAndInfo('${p['name']}', [
          '${p['dept']}・店內碼 ${p['store_code']}',
          '點一下登錄到期日',
        ]),
        trailing: const Icon(Icons.chevron_right, color: _grey),
      );

  Widget _card(Map<String, Object?> b, {VoidCallback? onTap}) {
    final status = b['status'] as String;
    final expiry = DateTime.parse(b['expiry_date'] as String);
    final today = DateTime.now();
    final days = expiry.difference(DateTime(today.year, today.month, today.day)).inDays;

    // 左邊大字：剩幾天（已過期顯示過了幾天）
    Color color;
    String big, small;
    if (status == '已處理') {
      color = _grey;
      big = '✓';
      small = '已處理';
    } else if (days < 0) {
      color = _purple;
      big = '${-days}';
      small = '天前過期';
    } else if (days == 0) {
      color = status == '即將過期' ? _red : _green;
      big = '0';
      small = '今天到期';
    } else {
      color = status == '即將過期' ? _red : _green;
      big = '$days';
      small = '天後到期';
    }

    return _shell(
      color: color,
      onTap: onTap,
      onLongPress: () => _actions(b),
      lead: Column(mainAxisSize: MainAxisSize.min, children: [
        FittedBox(
          child: Text(big,
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.bold, color: color, height: 1.1)),
        ),
        Text(small, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.bold)),
      ]),
      body: _nameAndInfo(
        '${b['name'] ?? '(商品已不在資料庫)'}',
        ['${b['dept']}・到期日 ${b['expiry_date']}', '國碼 ${b['barcode']}'],
        struck: status == '已處理',
      ),
      // 長按不容易被發現，另外放一個按鈕
      trailing: IconButton(
        tooltip: '更多動作',
        icon: const Icon(Icons.more_vert, color: _grey),
        onPressed: () => _actions(b),
      ),
    );
  }

  void _actions(Map<String, Object?> b) {
    showModalBottomSheet(
        context: context,
        builder: (_) => SafeArea(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ListTile(
                    title: Text('${b['name'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold))),
                ListTile(
                    leading: const Icon(Icons.edit, color: kPink),
                    title: const Text('編輯'),
                    subtitle: const Text('修改品名、部門、國碼、店內碼、到期日'),
                    onTap: () async {
                      Navigator.pop(context);
                      await Navigator.push(context,
                          MaterialPageRoute(builder: (_) => ProductFormPage(product: b)));
                      _load();
                    }),
                ListTile(
                    leading: const Icon(Icons.check_circle, color: _green),
                    title: const Text('標記已處理（不再提醒）'),
                    onTap: () async {
                      Navigator.pop(context);
                      await Repo.i.markDone(b['id'] as String);
                      await Notifier.cancel(b['id'] as String);
                      _load();
                    }),
                ListTile(
                    leading: const Icon(Icons.delete, color: _red),
                    title: const Text('刪除這筆'),
                    onTap: () async {
                      Navigator.pop(context);
                      await Repo.i.softDelete(b['id'] as String);
                      await Notifier.cancel(b['id'] as String);
                      _load();
                    }),
              ]),
            ));
  }
}
