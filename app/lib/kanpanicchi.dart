import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'trackpad.dart';

/// スマホ→PCへ送るファイル1件あたりの上限（base64後）。PC側WsServer.csの
/// 12MB上限と合わせている。大きすぎるファイルはWebSocketのテキストフレームを
/// 圧迫するため、ここで先に弾いてユーザーに伝える。
const _maxFileTransferBytes = 8 * 1024 * 1024;

const _kAccent = Color(0xFF00F5FF);
const _kMagenta = Color(0xFFFF006E);

/// 表示名のデフォルト。名前変更ダイアログの4文字制限に収まる長さにしてある
/// （ユーザーが好きな名前に変えられるので、これはあくまで初期値）。
const kCharacterName = 'かんぱに';

/// PC側のPreToolUseフックから届いた1件のツール活動（`claude_activity`）。
class ClaudeActivity {
  ClaudeActivity({required this.tool, required this.detail})
    : time = DateTime.now();

  final String tool;
  final String detail;
  final DateTime time;
}

/// PC側のStop/Notificationフックから届いた通知（`claude_notify`）。
/// アバターの状態にも反映するため、通知アラートの発火とは別にAI社員ページへも渡す。
class ClaudeNotifyEvent {
  ClaudeNotifyEvent({required this.event, required this.message})
    : time = DateTime.now();

  final String event; // "stop" | "notification"
  final String message;
  final DateTime time;
}

/// PC側のTodoWriteフックから届いたTODO1件（`claude_todos`）。
class TodoItem {
  const TodoItem({
    required this.content,
    required this.status,
    required this.activeForm,
  });

  factory TodoItem.fromJson(Map<String, dynamic> j) => TodoItem(
    content: (j['content'] as String?) ?? '',
    status: (j['status'] as String?) ?? 'pending',
    activeForm: (j['activeForm'] as String?) ?? '',
  );

  final String content;
  final String status; // "pending" | "in_progress" | "completed"
  final String activeForm;
}

/// PC側でClaude Haikuが生成した実況コメント（`claude_activity_comment`）。
/// ツール呼び出しの直後、少し遅れて届く「おまけ」の一言。
class ActivityComment {
  ActivityComment({required this.text}) : time = DateTime.now();

  final String text;
  final DateTime time;
}

/// オフィス内の「持ち場」。キャラクターがこの位置(Alignment)へ移動する。
class _Zone {
  const _Zone(this.align, this.propIcon, this.verb, this.roomName, this.color);
  final Alignment align;
  final IconData propIcon;
  final String verb;
  final String roomName;

  /// 部屋ごとの持ち色。ステータス表示・キャラの発光色・部屋カードに共通で使う。
  final Color color;
}

const _zoneIdle = _Zone(
  Alignment.center,
  Icons.chair_alt,
  '待機中',
  '休憩スペース',
  Colors.white38,
);
const _zoneEditing = _Zone(
  Alignment(-0.7, -0.6),
  Icons.desktop_windows,
  '編集中',
  '開発デスク',
  Color(0xFF29B6F6),
);
const _zoneCommand = _Zone(
  Alignment(0.7, -0.6),
  Icons.terminal,
  'コマンド実行中',
  'サーバー室',
  Color(0xFFB388FF),
);
const _zoneSearching = _Zone(
  Alignment(-0.7, 0.6),
  Icons.menu_book,
  '調査中',
  '資料室',
  Color(0xFFFFC24B),
);
const _zoneDelegating = _Zone(
  Alignment(0.7, 0.6),
  Icons.groups,
  '委任中',
  '会議室',
  _kMagenta,
);

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
const _zoneWorking = _Zone(
  Alignment.center,
  Icons.smart_toy,
  '作業中',
  '休憩スペース',
  _kAccent,
);

_Zone _zoneFor(String tool) => _zones[tool] ?? _zoneWorking;

// ─────────────────────────────────────── 育成（レベル/経験値）
// 「タスクをこなすと経験値が増える」の経験値量。ツール呼び出し1回ごとに少量、
// ターン完了（stop）でまとまった量を加算する。承認待ち（notification）は
// まだ完了していない作業なので加算しない。
int _xpForTool(String tool) {
  switch (tool) {
    case 'Edit':
    case 'Write':
    case 'NotebookEdit':
    case 'Bash':
      return 2;
    case 'Task':
      return 3;
    case 'Read':
    case 'Grep':
    case 'Glob':
    case 'WebSearch':
    case 'WebFetch':
      return 1;
    default:
      return 1;
  }
}

