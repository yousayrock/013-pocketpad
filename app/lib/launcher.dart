import 'dart:async';

import 'package:flutter/material.dart';

import 'trackpad.dart';

const _kAccent = Color(0xFF00F5FF);
const _kMagenta = Color(0xFFFF006E);

/// Stream Deck風ランチャーの1ボタン定義。
/// tapで送るJSONメッセージ（type: shortcut / launch / text / macro）を丸ごと持つ。
class DeckButton {
  const DeckButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.message,
  });

  final String label;
  final IconData icon;
  final Color color;
  final Map<String, dynamic> message;
}

/// 初期プリセット（12個）。後から編集・追加できるようにこのリストを差し替える設計。
const List<DeckButton> defaultDeck = [
  DeckButton(
    label: 'コピー',
    icon: Icons.copy,
    color: _kAccent,
    message: {'type': 'shortcut', 'keys': ['ctrl', 'c']},
  ),
  DeckButton(
    label: '貼り付け',
    icon: Icons.content_paste,
    color: _kAccent,
    message: {'type': 'shortcut', 'keys': ['ctrl', 'v']},
  ),
  DeckButton(
    label: '切り取り',
    icon: Icons.content_cut,
    color: _kAccent,
    message: {'type': 'shortcut', 'keys': ['ctrl', 'x']},
  ),
  DeckButton(
    label: '元に戻す',
    icon: Icons.undo,
    color: _kAccent,
    message: {'type': 'shortcut', 'keys': ['ctrl', 'z']},
  ),
  DeckButton(
    label: '全選択',
    icon: Icons.select_all,
    color: _kAccent,
    message: {'type': 'shortcut', 'keys': ['ctrl', 'a']},
  ),
  DeckButton(
    label: 'スクショ',
    icon: Icons.fullscreen,
    color: _kMagenta,
    // PCの全画面を撮ってスマホに転送（スマホ側でプレビュー表示）
    message: {'type': 'screenshot'},
  ),
  DeckButton(
    label: 'デスクトップ',
    icon: Icons.desktop_windows,
    color: _kMagenta,
    message: {'type': 'shortcut', 'keys': ['win', 'd']},
  ),
  DeckButton(
    label: 'タスク切替',
    icon: Icons.swap_horiz,
    color: _kMagenta,
    message: {'type': 'shortcut', 'keys': ['alt', 'tab']},
  ),
  DeckButton(
    label: 'メモ帳',
    icon: Icons.note,
    color: Colors.amberAccent,
    message: {'type': 'launch', 'target': 'notepad.exe'},
  ),
  DeckButton(
    label: '電卓',
    icon: Icons.calculate,
    color: Colors.amberAccent,
    message: {'type': 'launch', 'target': 'calc.exe'},
  ),
  DeckButton(
    label: 'ブラウザ',
    icon: Icons.public,
    color: Colors.amberAccent,
    message: {'type': 'launch', 'target': 'https://www.google.com'},
  ),
  DeckButton(
    label: 'ロック',
    icon: Icons.lock,
    color: Colors.redAccent,
    message: {'type': 'launch', 'target': 'rundll32.exe user32.dll,LockWorkStation'},
  ),
];

/// Claude Codeページのデフォルトコマンドデッキ。
/// テキスト/スラッシュコマンド系はEnter送信までを1タップで済ませるため、
/// PC側の`macro`（steps順次実行）で「入力→Enter」をまとめて送る。
const List<DeckButton> defaultClaudeDeck = [
  DeckButton(
    label: 'Enter',
    icon: Icons.keyboard_return,
    color: _kAccent,
    message: {'type': 'shortcut', 'keys': ['enter']},
  ),
  DeckButton(
    label: 'Esc',
    icon: Icons.cancel_outlined,
    color: _kMagenta,
    message: {'type': 'shortcut', 'keys': ['esc']},
  ),
  DeckButton(
    label: 'Ctrl+C',
    icon: Icons.stop_circle_outlined,
    color: _kMagenta,
    message: {'type': 'shortcut', 'keys': ['ctrl', 'c']},
  ),
  DeckButton(
    label: '1 Yes',
    icon: Icons.check,
    color: _kAccent,
    message: {
      'type': 'macro',
      'steps': [
        {'type': 'text', 'text': '1'},
        {'type': 'shortcut', 'keys': ['enter']},
      ],
    },
  ),
  DeckButton(
    label: '2 常に許可',
    icon: Icons.done_all,
    color: _kAccent,
    message: {
      'type': 'macro',
      'steps': [
        {'type': 'text', 'text': '2'},
        {'type': 'shortcut', 'keys': ['enter']},
      ],
    },
  ),
  DeckButton(
    label: '3 No',
    icon: Icons.close,
    color: _kMagenta,
    message: {
      'type': 'macro',
      'steps': [
        {'type': 'text', 'text': '3'},
        {'type': 'shortcut', 'keys': ['enter']},
      ],
    },
  ),
  DeckButton(
    label: '/clear',
    icon: Icons.layers_clear,
    color: Colors.amberAccent,
    message: {
      'type': 'macro',
      'steps': [
        {'type': 'text', 'text': '/clear'},
        {'type': 'shortcut', 'keys': ['enter']},
      ],
    },
  ),
  DeckButton(
    label: '/compact',
    icon: Icons.compress,
    color: Colors.amberAccent,
    message: {
      'type': 'macro',
      'steps': [
        {'type': 'text', 'text': '/compact'},
        {'type': 'shortcut', 'keys': ['enter']},
      ],
    },
  ),
  DeckButton(
    label: '/resume',
    icon: Icons.history,
    color: Colors.amberAccent,
    message: {
      'type': 'macro',
      'steps': [
        {'type': 'text', 'text': '/resume'},
        {'type': 'shortcut', 'keys': ['enter']},
      ],
    },
  ),
];

