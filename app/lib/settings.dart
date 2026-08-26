import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'launcher.dart';

// ─────────────────────────────────────── アイコンカタログ
// DeckButtonのアイコンは「名前」で保存する。codePointから動的に復元すると
// アイコンフォントのtree-shakingが壊れる（--no-tree-shake-iconsが必要になる）
// ため、constな候補をここに列挙して 名前→IconData で引く。
const Map<String, IconData> kIconCatalog = {
  // defaultDeckで使用中
  'copy': Icons.copy,
  'content_paste': Icons.content_paste,
  'content_cut': Icons.content_cut,
  'undo': Icons.undo,
  'select_all': Icons.select_all,
  'fullscreen': Icons.fullscreen,
  'desktop_windows': Icons.desktop_windows,
  'swap_horiz': Icons.swap_horiz,
  'note': Icons.note,
  'calculate': Icons.calculate,
  'public': Icons.public,
  'lock': Icons.lock,
  // defaultClaudeDeckで使用中
  'keyboard_return': Icons.keyboard_return,
  'cancel_outlined': Icons.cancel_outlined,
  'stop_circle_outlined': Icons.stop_circle_outlined,
  'check': Icons.check,
  'done_all': Icons.done_all,
  'close': Icons.close,
  'layers_clear': Icons.layers_clear,
  'compress': Icons.compress,
  'history': Icons.history,
  // 汎用
  'redo': Icons.redo,
  'save': Icons.save,
  'search': Icons.search,
  'folder': Icons.folder,
  'folder_open': Icons.folder_open,
  'home': Icons.home,
  'settings': Icons.settings,
  'star': Icons.star,
  'favorite': Icons.favorite,
  'bolt': Icons.bolt,
  'play_arrow': Icons.play_arrow,
  'pause': Icons.pause,
  'stop': Icons.stop,
  'skip_next': Icons.skip_next,
  'skip_previous': Icons.skip_previous,
  'volume_up': Icons.volume_up,
  'volume_down': Icons.volume_down,
  'volume_off': Icons.volume_off,
  'mic': Icons.mic,
  'camera_alt': Icons.camera_alt,
  'movie': Icons.movie,
  'music_note': Icons.music_note,
  'headphones': Icons.headphones,
  'sports_esports': Icons.sports_esports,
  'terminal': Icons.terminal,
  'code': Icons.code,
  'keyboard': Icons.keyboard,
  'mouse': Icons.mouse,
  'print': Icons.print,
  'wifi': Icons.wifi,
  'bluetooth': Icons.bluetooth,
  'power_settings_new': Icons.power_settings_new,
  'refresh': Icons.refresh,
  'delete': Icons.delete,
  'edit': Icons.edit,
  'mail': Icons.mail,
  'chat': Icons.chat,
  'alarm': Icons.alarm,
  'schedule': Icons.schedule,
  'download': Icons.download,
  'upload': Icons.upload,
  'link': Icons.link,
  'language': Icons.language,
  'light_mode': Icons.light_mode,
  'dark_mode': Icons.dark_mode,
  'apps': Icons.apps,
  'rocket_launch': Icons.rocket_launch,
  'widgets': Icons.widgets,
};

/// カタログ内でのアイコン名を返す。カタログ外なら 'widgets'。
String iconNameOf(IconData icon) {
  for (final e in kIconCatalog.entries) {
    if (e.value == icon) return e.key;
  }
  return 'widgets';
}

// ─────────────────────────────────────── カラーパレット
// デッキボタンの色候補。保存はARGB32のintなので将来カスタム色にも拡張できる。
const List<Color> kColorPalette = [
  Color(0xFF00F5FF), // kAccent（シアン）
  Color(0xFFFF006E), // kMagenta
  Colors.amberAccent,
  Colors.redAccent,
  Colors.greenAccent,
  Colors.orangeAccent,
  Colors.purpleAccent,
  Colors.lightBlueAccent,
];

// ─────────────────────────────────────── ページ / 下部ボタンの定義
const kPageNames = {
  'trackpad': 'トラックパッド',
  'macro': 'マクロ',
  'youtube': 'YouTube',
};

const kPageIcons = {
  'trackpad': Icons.touch_app,
  'macro': Icons.grid_view,
  'youtube': Icons.play_circle_outline,
};

const kBottomButtonNames = {
  'enter': 'Enter',
  'backspace': 'バックスペース',
  'keyboard': 'キーボード表示',
  'alttab': 'タスク切替（Alt+Tab）',
  'win': 'Winキー',
  'mic': 'マイク入力',
};

const kBottomButtonIcons = {
  'enter': Icons.keyboard_return,
  'backspace': Icons.backspace_outlined,
  'keyboard': Icons.keyboard,
  'alttab': Icons.swap_horiz,
  'mic': Icons.mic,
  'win': Icons.window,
};

/// 順序付き+表示フラグの1項目（ページ・下部ボタン共用）。
class ToggleEntry {
  ToggleEntry(this.id, {this.enabled = true});