const _xpPerStop = 20;

/// TODOを1件「完了」にするごとのXP。TodoWriteの進捗にも育成が連動する。
const _xpPerTodo = 5;

/// 1ターン中にツールを何回使ったか（=仕事の大変さの目安）に応じたボーナスXP。
/// 難しい仕事＝ツール呼び出しが多いターンほど、完了時にまとまった追加報酬を出す。
int _stopBonus(int toolCallsThisTurn) {
  if (toolCallsThisTurn >= 15) return 25;
  if (toolCallsThisTurn >= 8) return 10;
  return 0;
}

/// レベルNからN+1に上がるのに必要な経験値。
int _xpToNext(int level) => 80 + (level - 1) * 20;

/// レベル帯ごとの役職（「AI社員」が出世していく体で）。
String _rankFor(int level) {
  if (level >= 20) return '社長';
  if (level >= 15) return '部長';
  if (level >= 10) return '課長';
  if (level >= 5) return '主任';
  return '新人';
}

/// tool_name/detailから「今これをしています」がわかる、誰にでもわかる簡単な一文を作る。
/// ファイル名やコマンドの生の文字列はあえて出さず、小学生でも意味がわかる
/// 言葉だけで表現する（Bashだけはコマンドの中身を見て、もう少し具体的にする）。
String _activitySentence(String tool, String detail) {
  switch (tool) {
    case 'Edit':
    case 'Write':
    case 'NotebookEdit':
      return 'プログラムを書き直しています';
    case 'Bash':
      return _bashSentence(detail);
    case 'Read':
      return '中身を確認しています';
    case 'Grep':
    case 'Glob':
      return '必要な場所をさがしています';
    case 'WebSearch':
      return 'インターネットで調べています';
    case 'WebFetch':
      return 'インターネットのページを見ています';
    case 'Task':
      return '別の作業をお願いしています';
    default:
      return 'お仕事をしています';
  }
}

/// Bashコマンドの先頭語から、パソコンに何を指示しているのかを平易な言葉にする。
String _bashSentence(String command) {
  final tokens = command.trimLeft().split(RegExp(r'\s+'));
  final head = tokens.isEmpty ? '' : tokens.first;
  final second = tokens.length > 1 ? tokens[1] : '';
  switch (head) {
    case 'git':
      return 'これまでの作業を記録しています';
    case 'npm':
    case 'pnpm':
    case 'yarn':
      return '必要な部品をダウンロードしています';
    case 'flutter':
      if (second == 'pub') return '必要な部品をダウンロードしています';
      if (second == 'build' || second == 'run') return 'アプリを組み立てています';
      return 'アプリの動作を確認しています';
    case 'dotnet':
      if (second == 'build' || second == 'publish') return 'プログラムを組み立てています';
      return 'プログラムを動かしています';
    case 'adb':
      return 'スマホと通信しています';
    case 'curl':
    case 'wget':
      return 'インターネットと通信しています';
    case 'mkdir':
      return '新しいフォルダを作っています';
    case 'rm':
    case 'del':
      return '不要なファイルを片付けています';
    case 'ls':
    case 'dir':
    case 'find':
      return 'ファイルの一覧を見ています';
    case 'echo':
      return '画面にメッセージを表示しています';
    default:
      return 'パソコンに指示を出しています';
  }
}

/// 部屋の詳細シート（ユーザーが自分で開いた画面）用に、対象の種類を表す
/// ラベルを返す。メインのステータス表示は小学生向けにあえて簡略化しているが、
/// ここは能動的に詳しく見たい人向けなので、具体的な対象（ファイル名/コマンド等）
/// も一緒に見せる。
String? _activityDetailLabel(String tool) {
  switch (tool) {
    case 'Edit':
    case 'Write':
    case 'NotebookEdit':
    case 'Read':
      return '対象ファイル';
    case 'Bash':
      return '実行したコマンド';
    case 'Grep':
    case 'Glob':
      return '検索キーワード';
    case 'WebSearch':
      return '調べた内容';
    case 'WebFetch':
      return '見たページ';
    case 'Task':
      return 'お願いした内容';
    default:
      return null;
  }
}

