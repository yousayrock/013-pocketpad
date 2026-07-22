# PocketPad 通信プロトコル v1

WebSocket 1本で全通信を行う。**テキストフレーム＝JSON**（制御・低頻度イベント）、**バイナリフレーム＝高頻度入力**（マウス移動・スクロール）。

## 接続フロー

```
1. PC側トレイアプリがQRコードを表示
   QR内容: pocketpad://{host}:{port}?token={pairing_token}
2. スマホがQRを読み取り WebSocket接続 → auth送信
3. PC側画面に6桁PINを表示 → スマホで入力 → pin送信
4. PCが device_secret を発行 → スマホが保存
5. 以降は device_secret で自動接続（PIN不要）
```

## JSONメッセージ（テキストフレーム）

すべて `{"type": "...", ...}` 形式。

### 認証

| type | 方向 | フィールド | 説明 |
|------|------|-----------|------|
| `auth` | 📱→PC | `token`, `device_id`, `device_name` | 初回ペアリング開始 |
| `pin` | 📱→PC | `pin` | PIN確認 |
| `auth_ok` | PC→📱 | `device_secret` | ペアリング完了・秘密鍵発行 |
| `resume` | 📱→PC | `device_id`, `device_secret` | 2回目以降の自動接続 |
| `auth_ng` | PC→📱 | `reason` | 認証失敗 |

### 入力（低頻度）

| type | 方向 | フィールド | 説明 |
|------|------|-----------|------|
| `click` | 📱→PC | `button` (left/right/middle), `action` (down/up/tap/double) | クリック |
| `key` | 📱→PC | `vk` (仮想キーコード), `modifiers` [ctrl,alt,shift,win], `action` (down/up/tap) | キー入力 |
| `text` | 📱→PC | `text` | IME経由テキスト（SendInput UNICODE） |
| `shortcut` | 📱→PC | `keys` (例 ["ctrl","shift","esc"]) | ショートカット一括。キー名は a-z / 0-9 / f1-f24 / win,ctrl,shift,alt / esc,enter,tab,space,backspace,delete,prtsc / up,down,left,right / home,end,pageup,pagedown,insert,apps / volup,voldown,mute,playpause,nexttrack,prevtrack / plus,minus,period,comma / kanji |
| `launch` | 📱→PC | `target` | exe・URL・フォルダをShellExecuteで起動 |
| `screenshot` | 📱→PC | なし | PC全画面キャプチャの要求 |
| `screenshot_result` | PC→📱 | `jpeg` (base64) | キャプチャ結果 |
| `screenshot_error` | PC→📱 | なし | キャプチャ失敗 |
| `macro` | 📱→PC | `steps` [{type: shortcut/text/launch/delay, ...}] | ステップを順次実行。delayは `ms` |
| `power` | 📱→PC | `action` (sleep/shutdown/restart) | PC電源操作。スマホ側で確認ダイアログを挟むこと |
| `claude_notify` | PC→📱 | `event` (stop/notification), `message` | Claude Codeフック(Stop/Notification)発火の通知。`POST /api/claude-notify`経由でPCが受け取り中継する |
| `claude_activity` | PC→📱 | `tool` (Bash/Edit/Read/...等のツール名), `detail` (ファイル名/コマンド等の短い対象、空文字あり) | Claude Codeフック(PreToolUse)発火のツール活動通知。`POST /api/claude-activity`経由でPCが受け取り中継する。「AI社員」ページのアバターがこれで反応する |

### 状態

| type | 方向 | フィールド | 説明 |
|------|------|-----------|------|
| `ping` / `pong` | 双方向 | `ts` | 死活監視（5秒間隔）。スマホはpongが12秒途絶えたら死に接続とみなして切断→再接続する |

### 設定同期

設定の正はPC側 `%APPDATA%\PocketPad\settings.json`。競合は Last-write-wins。
同期はスマホ主導で始める（authよりあとにスマホがlistenを張るため、PC自発だと取りこぼす）。

| type | 方向 | フィールド | 説明 |
|------|------|-----------|------|
| `config_get` | 📱→PC | なし | 接続直後に送る。PCは保存があれば `config`、なければ `config_request` を返す |
| `config` | PC→📱 | `settings` | 設定の配信（config_get応答／ダッシュボード編集時のプッシュ）。スマホは適用+永続化し、エコーバックしない |
| `config_request` | PC→📱 | なし | PC未保存時にスマホの現在設定を要求（初回シード） |
| `config_set` | 📱→PC | `settings` | スマホの現在設定。PCは保存のみ（返信・プッシュなし） |

`settings` スキーマ（スマホ側 `AppSettings.toJson()` と同一）:

```json
{
  "v": 1,
  "sensitivity": 1.4,
  "pages":         [{"id": "trackpad|macro|youtube", "enabled": true}, ...],
  "bottomButtons": [{"id": "enter|backspace|keyboard|alttab|win|mic", "enabled": true}, ...],
  "deck": [{"label": "コピー", "icon": "copy", "color": 4278251519,
            "message": {"type": "shortcut", "keys": ["ctrl","c"]}}, ...],
  "invertScroll": false
}
```

`icon` はアイコンカタログのキー名（app/lib/settings.dart の kIconCatalog）、`color` はARGB32のint。

## HTTP（設定ダッシュボード）

PC側Kestrel（ポート9013）が配信。**localhost以外からのアクセスは403**（/ws はLAN可）。

| メソッド/パス | 説明 |
|------|------|
| `GET /` | ダッシュボードHTML（トレイメニュー「設定ダッシュボードを開く」から起動） |
| `GET /api/config` | 保存済み設定JSON。未保存なら404 |
| `PUT /api/config` | 設定を検証して保存し、接続中のスマホへ `config` をプッシュ。応答 `{ok, pushed}` |
| `GET /api/status` | `{connected: bool}` スマホ接続状態 |
| `POST /api/claude-notify` | Claude Codeフックスクリプトからの通知中継用。body `{event, message}` → 接続中スマホへ`claude_notify`をプッシュ。応答 `{ok, pushed}` |
| `POST /api/claude-activity` | Claude CodeのPreToolUseフックからのツール活動中継用。body `{tool, detail}` → 接続中スマホへ`claude_activity`をプッシュ。応答 `{ok, pushed}` |

## バイナリフレーム（高頻度入力）

リトルエンディアン。クライアント側で集約して送信する（**mouse_move=8ms、scroll=40ms間隔**。スクロールを8msで送ると毎秒最大125発のホイールイベントになり、重いページではブラウザが追いつかない）。

| byte 0 | 内容 | ペイロード | 合計 |
|--------|------|-----------|------|
| `0x01` | mouse_move | int16 dx, int16 dy（相対移動量） | 5 bytes |
| `0x02` | scroll | int16 delta_v, int16 delta_h | 5 bytes |

## セキュリティ（Phase1）

- LAN内のみ（外部公開なし）
- pairing_token はQR表示ごとにランダム生成・5分で失効
- device_secret は 256bit ランダム。PC側はSQLiteに、スマホ側は flutter_secure_storage に保存
- TLSはPhase1では見送り（LAN内・自己署名証明書の複雑さ回避）。Phase2でQRに公開鍵フィンガープリントを含めるピン留め方式を検討
