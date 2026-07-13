import 'package:flutter/material.dart';

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

/// ランチャーパネル本体。ボタンをグリッド表示し、タップでonSendにメッセージを渡す。
class LauncherPanel extends StatelessWidget {
  const LauncherPanel({
    super.key,
    required this.buttons,
    required this.onSend,
  });

  final List<DeckButton> buttons;
  final void Function(Map<String, dynamic> message) onSend;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1,
      ),
      itemCount: buttons.length,
      itemBuilder: (context, i) {
        final b = buttons[i];
        return _DeckTile(button: b, onTap: () => onSend(b.message));
      },
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

  @override
  Widget build(BuildContext context) {
    final b = widget.button;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
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
