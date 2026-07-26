import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals, mapEquals;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'trackpad.dart';

/// スマホ→PCへ送るファイル1件あたりの上限（base64後）。PC側WsServer.csの
/// 12MB上限と合わせている。大きすぎるファイルはWebSocketのテキストフレームを
/// 圧迫するため、ここで先に弾いてユーザーに伝える。
const _maxFileTransferBytes = 8 * 1024 * 1024;

const _kAccent = Color(0xFF00F5FF);
const _kMagenta = Color(0xFFFF006E);

/// 今の接続経路。自宅LAN(直接ws://)か外出先(Cloudflare Tunnel経由のwss://)か。
/// 画面隅のバッジ表示に使うだけで、通信自体の分岐は接続確立側(main.dart)で完結している。
enum ConnKind { lan, remote }

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
  // "pending" | "in_progress" | "completed"
  // 現在PC側から届くのは pending/completed のみ。in_progress は将来の互換用。
  final String status;
  final String activeForm;
}

/// PC側でClaude Haikuが生成した実況コメント（`claude_activity_comment`）。
/// ツール呼び出しの直後、少し遅れて届く「おまけ」の一言。
class ActivityComment {
  ActivityComment({required this.text, DateTime? time})
    : time = time ?? DateTime.now();

  factory ActivityComment.fromJson(Map<String, dynamic> j) => ActivityComment(
    text: (j['text'] as String?) ?? '',
    time: DateTime.tryParse((j['timestamp'] as String?) ?? ''),
  );

  final String text;
  final DateTime time;
}

class HaikuStatus {
  const HaikuStatus({required this.available, this.reason});

  factory HaikuStatus.fromJson(Map<String, dynamic> j) => HaikuStatus(
    available: j['available'] == true,
    reason: j['reason'] as String?,
  );

  final bool available;
  final String? reason;
}

/// 資料室の日誌1件（`claude_knowledge`）。ターン完了時のClaude自身の最終応答を
/// そのまま保存したもの。新しいAI要約は行わない軽量方針。
class KnowledgeEntry {
  const KnowledgeEntry({
    required this.project,
    required this.summary,
    required this.timestamp,
    required this.toolsUsed,
    required this.touchedFiles,
    this.commitHash,
  });

  factory KnowledgeEntry.fromJson(Map<String, dynamic> j) => KnowledgeEntry(
    project: (j['project'] as String?) ?? '(不明)',
    summary: (j['summary'] as String?) ?? '',
    timestamp: (j['timestamp'] as String?) ?? '',
    toolsUsed: [
      for (final t in (j['toolsUsed'] as List? ?? const [])) t.toString(),
    ],
    touchedFiles: [
      for (final f in (j['touchedFiles'] as List? ?? const [])) f.toString(),
    ],
    commitHash: j['commitHash'] as String?,
  );

  final String project;
  final String summary;
  final String timestamp; // ISO8601（DateTimeOffset.ToString("O")）
  final List<String> toolsUsed;
  final List<String> touchedFiles;
  final String? commitHash;

  DateTime? get time => DateTime.tryParse(timestamp);
}

class DailyCharacter {
  const DailyCharacter({
    required this.date,
    required this.status,
    required this.theme,
    required this.reason,
    required this.palette,
    required this.bg,
    required this.dot,
    required this.stand,
    required this.walk,
    required this.blink,
  });

