import 'dart:async';

import 'package:flutter/material.dart';

import 'trackpad.dart';

const _kAccent = Color(0xFF00F5FF);
const _kMagenta = Color(0xFFFF006E);

/// PC側のPreToolUseフックから届いた1件のツール活動（`claude_activity`）。
class ClaudeActivity {
  ClaudeActivity({required this.tool, required this.detail}) : time = DateTime.now();

  final String tool;
  final String detail;
  final DateTime time;
}

/// PC側のStop/Notificationフックから届いた通知（`claude_notify`）。
/// アバターの状態にも反映するため、通知アラートの発火とは別にAI社員ページへも渡す。
class ClaudeNotifyEvent {
  ClaudeNotifyEvent({required this.event, required this.message}) : time = DateTime.now();

  final String event; // "stop" | "notification"
  final String message;
  final DateTime time;
}

/// オフィス内の「持ち場」。キャラクターがこの位置(Alignment)へ移動する。
class _Zone {
  const _Zone(this.align, this.propIcon, this.verb, this.roomName);
  final Alignment align;
  final IconData propIcon;
  final String verb;
  final String roomName;
}

const _zoneIdle = _Zone(Alignment.center, Icons.chair_alt, '待機中', '休憩スペース');
const _zoneEditing =
    _Zone(Alignment(-0.7, -0.6), Icons.desktop_windows, '編集中', '開発デスク');
const _zoneCommand =
    _Zone(Alignment(0.7, -0.6), Icons.terminal, 'コマンド実行中', 'サーバー室');
const _zoneSearching =
    _Zone(Alignment(-0.7, 0.6), Icons.menu_book, '調査中', '資料室');
const _zoneDelegating =
    _Zone(Alignment(0.7, 0.6), Icons.groups, '委任中', '会議室');

/// tool_name → ゾーンのマッピング。ここに無いツールは中央「作業中」扱い。
const _zones = <String, _Zone>{
  'Edit': _zoneEditing,
  'Write': _zoneEditing,
  'NotebookEdit': _zoneEditing,
  'Bash': _zoneCommand,
  'Read': _zoneSearching,
  'Grep': _zoneSearching,
  'Glob': _zoneSearching,
  'WebSearch': _zoneSearching,
  'WebFetch': _zoneSearching,
  'Task': _zoneDelegating,
};
const _zoneWorking = _Zone(Alignment.center, Icons.smart_toy, '作業中', '休憩スペース');

_Zone _zoneFor(String tool) => _zones[tool] ?? _zoneWorking;

