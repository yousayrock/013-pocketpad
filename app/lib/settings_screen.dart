import 'package:flutter/material.dart';

import 'deck_editor.dart';
import 'settings.dart';

const _kAccent = Color(0xFF00F5FF);

/// 設定画面。渡されたAppSettingsを直接書き換え、変更のたびに保存する。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.claudeNotifyEnabled,
    required this.onClaudeNotifyChanged,
  });

  final AppSettings settings;

  /// Claude Code通知（音・バイブ・フラッシュ）のON/OFF。
  /// デバイスローカルの状態でありPC同期設定には含まれないため、
  /// AppSettingsとは別に受け渡す。
  final bool claudeNotifyEnabled;
  final ValueChanged<bool> onClaudeNotifyChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppSettings get s => widget.settings;

  void _save() {
    s.save();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _header('トラックパッド感度'),
          Row(
            children: [
              const SizedBox(width: 16),
              const Icon(Icons.speed, color: Colors.white38, size: 20),
              Expanded(
                child: Slider(
                  value: s.sensitivity,
                  min: AppSettings.minSensitivity,
                  max: AppSettings.maxSensitivity,
                  divisions: 25,
                  activeColor: _kAccent,
                  label: s.sensitivity.toStringAsFixed(1),
                  onChanged: (v) => setState(() => s.sensitivity = v),
                  onChangeEnd: (_) => _save(),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(s.sensitivity.toStringAsFixed(1),
                    style: const TextStyle(color: _kAccent)),
              ),
            ],
          ),
          SwitchListTile(
            value: s.invertScroll,
            activeThumbColor: _kAccent,
            title: const Text('スクロール方向を反転'),
            secondary: const Icon(Icons.swap_vert, color: Colors.white38),
            onChanged: (v) {
              setState(() => s.invertScroll = v);
              _save();
            },
          ),
          _header('ページ（表示と並び順）'),
          _reorderableToggles(
            entries: s.pages,
            names: kPageNames,
            icons: kPageIcons,
            onToggle: (e, v) {
              if (!v && s.visiblePages.length <= 1) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('最低1ページは表示が必要です')));
                return;
              }
              e.enabled = v;
              _save();
            },
          ),
          _header('下部の操作ボタン（表示と並び順）'),
          _reorderableToggles(
            entries: s.bottomButtons,
            names: kBottomButtonNames,
            icons: kBottomButtonIcons,
            onToggle: (e, v) {
              e.enabled = v;
              _save();
            },
          ),
          _header('マクロ'),
          ListTile(
            leading: const Icon(Icons.grid_view, color: _kAccent),
            title: const Text('マクロボタンを編集'),
            subtitle: Text('${s.deck.length}個のボタン',
                style: const TextStyle(color: Colors.white38)),
            trailing: const Icon(Icons.chevron_right, color: Colors.white38),
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => DeckEditorScreen(
                        deck: s.deck,
                        title: 'マクロボタン',
                        onChanged: s.save,
                      )));
              setState(() {});
            },
          ),
          _header('Claude Code'),
          SwitchListTile(
            value: widget.claudeNotifyEnabled,
            activeThumbColor: _kAccent,
            title: const Text('作業完了・承認待ちの通知'),
            subtitle: const Text('音・バイブ・画面フラッシュで知らせます',
                style: TextStyle(fontSize: 12)),
            secondary: const Icon(Icons.smart_toy, color: Colors.white38),
            onChanged: widget.onClaudeNotifyChanged,
          ),
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.restore, color: Colors.redAccent),
            title: const Text('初期設定に戻す',
                style: TextStyle(color: Colors.redAccent)),
            onTap: _confirmReset,
          ),
        ],
      ),
    );
  }

  /// 並び替え＋表示スイッチ付きのリスト（ページ・下部ボタン共用）。
  Widget _reorderableToggles({
    required List<ToggleEntry> entries,
    required Map<String, String> names,
    required Map<String, IconData> icons,
    required void Function(ToggleEntry, bool) onToggle,
  }) {
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorderItem: (oldIndex, newIndex) {
        entries.insert(newIndex, entries.removeAt(oldIndex));
        _save();
      },
      children: [
        for (var i = 0; i < entries.length; i++)
          ListTile(
            key: ValueKey(entries[i].id),
            leading: Icon(icons[entries[i].id],
                color: entries[i].enabled ? _kAccent : Colors.white24),
            title: Text(
              names[entries[i].id] ?? entries[i].id,
              style: TextStyle(
                  color: entries[i].enabled ? Colors.white : Colors.white38),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: entries[i].enabled,
                  activeThumbColor: _kAccent,
                  onChanged: (v) => onToggle(entries[i], v),
                ),
                ReorderableDragStartListener(
                  index: i,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.drag_handle, color: Colors.white38),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white54,
                fontSize: 13,
                fontWeight: FontWeight.bold)),
      );

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('初期設定に戻す'),
        content: const Text('ページ構成・下部ボタン・感度・マクロボタンが\nすべて初期状態に戻ります。よろしいですか？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('戻す', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok != true) return;
    final d = AppSettings.defaults();
    s
      ..pages = d.pages
      ..bottomButtons = d.bottomButtons
      ..sensitivity = d.sensitivity
      ..deck = d.deck;
    _save();
  }
}