  factory DailyCharacter.fromJson(Map<String, dynamic> j) {
    String stringField(String key, String fallbackValue) =>
        j[key] is String ? j[key] as String : fallbackValue;
    Color colorField(String key, Color fallbackValue) =>
        _parseColor(j[key]) ?? fallbackValue;
    List<String> rowsField(String key, List<String> fallbackValue) {
      final value = j[key];
      if (value is! List || value.length != 8) return fallbackValue;
      final rows = <String>[];
      for (final row in value) {
        if (row is! String || row.length != 7) return fallbackValue;
        rows.add(row);
      }
      return rows;
    }

    var palette = fallback.palette;
    final rawPalette = j['palette'];
    if (rawPalette is Map) {
      final parsed = <String, Color>{};
      var valid = true;
      for (final entry in rawPalette.entries) {
        final color = _parseColor(entry.value);
        if (color == null) {
          valid = false;
          break;
        }
        parsed[entry.key.toString()] = color;
      }
      if (valid && parsed.isNotEmpty) palette = parsed;
    }
    final rawStatus = j['status'];
    final status =
        rawStatus == 'ready' ||
            rawStatus == 'generating' ||
            rawStatus == 'default'
        ? rawStatus as String
        : fallback.status;
    return DailyCharacter(
      date: stringField('date', fallback.date),
      status: status,
      theme: stringField('theme', fallback.theme),
      reason: stringField('reason', fallback.reason),
      palette: palette,
      bg: colorField('bg', fallback.bg),
      dot: colorField('dot', fallback.dot),
      stand: rowsField('stand', fallback.stand),
      walk: rowsField('walk', fallback.walk),
      blink: rowsField('blink', fallback.blink),
    );
  }

  static Color? _parseColor(dynamic value) {
    if (value is! String || !RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(value)) {
      return null;
    }
    return Color(0xFF000000 | int.parse(value.substring(1), radix: 16));
  }

  static const fallback = DailyCharacter(
    date: '',
    status: 'default',
    theme: 'いつものかんぱにっち',
    reason: '',
    palette: _defaultSpritePalette,
    bg: Color(0xFF070B16),
    dot: Colors.white,
    stand: _spriteStand,
    walk: _spriteWalk,
    blink: _spriteStandBlink,
  );

