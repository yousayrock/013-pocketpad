import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'kanpanicchi.dart';
import 'claude_notify_service.dart';
import 'launcher.dart';
import 'settings.dart';
import 'settings_screen.dart';
import 'trackpad.dart';
import 'youtube.dart';

// 011号RoadTalkと同じサイバーパンク配色
const kBg = Color(0xFF050810);
const kAccent = Color(0xFF00F5FF);
const kMagenta = Color(0xFFFF006E);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  initClaudeNotifyService();
  runApp(const PocketPadApp());
}

class PocketPadApp extends StatelessWidget {
  const PocketPadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PocketPad',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(
          primary: kAccent,
          secondary: kMagenta,
          surface: Color(0xFF0A1020),
        ),
      ),
      home: const ConnectScreen(),
    );
  }
}

// ─────────────────────────────────────── 接続画面

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _host = TextEditingController();
  final _token = TextEditingController();
  bool _busy = false;
  bool _showManual = false;
  String _status = '';
  bool _autoRetry = true; // 前回PCへ成功するまで自動再接続を続ける

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      _host.text = p.getString('host') ?? '';
      _token.text = p.getString('token') ?? '';
      if (!mounted) return;
      setState(() {});
      if (_host.text.isNotEmpty && _token.text.isNotEmpty) {
        _autoConnect(); // 前回のPCへ自動再接続
      } else {
        // 初回はQRスキャンがデフォルト動線
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scanQr();
        });
      }
    });
  }

  /// 前回PCへ、成功するまで数秒ごとに自動再接続を続ける。
  /// _busyは立てない（ボタンを殺すとループを止める手段がなくなる）。
  /// QR/手動ボタンを押すと _autoRetry=false で止まる。
  Future<void> _autoConnect() async {
    while (_autoRetry &&
        mounted &&
        _host.text.isNotEmpty &&
        _token.text.isNotEmpty) {
      // 1行に収まる長さにする（IPを含めても途中で折り返させない）
      setState(() => _status = '再接続中…（${_host.text}）');
      if (await _tryConnect(
        _host.text,
        _token.text,
        const Duration(seconds: 3),
        auto: true,
      )) {
        return; // 成功したらTrackpadScreenへ遷移済み
      }
      if (!mounted || !_autoRetry) return;
      setState(() => _status = '接続待ち…\n下のボタンでいつでも接続し直せます');
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  /// 1ホストへの接続試行。成功したらTrackpadScreenへ遷移してtrueを返す。
  /// auto=trueの自動再接続は、ユーザーがQR/手動を選んだ後に成功しても遷移しない。
  Future<bool> _tryConnect(
    String host,
    String token,
    Duration timeout, {
    bool auto = false,
  }) async {
    try {
      final channel = WebSocketChannel.connect(Uri.parse('ws://$host:9013/ws'));
      await channel.ready.timeout(timeout);

      final stream = channel.stream.asBroadcastStream();
      channel.sink.add(
        jsonEncode({
          'type': 'auth',
          'token': token,
          'device_id': 'a25',
          'device_name': 'A25',
        }),
      );

      final reply = await stream
          .firstWhere((m) => m is String)
          .timeout(timeout);
      final json = jsonDecode(reply as String) as Map<String, dynamic>;

      if (json['type'] != 'auth_ok') {
        channel.sink.close();
        return false;
      }
      if (auto && !_autoRetry) {
        // 接続試行中にユーザーがQR/手動を選んだ。横取りせず破棄する
        channel.sink.close();
        return false;
      }
      final p = await SharedPreferences.getInstance();
      await p.setString('host', host);
      await p.setString('token', token);
      if (!mounted) return true;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => TrackpadScreen(channel: channel, stream: stream),
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _connect() async {
    _autoRetry = false; // 手動接続を選んだので自動リトライは止める
    final host = _host.text.trim();
    final token = _token.text.trim();
    if (host.isEmpty || token.isEmpty) return;

    setState(() => _busy = true);
    final ok = await _tryConnect(host, token, const Duration(seconds: 5));
    if (!ok) _fail('接続失敗。PC側アプリの起動・IP・トークンを確認してください');
  }

  /// PC画面のQRを読み取り、接続する。
  Future<void> _scanQr() async {
    _autoRetry = false; // QRを選んだので自動リトライは止める
    final raw = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (raw == null || !mounted) return;

    // QRデータは "PP|IP|PORT|TOKEN"（データ量を絞って読みやすくした形式）
    final parts = raw.split('|');
    if (parts.length < 4 || parts[0] != 'PP') {
      _fail('ゲームパッドのQRではないようです');
      return;
    }
    final host = parts[1];
    final token = parts[3];
    _host.text = host;
    _token.text = token;

    setState(() => _busy = true);
    if (!await _tryConnect(host, token, const Duration(seconds: 4))) {
      _fail('接続できませんでした。PCと同じWiFiにいるか確認してください');
    }
  }

  void _fail(String msg) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = msg;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: kMagenta));
  }

  @override
  Widget build(BuildContext context) {
    // 機種ごとの画面幅・縦横比の差に追従：幅400dpを基準にヒーロー部を拡縮し、
    // タブレット等の広い画面ではコンテンツ幅を480dpで頭打ちにして間延びを防ぐ
    final size = MediaQuery.sizeOf(context);
    final s = (size.width / 400).clamp(0.75, 1.15).toDouble();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 96 * s,
                    height: 96 * s,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: kAccent.withValues(alpha: 0.6),
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: kAccent.withValues(alpha: 0.25),
                          blurRadius: 24,
                        ),
                      ],
                    ),
                    child: Icon(Icons.touch_app, size: 44 * s, color: kAccent),
                  ),
                  SizedBox(height: 24 * s),
                  // letterSpacingは最終文字の後ろにも付くので、左paddingで相殺して中央に見せる
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                      'PocketPad',
                      style: TextStyle(
                        fontSize: 40 * s,
                        fontWeight: FontWeight.bold,
                        color: kAccent,
                        letterSpacing: 6,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 狭い画面では1行に収まらないため、折り返し位置を固定して中央揃え
                  const Text(
                    'Your PC. In Your Pocket.\n未来ガジェット013号',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 32),
                  // スピナーは文の横に置くと折り返し時に左端へ浮くので、上に重ねて中央揃え
                  if (_status.isNotEmpty) ...[
                    if (_busy || _autoRetry)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 20),
                  ],
                  SizedBox(
                    width: double.infinity,
                    height: 64,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _scanQr,
                      icon: const Icon(Icons.qr_code_scanner, size: 28),
                      label: const Text(
                        'QRコードで接続',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _showManual = !_showManual),
                    child: Text(
                      _showManual ? '手動入力を閉じる' : '手動で入力する',
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),
                  if (_showManual) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _host,
                      decoration: const InputDecoration(
                        labelText: 'PCのIPアドレス（例: 192.168.1.10）',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.url,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _token,
                      decoration: const InputDecoration(
                        labelText: 'ペアリングトークン',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: OutlinedButton(
                        onPressed: _busy ? null : _connect,
                        child: Text(
                          _busy ? '接続中…' : 'この情報で接続',
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 40),
                  const Text(
                    'PC側はタスクトレイのPocketPadアイコンを\nクリックするとQRが表示されます',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────── QRスキャン画面

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text('PC画面のQRを読み取る'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flashlight_on),
            tooltip: 'ライト',
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_handled || capture.barcodes.isEmpty) return;
              final raw = capture.barcodes.first.rawValue;
              if (raw == null) return;
              _handled = true;
              Navigator.of(context).pop(raw);
            },
          ),
          // スキャン枠
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: kAccent, width: 3),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          // 案内カード
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.all(24),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: kBg.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: kAccent.withValues(alpha: 0.3)),
              ),
              child: const Text(
                'PCのトレイアイコンをクリック\nQRコードを枠に合わせてください',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────── トラックパッド画面

class TrackpadScreen extends StatefulWidget {
  const TrackpadScreen({
    super.key,
    required this.channel,
    required this.stream,
  });

  final WebSocketChannel channel;
  final Stream<dynamic> stream;

  @override
  State<TrackpadScreen> createState() => _TrackpadScreenState();
}

class _TrackpadScreenState extends State<TrackpadScreen> with WidgetsBindingObserver {
  // 入力欄の先頭に置く番兵（ゼロ幅スペース）。これが消えた＝空欄で
  // バックスペースが押されたと分かるので、PCへbackspaceを転送する。
  static final _zwsp = String.fromCharCode(0x200B);

  double _dx = 0, _dy = 0, _scroll = 0;
  int _flushTick = 0;
  Timer? _flush;
  Timer? _ping;

  /// 最後にpongを受信した時刻。12秒以上途絶えたら死に接続（Wi-Fi瞬断等）と
  /// みなして接続画面へ戻す。TCPの切断検知（数分かかる）を待っている間は
  /// 送信がキューに溜まり続け「だんだん重くなって固まる」ように見えるため。
  int _lastPong = DateTime.now().millisecondsSinceEpoch;
  Timer? _bsRepeat;
  StreamSubscription? _sub;
  final _text = TextEditingController(text: _zwsp);
  bool _showKeyboard = false;
  final _textFocus = FocusNode();
  int _tab = 0; // 表示中ページ（_settings.visiblePages のインデックス）
  double? _navSwipeStartX; // ページ切替バーのスワイプ判定用
  AppSettings _settings = AppSettings.defaults();
  late final Future<AppSettings> _settingsFuture;

  /// PCからのconfigを適用済みか。ローカルload完了が後から来ても上書きしない。
  bool _remoteConfigApplied = false;

  bool _claudeNotifyEnabled = true;
  ClaudeActivity? _lastClaudeActivity;
  ClaudeNotifyEvent? _lastClaudeNotifyEvent;
  List<TodoItem> _lastTodos = [];
  ActivityComment? _lastActivityComment;
  final SpeechToText _speech = SpeechToText();
  bool _speechAvailable = false;
  bool _micListening = false;
  String _micLastWords = '';
  bool _micSent = false;
  static const _claudeNotifyPrefsKey = 'claude_notify_enabled';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() =>
          _claudeNotifyEnabled = p.getBool(_claudeNotifyPrefsKey) ?? true);
    });
    setupClaudeNotifications().then((_) => startClaudeKeepAliveService());
    _settingsFuture = AppSettings.load();
    _settingsFuture.then((s) {
      if (!mounted || _remoteConfigApplied) return;
      s.onSaved = _pushConfig;
      setState(() => _settings = s);
    });
    // 8ms間引き集約（protocol.md v1）
    _flush = Timer.periodic(
      const Duration(milliseconds: 8),
      (_) => _flushMove(),
    );
    _ping = Timer.periodic(const Duration(seconds: 5), (_) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastPong > 12000) {
        _disconnected(); // 死に接続を諦める。接続画面に戻れば自動再接続が走る
        return;
      }
      _sendJson({'type': 'ping', 'ts': now});
    });
    _sub = widget.stream.listen(
      _onMessage,
      onDone: _disconnected,
      onError: (_) => _disconnected(),
    );
    // 設定同期はスマホ主導（listen登録後に送るので応答を取りこぼさない）。
    // PCに保存があれば config、なければ config_request が返る。
    _sendJson({'type': 'config_get'});
    // かんぱにっちのTODOも同じ理由でスマホ主導で取りに行く
    // （PCが直近のTodoWrite内容を覚えていれば claude_todos が返る）。
    _sendJson({'type': 'claude_todos_get'});
  }

  /// PCからの受信処理。スクショ結果を受け取ったらプレビュー画面へ。
  void _onMessage(dynamic m) {
    if (m is! String) return;
    Map<String, dynamic> j;
    try {
      j = jsonDecode(m) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (j['type'] == 'pong') {
      _lastPong = DateTime.now().millisecondsSinceEpoch;
    } else if (j['type'] == 'screenshot_result' && mounted) {
      final bytes = base64Decode(j['jpeg'] as String);
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ScreenshotPreview(bytes: bytes)),
      );
    } else if (j['type'] == 'screenshot_error' && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('スクショの取得に失敗しました'),
          backgroundColor: kMagenta,
        ),
      );
    } else if (j['type'] == 'config' && j['settings'] is Map) {
      // PC保存の設定を適用+永続化（config_setは送り返さない=ループ防止）
      final s = AppSettings.fromJson(
        (j['settings'] as Map).cast<String, dynamic>(),
      );
      _remoteConfigApplied = true;
      s.onSaved = _pushConfig;
      s.save(notify: false);
      if (mounted) {
        setState(() {
          _settings = s;
          _tab = _tab.clamp(0, s.visiblePages.length - 1);
        });
      }
    } else if (j['type'] == 'config_request') {
      // PC未保存（初回）。ローカルload完了を待ってから現在設定を送る
      _settingsFuture.then((_) {
        if (mounted) _pushConfig(_settings.toJson());
      });
    } else if (j['type'] == 'claude_notify') {
      // Claude Codeページ（コントローラーUI）は廃止したが、Claude Code純正の
      // Remote Controlを使わずスマホを見ていない時に気づけるよう、通知アラート
      // （音+バイブ+フラッシュ／バックグラウンド時はシステム通知）だけは残す。
      final event = (j['event'] as String?) ?? '';
      final message = (j['message'] as String?) ?? '';
      // 「AI社員」ページのアバターにも反映（通知トグルOFFでもページ上の状態は更新する）
      setState(() => _lastClaudeNotifyEvent = ClaudeNotifyEvent(event: event, message: message));
      if (_claudeNotifyEnabled) {
        final foreground =
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
        if (foreground) {
          playForegroundAlert(event, message);
          _flashClaudeAlert(event == 'notification');
        } else {
          showClaudeAlert(event, message);
        }
      }
    } else if (j['type'] == 'claude_activity') {
      final tool = (j['tool'] as String?) ?? '';
      final detail = (j['detail'] as String?) ?? '';
      setState(() => _lastClaudeActivity = ClaudeActivity(tool: tool, detail: detail));
    } else if (j['type'] == 'claude_todos') {
      final raw = (j['todos'] as List?) ?? const [];
      setState(() => _lastTodos = [
            for (final t in raw) TodoItem.fromJson((t as Map).cast<String, dynamic>()),
          ]);
    } else if (j['type'] == 'claude_activity_comment') {
      final text = (j['text'] as String?) ?? '';
      if (text.isNotEmpty) {
        setState(() => _lastActivityComment = ActivityComment(text: text));
      }
    } else if (j['type'] == 'file_transfer_result' && mounted) {
      final ok = j['ok'] == true;
      final filename = (j['filename'] as String?) ?? '';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          ok ? 'PCへ送信しました: $filename' : 'PCへの送信に失敗しました',
          style: TextStyle(color: ok ? kBg : Colors.white),
        ),
        backgroundColor: ok ? kAccent : kMagenta,
      ));
    }
  }

  /// Claude Code通知の視覚アラート（フォアグラウンド時の画面フラッシュ）。
  /// 一瞬でピークまで立ち上げてからフェードアウトする2段階アニメーションで
  /// はっきり目につくようにする。承認待ち＝マゼンタ、完了＝シアンで色分け。
  void _flashClaudeAlert(bool isNotification) {
    final color = isNotification ? kMagenta : kAccent;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) =>
          IgnorePointer(child: _ClaudeFlash(color: color, onDone: () => entry.remove())),
    );
    overlay.insert(entry);
  }

  void _setClaudeNotifyEnabled(bool enabled) {
    setState(() => _claudeNotifyEnabled = enabled);
    SharedPreferences.getInstance()
        .then((p) => p.setBool(_claudeNotifyPrefsKey, enabled));
  }

  /// 現在設定をPCへ送って保存させる（AppSettings.saveのフックからも呼ばれる）。
  void _pushConfig(Map<String, dynamic> json) =>
      _sendJson({'type': 'config_set', 'settings': json});

  void _disconnected() {
    if (!mounted) return;
    final nav = Navigator.of(context);
    // 切断時にボトムシート・ダイアログ・スクショプレビュー等が開いていると、
    // 土台のルートをpushReplacementで破棄した時に開いていた側が親を失い
    // フレームワークのアサーション（_dependents.isEmpty）でクラッシュする。
    // 先に自分より上のルートをすべて閉じてから接続画面へ差し替える。
    nav.popUntil((route) => route.isFirst);
    nav.pushReplacement(
      MaterialPageRoute(builder: (_) => const ConnectScreen()),
    );
  }

  void _flushMove() {
    _flushTick++;
    if (_dx.abs() >= 1 || _dy.abs() >= 1) {
      _sendBinary(0x01, _dx.round(), _dy.round());
      _dx = 0;
      _dy = 0;
    }
    // スクロールは40ms（5tick）に1回へ間引く。8ms刻みだと毎秒最大125発の
    // ホイールイベントになり、重いページではブラウザの処理が追いつかない
    if (_flushTick % 5 == 0 && _scroll.abs() >= 1) {
      _sendBinary(0x02, _scroll.round(), 0);
      _scroll = 0;
    }
  }

  void _sendBinary(int type, int a, int b) {
    final bd = ByteData(5)
      ..setUint8(0, type)
      ..setInt16(1, a.clamp(-32768, 32767), Endian.little)
      ..setInt16(3, b.clamp(-32768, 32767), Endian.little);
    widget.channel.sink.add(bd.buffer.asUint8List());
  }

  void _sendJson(Map<String, dynamic> obj) =>
      widget.channel.sink.add(jsonEncode(obj));

  void _move(double dx, double dy) {
    _dx += dx * _settings.sensitivity;
    _dy += dy * _settings.sensitivity;
  }

  void _onScrollDelta(double dy) =>
      _scroll += _settings.invertScroll ? -dy : dy;

  void _shortcut(List<String> keys) =>
      _sendJson({'type': 'shortcut', 'keys': keys});

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flush?.cancel();
    _ping?.cancel();
    _bsRepeat?.cancel();
    _sub?.cancel();
    widget.channel.sink.close();
    _text.dispose();
    _textFocus.dispose();
    if (_micListening) _speech.stop();
    stopClaudeKeepAliveService();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // ファイルピッカー等の別Activityから戻った直後、この端末のGPUドライバが
    // 古いフレームを残す描画崩れ（複数アニメーション併用時に再現）を起こすことが
    // あったため、resumed時に明示的に再描画を要求して上書きさせる。
    if (state == AppLifecycleState.resumed && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final pages = _settings.visiblePages;
    final tab = _tab.clamp(0, pages.length - 1);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // ページ本体（表示設定に応じてトラックパッド / マクロ / YouTube）
            Expanded(child: _buildPage(pages[tab])),
            // テキスト入力（どの画面でもキーボードトグルで表示）
            if (_showKeyboard)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: TextField(
                  controller: _text,
                  focusNode: _textFocus,
                  autofocus: true,
                  textInputAction: TextInputAction.send,
                  decoration: InputDecoration(
                    labelText: 'Enterで送信。空欄でのバックスペースはPCに効く',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.send, color: kAccent),
                      onPressed: _sendText,
                    ),
                  ),
                  onChanged: (v) {
                    // 番兵が消えた＝空欄でバックスペース → PCのカーソル位置の文字を消す
                    if (!v.contains(_zwsp)) {
                      _shortcut(['backspace']);
                      _text.value = TextEditingValue(
                        text: _zwsp + v,
                        selection: const TextSelection.collapsed(offset: 1),
                      );
                    }
                  },
                  onSubmitted: (_) {
                    _sendText();
                    _sendJson({
                      'type': 'key',
                      'vk': 0x0D,
                      'action': 'tap',
                      'modifiers': <String>[],
                    });
                    _textFocus.requestFocus(); // キーボードを閉じず連続入力
                  },
                ),
              ),
            // ページ切替バー（帯全体・高さ44で受ける。操作ボタン行とは別の行なので
            // タップ判定の競合は起きない）。左半分タップ=前ページ、右半分=次ページ、
            // 横スワイプでも切替できる。右端は設定への歯車（常設。下部ボタン行は
            // 非表示にできるため、消えない場所に置く）。
            //
            // GestureDetector.onHorizontalDragEnd ではなく生のポインタイベント
            // （Listener）で判定する: 内側のチェブロン用GestureDetectorとジェスチャー
            // アリーナで競合し、開始位置によってはスワイプが認識されないことがあった
            // （チェブロン上から始まるドラッグが片方向だけ拾われない不具合の原因）。
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) => _navSwipeStartX = e.position.dx,
              onPointerUp: (e) {
                final startX = _navSwipeStartX;
                _navSwipeStartX = null;
                if (startX == null) return;
                final delta = e.position.dx - startX;
                if (delta < -40 && tab < pages.length - 1) {
                  setState(() => _tab = tab + 1);
                } else if (delta > 40 && tab > 0) {
                  setState(() => _tab = tab - 1);
                }
              },
              onPointerCancel: (_) => _navSwipeStartX = null,
              child: SizedBox(
                height: 44,
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          if (tab > 0) setState(() => _tab = tab - 1);
                        },
                        child: Icon(
                          Icons.chevron_left,
                          size: 28,
                          color: tab > 0 ? kAccent : Colors.white12,
                        ),
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: List.generate(
                        pages.length,
                        (i) => AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: tab == i ? 22 : 10,
                          height: 10,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(5),
                            color: tab == i ? kAccent : Colors.white24,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          if (tab < pages.length - 1) {
                            setState(() => _tab = tab + 1);
                          }
                        },
                        child: Icon(
                          Icons.chevron_right,
                          size: 28,
                          color: tab < pages.length - 1
                              ? kAccent
                              : Colors.white12,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 44,
                      child: IconButton(
                        icon: const Icon(
                          Icons.settings,
                          size: 22,
                          color: Colors.white38,
                        ),
                        onPressed: _openSettings,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_settings.enabledBottomButtons.isNotEmpty)
              // 物理/論理ピクセル換算のずれで幅ベース判定が誤動作したため、
              // ピクセル計算に頼らずボタン数だけで切り替える。Expandedは
              // 何個あっても絶対に画面幅からはみ出さない（=見切れない）ので、
              // 「そこそこの数まではExpandedで均等フィット、それより多い時だけ
              // 自然な幅で横スクロール」という単純な閾値にする。
              _settings.enabledBottomButtons.length <= 6
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          for (final id in _settings.enabledBottomButtons)
                            _bottomBtnById(id, expand: true),
                        ],
                      ),
                    )
                  : SizedBox(
                      height: 52,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        children: [
                          for (final id in _settings.enabledBottomButtons)
                            _bottomBtnById(id, expand: false),
                        ],
                      ),
                    ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// ページIDから本体ウィジェットを生成。
  Widget _buildPage(String id) {
    switch (id) {
      case 'office':
        return KanpanicchiPanel(
          latestActivity: _lastClaudeActivity,
          latestNotify: _lastClaudeNotifyEvent,
          todos: _lastTodos,
          latestComment: _lastActivityComment,
          onMove: _move,
          onScroll: _onScrollDelta,
          onClick: (button, action) =>
              _sendJson({'type': 'click', 'button': button, 'action': action}),
          onShortcut: _shortcut,
          onSendFile: (filename, base64) =>
              _sendJson({'type': 'file_transfer', 'filename': filename, 'data': base64}),
        );
      case 'youtube':
        return YoutubePanel(
          onSend: _sendJson,
          onMove: _move,
          onScroll: _onScrollDelta,
        );
      case 'macro':
        return LauncherPanel(
          buttons: _settings.deck,
          onSend: _sendJson,
          onMove: _move,
          onScroll: _onScrollDelta,
        );
      default: // trackpad
        return TrackpadArea(
          onMove: _move,
          onScroll: _onScrollDelta,
          onClick: (button, action) =>
              _sendJson({'type': 'click', 'button': button, 'action': action}),
          onShortcut: _shortcut,
          bottomMargin: 8,
          child: const Center(
            child: Text(
              'トラックパッド\nタップ=左クリック / 長押し=右クリック\nタップ後すぐなぞる=掴んで移動',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white24),
            ),
          ),
        );
    }
  }

  /// 下部操作ボタンをIDから生成（表示・並び順は設定に従う）。
  /// expand=trueなら画面幅に均等フィット、falseなら自然な幅（横スクロール用）。
  Widget _bottomBtnById(String id, {required bool expand}) {
    switch (id) {
      case 'enter':
        return _iconBtn(Icons.keyboard_return, () => _shortcut(['enter']),
            expand: expand);
      case 'backspace':
        return _backspaceBtn(expand: expand);
      case 'keyboard':
        return _iconBtn(
          _showKeyboard ? Icons.keyboard_hide : Icons.keyboard,
          () => setState(() => _showKeyboard = !_showKeyboard),
          expand: expand,
        );
      case 'alttab':
        return _iconBtn(Icons.swap_horiz, () => _shortcut(['alt', 'tab']),
            expand: expand);
      case 'win':
        return _iconBtn(Icons.window, () => _shortcut(['win']), expand: expand);
      case 'mic':
        return _iconBtn(
          _micListening ? Icons.mic : Icons.mic_none,
          _toggleMic,
          color: _micListening ? kMagenta : null,
          expand: expand,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// マイクボタン: タップで音声入力を開始/停止。認識結果はテキスト入力として
  /// 送信する（クリップボード等ではなく、常にフォーカス中の入力欄へEnter付きで送る）。
  Future<void> _toggleMic() async {
    if (_micListening) {
      // 扇風機など常時ノイズがある環境ではOS側の無音判定(pauseFor)が働かず
      // 自動送信されないことがあるため、手動停止時にその時点までの認識結果を
      // こちらから確実に送る（onResultのfinalResultを待たない）。
      _sendMicResultIfAny();
      await _speech.stop();
      if (mounted) setState(() => _micListening = false);
      return;
    }
    _speechAvailable = await _speech.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') {
          if (mounted) setState(() => _micListening = false);
        }
      },
      onError: (_) {
        // タイムアウト等のエラーで打ち切られた場合も、ここまで認識できていた
        // 分は失わずに送る（以前はここで結果を送らず無言で捨てていたため、
        // 話している途中でエラー終了すると入力が消えて見えていた）。
        _sendMicResultIfAny();
        if (mounted) setState(() => _micListening = false);
      },
    );
    if (!_speechAvailable) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('音声入力を利用できません（マイク権限を確認してください）'),
        ));
      }
      return;
    }
    _micLastWords = '';
    _micSent = false;
    setState(() => _micListening = true);
    await _speech.listen(
      onResult: (result) {
        // 途中経過でも常に最新の認識結果を保持しておく（手動停止時の
        // フォールバック送信で使うため）。
        _micLastWords = result.recognizedWords;
        if (!result.finalResult) return;
        _sendMicResultIfAny();
        // ここでこちらから明示stop()すると、OS側が無音判定で自然に終了する際の
        // 完了音（ピロ）と競合し鳴らないことがあったため呼ばない。終了検知は
        // onStatusのnotListening/doneに任せる（_micListeningのfalse化もそちら）。
      },
      // pauseFor: 無音がこの時間続くまで自動送信しない（デフォルトが短く
      // 話し終える前に切れる、というフィードバックを受けて延長したが、
      // 8秒は長すぎて逆に精度が悪く感じられたため短縮）。
      // 端末によってはAndroid自体が1〜3秒で無音判定を打ち切ることがあり、
      // その場合はOS側の制限が優先される（プラグイン側では回避不可）。
      //
      // listenMode: dictation は confirmation/search 用のモードと違い長文の
      // 書き取り用として指定（※speech_to_textのlistenModeはiOS専用でAndroidの
      // 挙動には影響しない）。
      listenOptions: SpeechListenOptions(
        localeId: 'ja_JP',
        pauseFor: const Duration(seconds: 3),
        listenFor: const Duration(seconds: 60),
        listenMode: ListenMode.dictation,
      ),
    );
  }

  /// マイクの認識結果を1回だけ送信する（onResultのfinalResult・onError・
  /// 手動停止のいずれからも呼ばれうるため、二重送信しないよう_micSentでガードする）。
  void _sendMicResultIfAny() {
    if (_micSent) return;
    _micSent = true;
    if (_micLastWords.isEmpty) return;
    _sendJson({
      'type': 'macro',
      'steps': [
        {'type': 'text', 'text': _micLastWords},
        {'type': 'shortcut', 'keys': ['enter']},
      ],
    });
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          settings: _settings,
          claudeNotifyEnabled: _claudeNotifyEnabled,
          onClaudeNotifyChanged: _setClaudeNotifyEnabled,
        ),
      ),
    );
    if (!mounted) return;
    // 設定画面でページ構成が変わった可能性があるので反映＋タブを範囲内に収める
    setState(() {
      _tab = _tab.clamp(0, _settings.visiblePages.length - 1);
    });
  }

  /// 下部ボタン共通の幅（横スクロール表示のため固定幅で並べる）。
  static const _bottomBtnWidth = 72.0;

  /// バックスペースボタン。タップで1文字、長押しで連続削除。
  Widget _backspaceBtn({required bool expand}) {
    final button = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Listener(
        onPointerUp: (_) => _bsRepeat?.cancel(),
        onPointerCancel: (_) => _bsRepeat?.cancel(),
        child: OutlinedButton(
          onPressed: () => _shortcut(['backspace']),
          onLongPress: () {
            _shortcut(['backspace']);
            _bsRepeat?.cancel();
            _bsRepeat = Timer.periodic(
              const Duration(milliseconds: 90),
              (_) => _shortcut(['backspace']),
            );
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: kAccent,
            side: BorderSide(color: kAccent.withValues(alpha: 0.4)),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Icon(Icons.backspace_outlined, size: expand ? 26 : 22),
        ),
      ),
    );
    return expand ? Expanded(child: button) : SizedBox(width: _bottomBtnWidth, child: button);
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap,
      {Color? color, required bool expand}) {
    final c = color ?? kAccent;
    final button = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: c,
          side: BorderSide(color: c.withValues(alpha: 0.4)),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Icon(icon, size: expand ? 26 : 22),
      ),
    );
    return expand ? Expanded(child: button) : SizedBox(width: _bottomBtnWidth, child: button);
  }

  void _sendText() {
    final t = _text.text.replaceAll(_zwsp, '');
    if (t.isEmpty) return;
    _sendJson({'type': 'text', 'text': t});
    // 空にせず番兵だけ残す（空欄バックスペース検出用）
    _text.value = TextEditingValue(
      text: _zwsp,
      selection: const TextSelection.collapsed(offset: 1),
    );
  }
}

/// Claude Code通知の画面フラッシュ本体。ピークまで一瞬で立ち上げてからフェードアウトする。
class _ClaudeFlash extends StatefulWidget {
  const _ClaudeFlash({required this.color, required this.onDone});

  final Color color;
  final VoidCallback onDone;

  @override
  State<_ClaudeFlash> createState() => _ClaudeFlashState();
}

class _ClaudeFlashState extends State<_ClaudeFlash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    );
    _opacity = TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.65), weight: 100),
      TweenSequenceItem(tween: Tween(begin: 0.65, end: 0.0), weight: 450),
    ]).animate(_controller);
    _controller.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _opacity,
        builder: (context, child) =>
            Container(color: widget.color.withValues(alpha: _opacity.value)),
      );
}

// ─────────────────────────────────────── スクショプレビュー画面

class ScreenshotPreview extends StatelessWidget {
  const ScreenshotPreview({super.key, required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text('PCのスクリーンショット', style: TextStyle(color: kAccent)),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5,
          child: Image.memory(bytes),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'ピンチでズーム。長押しで保存、または標準フォトアプリで切り抜けます',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}
