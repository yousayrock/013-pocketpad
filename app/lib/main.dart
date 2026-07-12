import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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

  Future<void> _autoConnect() async {
    setState(() {
      _busy = true;
      _status = '前回のPC（${_host.text}）に再接続中…';
    });
    final ok =
        await _tryConnect(_host.text, _token.text, const Duration(seconds: 3));
    if (!ok && mounted) {
      setState(() {
        _busy = false;
        _status = '自動接続できませんでした。QRを読み取ってください';
      });
      _scanQr(); // 失敗したらそのままカメラを開く（開けばカメラの動線）
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
    final host = _host.text.trim();
    final token = _token.text.trim();
    if (host.isEmpty || token.isEmpty) return;

    setState(() => _busy = true);
    final ok = await _tryConnect(host, token, const Duration(seconds: 5));
    if (!ok) _fail('接続失敗。PC側アプリの起動・IP・トークンを確認してください');
  }

  /// PC画面のQRを読み、記載された全ホスト候補へ順に接続を試みる。
  Future<void> _scanQr() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
    if (raw == null || !mounted) return;

    List<String> hosts;
    String token;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['app'] != 'pocketpad') throw const FormatException();
      hosts = List<String>.from(j['hosts'] as List);
      token = j['token'] as String;
    } catch (_) {
      _fail('PocketPadのQRではないようです');
      return;
    }

    setState(() => _busy = true);
    for (final host in hosts) {
      _host.text = host;
      _token.text = token;
      if (await _tryConnect(host, token, const Duration(seconds: 3))) return;
    }
    _fail('QRのどのIPにも接続できませんでした。PCと同じWiFiにいるか確認してください');
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
  bool _liveType = false; // IME変換確定をそのままPCへ流すモード（実験用。デフォルトは一括送信）
  final _textFocus = FocusNode();
  String _lastSent = '';
  Timer? _liveDebounce;
  bool _internalEdit = false;

  /// 番兵（ゼロ幅スペース）。欄の先頭に常駐させ、これが消えたら
  /// 「空欄でBackspaceが押された」と判定してPCへBackspaceを送る。
  static const _zw = '​';

  @override
  void initState() {
    super.initState();
    // 8ms間引き集約（protocol.md v1）
    _flush = Timer.periodic(const Duration(milliseconds: 8), (_) => _flushMove());
    _ping = Timer.periodic(const Duration(seconds: 5), (_) {
      _sendJson({'type': 'ping', 'ts': DateTime.now().millisecondsSinceEpoch});
    });
    _sub = widget.stream.listen((_) {}, onDone: _disconnected, onError: (_) => _disconnected());
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

  void _click(String button) =>
      _sendJson({'type': 'click', 'button': button, 'action': 'tap'});

  void _shortcut(List<String> keys) =>
      _sendJson({'type': 'shortcut', 'keys': keys});

  @override
  void dispose() {
    _flush?.cancel();
    _ping?.cancel();
    _liveDebounce?.cancel();
    _sub?.cancel();
    widget.channel.sink.close();
    _text.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text('PocketPad',
            style: TextStyle(color: kAccent, letterSpacing: 2)),
        actions: [
          IconButton(
            icon: Icon(_showKeyboard ? Icons.keyboard_hide : Icons.keyboard),
            onPressed: () => setState(() => _showKeyboard = !_showKeyboard),
          ),
        ],
      ),
      body: Column(
        children: [
          // トラックパッド ＋ スクロールストリップ
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (d) {
                      _dx += d.delta.dx * _sensitivity;
                      _dy += d.delta.dy * _sensitivity;
                    },
                    onTap: () => _click('left'),
                    onDoubleTap: () =>
                        _sendJson({'type': 'click', 'button': 'left', 'action': 'double'}),
                    onLongPress: () => _click('right'),
                    child: Container(
                      margin: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        border: Border.all(color: kAccent.withValues(alpha: 0.3)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Center(
                        child: Text(
                          'トラックパッド\nタップ=左クリック / 長押し=右クリック',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white24),
                        ),
                      ),
                    ),
                  ),
                ),
                // スクロールストリップ
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (d) => _scroll += -d.delta.dy * 4,
                  child: Container(
                    width: 44,
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
          // テキスト入力（キーボードトグル時）
          if (_showKeyboard) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  const Text('リアルタイム入力', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  Switch(
                    value: _liveType,
                    activeColor: kAccent,
                    onChanged: (v) => setState(() {
                      _liveType = v;
                      _lastSent = '';
                      _setFieldRaw(v ? _zw : '');
                    }),
                  ),
                  if (_liveType)
                    const Expanded(
                      child: Text('変換確定した文字がそのままPCに入力されます',
                          style: TextStyle(color: Colors.white38, fontSize: 11)),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextField(
                controller: _text,
                focusNode: _textFocus,
                autofocus: true,
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(
                  hintText: _liveType
                      ? 'ここに打つとPCにそのまま入る'
                      : '文章を完成させてEnterでPCへ（PC側Enterも押される）',
                  border: const OutlineInputBorder(),
                  suffixIcon: _liveType
                      ? IconButton(
                          icon: const Icon(Icons.refresh, color: kMagenta),
                          tooltip: '欄をリセット（PC側はそのまま）',
                          onPressed: () {
                            _lastSent = '';
                            _setFieldRaw(_zw);
                          },
                        )
                      : IconButton(
                          icon: const Icon(Icons.send, color: kAccent),
                          onPressed: _sendText,
                        ),
                ),
                onChanged: _liveType ? (_) => _onLiveChanged() : null,
                onSubmitted: (_) {
                  if (_liveType) {
                    _syncLive(); // 未送信分を先に送ってからEnter
                    _sendJson({'type': 'key', 'vk': 0x0D, 'action': 'tap', 'modifiers': <String>[]});
                    _lastSent = '';
                    _setFieldRaw(_zw);
                  } else {
                    _sendText();
                    _sendJson({'type': 'key', 'vk': 0x0D, 'action': 'tap', 'modifiers': <String>[]});
                  }
                  _textFocus.requestFocus(); // キーボードを閉じず連続入力
                },
              ),
            ),
          ],
          // クリック・ショートカットバー
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      _btn('左クリック', () => _click('left'), flex: 2),
                      _btn('中', () => _click('middle')),
                      _btn('右クリック', () => _click('right'), flex: 2),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _btn('Esc', () => _shortcut(['esc'])),
                      _btn('Enter', () => _shortcut(['enter'])),
                      _btn('Alt+Tab', () => _shortcut(['alt', 'tab'])),
                      _btn('⊞', () => _shortcut(['win'])),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _btn(String label, VoidCallback onTap, {int flex = 1}) {
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
          ),
          child: Text(label),
        ),
      ),
    );
  }

  void _sendText() {
    if (_text.text.isEmpty) return;
    _sendJson({'type': 'text', 'text': _text.text});
    _text.clear();
  }

  /// 入力欄をプログラムから書き換える（onChangedは発火しないがガードもかける）
  void _setFieldRaw(String s) {
    _internalEdit = true;
    _text.value = TextEditingValue(
      text: s,
      selection: TextSelection.collapsed(offset: s.length),
    );
    _internalEdit = false;
  }

  /// 変更のたびに120msデバウンス。IMEの中間状態を送らず、確定後の状態だけ同期する。
  void _onLiveChanged() {
    _liveDebounce?.cancel();
    _liveDebounce = Timer(const Duration(milliseconds: 120), _syncLive);
  }

  /// リアルタイム入力の同期。確定済みテキストの差分をPCへ送る。
  /// 番兵が消えていたら空欄Backspaceと判定。削除分はBackspaceとして送る。
  void _syncLive() {
    if (!_liveType || _internalEdit) return;
    if (_text.value.composing.isValid) return; // 変換中（下線状態）は確定を待つ

    final raw = _text.text;
    final content = raw.replaceAll(_zw, '');
    // 番兵が消え、かつ打った分も残っていない＝空欄でBackspace → PCの既存文字を1つ消す
    final sentinelBs = (!raw.contains(_zw) && _lastSent.isEmpty && content.isEmpty) ? 1 : 0;

    var p = 0;
    while (p < _lastSent.length && p < content.length && _lastSent[p] == content[p]) {
      p++;
    }
    final deletes = (_lastSent.length - p) + sentinelBs;
    for (var i = 0; i < deletes; i++) {
      _sendJson({'type': 'key', 'vk': 0x08, 'action': 'tap', 'modifiers': <String>[]});
    }
    final added = content.substring(p);
    if (added.isNotEmpty) {
      _sendJson({'type': 'text', 'text': added});
    }
    _lastSent = content;
    // 番兵の復活は欄が空のときだけ。入力中に欄を書き換えるとIMEの変換が
    // 中断されて文字が途中で切れるため、タイピング中は触らない。
    if (!raw.contains(_zw) && content.isEmpty) _setFieldRaw(_zw);
  }
}
