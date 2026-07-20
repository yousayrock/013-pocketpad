import 'package:flutter/material.dart';

import 'launcher.dart';
import 'trackpad.dart';

const _kAccent = Color(0xFF00F5FF);
const _kMagenta = Color(0xFFFF006E);

/// PC側のClaude Codeフック(Stop/Notification)から届いた1件の通知。
class ClaudeNotification {
  ClaudeNotification({required this.event, required this.message})
      : time = DateTime.now();

  final String event; // "stop" | "notification"
  final String message;
  final DateTime time;

  bool get isNotification => event == 'notification';
}

/// Claude Codeコントローラーページ。
/// 上：直近の通知カード＋トラックパッド。下：コマンドボタン。
/// コマンドの追加・編集は設定画面（⚙️）から行う（マクロページと同じ導線）。
class ClaudeControlPanel extends StatelessWidget {
  const ClaudeControlPanel({
    super.key,
    required this.latest,
    required this.onSend,
    required this.notifyEnabled,
    required this.onToggleNotify,
    required this.deck,
    required this.onMove,
    required this.onScroll,
  });

  final ClaudeNotification? latest;
  final void Function(Map<String, dynamic> message) onSend;
  final bool notifyEnabled;
  final void Function(bool enabled) onToggleNotify;
  final List<DeckButton> deck;
  final void Function(double dx, double dy) onMove;
  final void Function(double dy) onScroll;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Row(
            children: [
              Expanded(child: _LatestCard(latest: latest)),
              const SizedBox(width: 8),
              Column(
                children: [
                  Switch(
                    value: notifyEnabled,
                    activeThumbColor: _kAccent,
                    onChanged: onToggleNotify,
                  ),
                  const Text('通知',
                      style: TextStyle(color: Colors.white38, fontSize: 10)),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: TrackpadArea(
            onMove: onMove,
            onScroll: onScroll,
            onClick: (button, action) =>
                onSend({'type': 'click', 'button': button, 'action': action}),
            child: const Center(
              child: Icon(Icons.touch_app, color: Colors.white12, size: 32),
            ),
          ),
        ),
        _ClaudeDeckGrid(deck: deck, onTap: onSend),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _LatestCard extends StatelessWidget {
  const _LatestCard({required this.latest});

  final ClaudeNotification? latest;

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final color = latest == null
        ? Colors.white24
        : (latest!.isNotification ? _kMagenta : _kAccent);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0A1020),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 2),
      ),
      child: Row(
        children: [
          Icon(
            latest == null
                ? Icons.smart_toy
                : (latest!.isNotification
                    ? Icons.notifications_active
                    : Icons.check_circle_outline),
            color: color,
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 長文でも縦に潰れないよう1行固定＋横スクロールで見せる
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    latest == null ? '待機中' : latest!.message,
                    maxLines: 1,
                    softWrap: false,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
                if (latest != null)
                  Text(_fmtTime(latest!.time),
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// ユーザーが編集可能なコマンドボタン一覧（マクロページと同じDeckButtonモデル）。
/// launcher.dartのLauncherPanelと同じ考え方: 正方形タイルを3列×2段だけ見せて、
/// はみ出た分は縦スクロールで続きが現れる（マクロページと統一感を持たせる）。
class _ClaudeDeckGrid extends StatelessWidget {
  const _ClaudeDeckGrid({required this.deck, required this.onTap});

  final List<DeckButton> deck;
  final void Function(Map<String, dynamic> message) onTap;

  @override
  Widget build(BuildContext context) {
    if (deck.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('コマンドがありません。設定 → Claude Codeコマンドを編集 から追加できます',
            style: TextStyle(color: Colors.white24, fontSize: 12)),
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
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
          itemCount: deck.length,
          itemBuilder: (context, i) {
            final b = deck[i];
            return _ClaudeDeckTile(button: b, onTap: () => onTap(b.message));
          },
        ),
      );
    });
  }
}

class _ClaudeDeckTile extends StatefulWidget {
  const _ClaudeDeckTile({required this.button, required this.onTap});

  final DeckButton button;
  final VoidCallback onTap;

  @override
  State<_ClaudeDeckTile> createState() => _ClaudeDeckTileState();
}

class _ClaudeDeckTileState extends State<_ClaudeDeckTile> {
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
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: b.color.withValues(alpha: _pressed ? 1 : 0.4),
            width: 1.5,
          ),
          boxShadow: _pressed
              ? [BoxShadow(color: b.color.withValues(alpha: 0.4), blurRadius: 10)]
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
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