  final String date;
  final String status;
  final String theme;
  final String reason;
  final Map<String, Color> palette;
  final Color bg;
  final Color dot;
  final List<String> stand;
  final List<String> walk;
  final List<String> blink;
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
  Alignment(-0.7, -0.8),
  Icons.desktop_windows,
  '編集中',
  '開発デスク',
  Color(0xFF29B6F6),
);
const _zoneCommand = _Zone(
  Alignment(0.7, -0.8),
  Icons.terminal,
  'コマンド実行中',
  'サーバー室',
  Color(0xFFB388FF),
);
const _zoneSearching = _Zone(
  Alignment(-0.7, 0.8),
  Icons.menu_book,
  '調査中',
  '資料室',
  Color(0xFFFFC24B),
);
const _zoneDelegating = _Zone(
  Alignment(0.7, 0.8),
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

/// "HH:mm:ss"形式の時刻表示。実況ログ・部屋詳細・資料室で共通に使う。
String _fmtTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

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

const _defaultSpritePalette = <String, Color>{
  '1': _kAccent,
  '2': _kMagenta,
  '0': Colors.black,
};

class _PixelSprite extends StatelessWidget {
  const _PixelSprite({
    required this.rows,
    required this.glow,
    required this.palette,
    this.pixelSize = 6.0,
  });
  final List<String> rows;
  final Color glow;
  final Map<String, Color> palette;
  final double pixelSize;

  @override
  Widget build(BuildContext context) {
    final w = rows.first.length * pixelSize;
    final h = rows.length * pixelSize;
    return SizedBox(
      width: w,
      height: h,
      child: CustomPaint(
        painter: _SpritePainter(rows, pixelSize, glow, palette),
      ),
    );
  }
}

class _SpritePainter extends CustomPainter {
  _SpritePainter(this.rows, this.pixelSize, this.glow, this.palette);
  final List<String> rows;
  final double pixelSize;
  final Color glow;
  final Map<String, Color> palette;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (var y = 0; y < rows.length; y++) {
      final row = rows[y];
      for (var x = 0; x < row.length; x++) {
        final color = palette[row[x]];
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
      !listEquals(oldDelegate.rows, rows) ||
      oldDelegate.pixelSize != pixelSize ||
      oldDelegate.glow != glow ||
      !mapEquals(oldDelegate.palette, palette);
}

/// たまごっちの筐体っぽい「床」の質感を出すドット格子。
class _FloorPainter extends CustomPainter {
  const _FloorPainter(this.dotColor);
  final Color dotColor;
  static const _step = 14.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = dotColor.withValues(alpha: 0.05);
    for (var y = _step / 2; y < size.height; y += _step) {
      for (var x = _step / 2; x < size.width; x += _step) {
        canvas.drawCircle(Offset(x, y), 1.1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FloorPainter oldDelegate) =>
      oldDelegate.dotColor != dotColor;
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

/// 今の接続経路を示す小さなバッジ（🟢自宅LAN / 🟡外出先）。画面隅に控えめに置くだけ。
class _ConnKindBadge extends StatelessWidget {
  const _ConnKindBadge({required this.kind});
  final ConnKind kind;

  @override
  Widget build(BuildContext context) {
    final isLan = kind == ConnKind.lan;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.circle,
            size: 8,
            color: isLan ? Colors.greenAccent : Colors.amberAccent,
          ),
          const SizedBox(width: 4),
          Text(
            isLan ? 'LAN' : 'リモート',
            style: const TextStyle(color: Colors.white54, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

/// オフィス上部の日替わりキャラクター表示。
class _StatsHeader extends StatelessWidget {
  const _StatsHeader({
    required this.name,
    required this.character,
    required this.color,
    required this.onNameTap,
    required this.onThemeTap,
  });

  final String name;
  final DailyCharacter character;
  final Color color;
  final VoidCallback onNameTap;
  final VoidCallback onThemeTap;

  @override
  Widget build(BuildContext context) {
    // statusはPC側の DailyCharacter.Status と対応（generating/ready/failed/holiday）。
    // 生成できていない状態でreasonをそのまま出すと空欄になるので、状態ごとの文言に倒す。
    final reason = switch (character.status) {
      'generating' => '今日のキャラを準備中…',
      'failed' => '今日のキャラはまだ作られていないよ',
      'holiday' when character.reason.isEmpty => '昨日はおやすみだったよ',
      _ => character.reason,
    };
    return Padding(
      // 右上のトラックパッド切替ボタン（Positioned top:4,right:4、タップ領域48x48）と
      // 被らないよう、右側は多めに余白を取る。
      padding: const EdgeInsets.fromLTRB(12, 10, 44, 8),
      child: Row(
        children: [
          // ヘッダーのテーマ・理由は1行に省略されるため、アイコンからも
          // 全文を読めるようにする（理由行のタップと同じ詳細シートを開く）。
          GestureDetector(
            onTap: onThemeTap,
            child: Container(
              width: 34,
              height: 34,
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.18),
                border: Border.all(color: color.withValues(alpha: 0.5)),
              ),
              child: FittedBox(
                child: _PixelSprite(
                  rows: character.stand,
                  glow: color,
                  palette: character.palette,
                ),
              ),
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
                      Flexible(
                        child: Text(
                          '$name / ${character.theme}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
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
                GestureDetector(
                  onTap: onThemeTap,
                  child: Text(
                    reason,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TodoBoard extends StatefulWidget {
  const _TodoBoard({required this.todos, required this.color});

  final List<TodoItem> todos;
  final Color color;

  @override
  State<_TodoBoard> createState() => _TodoBoardState();
}

class _TodoBoardState extends State<_TodoBoard> {
  static final _prefix = RegExp(
    r'^\[(?:(?:phase|フェーズ)\s*:\s*([^/\]]+?)(?:\s*/\s*(P\d+))?|(P\d+))\]\s*',
    caseSensitive: false,
  );
  // 同期で未知のフェーズが増えても一覧が勝手に開かないよう、開いたものだけを保持する。
  final Set<String> _expanded = {};
  bool _completedCollapsed = true;

  static String _phase(TodoItem task) {
    final value = _prefix.firstMatch(task.content)?.group(1)?.trim();
    return value == null || value.isEmpty ? '未分類' : value;
  }

  static String? _priority(TodoItem task) {
    final match = _prefix.firstMatch(task.content);
    return (match?.group(2) ?? match?.group(3))?.toUpperCase();
  }

  static String _label(TodoItem task, {bool active = false}) {
    final source =
        active && task.activeForm.isNotEmpty && task.activeForm != task.content
        ? task.activeForm
        : task.content;
    return source.replaceFirst(_prefix, '');
  }

  static int _rank(TodoItem task) => switch (task.status) {
    'in_progress' => 0,
    _ => switch (_priority(task)) {
      'P1' => 1,
      'P3' => 3,
      _ => 2,
    },
  };

  @override
  Widget build(BuildContext context) {
    final tasks = widget.todos;
    if (tasks.isEmpty) {
      return Center(
        child: Text(
          'Claude CodeがTODOを作ると\nここに一覧が表示されます',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white24, fontSize: 11),
        ),
      );
    }
    final done = tasks.where((task) => task.status == 'completed').length;
    final completed = tasks
        .where((task) => task.status == 'completed')
        .toList();
    final remaining = tasks.where((task) => task.status != 'completed').toList()
      ..sort((a, b) {
        final ranked = _rank(a).compareTo(_rank(b));
        return ranked != 0
            ? ranked
            : tasks.indexOf(a).compareTo(tasks.indexOf(b));
      });
    final activeTask = remaining.firstOrNull;
    final featured = remaining.take(3).toList();
    // 上段の「いま」「次」と同じ項目を下段へ再掲せず、540pxを有効に使う。
    final featuredSet = featured.toSet();
    final grouped = <String, List<TodoItem>>{};
    for (final task in remaining) {
      if (!featuredSet.contains(task)) {
        grouped.putIfAbsent(_phase(task), () => []).add(task);
      }
    }

    return Column(
      children: [
        // スクロール領域の外へ置き、全体進捗を常に一目で確認できるようにする。
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 5),
          child: Column(
            children: [
              Row(
                children: [
                  const Text(
                    '進捗',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '$done/${tasks.length}  残り${remaining.length}件',
                    style: const TextStyle(color: Colors.white60, fontSize: 10),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: done / tasks.length,
                  minHeight: 8,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation<Color>(widget.color),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'いま',
              style: TextStyle(
                color: widget.color,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        if (remaining.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 7),
            child: Text(
              'すべて完了しました',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          )
        else ...[
          _taskRow(activeTask!, active: true, phase: _phase(activeTask)),
          if (featured.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 3, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '次',
                  style: TextStyle(
                    color: widget.color,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          for (final task in featured.skip(1))
            _taskRow(task, active: false, phase: _phase(task)),
        ],
        const Divider(height: 4, thickness: 1, color: Colors.white10),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
            children: [
              for (final entry in grouped.entries) ...[
                _phaseHeader(entry.key, entry.value, activeTask),
                if (_expanded.contains(entry.key))
                  for (final task in entry.value) _taskRow(task, active: false),
              ],
              if (completed.isNotEmpty) ...[
                _completedHeader(completed.length),
                if (!_completedCollapsed)
                  for (final task in completed) _completedTaskRow(task),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _completedHeader(int count) {
    return InkWell(
      onTap: () => setState(() {
        _completedCollapsed = !_completedCollapsed;
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              _completedCollapsed ? Icons.chevron_right : Icons.expand_more,
              color: Colors.white38,
              size: 16,
            ),
            Expanded(
              child: Text(
                '完了 $count件',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _completedTaskRow(TodoItem task) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 0, 2),
      child: Row(
        children: [
          const Icon(
            Icons.check_circle_outline,
            color: Colors.white24,
            size: 13,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _label(task),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _phaseHeader(
    String phase,
    List<TodoItem> tasks,
    TodoItem? activeTask,
  ) {
    final urgent = tasks.any(
      (task) =>
          task.status != 'completed' &&
          (identical(task, activeTask) || _priority(task) == 'P1'),
    );
    return InkWell(
      onTap: () => setState(() {
        if (!_expanded.add(phase)) _expanded.remove(phase);
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              _expanded.contains(phase)
                  ? Icons.expand_more
                  : Icons.chevron_right,
              color: urgent ? _kMagenta : Colors.white54,
              size: 16,
            ),
            Expanded(
              child: Text(
                phase,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: urgent ? Colors.white : Colors.white60,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '残り${tasks.length}',
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _taskRow(TodoItem task, {required bool active, String? phase}) {
    final priority = _priority(task);
    final priorityColor = switch (priority) {
      'P1' => Colors.redAccent,
      'P2' => Colors.amber,
      'P3' => Colors.white38,
      _ => Colors.transparent,
    };
    return Container(
      margin: EdgeInsets.fromLTRB(phase == null ? 16 : 12, 1, 0, 1),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: priorityColor, width: 2)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 5),
      child: Row(
        children: [
          Icon(
            active ? Icons.autorenew : Icons.radio_button_unchecked,
            color: active ? _kMagenta : Colors.white24,
            size: 13,
          ),
          const SizedBox(width: 5),
          if (priority != null) ...[
            Text(
              priority,
              style: TextStyle(
                color: priorityColor,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              _label(task, active: active),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          if (phase != null) ...[
            const SizedBox(width: 4),
            Container(
              constraints: const BoxConstraints(maxWidth: 68),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                phase,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 下半分の「実況ログ」。PC側でClaude Haikuが生成した実況コメントを新しい順に
/// 時系列表示する（TODOパネルとチップタップで切り替え）。
class _CommentaryPanel extends StatelessWidget {
  const _CommentaryPanel({
    required this.comments,
    required this.color,
    required this.status,
  });
  final List<ActivityComment> comments;
  final Color color;
  final HaikuStatus? status;

  @override
  Widget build(BuildContext context) {
    if (comments.isEmpty) {
      return Center(
        child: Text(
          status?.available == false
              ? status?.reason ?? '実況は現在利用できません'
              : 'Claude Codeが動き出すと\nここに実況が流れます',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white24, fontSize: 12),
        ),
      );
    }
    final showStatus = status?.available == false;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: comments.length + (showStatus ? 1 : 0),
      itemBuilder: (context, i) {
        if (showStatus && i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              status?.reason ?? '実況は現在利用できません',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.amberAccent, fontSize: 11),
            ),
          );
        }
        final commentIndex = i - (showStatus ? 1 : 0);
        final c = comments[commentIndex];
        // 最新の1件だけ色付きで強調し、過去分は落ち着いた色にする。
        final isLatest = commentIndex == 0;
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

/// 資料室のナレッジ棚。ターン完了ごとの日誌をプロジェクト×日付でグループ化して
/// 新しい順に見せる（新しい要約生成は行わず、既存データを表示側で束ねるだけ）。
class _KnowledgeShelfPage extends StatelessWidget {
  const _KnowledgeShelfPage({required this.entries, required this.color});
  final List<KnowledgeEntry> entries;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final byProject = <String, List<KnowledgeEntry>>{};
    for (final e in entries) {
      byProject.putIfAbsent(e.project, () => []).add(e);
    }
    for (final list in byProject.values) {
      list.sort(
        (a, b) => (b.time ?? DateTime(0)).compareTo(a.time ?? DateTime(0)),
      );
    }
    final projects = byProject.keys.toList()
      ..sort((a, b) {
        final at = byProject[a]!.first.time ?? DateTime(0);
        final bt = byProject[b]!.first.time ?? DateTime(0);
        return bt.compareTo(at);
      });

    return Scaffold(
      backgroundColor: const Color(0xFF0A1020),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A1020),
        foregroundColor: color,
        title: const Text('資料室 - ナレッジ'),
      ),
      body: entries.isEmpty
          ? const Center(
              child: Text(
                'まだ日誌がありません\n作業が一段落するとここに溜まっていきます',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 13),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                for (final project in projects) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 6),
                    child: Text(
                      project,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  for (final group in _groupByDate(byProject[project]!)) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 4),
                      child: Text(
                        group.dateLabel,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    for (final e in group.entries)
                      _KnowledgeCard(entry: e, color: color),
                  ],
                  const SizedBox(height: 6),
                ],
              ],
            ),
    );
  }

  List<_DateGroup> _groupByDate(List<KnowledgeEntry> list) {
    final map = <String, List<KnowledgeEntry>>{};
    final order = <String>[];
    for (final e in list) {
      final t = e.time;
      final key = t == null
          ? '(日付不明)'
          : '${t.year}/${t.month.toString().padLeft(2, '0')}/${t.day.toString().padLeft(2, '0')}';
      if (!map.containsKey(key)) order.add(key);
      map.putIfAbsent(key, () => []).add(e);
    }
    return [for (final k in order) _DateGroup(k, map[k]!)];
  }
}

class _DateGroup {
  _DateGroup(this.dateLabel, this.entries);
  final String dateLabel;
  final List<KnowledgeEntry> entries;
}

/// ナレッジ棚の日誌カード1件。要約本文＋使った手段/触ったファイル/コミットの小さなタグ。
class _KnowledgeCard extends StatelessWidget {
  const _KnowledgeCard({required this.entry, required this.color});
  final KnowledgeEntry entry;
  final Color color;

  Widget _tag(String text, Color c, {bool mono = false}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: c.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: c,
        fontSize: 11,
        fontFamily: mono ? 'monospace' : null,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = entry.time;
    final hasTags =
        entry.toolsUsed.isNotEmpty ||
        entry.touchedFiles.isNotEmpty ||
        entry.commitHash != null;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.summary,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          if (hasTags) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tool in entry.toolsUsed) _tag(tool, color),
                for (final f in entry.touchedFiles.take(6))
                  _tag(f, Colors.white38, mono: true),
                if (entry.commitHash != null)
                  _tag(entry.commitHash!, _kAccent, mono: true),
              ],
            ),
          ],
          if (t != null) ...[
            const SizedBox(height: 6),
            Text(
              _fmtTime(t),
              style: const TextStyle(color: Colors.white24, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

/// 「かんぱにっち」ページ。Claude Codeが今何をしているかを日替わりの
/// ドット絵キャラクターで見せるビューワー。
/// オフィス内の持ち場（編集/コマンド/調査/委任/待機）を活動に応じて移動する。
/// 上半分はデフォルトでこのオフィス表示、右上のボタンでトラックパッドに開閉できる。
class KanpanicchiPanel extends StatefulWidget {
  const KanpanicchiPanel({
    super.key,
    required this.latestActivity,
    required this.latestNotify,
    required this.todos,
    required this.knowledge,
    required this.latestComment,
    required this.commentHistory,
    required this.haikuStatus,
    required this.character,
    required this.connKind,
    required this.onMove,
    required this.onScroll,
    required this.onClick,
    required this.onShortcut,
    required this.onSendFile,
  });

  final ClaudeActivity? latestActivity;
  final ClaudeNotifyEvent? latestNotify;
  final List<TodoItem> todos;
  final List<KnowledgeEntry> knowledge;
  final ActivityComment? latestComment;
  final List<ActivityComment> commentHistory;
  final HaikuStatus? haikuStatus;
  final DailyCharacter character;

  /// 今の接続経路（自宅LAN/外出先）。画面隅の小さなバッジ表示にのみ使う。
  final ConnKind connKind;
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
  // ステータス行の文字が長い時、自動で横に流す（ニュースティッカー風）。
  // Timer+jumpToだとvsyncと同期せずカクつくため、animateTo（Flutterの
  // アニメーション基盤でティッカー駆動）でループさせる。
  final ScrollController _statusScroll = ScrollController();
  final PageController _bottomPageController = PageController(
    initialPage: 0,
    keepPage: false,
  );
  String? _marqueeLabelSeen;
  int _marqueeGeneration = 0;
  static const _kNameKey = 'kanpanicchi_display_name';
  String _displayName = kCharacterName;

  @override
  void initState() {
    super.initState();
    _bounce = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _armIdleTimer();
    _armBlink();
    _commentLog.addAll(widget.commentHistory.reversed);
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      p.remove('kanpanicchi_level');
      p.remove('kanpanicchi_xp');
      p.remove('kanpanicchi_lifetime_events');
      setState(() {
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
            if (zone == _zoneSearching) ...[
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
                    _showKnowledgeShelf(zone);
                  },
                  icon: const Icon(Icons.auto_stories),
                  label: const Text('ナレッジを見る'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showThemeDetail() {
    final character = widget.character;
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
            Text(
              character.theme,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              character.reason,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 12),
            Text(
              character.date,
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  /// 資料室から呼ぶ、ナレッジ棚（日誌一覧）ページを開く。
  void _showKnowledgeShelf(_Zone zone) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            _KnowledgeShelfPage(entries: widget.knowledge, color: zone.color),
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
    final comment = widget.latestComment;
    if (comment != null && !identical(comment, oldWidget.latestComment)) {
      _onComment(comment);
    }
    if (!identical(widget.commentHistory, oldWidget.commentHistory)) {
      setState(() {
        _commentLog
          ..clear()
          ..addAll(widget.commentHistory.reversed);
      });
    }
  }

  /// Haiku実況が届いた時の処理。ステータス表示・アイドル時の「待っている内容」を
  /// この一言に更新し、実況ログにも積む（ツール名/コマンドより柔らかい表現）。
  void _onComment(ActivityComment c) {
    _lastActivityLabel = c.text;
    setState(() {
      _status = _Status(
        icon: _status.icon,
        color: _status.color,
        label: c.text,
      );
      _commentLog.insert(0, c);
      if (_commentLog.length > 30) _commentLog.removeLast();
    });
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
  }

  void _onNotify(ClaudeNotifyEvent n) {
    final isWaiting = n.event == 'notification';
    final icon = isWaiting ? Icons.notifications_active : Icons.check_circle;
    final color = isWaiting ? _kMagenta : _kAccent;
    final label = isWaiting
        ? '承認を待っています: ${n.message}'
        : '完了しました: ${n.message}';
    _doneRevertTimer?.cancel();
    if (!isWaiting) {
      // ターンが完了した＝もう「待っている」ことは無いので、次にアイドルに
      // なった時は素直に「待機中」でよい。
      _lastActivityLabel = null;
      // 完了はしばらく強調してから待機に戻す
      _doneRevertTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) _moveTo(_zoneIdle, _zoneIdle.color, _zoneIdle.verb);
      });
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
    _marqueeGeneration++; // 実行中のマーキーループを無効化する
    _statusScroll.dispose();
    _bottomPageController.dispose();
    super.dispose();
  }

  /// ステータス行の文字がコンテナ幅に収まらない時だけ、自動で横に流し続ける
  /// （ニュースティッカー風。端まで行ったら先頭に戻ってループ）。
  void _maybeStartMarquee(String label) {
    if (_marqueeLabelSeen == label) return;
    _marqueeLabelSeen = label;
    final gen = ++_marqueeGeneration; // 前のラベルのループを無効化する
    if (_statusScroll.hasClients) _statusScroll.jumpTo(0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _runMarqueeLoop(gen));
  }

  /// animateTo（Flutterのアニメーション基盤・vsync同期）でスクロールを流し続ける。
  /// jumpToを毎フレーム手動で呼ぶ方式だとフレームと同期せずカクつくため使わない。
  Future<void> _runMarqueeLoop(int gen) async {
    while (mounted && gen == _marqueeGeneration && _statusScroll.hasClients) {
      final max = _statusScroll.position.maxScrollExtent;
      if (max <= 0) return; // 収まっているので不要
      await _statusScroll.animateTo(
        max,
        duration: Duration(milliseconds: (max * 30).round()), // 秒速約33px
        curve: Curves.linear,
      );
      if (!mounted || gen != _marqueeGeneration || !_statusScroll.hasClients) {
        return;
      }
      await Future.delayed(const Duration(milliseconds: 700)); // 末尾で一拍
      if (!mounted || gen != _marqueeGeneration || !_statusScroll.hasClients) {
        return;
      }
      _statusScroll.jumpTo(0);
      await Future.delayed(const Duration(milliseconds: 500)); // 先頭でも一拍
    }
  }

  /// TODO/実況ページのどちらにいるかを示す小さなドット（タップ不要、目印だけ）。
  Widget _bottomPageDot(int index) {
    final active = _bottomTab == index;
    final color = _status.color;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: active ? 14 : 6,
      height: 6,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: active ? color : Colors.white24,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _maybeStartMarquee(_status.label);
    final character = widget.character;
    return Stack(
      children: [
        Positioned.fill(
          child: Column(
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
                                    color: character.bg,
                                    borderRadius: BorderRadius.circular(19),
                                    border: Border.all(color: Colors.white10),
                                  ),
                                  child: Column(
                                    children: [
                                      _StatsHeader(
                                        name: _displayName,
                                        character: character,
                                        color: _status.color,
                                        onNameTap: _renameCharacter,
                                        onThemeTap: _showThemeDetail,
                                      ),
                                      Expanded(
                                        child: Stack(
                                          children: [
                                            // たまごっちの筐体っぽい床の質感
                                            Center(
                                              child: SizedBox.expand(
                                                child: CustomPaint(
                                                  painter: _FloorPainter(
                                                    character.dot,
                                                  ),
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
                                                  onTap: () =>
                                                      _showRoomDetail(z),
                                                ),
                                              ),
                                            // キャラクター本体。部屋カード（会議室など）と重なる位置に
                                            // 来ることがあり、素のままだと上に乗ったキャラがタップを
                                            // 吸ってしまい部屋カードのInkWellまで届かないことがあるため、
                                            // キャラ自体はタップを素通しする（操作対象ではないので）。
                                            IgnorePointer(
                                              child: AnimatedAlign(
                                                duration: _moveDuration,
                                                curve: Curves.easeInOut,
                                                // 部屋カードと重ならないよう、以前はここで倍率を0.05まで
                                                // 落として中央の隙間(実測約43px)に閉じ込めていたが、
                                                // キャラを大きくした今はその幅に収まらず、閉じ込めても
                                                // 結局重なる。重なってもタップは上のIgnorePointerで
                                                // 素通しするので実害は無い。「持ち場まで歩いていく」のが
                                                // 本来の見せ方なので、部屋の位置そのものへ移動させる。
                                                alignment: _zone.align,
                                                child: AnimatedBuilder(
                                                  animation: _bounce,
                                                  builder: (context, child) {
                                                    final bounceY = _walking
                                                        ? 0.0
                                                        : -_bounce.value * 3;
                                                    return Transform.translate(
                                                      offset: Offset(
                                                        0,
                                                        bounceY,
                                                      ),
                                                      child: child,
                                                    );
                                                  },
                                                  child: _PixelSprite(
                                                    // 7列×8行なので 49×56px。
                                                    pixelSize: 7.0,
                                                    rows:
                                                        _walking && !_walkFrameA
                                                        ? character.walk
                                                        : (_blinking
                                                              ? character.blink
                                                              : character
                                                                    .stand),
                                                    glow: _status.color,
                                                    palette: character.palette,
                                                  ),
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
                    Positioned(
                      top: 8,
                      left: 8,
                      child: _ConnKindBadge(kind: widget.connKind),
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
                            child: SingleChildScrollView(
                              controller: _statusScroll,
                              scrollDirection: Axis.horizontal,
                              physics: const NeverScrollableScrollPhysics(),
                              child: Text(
                                _status.label,
                                maxLines: 1,
                                softWrap: false,
                                style: TextStyle(
                                  color: _status.color,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                          // TODO/実況ログは下のカラムをどこでも横スワイプすれば切り替わる。
                          _bottomPageDot(0),
                          _bottomPageDot(1),
                        ],
                      ),
                    ),
                    Expanded(
                      child: PageView(
                        controller: _bottomPageController,
                        onPageChanged: (i) => setState(() => _bottomTab = i),
                        children: [
                          _TodoBoard(todos: widget.todos, color: _status.color),
                          _CommentaryPanel(
                            comments: _commentLog,
                            color: _status.color,
                            status: widget.haikuStatus,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
