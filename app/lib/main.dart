import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'launcher.dart';
import 'trackpad.dart';
import 'youtube.dart';

// 011号RoadTalkと同じサイバーパンク配色
const kBg = Color(0xFF050810);
const kAccent = Color(0xFF00F5FF);
const kMagenta = Color(0xFFFF006E);

void main() => runApp(const PocketPadApp());

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
        WidgetsBinding.instance.addPostFrameCallback((_) => _scanQr());
      }
    });
  }

  /// 前回PCへ、成功するまで数秒ごとに自動再接続を続ける。
  /// QR/手動を触ると _autoRetry=false で止まる。
  Future<void> _autoConnect() async {
    while (_autoRetry && mounted &&
        _host.text.isNotEmpty && _token.text.isNotEmpty) {
      setState(() {
        _busy = true;
        _status = '前回のPC（${_host.text}）に再接続中…';
      });
      if (await _tryConnect(
          _host.text, _token.text, const Duration(seconds: 3))) {
        return; // 成功したらTrackpadScreenへ遷移済み
      }
      if (!mounted || !_autoRetry) return;
      setState(() => _status = '接続待ち…（PCのアプリが起動しているか確認）');
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  /// 1ホストへの接続試行。成功したらTrackpadScreenへ遷移してtrueを返す。
  Future<bool> _tryConnect(String host, String token, Duration timeout) async {
    try {
      final channel =
          WebSocketChannel.connect(Uri.parse('ws://$host:9013/ws'));
      await channel.ready.timeout(timeout);

      final stream = channel.stream.asBroadcastStream();
      channel.sink.add(jsonEncode({
        'type': 'auth',
        'token': token,
        'device_id': 'a25',
        'device_name': 'A25',
      }));

      final reply =
          await stream.firstWhere((m) => m is String).timeout(timeout);
      final json = jsonDecode(reply as String) as Map<String, dynamic>;

      if (json['type'] != 'auth_ok') {
        channel.sink.close();
        return false;
      }
      final p = await SharedPreferences.getInstance();
      await p.setString('host', host);
      await p.setString('token', token);
      if (!mounted) return true;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => TrackpadScreen(channel: channel, stream: stream),
      ));
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
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), backgroundColor: kMagenta));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border:
                        Border.all(color: kAccent.withValues(alpha: 0.6), width: 2),
                    boxShadow: [
                      BoxShadow(
                          color: kAccent.withValues(alpha: 0.25), blurRadius: 24),
                    ],
                  ),
                  child: const Icon(Icons.touch_app, size: 44, color: kAccent),
                ),
                const SizedBox(height: 24),
                const Text('PocketPad',
                    style: TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.bold,
                        color: kAccent,
                        letterSpacing: 6)),
                const SizedBox(height: 4),
                const Text('Your PC. In Your Pocket. — 未来ガジェット013号',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 32),
                if (_status.isNotEmpty) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.only(right: 10),
                          child: SizedBox(
                              width: 14,
                              height: 14,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      Flexible(
                        child: Text(_status,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],
                SizedBox(
                  width: double.infinity,
                  height: 64,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _scanQr,
                    icon: const Icon(Icons.qr_code_scanner, size: 28),
                    label: const Text('QRコードで接続',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _showManual = !_showManual),
                  child: Text(_showManual ? '手動入力を閉じる' : '手動で入力する',
                      style: const TextStyle(color: Colors.white54)),
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
                      child: Text(_busy ? '接続中…' : 'この情報で接続',
                          style: const TextStyle(fontSize: 16)),
                    ),
                  ),
                ],
                const SizedBox(height: 40),
                const Text(
                    'PC側はタスクトレイのPocketPadアイコンを\nクリックするとQRが表示されます',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ],
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: kBg.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: kAccent.withValues(alpha: 0.3)),
              ),
              child: const Text(
                'PCのタスクトレイアイコンをクリックして\n表示されたQRコードを枠に合わせてください',
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
  const TrackpadScreen({super.key, required this.channel, required this.stream});

  final WebSocketChannel channel;
  final Stream<dynamic> stream;

  @override
  State<TrackpadScreen> createState() => _TrackpadScreenState();
}

class _TrackpadScreenState extends State<TrackpadScreen> {
  static const _sensitivity = 1.4;

  double _dx = 0, _dy = 0, _scroll = 0;
  Timer? _flush;
  Timer? _ping;
  StreamSubscription? _sub;
  final _text = TextEditingController();
  bool _showKeyboard = false;
  final _textFocus = FocusNode();
  int _tab = 0; // 0=トラックパッド, 1=ランチャー

