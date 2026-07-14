import 'dart:convert';

import 'package:flutter/material.dart';

import 'launcher.dart';
import 'settings.dart';

const _kAccent = Color(0xFF00F5FF);

/// マクロボタンの一覧編集画面（並び替え・追加・削除・タップで個別編集）。
class DeckEditorScreen extends StatefulWidget {
  const DeckEditorScreen({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<DeckEditorScreen> createState() => _DeckEditorScreenState();
}

class _DeckEditorScreenState extends State<DeckEditorScreen> {
  List<DeckButton> get deck => widget.settings.deck;

  void _save() {
    widget.settings.save();
    setState(() {});
  }

  Future<void> _edit(int index) async {
    final result = await Navigator.of(context).push<DeckButton>(
        MaterialPageRoute(
            builder: (_) => DeckButtonEditScreen(button: deck[index])));
    if (result == null) return;
    deck[index] = result;
    _save();
  }

  Future<void> _add() async {
    final result = await Navigator.of(context).push<DeckButton>(
        MaterialPageRoute(builder: (_) => const DeckButtonEditScreen()));
    if (result == null) return;
    deck.add(result);
    _save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('マクロボタン')),
      floatingActionButton: FloatingActionButton(
        backgroundColor: _kAccent,
        foregroundColor: Colors.black,
        onPressed: _add,
        child: const Icon(Icons.add),
      ),
      body: deck.isEmpty
          ? const Center(
              child: Text('ボタンがありません。右下の＋で追加',
                  style: TextStyle(color: Colors.white38)))
          : ReorderableListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              buildDefaultDragHandles: false,
              itemCount: deck.length,
              onReorderItem: (oldIndex, newIndex) {
                deck.insert(newIndex, deck.removeAt(oldIndex));
                _save();
              },
              itemBuilder: (context, i) {
                final b = deck[i];
                return ListTile(
                  key: ObjectKey(b),
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border:
                          Border.all(color: b.color.withValues(alpha: 0.6)),
                      color: b.color.withValues(alpha: 0.12),
                    ),
                    child: Icon(b.icon, color: b.color, size: 22),
                  ),
                  title: Text(b.label),
                  subtitle: Text(summarizeMessage(b.message),
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 12)),
                  onTap: () => _edit(i),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.white38),
                        onPressed: () => _confirmDelete(i),
                      ),
                      ReorderableDragStartListener(
                        index: i,
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child:
                              Icon(Icons.drag_handle, color: Colors.white38),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Future<void> _confirmDelete(int index) async {
    final b = deck[index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('「${b.label}」を削除'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('削除',
                  style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok != true) return;
    deck.removeAt(index);
    _save();
  }
}

/// アクション（message）の1行要約。一覧のsubtitleに使う。
String summarizeMessage(Map<String, dynamic> m) {
  switch (m['type']) {
    case 'shortcut':
      final keys = m['keys'];
      return keys is List ? 'ショートカット: ${keys.join(' + ')}' : 'ショートカット';
    case 'launch':
      return '起動: ${m['target'] ?? ''}';
    case 'text':
      return 'テキスト入力: ${m['text'] ?? ''}';
    case 'screenshot':
      return 'スクリーンショット';
    case 'power':
      const names = {'sleep': 'スリープ', 'shutdown': 'シャットダウン', 'restart': '再起動'};
      return '電源: ${names[m['action']] ?? m['action']}';
    case 'macro':
      final steps = m['steps'];
      return 'マクロ（${steps is List ? steps.length : '?'}ステップ）';
    default:
      return 'JSON: ${jsonEncode(m)}';
  }
}

// ─────────────────────────────────────── 個別ボタンの編集画面

class DeckButtonEditScreen extends StatefulWidget {
  const DeckButtonEditScreen({super.key, this.button});

  /// nullなら新規作成。
  final DeckButton? button;

  @override
  State<DeckButtonEditScreen> createState() => _DeckButtonEditScreenState();
}

class _DeckButtonEditScreenState extends State<DeckButtonEditScreen> {
  static const _modifiers = ['ctrl', 'alt', 'shift', 'win'];

  late final TextEditingController _label;
  late IconData _icon;
  late Color _color;

  // アクションエディタの状態
  late String _type; // shortcut / launch / text / screenshot / json
  final Set<String> _mods = {};
  late final TextEditingController _key;
  late final TextEditingController _target;
  late final TextEditingController _text;
  late final TextEditingController _json;

  @override
  void initState() {
    super.initState();
    final b = widget.button;
    _label = TextEditingController(text: b?.label ?? '');
    _icon = b?.icon ?? Icons.bolt;
    _color = b?.color ?? _kAccent;

    // 既存messageをtype別フォームに展開。フォーム化できないものはJSON直編集。
    final m = b?.message ?? const {'type': 'shortcut', 'keys': <String>[]};
    var key = '';
    var target = '';
    var text = '';
    switch (m['type']) {
      case 'shortcut':
        _type = 'shortcut';
        final keys = (m['keys'] as List?)?.cast<String>() ?? const [];
        for (final k in keys) {
          if (_modifiers.contains(k) && key.isEmpty) {
            _mods.add(k);
          } else {
            key = key.isEmpty ? k : '$key $k';
          }
        }
      case 'launch':
        _type = 'launch';
        target = m['target'] as String? ?? '';
      case 'text':
        _type = 'text';
        text = m['text'] as String? ?? '';
      case 'screenshot':
        _type = 'screenshot';
      default:
        _type = 'json';
    }
    _key = TextEditingController(text: key);
    _target = TextEditingController(text: target);
    _text = TextEditingController(text: text);
    _json = TextEditingController(
        text: const JsonEncoder.withIndent('  ').convert(m));
  }

  @override
  void dispose() {
    _label.dispose();
    _key.dispose();
    _target.dispose();
    _text.dispose();
    _json.dispose();
    super.dispose();
  }

  /// フォーム内容からmessageを組み立てる。不正ならnullを返しSnackBarで通知。
  Map<String, dynamic>? _buildMessage() {
    switch (_type) {
      case 'shortcut':
        final key = _key.text.trim().toLowerCase();
        final keys = [
          for (final mod in _modifiers)
            if (_mods.contains(mod)) mod,
          ...key.split(RegExp(r'\s+')).where((k) => k.isNotEmpty),
        ];
        if (keys.isEmpty) {
          _warn('キーを入力してください');
          return null;
        }
        return {'type': 'shortcut', 'keys': keys};
      case 'launch':
        final target = _target.text.trim();
        if (target.isEmpty) {
          _warn('起動対象を入力してください');
          return null;
        }
        return {'type': 'launch', 'target': target};
      case 'text':
        if (_text.text.isEmpty) {
          _warn('入力するテキストを設定してください');
          return null;
        }
        return {'type': 'text', 'text': _text.text};
      case 'screenshot':
        return {'type': 'screenshot'};
      default: // json
        try {
          final decoded = jsonDecode(_json.text);
          if (decoded is! Map || decoded['type'] is! String) {
            _warn('"type" を含むJSONオブジェクトにしてください');
            return null;
          }
          return decoded.cast<String, dynamic>();
        } catch (e) {
          _warn('JSONが不正です: $e');
          return null;
        }
    }
  }

  void _warn(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  void _submit() {
    final message = _buildMessage();
    if (message == null) return;
    final label = _label.text.trim();
    if (label.isEmpty) {
      _warn('ラベルを入力してください');
      return;
    }
    Navigator.of(context).pop(
        DeckButton(label: label, icon: _icon, color: _color, message: message));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.button == null ? 'ボタンを追加' : 'ボタンを編集'),
        actions: [
          IconButton(
              icon: const Icon(Icons.check, color: _kAccent),
              onPressed: _submit),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // プレビュー + ラベル
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: _color.withValues(alpha: 0.6), width: 2),
                  color: _color.withValues(alpha: 0.12),
                ),
                child: Icon(_icon, color: _color, size: 30),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _label,
                  decoration: const InputDecoration(
                    labelText: 'ラベル',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _header('アイコン'),
          _iconGrid(),
          const SizedBox(height: 16),
          _header('色'),
          Wrap(
            spacing: 10,
            children: [
              for (final c in kColorPalette)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c,
                      border: Border.all(
                        color: _color == c ? Colors.white : Colors.transparent,
                        width: 3,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          _header('アクション'),
          Wrap(
            spacing: 8,
            children: [
              _typeChip('shortcut', 'ショートカット'),
              _typeChip('launch', 'アプリ/URL起動'),
              _typeChip('text', 'テキスト入力'),
              _typeChip('screenshot', 'スクショ'),
              _typeChip('json', '上級者向け(JSON)'),
            ],
          ),
          const SizedBox(height: 12),
          ..._actionFields(),
        ],
      ),
    );
  }

  Widget _typeChip(String type, String label) {
    return ChoiceChip(
      label: Text(label),
      selected: _type == type,
      selectedColor: _kAccent.withValues(alpha: 0.25),
      onSelected: (_) => setState(() => _type = type),
    );
  }

  List<Widget> _actionFields() {
    switch (_type) {
      case 'shortcut':
        return [
          Wrap(
            spacing: 8,
            children: [
              for (final mod in _modifiers)
                FilterChip(
                  label: Text(mod.toUpperCase()),
                  selected: _mods.contains(mod),
                  selectedColor: _kAccent.withValues(alpha: 0.25),
                  onSelected: (v) => setState(
                      () => v ? _mods.add(mod) : _mods.remove(mod)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            decoration: const InputDecoration(
              labelText: 'キー',
              hintText: '例: c / enter / tab / f5 / delete / space',
              border: OutlineInputBorder(),
            ),
          ),
        ];
      case 'launch':
        return [
          TextField(
            controller: _target,
            decoration: const InputDecoration(
              labelText: '起動対象（exe / URL / フォルダ）',
              hintText: '例: notepad.exe / https://example.com',
              border: OutlineInputBorder(),
            ),
          ),
        ];
      case 'text':
        return [
          TextField(
            controller: _text,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'PCに入力するテキスト',
              border: OutlineInputBorder(),
            ),
          ),
        ];
      case 'screenshot':
        return [
          const Text('PCの全画面を撮ってスマホに表示します。設定項目はありません。',
              style: TextStyle(color: Colors.white38)),
        ];
      default: // json
        return [
          TextField(
            controller: _json,
            maxLines: 10,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              labelText: '送信するJSON',
              helperText:
                  '例: {"type":"macro","steps":[{"type":"shortcut","keys":["win","r"]},'
                  '{"type":"wait","ms":300},{"type":"text","text":"cmd"}]}',
              helperMaxLines: 4,
              border: OutlineInputBorder(),
            ),
          ),
        ];
    }
  }

  Widget _iconGrid() {
    return GridView.count(
      crossAxisCount: 8,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
      children: [
        for (final entry in kIconCatalog.entries)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _icon = entry.value),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: _icon == entry.value
                    ? _kAccent.withValues(alpha: 0.25)
                    : Colors.transparent,
                border: Border.all(
                  color: _icon == entry.value
                      ? _kAccent
                      : Colors.transparent,
                ),
              ),
              child: Icon(entry.value,
                  size: 20,
                  color:
                      _icon == entry.value ? _kAccent : Colors.white54),
            ),
          ),
      ],
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white54,
                fontSize: 13,
                fontWeight: FontWeight.bold)),
      );
}