/// ランチャーパネル本体。上半分はトラックパッド、下は3列×2段のマクロボタン。
/// ボタンは縦スクロールで次の6個がぬるっと出てくる。
class LauncherPanel extends StatelessWidget {
  const LauncherPanel({
    super.key,
    required this.buttons,
    required this.onSend,
    required this.onMove,
    required this.onScroll,
  });

  final List<DeckButton> buttons;
  final void Function(Map<String, dynamic> message) onSend;
  final void Function(double dx, double dy) onMove;
  final void Function(double dy) onScroll;

  /// 電源系（sleep/shutdown/restart）だけは誤タップが致命的なので確認を挟む。
  Future<void> _handleTap(BuildContext context, DeckButton b) async {
    if (b.message['type'] != 'power') {
      onSend(b.message);
      return;
    }
    const names = {'sleep': 'スリープ', 'shutdown': 'シャットダウン', 'restart': '再起動'};
    final name = names[b.message['action']] ?? b.message['action'];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('PCを$nameしますか？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('$nameする',
                  style: const TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok == true) onSend(b.message);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 上半分：トラックパッド + スクロール帯
        Expanded(
          child: TrackpadArea(
            onMove: onMove,
            onScroll: onScroll,
            onClick: (button, action) => onSend(
                {'type': 'click', 'button': button, 'action': action}),
            child: const Center(
              child: Icon(Icons.touch_app, color: Colors.white12, size: 32),
            ),
          ),
        ),
        // 下：マクロボタン。6個（3列×2段）だけ見せて、スクロールで続きが現れる
        LayoutBuilder(builder: (context, constraints) {
          const cols = 3;
          const spacing = 12.0;
          const pad = 12.0;
          final tile =
              (constraints.maxWidth - pad * 2 - spacing * (cols - 1)) / cols;
          final height = tile * 2 + spacing + pad * 2;
          return SizedBox(
            height: height,
            child: GridView.builder(
              padding: const EdgeInsets.all(pad),
              physics: const BouncingScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: spacing,
                crossAxisSpacing: spacing,
                childAspectRatio: 1,
              ),
              itemCount: buttons.length,
              itemBuilder: (context, i) {
                final b = buttons[i];
                return _DeckTile(button: b, onTap: () => _handleTap(context, b));
              },
            ),
          );
        }),
      ],
    );
  }
}

class _DeckTile extends StatefulWidget {
  const _DeckTile({required this.button, required this.onTap});

  final DeckButton button;
  final VoidCallback onTap;

  @override
  State<_DeckTile> createState() => _DeckTileState();
}

class _DeckTileState extends State<_DeckTile> {
  bool _pressed = false;
  Timer? _repeat;

  /// 音量±だけは長押しで連射できるようにする（押しっぱなしで調節）
  bool get _repeatable {
    final m = widget.button.message;
    if (m['type'] != 'shortcut') return false;
    final keys = (m['keys'] as List?) ?? const [];
    return keys.length == 1 && (keys.first == 'volup' || keys.first == 'voldown');
  }

  void _startRepeat() {
    widget.onTap();
    _repeat = Timer.periodic(
        const Duration(milliseconds: 120), (_) => widget.onTap());
  }

  void _stopRepeat() {
    _repeat?.cancel();
    _repeat = null;
    if (mounted) setState(() => _pressed = false);
  }

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.button;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      onLongPressStart: _repeatable ? (_) => _startRepeat() : null,
      onLongPressEnd: _repeatable ? (_) => _stopRepeat() : null,
      onLongPressCancel: _repeatable ? _stopRepeat : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        decoration: BoxDecoration(
          color: _pressed
              ? b.color.withValues(alpha: 0.25)
              : const Color(0xFF0A1020),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: b.color.withValues(alpha: _pressed ? 1 : 0.4),
            width: 2,
          ),
          boxShadow: _pressed
              ? [BoxShadow(color: b.color.withValues(alpha: 0.4), blurRadius: 12)]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(b.icon, color: b.color, size: 32),
            const SizedBox(height: 8),
            Text(
              b.label,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