class _Status {
  const _Status({required this.icon, required this.color, required this.label});
  final IconData icon;
  final Color color;
  final String label;
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
// たまごっち風に瞬きさせるための「目を閉じた」立ち姿フレーム。
const _spriteStandBlink = [
  '...2...',
  '.11111.',
  '1111111',
  '1111111',
  '1111111',
  '.11111.',
  '..1.1..',
  '..1.1..',
];

const _spritePalette = <String, Color>{
  '1': _kAccent,
  '2': _kMagenta,
  '0': Colors.black,
  '3': Color(0xFF1A2340), // ネクタイ（Lv5〜）
  '4': Color(0xFFFFC72C), // バッジ・王冠（Lv10〜/Lv20〜）
};

/// レベル帯に応じて見た目に「出世」の装飾を足していく（既存のスプライト定数
/// 自体は変更せず、行を書き換え/追加するだけの加算方式）。
List<String> _withTie(List<String> rows) {
  if (rows.length <= 5) return rows;
  final r = List<String>.from(rows);
  r[5] = r[5].replaceRange(3, 4, '3');
  return r;
}

List<String> _withBadge(List<String> rows) {
  if (rows.length <= 4) return rows;
  final r = List<String>.from(rows);
  r[4] = r[4].replaceRange(5, 6, '4');
  return r;
}

List<String> _withCrown(List<String> rows) => ['..444..', ...rows];

List<String> _tieredSprite(int level, List<String> base) {
  var rows = base;
  if (level >= 5) rows = _withTie(rows);
  if (level >= 10) rows = _withBadge(rows);
  if (level >= 20) rows = _withCrown(rows);
  return rows;
}

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

/// たまごっちの筐体っぽい「床」の質感を出すドット格子。
class _FloorPainter extends CustomPainter {
  const _FloorPainter();
  static const _step = 14.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.05);
    for (var y = _step / 2; y < size.height; y += _step) {
      for (var x = _step / 2; x < size.width; x += _step) {
        canvas.drawCircle(Offset(x, y), 1.1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FloorPainter oldDelegate) => false;
}

/// レベルアップ時に一瞬だけ出る祝福バナー。main.dartの_ClaudeFlashと同じ
/// 自己完結OverlayEntry方式（アニメーション終了で自動的に自分を消す）。
class _LevelUpBanner extends StatefulWidget {
  const _LevelUpBanner({
    required this.name,
    required this.level,
    required this.rank,
    required this.onDone,
  });

  final String name;
  final int level;
  final String rank;
  final VoidCallback onDone;

  @override
  State<_LevelUpBanner> createState() => _LevelUpBannerState();
}

class _LevelUpBannerState extends State<_LevelUpBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    );
    _scale = TweenSequence([
      TweenSequenceItem(
        tween: Tween(
          begin: 0.8,
          end: 1.05,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 350,
      ),
      TweenSequenceItem(tween: Tween(begin: 1.05, end: 1.0), weight: 150),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 1400),
    ]).animate(_controller);
    _opacity = TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 200),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 1300),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 400),
    ]).animate(_controller);
    _controller.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Opacity(
        opacity: _opacity.value,
        child: Transform.scale(scale: _scale.value, child: child),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 20),
        decoration: BoxDecoration(
          color: const Color(0xFF0A1020),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _kAccent, width: 2),
          boxShadow: [
            BoxShadow(
              color: _kAccent.withValues(alpha: 0.5),
              blurRadius: 30,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'LEVEL UP!',
              style: TextStyle(
                color: _kMagenta,
                fontWeight: FontWeight.w900,
                fontSize: 22,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${widget.name}  Lv.${widget.level} ${widget.rank}',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 部屋（持ち場）1つ分のカード。什器アイコン+ラベルを部屋の色でタグ付けする。
class _RoomCard extends StatelessWidget {
  const _RoomCard({required this.zone, this.onTap});
  final _Zone zone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: zone.color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: zone.color.withValues(alpha: 0.4)),
          ),
          // 画面が小さい端末だと4部屋分の縦幅が窮屈になりオーバーフローしうるため、
          // FittedBoxで使える範囲いっぱいまで縮小させる（はみ出させない）。
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(zone.propIcon, color: zone.color, size: 30),
                const SizedBox(height: 3),
                Text(
                  zone.roomName,
                  style: TextStyle(
                    color: zone.color,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// オフィス上部の育成ステータス表示。アバターチップ + レベル/役職 + 経験値バー。
class _StatsHeader extends StatelessWidget {
  const _StatsHeader({
    required this.name,
    required this.level,
    required this.xp,
    required this.xpToNext,
    required this.rank,
    required this.color,
    required this.onNameTap,
  });

  final String name;
  final int level;
  final int xp;
  final int xpToNext;
  final String rank;
  final Color color;
  final VoidCallback onNameTap;

  @override
  Widget build(BuildContext context) {
    final progress = (xp / xpToNext).clamp(0.0, 1.0);
    return Padding(
      // 右上のトラックパッド切替ボタン（Positioned top:4,right:4、タップ領域48x48）と
      // 被らないよう、右側は多めに余白を取る。
      padding: const EdgeInsets.fromLTRB(12, 10, 44, 8),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.18),
              border: Border.all(color: color.withValues(alpha: 0.5)),
            ),
            child: FittedBox(
              child: _PixelSprite(rows: _spriteStand, glow: color),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: onNameTap,
                  child: Row(
                    children: [
                      // 名前は自由入力で長くなりうるため横スクロールで見せる。
                      // Lv./役職は常に見えていてほしいのでスクロール対象の外に固定する。
                      Flexible(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Text(
                            name,
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                      Text(
                        ' Lv.$level $rank',
                        style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.edit,
                        color: color.withValues(alpha: 0.6),
                        size: 12,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 5),
                Stack(
                  children: [
                    Container(
                      height: 6,
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: progress),
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOut,
                      builder: (context, value, _) => FractionallySizedBox(
                        widthFactor: value,
                        child: Container(
                          height: 6,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$xp/$xpToNext',
            style: const TextStyle(color: Colors.white38, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

/// 下半分の「TODOリスト」。Claude Code自身のTodoWriteの進捗をそのまま見せる
/// （未着手/実行中/完了）。完了した分は_onTodosUpdatedでXPにも反映される。
class _TodoPanel extends StatelessWidget {
  const _TodoPanel({required this.todos, required this.color});
  final List<TodoItem> todos;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (todos.isEmpty) {
      return const Center(
        child: Text(
          'Claude CodeがTODOを作ると\nここに一覧が表示されます',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white24, fontSize: 12),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: todos.length,
      itemBuilder: (context, i) {
        final t = todos[i];
        final done = t.status == 'completed';
        final active = t.status == 'in_progress';
        final icon = done
            ? Icons.check_circle
            : active
            ? Icons.autorenew
            : Icons.radio_button_unchecked;
        final iconColor = done ? color : (active ? _kMagenta : Colors.white24);
        final label = active && t.activeForm.isNotEmpty
            ? t.activeForm
            : t.content;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: iconColor, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: done ? Colors.white38 : Colors.white70,
                    fontSize: 13,
                    decoration: done ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 下半分の「実況ログ」。PC側でClaude Haikuが生成した実況コメントを新しい順に
/// 時系列表示する（TODOパネルとチップタップで切り替え）。
class _CommentaryPanel extends StatelessWidget {
  const _CommentaryPanel({required this.comments, required this.color});
  final List<ActivityComment> comments;
  final Color color;

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    if (comments.isEmpty) {
      return const Center(
        child: Text(
          'Claude Codeが動き出すと\nここに実況が流れます',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white24, fontSize: 12),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: comments.length,
      itemBuilder: (context, i) {
        final c = comments[i];
        // 最新の1件だけ色付きで強調し、過去分は落ち着いた色にする。
        final isLatest = i == 0;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                isLatest ? Icons.campaign : Icons.chat_bubble_outline,
                color: isLatest ? color : Colors.white24,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  c.text,
                  style: TextStyle(
                    color: isLatest ? Colors.white : Colors.white54,
                    fontSize: 13,
                    fontWeight: isLatest ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _fmtTime(c.time),
                style: const TextStyle(color: Colors.white24, fontSize: 10),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 「かんぱにっち」ページ。Claude Codeが今何をしているかをドット絵キャラクターで見せながら、
/// タスクをこなすたびにユーザーと一緒にレベルアップしていく育成要素つきビューワー。
/// オフィス内の持ち場（編集/コマンド/調査/委任/待機）を活動に応じて移動する。
/// 上半分はデフォルトでこのオフィス表示、右上のボタンでトラックパッドに開閉できる。
class KanpanicchiPanel extends StatefulWidget {
  const KanpanicchiPanel({
    super.key,
    required this.latestActivity,
    required this.latestNotify,
    required this.todos,
    required this.latestComment,
    required this.onMove,
    required this.onScroll,
    required this.onClick,
    required this.onShortcut,
    required this.onSendFile,
  });

  final ClaudeActivity? latestActivity;
  final ClaudeNotifyEvent? latestNotify;
  final List<TodoItem> todos;
  final ActivityComment? latestComment;
  final void Function(double dx, double dy) onMove;
  final void Function(double dy) onScroll;
  final void Function(String button, String action) onClick;
  final void Function(List<String> keys) onShortcut;

  /// サーバー室からPCへファイルを送る（ファイル名, base64データ）。
  final void Function(String filename, String base64) onSendFile;

  @override
  State<KanpanicchiPanel> createState() => _KanpanicchiPanelState();
}

class _KanpanicchiPanelState extends State<KanpanicchiPanel>
    with SingleTickerProviderStateMixin {
  static const _moveDuration = Duration(milliseconds: 500);

  bool _showTrackpad = false;
  _Zone _zone = _zoneIdle;
  _Status _status = const _Status(
    icon: Icons.chair_alt,
    color: Colors.white38,
    label: '待機中',
  );
  // 部屋タップで詳細を見せるための、部屋ごとの直近の活動（生のツール/対象/時刻）。
  final Map<String, ClaudeActivity> _lastActivityByRoom = {};
  // 今のターン（次のstopまで）で何回ツールを使ったか。完了時のボーナスXP判定に使う。
  int _toolCallsSinceStop = 0;
  // 直近の活動の一言。アイドル判定（30秒操作なし）になった時、ただ「待機中」に
  // するのではなく「ビルド中でしばらく時間がかかっている」等、何を待っているか
  // 分かるようにするために使う。ターン完了(stop)でクリアする。
  String? _lastActivityLabel;
  // Haiku実況の履歴（新しい順）。TODOパネルとタップで切り替えて時系列表示する。
  final List<ActivityComment> _commentLog = [];
  // 下半分の表示切り替え。0=TODO, 1=実況ログ。
  int _bottomTab = 0;
  Timer? _idleTimer;
  Timer? _doneRevertTimer;
  Timer? _walkFrameTimer;
  Timer? _arriveTimer;
  bool _walking = false;
  bool _walkFrameA = true;
  late final AnimationController _bounce;
  Timer? _blinkTimer;
  bool _blinking = false;

  // ── 育成（レベル/経験値）。永続化キーはshared_preferencesの他設定と同じ
  // プリミティブキー方式（AppSettingsのJSON blobほど複雑な構造ではないため）。
  static const _kLevelKey = 'kanpanicchi_level';
  static const _kXpKey = 'kanpanicchi_xp';
  static const _kLifetimeKey = 'kanpanicchi_lifetime_events';
  static const _kNameKey = 'kanpanicchi_display_name';
  int _level = 1;
  int _xp = 0;
  int _lifetimeEvents = 0;
  String _displayName = kCharacterName;
  // ツール呼び出しの経験値ファーミング対策: 直近の付与時刻と、直近60秒間に
  // 経験値を付与したツール呼び出し回数を覚えておき、連打を弾く。
  // stopイベント（ターン完了）はターン単位で自然にレート制限されるため対象外。
  DateTime? _lastToolXpAt;
  final List<DateTime> _xpTimestamps = [];

  @override
  void initState() {
    super.initState();
    _bounce = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _armIdleTimer();
    _armBlink();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _level = p.getInt(_kLevelKey) ?? 1;
        _xp = p.getInt(_kXpKey) ?? 0;
        _lifetimeEvents = p.getInt(_kLifetimeKey) ?? 0;
        final savedName = p.getString(_kNameKey);
        if (savedName != null && savedName.isNotEmpty) _displayName = savedName;
      });
    });
  }

  /// 社員に好きな名前をつけられるリネームダイアログ。ステータス欄の名前タップで開く。
  Future<void> _renameCharacter() async {
    final controller = TextEditingController(text: _displayName);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0A1020),
        title: const Text('名前を変更', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 4,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: kCharacterName),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final name = result.trim().isEmpty ? kCharacterName : result.trim();
    setState(() => _displayName = name);
    SharedPreferences.getInstance().then((p) => p.setString(_kNameKey, name));
  }

  /// たまごっちらしい「生きてる感」のための瞬き。数秒おきに一瞬だけ目を閉じる。
  void _armBlink() {
    _blinkTimer = Timer(const Duration(milliseconds: 2600), () {
      if (!mounted) return;
      setState(() => _blinking = true);
      Timer(const Duration(milliseconds: 120), () {
        if (!mounted) return;
        setState(() => _blinking = false);
        _armBlink();
      });
    });
  }

  void _saveProgress() {
    SharedPreferences.getInstance().then((p) {
      p.setInt(_kLevelKey, _level);
      p.setInt(_kXpKey, _xp);
      p.setInt(_kLifetimeKey, _lifetimeEvents);
    });
  }

  /// 経験値を加算し、レベルアップを検出する。tool!=nullならツール呼び出し由来
  /// （ファーミング対策のスロットル対象）、nullならstopイベント由来（対象外）。
  void _awardXp(int amount, {String? tool}) {
    if (tool != null) {
      final now = DateTime.now();
      if (_lastToolXpAt != null &&
          now.difference(_lastToolXpAt!) < const Duration(seconds: 3)) {
        return;
      }
      _xpTimestamps.removeWhere(
        (t) => now.difference(t) > const Duration(seconds: 60),
      );
      if (_xpTimestamps.length >= 20) return;
      _lastToolXpAt = now;
      _xpTimestamps.add(now);
    }
    var xp = _xp + amount;
    var level = _level;
    var leveledUp = false;
    while (xp >= _xpToNext(level)) {
      xp -= _xpToNext(level);
      level++;
      leveledUp = true;
    }
    setState(() {
      _xp = xp;
      _level = level;
      _lifetimeEvents++;
    });
    _saveProgress();
    if (leveledUp) _showLevelUpBanner();
  }

  void _showLevelUpBanner() {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => IgnorePointer(
        child: _LevelUpBanner(
          name: _displayName,
          level: _level,
          rank: _rankFor(_level),
          onDone: () => entry.remove(),
        ),
      ),
    );
    overlay.insert(entry);
  }

  /// 部屋タップ時、その部屋での直近の活動を詳しく見せる（メインの一言は
  /// あえて簡略化しているため、気になる人向けに生のツール名/対象を出す）。
  void _showRoomDetail(_Zone zone) {
    final activity = _lastActivityByRoom[zone.roomName];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0A1020),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(zone.propIcon, color: zone.color, size: 22),
                const SizedBox(width: 8),
                Text(
                  zone.roomName,
                  style: TextStyle(
                    color: zone.color,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (activity == null)
              const Text(
                'まだこの部屋でのお仕事はありません',
                style: TextStyle(color: Colors.white38, fontSize: 13),
              )
            else ...[
              Text(
                '最後にしていたお仕事:',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                _activitySentence(activity.tool, activity.detail),
                style: TextStyle(
                  color: zone.color,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              // ここは自分から詳しく見に来た人向けの画面なので、メインのステータス
              // 表示とは違い、対象ファイル名/実行コマンド等の具体的な内容も見せる。
              if (activity.detail.isNotEmpty &&
                  _activityDetailLabel(activity.tool) != null) ...[
                const SizedBox(height: 10),
                Text(
                  '${_activityDetailLabel(activity.tool)}:',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const SizedBox(height: 4),
                Text(
                  activity.detail,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontFamily: 'monospace',
                  ),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                _fmtTime(activity.time),
                style: const TextStyle(color: Colors.white24, fontSize: 12),
              ),
            ],
            if (zone == _zoneCommand) ...[
              const SizedBox(height: 18),
              const Divider(color: Colors.white12),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: zone.color,
                    side: BorderSide(color: zone.color.withValues(alpha: 0.5)),
                  ),
                  onPressed: () {
                    Navigator.of(context).pop();
                    _pickAndSendFile();
                  },
                  icon: const Icon(Icons.upload_file),
                  label: const Text('PCにファイルを送る'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// サーバー室から呼ぶ、スマホ→PCのファイル送信。選んだファイルをbase64にして
  /// WebSocket経由でPC(PocketPadTray)へ送る。PC側は Downloads\PocketPad に保存する。
  Future<void> _pickAndSendFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) return;
    if (!mounted) return;
    if (bytes.length > _maxFileTransferBytes) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ファイルが大きすぎます（上限8MB）'),
          backgroundColor: _kMagenta,
        ),
      );
      return;
    }
    widget.onSendFile(file.name, base64Encode(bytes));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${file.name} をPCへ送信中…'),
        backgroundColor: _kAccent,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant KanpanicchiPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final activity = widget.latestActivity;
    if (activity != null && !identical(activity, oldWidget.latestActivity)) {
      _onActivity(activity);
    }
    final notify = widget.latestNotify;
    if (notify != null && !identical(notify, oldWidget.latestNotify)) {
      _onNotify(notify);
    }
    if (!identical(widget.todos, oldWidget.todos)) {
      _onTodosUpdated(oldWidget.todos, widget.todos);
    }
    final comment = widget.latestComment;
    if (comment != null && !identical(comment, oldWidget.latestComment)) {
      _onComment(comment);
    }
  }

  /// Haiku実況が届いた時の処理。ステータス表示・アイドル時の「待っている内容」を
  /// この一言に更新し、実況ログにも積む（ツール名/コマンドより柔らかい表現）。
  void _onComment(ActivityComment c) {
    _lastActivityLabel = c.text;
    setState(() {
      _status = _Status(icon: _status.icon, color: _status.color, label: c.text);
      _commentLog.insert(0, c);
      if (_commentLog.length > 30) _commentLog.removeLast();
    });
  }

  /// TODOが新たに完了（pending/in_progress → completed）になった分だけXPを渡す。
  /// contentの文字列で前後の対応を取る（TodoWriteはターン内で同じ内容を使い回すため）。
  void _onTodosUpdated(List<TodoItem> oldTodos, List<TodoItem> newTodos) {
    final wasCompleted = {
      for (final t in oldTodos)
        if (t.status == 'completed') t.content,
    };
    final newlyCompleted = newTodos
        .where(
          (t) => t.status == 'completed' && !wasCompleted.contains(t.content),
        )
        .length;
    if (newlyCompleted > 0) _awardXp(_xpPerTodo * newlyCompleted);
  }

  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: 30), () {
      if (!mounted) return;
      // 直前の活動が分かっていれば「待機中」で終わらせず、何を待っているのか
      // （例:「アプリを組み立てています」中のビルド待ち）が伝わるようにする。
      final label = _lastActivityLabel != null
          ? '${_lastActivityLabel!}（時間がかかっています…）'
          : _zoneIdle.verb;
      _moveTo(_zoneIdle, _zoneIdle.color, label);
    });
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
    final label = _activitySentence(a.tool, a.detail);
    _moveTo(zone, zone.color, label);
    _lastActivityByRoom[zone.roomName] = a;
    _lastActivityLabel = label;
    _doneRevertTimer?.cancel();
    _armIdleTimer();
    _toolCallsSinceStop++;
    _awardXp(_xpForTool(a.tool), tool: a.tool);
  }

  void _onNotify(ClaudeNotifyEvent n) {
    final isWaiting = n.event == 'notification';
    final icon = isWaiting ? Icons.notifications_active : Icons.check_circle;
    final color = isWaiting ? _kMagenta : _kAccent;
    var label = isWaiting ? '承認を待っています: ${n.message}' : '完了しました: ${n.message}';
    _doneRevertTimer?.cancel();
    if (!isWaiting) {
      // ターンが完了した＝もう「待っている」ことは無いので、次にアイドルに
      // なった時は素直に「待機中」でよい。
      _lastActivityLabel = null;
      // 完了はしばらく強調してから待機に戻す
      _doneRevertTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) _moveTo(_zoneIdle, _zoneIdle.color, _zoneIdle.verb);
      });
      final bonus = _stopBonus(_toolCallsSinceStop);
      _toolCallsSinceStop = 0;
      if (bonus > 0) label = '$label（大変な仕事お疲れさま！ボーナスXP+$bonus）';
      _awardXp(_xpPerStop + bonus);
    }
    setState(() => _status = _Status(icon: icon, color: color, label: label));
    _armIdleTimer();
  }

  @override
  void dispose() {
    _bounce.dispose();
    _idleTimer?.cancel();
    _doneRevertTimer?.cancel();
    _walkFrameTimer?.cancel();
    _arriveTimer?.cancel();
    _blinkTimer?.cancel();
    super.dispose();
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  Widget _bottomTabChip(String label, int index) {
    final active = _bottomTab == index;
    final color = _status.color;
    return GestureDetector(
      onTap: () => setState(() => _bottomTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: active ? color.withValues(alpha: 0.6) : Colors.white24),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? color : Colors.white38,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

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
                          child: Icon(
                            Icons.touch_app,
                            color: Colors.white12,
                            size: 32,
                          ),
                        ),
                      )
                    // 一部端末(MediaTek系GPU)で、複数アニメーション併用時に古い
                    // フレームが合成されずそのまま残る描画崩れが再現したため、
                    // このパネルを独立したレイヤーとして常にフル再合成させる。
                    : RepaintBoundary(
                        child: Container(
                          margin: const EdgeInsets.all(8),
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                _zone.color.withValues(alpha: 0.4),
                                Colors.white12,
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF070B16),
                              borderRadius: BorderRadius.circular(19),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: Column(
                              children: [
                                _StatsHeader(
                                  name: _displayName,
                                  level: _level,
                                  xp: _xp,
                                  xpToNext: _xpToNext(_level),
                                  rank: _rankFor(_level),
                                  color: _status.color,
                                  onNameTap: _renameCharacter,
                                ),
                                Expanded(
                                  child: Stack(
                                    children: [
                                      // たまごっちの筐体っぽい床の質感
                                      const Center(
                                        child: SizedBox.expand(
                                          child: CustomPaint(
                                            painter: _FloorPainter(),
                                          ),
                                        ),
                                      ),
                                      // 各持ち場の部屋カード
                                      for (final z in {
                                        _zoneEditing,
                                        _zoneCommand,
                                        _zoneSearching,
                                        _zoneDelegating,
                                      })
                                        Align(
                                          alignment: z.align,
                                          child: _RoomCard(
                                            zone: z,
                                            onTap: () => _showRoomDetail(z),
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
                                            final bounceY = _walking
                                                ? 0.0
                                                : -_bounce.value * 3;
                                            // 部屋カードの真上に重ならないよう、部屋の中心から
                                            // 画面の外側（コーナー側）へずらして隣に立たせる。
                                            final dx =
                                                46.0 *
                                                (_zone.align.x >= 0 ? 1 : -1);
                                            final dy =
                                                30.0 *
                                                (_zone.align.y >= 0 ? 1 : -1);
                                            return Transform.translate(
                                              offset: Offset(dx, dy + bounceY),
                                              child: child,
                                            );
                                          },
                                          child: _PixelSprite(
                                            rows: _tieredSprite(
                                              _level,
                                              _walking && !_walkFrameA
                                                  ? _spriteWalk
                                                  : (_blinking
                                                        ? _spriteStandBlink
                                                        : _spriteStand),
                                            ),
                                            glow: _status.color,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
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
                  onPressed: () =>
                      setState(() => _showTrackpad = !_showTrackpad),
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
                child: Row(
                  children: [
                    Expanded(
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
                    // TODO/実況ログはタップで切り替える（スワイプだと誤操作しやすいため）。
                    _bottomTabChip('TODO', 0),
                    const SizedBox(width: 6),
                    _bottomTabChip('実況', 1),
                  ],
                ),
              ),
              Expanded(
                child: _bottomTab == 0
                    ? _TodoPanel(todos: widget.todos, color: _status.color)
                    : _CommentaryPanel(comments: _commentLog, color: _status.color),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
