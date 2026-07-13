import 'package:flutter/material.dart';

const _kBg = Color(0xFF050810);
const _kAccent = Color(0xFF00F5FF);
const _kRed = Color(0xFFFF0033);

/// YouTube操作パネル。Brave等のブラウザでYouTubeを見ているとき、
/// プレイヤーにフォーカスがある状態でキーボードショートカットを送る。
class YoutubePanel extends StatelessWidget {
  const YoutubePanel({super.key, required this.onSend});

  final void Function(Map<String, dynamic> message) onSend;

  void _key(String k) => onSend({'type': 'shortcut', 'keys': [k]});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.smart_display, color: _kRed, size: 28),
              const SizedBox(width: 8),
              const Text('YouTube コントローラー',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 4),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('※ 先に動画を一度タップしてプレイヤーを選択してください',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
          ),
          const SizedBox(height: 20),
          // 再生コントロール：巻き戻し / 再生一時停止 / 早送り
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _round(Icons.replay_10, '10秒戻る', () => _key('j')),
              _big(Icons.play_arrow, '再生 / 一時停止', () => _key('k')),
              _round(Icons.forward_10, '10秒送る', () => _key('l')),
            ],
          ),
          const SizedBox(height: 24),
          // 音量
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _round(Icons.volume_down, '音量 −', () => _key('down')),
              _round(Icons.volume_off, 'ミュート', () => _key('m')),
              _round(Icons.volume_up, '音量 ＋', () => _key('up')),
            ],
          ),
          const SizedBox(height: 24),
          // 全画面
          Row(
            children: [
              Expanded(child: _wide(Icons.fullscreen, '全画面', () => _key('f'))),
              const SizedBox(width: 12),
              Expanded(
                  child: _wide(Icons.fullscreen_exit, '閉じる', () => _key('esc'))),
            ],
          ),
        ],
      ),
    );
  }

  // 中サイズ丸ボタン
  Widget _round(IconData icon, String label, VoidCallback onTap) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CircleBtn(icon: icon, size: 64, color: _kAccent, onTap: onTap),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
      ],
    );
  }

  // 中央の大きな再生ボタン
  Widget _big(IconData icon, String label, VoidCallback onTap) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CircleBtn(icon: icon, size: 96, color: _kRed, onTap: onTap),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }

  // 横長ボタン（全画面用）
  Widget _wide(IconData icon, String label, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: _kAccent,
        side: BorderSide(color: _kAccent.withValues(alpha: 0.4)),
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

class _CircleBtn extends StatefulWidget {
  const _CircleBtn({
    required this.icon,
    required this.size,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final double size;
  final Color color;
  final VoidCallback onTap;

  @override
  State<_CircleBtn> createState() => _CircleBtnState();
}

class _CircleBtnState extends State<_CircleBtn> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _pressed ? widget.color.withValues(alpha: 0.3) : _kBg,
          border: Border.all(
              color: widget.color.withValues(alpha: _pressed ? 1 : 0.5),
              width: 2),
          boxShadow: _pressed
              ? [BoxShadow(color: widget.color.withValues(alpha: 0.5), blurRadius: 14)]
              : null,
        ),
        child: Icon(widget.icon, color: widget.color, size: widget.size * 0.5),
      ),
    );
  }
}