  final String id;
  bool enabled;

  Map<String, dynamic> toJson() => {'id': id, 'enabled': enabled};
}

// ─────────────────────────────────────── DeckButton のシリアライズ
// DeckButton本体（launcher.dart）はUI都合のIconData/Colorを持つため、
// JSON変換はこちらに置いて循環importを避ける。

Map<String, dynamic> deckButtonToJson(DeckButton b) => {
      'label': b.label,
      'icon': iconNameOf(b.icon),
      'color': b.color.toARGB32(),
      'message': b.message,
    };

DeckButton deckButtonFromJson(Map<String, dynamic> j) {
  final rawMsg = j['message'];
  return DeckButton(
    label: j['label'] as String? ?? '?',
    icon: kIconCatalog[j['icon']] ?? Icons.widgets,
    color: Color((j['color'] as num?)?.toInt() ?? 0xFF00F5FF),
    message: rawMsg is Map
        ? rawMsg.cast<String, dynamic>()
        : const {'type': 'screenshot'},
  );
}

// ─────────────────────────────────────── 設定本体

class AppSettings {
  AppSettings({
    required this.pages,
    required this.bottomButtons,
    required this.sensitivity,
    required this.deck,
    this.invertScroll = false,
  });

  /// 全ページ（順序付き。非表示でも順序を保持する）
  List<ToggleEntry> pages;

  /// 下部操作ボタン（順序付き。全部オフなら行ごと非表示）
  List<ToggleEntry> bottomButtons;

  /// トラックパッド感度（0.5〜3.0）
  double sensitivity;

  /// マクロページのボタン
  List<DeckButton> deck;

  /// トラックパッドのスクロール方向を反転するか
  bool invertScroll;

  /// 保存時に呼ばれるフック（PCへのconfig_set送信用）。シリアライズ対象外。
  void Function(Map<String, dynamic> json)? onSaved;

  static const _prefsKey = 'settings';
  static const minSensitivity = 0.5;
  static const maxSensitivity = 3.0;

  factory AppSettings.defaults() => AppSettings(
        pages: [for (final id in kPageNames.keys) ToggleEntry(id)],
        bottomButtons: [
          for (final id in kBottomButtonNames.keys) ToggleEntry(id)
        ],
        sensitivity: 1.4,
        deck: List.of(defaultDeck),
      );

  /// 表示するページID（enabledのみ、順序どおり）。必ず1件以上になる。
  List<String> get visiblePages =>
      [for (final p in pages.where((p) => p.enabled)) p.id];

  /// 表示する下部ボタンID（0件可）。
  List<String> get enabledBottomButtons =>
      [for (final b in bottomButtons.where((b) => b.enabled)) b.id];

  Map<String, dynamic> toJson() => {
        'v': 1,
        'pages': [for (final p in pages) p.toJson()],
        'bottomButtons': [for (final b in bottomButtons) b.toJson()],
        'sensitivity': sensitivity,
        'deck': [for (final b in deck) deckButtonToJson(b)],
        'invertScroll': invertScroll,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) {
    final s = AppSettings.defaults();
    s.sensitivity = ((j['sensitivity'] as num?)?.toDouble() ?? s.sensitivity)
        .clamp(minSensitivity, maxSensitivity);
    s.pages = _readEntries(j['pages'], kPageNames.keys);
    s.bottomButtons = _readEntries(j['bottomButtons'], kBottomButtonNames.keys);
    if (j['deck'] is List) {
      s.deck = [
        for (final e in j['deck'] as List)
          if (e is Map) deckButtonFromJson(e.cast<String, dynamic>()),
      ];
    }
    s.invertScroll = j['invertScroll'] == true;
    s._sanitize();
    return s;
  }

  /// 保存データから項目リストを復元。未知のIDは捨て、保存に無い既知のIDは
  /// 末尾に追加する（アプリ更新でページ/ボタンが増えても自動で現れる）。
  static List<ToggleEntry> _readEntries(dynamic raw, Iterable<String> known) {
    final result = <ToggleEntry>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map && known.contains(e['id'])) {
          result.add(
              ToggleEntry(e['id'] as String, enabled: e['enabled'] != false));
        }
      }
    }
    for (final id in known) {
      if (!result.any((r) => r.id == id)) result.add(ToggleEntry(id));
    }
    return result;
  }

  /// 不整合の補正。ページが全部オフなら先頭をオンに戻す。
  void _sanitize() {
    if (!pages.any((p) => p.enabled)) pages.first.enabled = true;
  }

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return AppSettings.defaults();
    try {
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return AppSettings.defaults(); // 壊れた保存データはデフォルトに戻す
    }
  }

  /// 保存。notify=false はPCから受け取った設定の永続化用（エコーバック防止）。
  Future<void> save({bool notify = true}) async {
    _sanitize();
    final prefs = await SharedPreferences.getInstance();
    final json = toJson();
    await prefs.setString(_prefsKey, jsonEncode(json));
    if (notify) onSaved?.call(json);
  }
}