/// Bashのコマンド文字列の先頭から、もう少し具体的な動詞に絞り込む
/// （「コマンド実行中」ばかりになるのを避ける）。ゾーン自体は変えず表示ラベルのみ調整。
String _bashVerb(String command) {
  final head = command.trimLeft().split(RegExp(r'\s+')).firstOrNull ?? '';
  final second = command.trimLeft().split(RegExp(r'\s+')).skip(1).firstOrNull ?? '';
  switch (head) {
    case 'git':
      return 'Git操作中';
    case 'npm':
    case 'pnpm':
    case 'yarn':
      return 'パッケージ管理中';
    case 'flutter':
      if (second == 'pub') return 'パッケージ管理中';
      if (second == 'build' || second == 'run') return 'ビルド中';
      return 'Flutter操作中';
    case 'dotnet':
      if (second == 'build' || second == 'publish') return 'ビルド中';
      return '.NET操作中';
    case 'adb':
      return '実機操作中';
    default:
      return 'コマンド実行中';
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class _Status {
  const _Status({required this.icon, required this.color, required this.label});
  final IconData icon;
  final Color color;
  final String label;
}

class _LogEntry {
  const _LogEntry({required this.icon, required this.color, required this.label, required this.time});
  final IconData icon;
  final Color color;
  final String label;
  final DateTime time;
}

// ─────────────────────────────────────── ドット絵キャラクター
// Flutter標準機能のみ（外部パッケージ不使用）。カイロソフト風の丸っこいミニキャラ。
// '.'=透明、'1'=シアン(本体)、'2'=マゼンタ(アンテナ)、'0'=黒(目)。
const _spriteStand = [
  '...2...',
  '.11111.',
  '1111111',
  '1101011',
  '1111111',
  '.11111.',
  '..1.1..',
  '..1.1..',
];
const _spriteWalk = [
  '...2...',
  '.11111.',
  '1111111',
  '1101011',
  '1111111',
  '.11111.',
  '.1...1.',
  '1.....1',
];

const _spritePalette = <String, Color>{
  '1': _kAccent,
  '2': _kMagenta,
  '0': Colors.black,
};

class _PixelSprite extends StatelessWidget {
  const _PixelSprite({required this.rows, required this.glow});
  static const pixelSize = 6.0;
  final List<String> rows;
  final Color glow;

  @override
  Widget build(BuildContext context) {
    final w = rows.first.length * pixelSize;
    final h = rows.length * pixelSize;
    return SizedBox(
      width: w,
      height: h,
      child: CustomPaint(painter: _SpritePainter(rows, pixelSize, glow)),
    );
  }
}

class _SpritePainter extends CustomPainter {
  _SpritePainter(this.rows, this.pixelSize, this.glow);
  final List<String> rows;
  final double pixelSize;
  final Color glow;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (var y = 0; y < rows.length; y++) {
      final row = rows[y];
      for (var x = 0; x < row.length; x++) {
        final color = _spritePalette[row[x]];
        if (color == null) continue;
        paint.color = color;
        canvas.drawRect(
          Rect.fromLTWH(x * pixelSize, y * pixelSize, pixelSize, pixelSize),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SpritePainter oldDelegate) =>
      oldDelegate.rows != rows || oldDelegate.glow != glow;
}

/// オフィスを4部屋に見せる十字の仕切り線。
class _RoomDividerPainter extends CustomPainter {
  const _RoomDividerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    canvas.drawLine(
        Offset(size.width / 2, 0), Offset(size.width / 2, size.height), paint);
    canvas.drawLine(
        Offset(0, size.height / 2), Offset(size.width, size.height / 2), paint);
  }

  @override
  bool shouldRepaint(covariant _RoomDividerPainter oldDelegate) => false;
}

/// 「AI社員」ページ。Claude Codeが今何をしているかをドット絵キャラクターで見せる
/// 観賞用ビューワー。オフィス内の持ち場（編集/コマンド/調査/委任/待機）を活動に応じて
/// 移動する。上半分はデフォルトでこのオフィス表示、右上のボタンでトラックパッドに開閉できる。
class AiOfficePanel extends StatefulWidget {
  const AiOfficePanel({
    super.key,
    required this.latestActivity,
    required this.latestNotify,
    required this.onMove,
    required this.onScroll,
    required this.onClick,
    required this.onShortcut,
  });

  final ClaudeActivity? latestActivity;
  final ClaudeNotifyEvent? latestNotify;
  final void Function(double dx, double dy) onMove;
  final void Function(double dy) onScroll;
  final void Function(String button, String action) onClick;
  final void Function(List<String> keys) onShortcut;

  @override
  State<AiOfficePanel> createState() => _AiOfficePanelState();
}

class _AiOfficePanelState extends State<AiOfficePanel>
    with SingleTickerProviderStateMixin {
  static const _moveDuration = Duration(milliseconds: 500);

  bool _showTrackpad = false;
  _Zone _zone = _zoneIdle;
  _Status _status = const _Status(icon: Icons.chair_alt, color: Colors.white38, label: '待機中');
  final List<_LogEntry> _log = [];
  Timer? _idleTimer;
  Timer? _doneRevertTimer;
  Timer? _walkFrameTimer;
  Timer? _arriveTimer;
  bool _walking = false;
  bool _walkFrameA = true;
  late final AnimationController _bounce;

  @override
  void initState() {
    super.initState();
    _bounce = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _armIdleTimer();
  }

  @override
  void didUpdateWidget(covariant AiOfficePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final activity = widget.latestActivity;
    if (activity != null && !identical(activity, oldWidget.latestActivity)) {
      _onActivity(activity);
    }
    final notify = widget.latestNotify;
    if (notify != null && !identical(notify, oldWidget.latestNotify)) {
      _onNotify(notify);
    }
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: 30), () {
      if (mounted) _moveTo(_zoneIdle, Colors.white38, _zoneIdle.verb);
    });
  }

  void _pushLog(IconData icon, Color color, String label, DateTime time) {
    _log.insert(0, _LogEntry(icon: icon, color: color, label: label, time: time));
    if (_log.length > 8) _log.removeLast();
  }

  /// キャラクターを指定ゾーンへ歩かせて、到着後にラベル/色を反映する。
  void _moveTo(_Zone zone, Color color, String label) {
    _walkFrameTimer?.cancel();
    _arriveTimer?.cancel();
    final moving = zone.align != _zone.align;
    setState(() {
      _zone = zone;
      _status = _Status(icon: zone.propIcon, color: color, label: label);
      _walking = moving;
    });
    if (moving) {
      _walkFrameTimer = Timer.periodic(const Duration(milliseconds: 150), (_) {
        if (mounted) setState(() => _walkFrameA = !_walkFrameA);
      });
      _arriveTimer = Timer(_moveDuration, () {
        _walkFrameTimer?.cancel();
        if (mounted) setState(() => _walking = false);
      });
    }
  }

  void _onActivity(ClaudeActivity a) {
    final zone = _zoneFor(a.tool);
    final verb = a.tool == 'Bash' ? _bashVerb(a.detail) : zone.verb;
    final label = a.detail.isEmpty ? verb : '$verb: ${a.detail}';
    _moveTo(zone, _kAccent, 'クロコが$label');
    _pushLog(zone.propIcon, _kAccent, 'クロコが$label', a.time);
    _doneRevertTimer?.cancel();
    _armIdleTimer();
  }

  void _onNotify(ClaudeNotifyEvent n) {
    final isWaiting = n.event == 'notification';
    final icon = isWaiting ? Icons.notifications_active : Icons.check_circle;
    final color = isWaiting ? _kMagenta : _kAccent;
    final label = isWaiting ? 'クロコが承認を待っています: ${n.message}' : 'クロコが完了しました: ${n.message}';
    setState(() => _status = _Status(icon: icon, color: color, label: label));
    _pushLog(icon, color, label, n.time);
    _doneRevertTimer?.cancel();
    if (!isWaiting) {
      // 完了はしばらく強調してから待機に戻す
      _doneRevertTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) _moveTo(_zoneIdle, Colors.white38, _zoneIdle.verb);
      });
    }
    _armIdleTimer();
  }

  @override
  void dispose() {
    _bounce.dispose();
    _idleTimer?.cancel();
    _doneRevertTimer?.cancel();
    _walkFrameTimer?.cancel();
    _arriveTimer?.cancel();
    super.dispose();
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: _showTrackpad
                    ? TrackpadArea(
                        onMove: widget.onMove,
                        onScroll: widget.onScroll,
                        onClick: widget.onClick,
                        onShortcut: widget.onShortcut,
                        bottomMargin: 4,
                        child: const Center(
                          child: Icon(Icons.touch_app, color: Colors.white12, size: 32),
                        ),
                      )
                    : Container(
                        margin: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Stack(
                          children: [
                            // 4部屋に見えるよう十字の仕切り線
                            const Center(
                              child: SizedBox.expand(
                                child: CustomPaint(painter: _RoomDividerPainter()),
                              ),
                            ),
                            // 各持ち場の什器（アイコン+ラベル）
                            for (final z in {
                              _zoneEditing,
                              _zoneCommand,
                              _zoneSearching,
                              _zoneDelegating,
                            })
                              Align(
                                alignment: z.align,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(z.propIcon, color: Colors.white24, size: 26),
                                    Text(z.roomName,
                                        style: const TextStyle(
                                            color: Colors.white24, fontSize: 9)),
                                  ],
                                ),
                              ),
                            // キャラクター本体
                            AnimatedAlign(
                              duration: _moveDuration,
                              curve: Curves.easeInOut,
                              alignment: _zone.align,
                              child: AnimatedBuilder(
                                animation: _bounce,
                                builder: (context, child) {
                                  final offsetY = _walking ? 0.0 : -_bounce.value * 3;
                                  return Transform.translate(
                                    offset: Offset(0, offsetY),
                                    child: child,
                                  );
                                },
                                child: _PixelSprite(
                                  rows: _walking && !_walkFrameA ? _spriteWalk : _spriteStand,
                                  glow: _status.color,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  icon: Icon(
                    _showTrackpad ? Icons.smart_toy : Icons.touch_app,
                    color: Colors.white38,
                  ),
                  tooltip: _showTrackpad ? 'オフィス表示に戻る' : 'トラックパッドを開く',
                  onPressed: () => setState(() => _showTrackpad = !_showTrackpad),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Text(
                  _status.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _status.color,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Expanded(
                child: _log.isEmpty
                    ? const Center(
                        child: Text(
                          'Claude Codeがツールを使うと\nここに活動ログが流れます',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white24, fontSize: 12),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        itemCount: _log.length,
                        itemBuilder: (context, i) {
                          final e = _log[i];
                          return ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            leading: Icon(e.icon, color: e.color, size: 18),
                            title: Text(e.label,
                                style: const TextStyle(color: Colors.white70, fontSize: 12)),
                            trailing: Text(_fmtTime(e.time),
                                style: const TextStyle(color: Colors.white24, fontSize: 10)),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
