import 'package:flutter/material.dart';

/// トラックパッド面（メイン画面とYouTube画面で共用）。
/// なぞる=カーソル移動 / タップ=左クリック / ダブルタップ=ダブルクリック /
/// 長押し=右クリック / タップ直後になぞる=掴んで移動（ドラッグ）。
class Trackpad extends StatefulWidget {
  const Trackpad({
    super.key,
    required this.onMove,
    required this.onClick,
    required this.borderColor,
    this.margin = const EdgeInsets.all(8),
    this.child,
  });

  /// 移動量（生のピクセルdelta。感度は呼び出し側で掛ける）
  final void Function(double dx, double dy) onMove;

  /// クリック送信（button: left/right, action: tap/double/down/up）
  final void Function(String button, String action) onClick;

  final Color borderColor;
  final EdgeInsets margin;
  final Widget? child;

  @override
  State<Trackpad> createState() => _TrackpadState();
}

class _TrackpadState extends State<Trackpad> {
  // タップ→350ms以内に再タッチしてなぞるとドラッグ開始（掴んで移動）
  static const _dragWindow = Duration(milliseconds: 350);
  static const _tapMaxDuration = Duration(milliseconds: 250);
  static const _tapMaxDistance = 20.0;

  DateTime? _lastTapUp; // 直前のタップが指を離した時刻
  Offset? _downPos;
  DateTime? _downTime;
  bool _dragArmed = false; // 今回のタッチがドラッグ候補か（タップ直後の再タッチ）
  bool _dragging = false;

  void _endDrag() {
    if (!_dragging) return;
    _dragging = false;
    widget.onClick('left', 'up');
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    // ドラッグ中に画面切替等で破棄されたら、PC側のボタンを離しておく
    if (_dragging) widget.onClick('left', 'up');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // タップ判定はジェスチャー競合の影響を受けないよう生ポインタで行う
      onPointerDown: (e) {
        _downPos = e.position;
        _downTime = DateTime.now();
        _dragArmed = _lastTapUp != null &&
            DateTime.now().difference(_lastTapUp!) < _dragWindow;
      },
      onPointerUp: (e) {
        final downTime = _downTime;
        final downPos = _downPos;
        if (downTime != null &&
            downPos != null &&
            DateTime.now().difference(downTime) < _tapMaxDuration &&
            (e.position - downPos).distance < _tapMaxDistance) {
          _lastTapUp = DateTime.now();
        } else {
          _lastTapUp = null;
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) {
          if (_dragArmed && !_dragging) {
            _dragging = true;
            widget.onClick('left', 'down');
            setState(() {});
          }
        },
        onPanUpdate: (d) => widget.onMove(d.delta.dx, d.delta.dy),
        onPanEnd: (_) => _endDrag(),
        onPanCancel: _endDrag,
        onTap: () => widget.onClick('left', 'tap'),
        onDoubleTap: () => widget.onClick('left', 'double'),
        onLongPress: () => widget.onClick('right', 'tap'),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: widget.margin,
          decoration: BoxDecoration(
            border: Border.all(
                color: widget.borderColor
                    .withValues(alpha: _dragging ? 0.9 : 0.3)),
            borderRadius: BorderRadius.circular(12),
            boxShadow: _dragging
                ? [
                    BoxShadow(
                        color: widget.borderColor.withValues(alpha: 0.25),
                        blurRadius: 12),
                  ]
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