  @override
  void initState() {
    super.initState();
    // 8ms間引き集約（protocol.md v1）
    _flush = Timer.periodic(const Duration(milliseconds: 8), (_) => _flushMove());
    _ping = Timer.periodic(const Duration(seconds: 5), (_) {
      _sendJson({'type': 'ping', 'ts': DateTime.now().millisecondsSinceEpoch});
    });
    _sub = widget.stream.listen(_onMessage,
        onDone: _disconnected, onError: (_) => _disconnected());
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
    if (j['type'] == 'screenshot_result' && mounted) {
      final bytes = base64Decode(j['jpeg'] as String);
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ScreenshotPreview(bytes: bytes),
      ));
    } else if (j['type'] == 'screenshot_error' && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('スクショの取得に失敗しました'), backgroundColor: kMagenta));
    }
  }

  void _disconnected() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ConnectScreen()));
  }

  void _flushMove() {
    if (_dx.abs() >= 1 || _dy.abs() >= 1) {
      _sendBinary(0x01, _dx.round(), _dy.round());
      _dx = 0;
      _dy = 0;
    }
    if (_scroll.abs() >= 1) {
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

  void _shortcut(List<String> keys) =>
      _sendJson({'type': 'shortcut', 'keys': keys});

  @override
  void dispose() {
    _flush?.cancel();
    _ping?.cancel();
    _sub?.cancel();
    widget.channel.sink.close();
    _text.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
        children: [
          // ページ本体（トラックパッド / マクロ / YouTube。操作バーのスワイプで移動）
          Expanded(
            child: _tab == 2
                ? YoutubePanel(
                    onSend: _sendJson,
                    onMove: (dx, dy) {
                      _dx += dx * _sensitivity;
                      _dy += dy * _sensitivity;
                    },
                    onScroll: (dy) => _scroll += dy,
                  )
                : _tab == 1
                ? LauncherPanel(buttons: defaultDeck, onSend: _sendJson)
                : Row(
              children: [
                Expanded(
                  child: Trackpad(
                    onMove: (dx, dy) {
                      _dx += dx * _sensitivity;
                      _dy += dy * _sensitivity;
                    },
                    onClick: (button, action) => _sendJson(
                        {'type': 'click', 'button': button, 'action': action}),
                    borderColor: kAccent,
                    child: const Center(
                      child: Text(
                        'トラックパッド\nタップ=左クリック / 長押し=右クリック\nタップ後すぐなぞる=掴んで移動',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white24),
                      ),
                    ),
                  ),
                ),
                // スクロールストリップ
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (d) => _scroll += -d.delta.dy * 4,
                  child: Container(
                    width: 60,
                    margin: const EdgeInsets.only(top: 8, bottom: 8, right: 8),
                    decoration: BoxDecoration(
                      border: Border.all(color: kMagenta.withValues(alpha: 0.3)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Center(
                      child: Icon(Icons.unfold_more, color: Colors.white24),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // テキスト入力（トラックパッド画面 かつ キーボードトグル時）
          if (_tab == 0 && _showKeyboard)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextField(
                controller: _text,
                focusNode: _textFocus,
                autofocus: true,
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(
                  hintText: '文章を完成させてEnterでPCへ（PC側Enterも押される）',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.send, color: kAccent),
                    onPressed: _sendText,
                  ),
                ),
                onSubmitted: (_) {
                  _sendText();
                  _sendJson({'type': 'key', 'vk': 0x0D, 'action': 'tap', 'modifiers': <String>[]});
                  _textFocus.requestFocus(); // キーボードを閉じず連続入力
                },
              ),
            ),
          // 操作バー：左右スワイプでページ切替（トラックパッド ⇄ マクロ）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v < -80 && _tab < 2) setState(() => _tab++);
              if (v > 80 && _tab > 0) setState(() => _tab--);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ページインジケーター（スワイプで移動できることを示す）
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    3,
                    (i) => AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: _tab == i ? 18 : 8,
                      height: 8,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        color: _tab == i ? kAccent : Colors.white24,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      _iconBtn(Icons.keyboard_return, () => _shortcut(['enter'])),
                      _iconBtn(
                          _showKeyboard ? Icons.keyboard_hide : Icons.keyboard,
                          () => setState(() => _showKeyboard = !_showKeyboard)),
                      _iconBtn(Icons.swap_horiz, () => _shortcut(['alt', 'tab'])),
                      _iconBtn(Icons.window, () => _shortcut(['win'])),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback onTap, {int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: kAccent,
            side: BorderSide(color: kAccent.withValues(alpha: 0.4)),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          child: Icon(icon, size: 22),
        ),
      ),
    );
  }

  void _sendText() {
    if (_text.text.isEmpty) return;
    _sendJson({'type': 'text', 'text': _text.text});
    _text.clear();
  }
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
        title: const Text('PCのスクリーンショット',
            style: TextStyle(color: kAccent)),
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
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12),
          ),
        ),
      ),
    );
  }
}
