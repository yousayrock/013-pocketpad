import 'dart:async';

import 'package:flutter/material.dart';

import 'trackpad.dart';

const _kBg = Color(0xFF050810);
const _kAccent = Color(0xFF00F5FF);
const _kRed = Color(0xFFFF0033);

/// YouTube操作パネル。Brave等のブラウザでYouTubeを見ているとき、
/// プレイヤーにフォーカスがある状態でキーボードショートカットを送る。
/// 上半分はトラックパッド（動画のタップ・シーク操作用）。
class YoutubePanel extends StatelessWidget {
  const YoutubePanel({
    super.key,
    required this.onSend,
    required this.onMove,
    required this.onScroll,
  });

  final void Function(Map<String, dynamic> message) onSend;
  final void Function(double dx, double dy) onMove;
  final void Function(double dy) onScroll;

  void _key(String k) => onSend({'type': 'shortcut', 'keys': [k]});

  void _click(String button, String action) =>
      onSend({'type': 'click', 'button': button, 'action': action});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 上半分：トラックパッド + スクロール帯（メイン画面と同じ操作系）
        Expanded(
          child: TrackpadArea(
            onMove: onMove,
            onScroll: onScroll,
            onClick: _click,
            child: const Center(
              child: Icon(Icons.touch_app, color: Colors.white12, size: 32),
            ),
          ),
        ),
        // 下半分：再生コントロール
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 巻き戻し / 再生一時停止 / 早送り（10秒キーは押しっぱなしで連射）
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _round(Icons.replay_10, '10秒戻る', () => _key('j'),
                      repeat: true),
                  _big(Icons.play_arrow, '再生 / 一時停止', () => _key('k')),
                  _round(Icons.forward_10, '10秒送る', () => _key('l'),
                      repeat: true),
                ],
              ),
              const SizedBox(height: 20),
              // 音量（±は押しっぱなしで連射）
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _round(Icons.volume_down, '音量 −', () => _key('down'),
                      repeat: true),
                  _round(Icons.volume_off, 'ミュート', () => _key('m')),
                  _round(Icons.volume_up, '音量 ＋', () => _key('up'),
                      repeat: true),
                ],
              ),
              const SizedBox(height: 20),
              // ブラウザバック / 全画面トグル（fキーは全画面⇄解除の切替）
              Row(
                children: [
                  Expanded(
                      child: _wide(Icons.arrow_back, '前の画面に戻る',
                          () => onSend({'type': 'shortcut', 'keys': ['alt', 'left']}))),
                  const SizedBox(width: 12),
                  Expanded(
                      child: _wide(Icons.fullscreen, '全画面 切替', () => _key('f'))),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // 中サイズ丸ボタン
  Widget _round(IconData icon, String label, VoidCallback onTap,
      {bool repeat = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CircleBtn(
            icon: icon, size: 60, color: _kAccent, onTap: onTap, repeat: repeat),
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
        _CircleBtn(icon: icon, size: 84, color: _kRed, onTap: onTap),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }

  // 横長ボタン（戻る・全画面用）
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

/// 丸ボタン。repeat=true なら押しっぱなしで連射
/// （即発火 → 350ms後から120ms間隔）。発火はすべて押した瞬間に行い、
/// タップ判定のスロップに影響されないよう Listener で生ポインタを拾う。
class _CircleBtn extends StatefulWidget {
  const _CircleBtn({
    required this.icon,
    required this.size,
    required this.color,
    required this.onTap,
    this.repeat = false,
  });

  final IconData icon;
  final double size;
  final Color color;
  final VoidCallback onTap;
  final bool repeat;

  @override
  State<_CircleBtn> createState() => _CircleBtnState();
}

class _CircleBtnState extends State<_CircleBtn> {
  bool _pressed = false;
  Timer? _delay;
  Timer? _repeat;

  void _down() {
    setState(() => _pressed = true);
    widget.onTap();
    if (widget.repeat) {
      _delay = Timer(const Duration(milliseconds: 350), () {
        _repeat = Timer.periodic(
            const Duration(milliseconds: 120), (_) => widget.onTap());
      });
    }
  }

  void _up() {
    _delay?.cancel();
    _repeat?.cancel();
    if (mounted) setState(() => _pressed = false);
  }

  @override
  void dispose() {
    _delay?.cancel();
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _down(),
      onPointerUp: (_) => _up(),
      onPointerCancel: (_) => _up(),
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
