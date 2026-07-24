# 仕様書: PocketPad リモート化 ＋ かんぱにっち遠隔モニター ＆ 資料庫ナレッジ化

> **この文書の目的**: 別のエージェント／実装者（クロコ）が単体で実装に着手できるハンドオフ仕様書。
> 現状コードの該当箇所・追加するメッセージ形式・prefsキー・UI・PC側ハンドラ・検証手順まで具体化する。
> 行番号は執筆時点（コミット `08e929f` 付近）の目安。**着手前に実際の該当箇所を必ず確認**すること。

---

## 0. 背景とゴール

PocketPad はスマホアプリ（`app/`）が同一LAN内のWindows PCトレイサーバー（`pc/PocketPadTray/`）へ
`ws://<LAN-IP>:9013/ws` で平文接続する構成。外出先からは使えない。

**ゴール**: 外出先（携帯回線）から Claude Code の作業を「かんぱにっち」（office ページ）で見守り、
必要時だけ介入できる遠隔モニターにする。さらに、かんぱにっちの**資料室**を
「作業日誌が溜まり、AIが要約してナレッジ化する場所」にする。

**接続方式**: Cloudflare Tunnel（cloudflared）。PCから外向きに接続を張るため、ポート開放・固定IP不要で、
本環境の **IPv6オンリー / CGNAT 回線でもそのまま通る**。Cloudflare がTLSを終端するので公開URLは必ず
`wss://<ホスト名>/ws`（443）になる。

**確定した設計方針（ユーザー承認済み）**
| 項目 | 決定 |
|---|---|
| 接続 | Cloudflare Tunnel（無料プラン＋独自ドメイン）で固定URL |
| 認証 | 既存ペアリングトークンのまま（8文字hex。露出リスクは承知の上・今回強化しない） |
| アプリ改修 | wss手入力ベース ＋ LAN/リモート切替・ステータスバッジ・履歴 |
| 通知 | FCMプッシュ（アプリを閉じていても承認待ちに気づける） |
| 資料庫 | PC側で生ログ蓄積＋Claude API（Haiku中心）で要約しpush |
| ナレッジ出力先 | PCにMarkdown保存 ＋ かんぱにっち資料室に表示（**Notionは記録しない**） |

実装は **3フェーズ**に分割。各フェーズ単体で価値が出る。**Phase 1 から順に**進めること。

---

## 1. 現状アーキテクチャ（変更の土台）

### PC側 `pc/PocketPadTray/`
- `WsServer.cs`
  - Kestrel が `0.0.0.0:9013`（全インターフェース）で待受: `builder.WebHost.UseKestrel(o => o.ListenAnyIP(Port))`（`:64`）。
  - `UseWebSockets`（KeepAliveInterval 15s, `:66`）。`/ws` を `HandleAsync` にマップ（`:67`）。
  - **平文 `ws://`／`http://` のみ。TLSなし。**
  - ダッシュボード/HTTP API（`/`, `/api/config`, `/api/status`, `/api/claude-activity`, `/api/claude-notify`）は
    `Reject(ctx)` で **loopback限定**（非ローカルは403, `:237-243`）。
  - `/ws` の認証: `{"type":"auth","token":...}` を `PairingToken` と文字列比較→ `auth_ok`（`:420-432`）。
    トークンは8文字hexで `%APPDATA%\PocketPad\pairing_token.txt` に平文保存（`:26-40`）。
  - PC→アプリ push メソッド:
    - `PushClaudeNotifyAsync`（`:276-289`）→ `{"type":"claude_notify","event":"stop|notification","message":...}`
    - `PushClaudeActivityAsync`（`:292-305`）→ `{"type":"claude_activity","tool":..,"detail":..}`
    - `PushClaudeTodosAsync`（`:308-321`）→ `{"type":"claude_todos","todos":[{content,status,activeForm}]}`
    - いずれも接続中クライアントが無ければ no-op。
  - 活動データの発生源: `app.MapPost("/api/claude-activity", ...)`（`:157-183`）が Claude Code フックのJSONを受け、
    `ExtractActivityDetail`（`:186-209`）で40字要約→ `PushClaudeActivityAsync`。
    `tool_name == "TodoWrite"` のとき `ExtractTodos`（`:211-234`）→ `PushClaudeTodosAsync`。
  - ファイル受信: `file_transfer` ハンドラ（`:524-545`）→ `%USERPROFILE%\Downloads\PocketPad` に保存、
    `{"type":"file_transfer_result","ok":..,"filename":..}` を返す。
- `Program.cs`: `new WsServer(port: 9013)`（`:12`）。トレイ左クリック/メニュー/`--qr` でQR表示。
- `QrForm.cs`: QRペイロード `PP|{ip}|{server.Port}|{server.PairingToken}`（`:28`）。
  `ip` は `PrimaryIPv4()`（`:102-116`、UDPソケットで送信元IP判定）。

### アプリ側 `app/lib/`
- `main.dart`
  - `ConnectScreen`（`:54-`）— state `_host`,`_token`,`_busy`,`_showManual`,`_status`,`_autoRetry`（`:61-67`）。
    initStateでprefsキー `'host'`,`'token'` を読み、両方あれば `_autoConnect()`、無ければ `_scanQr()`（`:72-85`）。
  - `_autoConnect()`（`:91-110`）— 成功するまで2秒間隔でリトライ。
  - `_tryConnect(host, token, timeout, {auto})`（`:114-161`）— **接続URLは `ws://$host:9013/ws` 固定（`:121`）**。
    auth送信（`:125-132`）→ `auth_ok` 判定（`:139`）→ prefs `'host'`,`'token'` 保存（`:148-150`）→
    `TrackpadScreen(channel, stream)` へ `pushReplacement`（`:152-156`）。
  - `_connect()`（`:163-172`）手動、`_scanQr()`（`:175-197`）— QR `PP|IP|PORT|TOKEN` を分割、
    `host=parts[1]`,`token=parts[3]`（**PORT=parts[2]は現状無視**）。
  - `ScanScreen`（`:362-438`）— `mobile_scanner`。
  - `TrackpadScreen`（`:442-450`）— コンストラクタ引数は `channel`,`stream` のみ（**接続種別を持っていない**）。
  - `_TrackpadScreenState`（`:456-`）— `_lastClaudeActivity`（`:484`）,`_lastClaudeNotifyEvent`（`:485`）,
    `_lastTodos`（`:486`）。受信 `_onMessage`（`:534-613`）で
    `claude_notify`（`:575-592`）/ `claude_activity`（`:593-596`）/ `claude_todos`（`:597-601`）を反映。
    `_disconnected()`（`:639-644`）は `ConnectScreen` へ戻す（自動再接続が走る）。
  - `_buildPage('office')`（`:879-893`）で `KanpanicchiPanel` を構築し
    `latestActivity/latestNotify/todos` と各コールバックを渡す。
- `kanpanicchi.dart`
  - `KanpanicchiPanel`（`:672-697`）— 引数 `latestActivity,latestNotify,todos,onMove,onScroll,onClick,onShortcut,onSendFile`。
  - ゾーン定義 `_zoneEditing/_zoneCommand/_zoneSearching(資料室)/_zoneDelegating/_zoneIdle`（`:66-89`）。
  - `didUpdateWidget` で3プロップの差分を検知して `_onActivity`（`:1011`）/`_onNotify`（`:1022`）/todos反映。
  - `build`（`:1056-`）: 上半分=オフィス/トラックパッド、下半分=ステータス1行（`:1182-1194`）＋ `_TodoPanel`（`:1196`）。
  - 部屋タップ `_showRoomDetail(z)`（`:1123` から呼ぶ）。
- `settings.dart`: `kPageNames['office']=kCharacterName`、`kPageIcons['office']=Icons.pets`、`visiblePages` で表示制御。

---

## 2. Phase 1 — 外から動く（最短MVP）

### 1-A. PC: cloudflared セットアップ（コード変更なし・環境構築）

Kestrelは変更不要。cloudflared が `http://localhost:9013` に横流しするだけで WebSocket も通る（cloudflaredはWS upgrade対応）。

手順（PowerShell）:
1. `winget install --id Cloudflare.cloudflared`
2. `cloudflared tunnel login`（独自ドメインのゾーンを認可）
3. `cloudflared tunnel create pocketpad`（資格情報JSONが `%USERPROFILE%\.cloudflared\<ID>.json`）
4. `%USERPROFILE%\.cloudflared\config.yml` を作成:
   ```yaml
   tunnel: <TUNNEL-ID>
   credentials-file: C:\Users\SpaceFamilyCompany\.cloudflared\<TUNNEL-ID>.json
   ingress:
     - hostname: pocketpad.example.com   # 実ドメインに置換
       path: ^/ws$                        # ← /ws のみ公開（必須）
       service: http://localhost:9013
     - service: http_status:404
   ```
5. `cloudflared tunnel route dns pocketpad pocketpad.example.com`
6. 動作確認 `cloudflared tunnel run pocketpad`。常用は `cloudflared service install` でサービス化。

> **【重要・セキュリティ】** cloudflared は localhost から Kestrel へ繋ぐため、`Reject()` の loopback判定が
> **トンネル経由の通信を「ローカル」と誤認して通してしまう**。`/api/claude-activity` は活動データ注入口なので、
> ingress を `^/ws$` に限定してダッシュボード/APIの外部露出を断つこと。これは任意ではなく**必須**。

### 1-B. アプリ: wss / 任意ホスト対応（最小改修）

`app/lib/main.dart` の `_ConnectScreenState` にヘルパを追加し、`:121` を置換する。

```dart
/// ホスト欄の値からWebSocket URIを組み立てる。
///  - "ws://" / "wss://" で始まる → そのまま利用（末尾に /ws を補完）
///  - それ以外（素のIP/ホスト名） → 従来どおり ws://<host>:9013/ws（LAN用）
Uri _buildWsUri(String host) {
  final h = host.trim();
  if (h.startsWith('ws://') || h.startsWith('wss://')) {
    return Uri.parse(h.endsWith('/ws') ? h : '$h/ws');
  }
  return Uri.parse('ws://$h:9013/ws');
}
```
`:121` を次に変更:
```dart
final channel = WebSocketChannel.connect(_buildWsUri(host));
```
- 認証ハンドシェイク（`:125-142`）・受信ハンドラ（`:534-613`）はスキーム非依存で**変更不要**。
- 期待挙動: `192.168.1.10` → `ws://192.168.1.10:9013/ws`（既存維持）／
  `wss://pocketpad.example.com` → `wss://pocketpad.example.com/ws`。

### 1-C. アプリ: LAN/リモート プロファイル切替

**prefsキー**（既存 `'host'` から移行）:
- `profile_lan_host`（例 `192.168.1.10`）
- `profile_remote_host`（例 `wss://pocketpad.example.com`）
- `token`（共通・既存キー流用）
- 移行: 起動時 `profile_lan_host` が未設定かつ旧 `'host'` があれば `profile_lan_host` に移す。

**UI（`ConnectScreen` の手動入力エリア `:313-343` を拡張）**:
- セグメント/トグル「自宅LAN / 外出先」。
- LAN欄（IP）と リモート欄（`wss://...`）の2フィールド＋トークン欄。
- 「接続」ボタンは選択中プロファイルで接続。

**自動接続（`_autoConnect` `:91-110` を拡張）**:
- 候補リスト `[profile_lan_host, profile_remote_host]`（非空のみ）を**LAN優先**で順に `_tryConnect`。
- LAN成功→即遷移。LAN失敗（家の外＝圏外）→ リモートへフォールバック。
- ギガ節約: 家では素のIP接続（無料・低遅延）を優先する意図。

**接続種別の伝搬**: `_tryConnect` 内で、使った host が `wss://`/`ws://` 始まりなら `remote`、
それ以外は `lan` と判定し、`TrackpadScreen` に渡す（1-Dで使用）。

### 1-D. アプリ: 接続ステータスバッジ

- `TrackpadScreen` にコンストラクタ引数 `connKind`（`'lan'|'remote'`）を追加（`:442-450` を拡張）。
  `_tryConnect` の遷移時（`:152-156`）に渡す。
- `KanpanicchiPanel` に `connKind` を渡し（`:882-`）、画面隅（例: `build` `:1163-1174` のPositioned付近）に小さなピルを表示:
  - 🟢 LAN（接続中・LAN）／🟡 リモート（接続中・wss）
  - 🔴 切断は基本 `ConnectScreen` 側の表示で担保（`_disconnected` で即戻るため）。任意で `ConnectScreen` にも状態表示。
- 目的: リモート時に**データ消費している自覚**を持たせる。

### 1-E. アプリ: アクティビティ履歴ログ

- `_TrackpadScreenState` に `final List<ActivityLogEntry> _activityLog = []`（上限10、リングバッファ）を追加。
  `ActivityLogEntry` は `{DateTime ts, String tool, String detail}`。
- `claude_activity` 受信部（`:593-596`）で `_activityLog` に追記し、超過分を先頭から捨てる。`setState` 内で。
- `KanpanicchiPanel` に `activityLog` を渡し、かんぱにっち下部または資料室に時系列表示
  （既存 `_fmtTime` `:1053-1054` を再利用）。**Phase 3 の作業日誌の入口**にもなる。

---

## 3. Phase 2 — FCM プッシュ通知（閉じてても届く）

**目的**: アプリを閉じていても `claude_notify` の **stop（承認待ち）/notification** に気づく。タップで office ページ直行。

### アプリ側
- Firebase 準備: Firebaseプロジェクト作成→Androidアプリ登録→`google-services.json` を `app/android/app/` に配置。
  `pubspec.yaml` に `firebase_core` / `firebase_messaging` を追加。
  **※メモリ「PocketPadはNDK要求パッケージを避ける」に従い、追加後ビルドログでNDK/CMakeダウンロードの有無を確認**（ギガ節約が最優先）。
- 起動時（`main`）にFirebase初期化＋FCMデバイストークン取得＋通知権限リクエスト。
- WS認証成功後（`_tryConnect` `:139` 以降）に `{"type":"register_push","fcm_token":"<token>"}` をPCへ送信。
- 通知タップ時のルーティング: アプリ起動→ `TrackpadScreen` で `office` ページを選択状態にする
  （`_tab` を office のインデックスへ）。バックグラウンド/終了状態の両方を `FirebaseMessaging.onMessageOpenedApp`／
  `getInitialMessage` でハンドリング。

### PC側（`WsServer.cs`）
- `register_push` ハンドラを追加（auth済みメッセージ処理付近、`:434` 以降）。受け取ったFCMトークンを
  `%APPDATA%\PocketPad\fcm_token.txt` 等に保存。
- 通知送信: `PushClaudeNotifyAsync`（`:276`）で event が `stop`/`notification` のとき、FCM HTTP v1 API へ送信。
  - エンドポイント: `POST https://fcm.googleapis.com/v1/projects/<project-id>/messages:send`
  - 認証: **Firebaseサービスアカウントの鍵JSON**からOAuth2アクセストークンを取得（`https://www.googleapis.com/auth/firebase.messaging` スコープ）。
  - ペイロード: `notification.title/body` ＋ タップ遷移用 `data.route="office"`。
- **鍵管理**: サービスアカウントJSONはリポジトリにコミットしない。トレイ設定 or 環境変数で参照。
- activity 連打では通知しない（stop/notification のみ対象、うるささ・データ抑制）。

---

## 4. Phase 3 — 資料庫ナレッジシステム（資料室）

生ログ蓄積 → AI要約 → 2出力（Markdown / アプリ）。**PC側主導**。

### 3-A. PC: 生ログ蓄積（`WsServer.cs`）
- `POST /api/claude-activity`（`:157-183`）と notify 経路で、受信イベントを **JSONL追記**。
  - 保存先: `%APPDATA%\PocketPad\worklog\YYYY-MM-DD.jsonl`
  - 1行: `{"ts":ISO8601, "tool":.., "detail":.., "todos":[...]?, "notify":{event,message}?}`
- スマホ切断中も記録が継続する（アプリ非依存でPC側に貯まる）ことが重要。

### 3-B. PC: Claude API で要約
- トリガー: **セッション終了（notify event=stop）ごとに、そのセッション分を要約** ＋ **日次ダイジェスト**（日単位のまとめ）。
- Anthropic Messages API を C# から HTTP 直叩き。
  - モデル既定 **`claude-haiku-4-5`**（安価・高速）。大きなロールアップ時のみ `claude-sonnet-5`。
  - APIキー: 環境変数 `ANTHROPIC_API_KEY` またはトレイ設定（**リポジトリにコミットしない**）。
  - ※ モデルID・エンドポイント・パラメータは実装時に `claude-api` スキル／公式ドキュメントで最終確認。
- 出力テキスト2種:
  - **作業日誌**: 時系列の短い要約（何をした/何が起きたか）。
  - **ナレッジ要点**: 重複排除した学び・決定事項・詰まりどころ。

### 3-C. 出力先（2つ）
1. **Markdown保存**: `%APPDATA%\PocketPad\knowledge\YYYY-MM-DD.md`（アプリ無しでも読める）。
2. **アプリへ push**: 新メッセージ型を追加。
   - `WsServer.cs` に `PushClaudeKnowledgeAsync`（既存 push 群 `:276-321` に倣う）。
   - 形式: `{"type":"claude_knowledge","diary":["...","..."],"notes":["...","..."]}`
   - アプリ `_onMessage`（`:534-613`）に `claude_knowledge` 分岐を追加し、state に保持→ `KanpanicchiPanel` へ。
   - **要約だけ送る**ためデータ量が小さい（ギガ節約）。

> Notion連携は今回スコープ外（記録しない）。将来やる場合は C# から Notion REST 直叩き、
> または Claude Code のスケジュールルーティン経由で追加可能。

### 3-D. アプリ: 資料室UI（`kanpanicchi.dart`）
- 資料室ゾーン `_zoneSearching`（`:66-89`）の部屋詳細（`_showRoomDetail` `:1123`）または専用ビューにタブ2つ:
  - **作業日誌**: `claude_knowledge.diary`（＋ Phase 1-E の `_activityLog` を時系列で接続）。
  - **ナレッジ要点**: `claude_knowledge.notes` を箇条書き。
- 演出: キャラが資料室にいる時「日誌をまとめています」等（既存 `_activitySentence` 系 `:144-209` と同じ作法）。

---

## 5. 変更・追加ファイル一覧

| ファイル | 変更内容 | フェーズ |
|---|---|---|
| `%USERPROFILE%\.cloudflared\config.yml`（新規・PC環境） | tunnel/ingress（/ws限定） | 1-A |
| `app/lib/main.dart` | `_buildWsUri`／プロファイル切替＆フォールバック／`connKind`伝搬／`_activityLog`／FCM登録・通知遷移／`claude_knowledge`受信 | 1-B,1-C,1-D,1-E,2,3 |
| `app/lib/kanpanicchi.dart` | `connKind`バッジ／`activityLog`表示／資料室UI（日誌・ナレッジ） | 1-D,1-E,3-D |
| `app/pubspec.yaml`, `app/android/app/**` | `firebase_core`/`firebase_messaging`, `google-services.json` | 2 |
| `pc/PocketPadTray/WsServer.cs` | `register_push`＋FCM送信／JSONL蓄積／Claude API要約／Markdown出力／`PushClaudeKnowledgeAsync` | 2,3 |
| `pc/PocketPadTray/`（新規クラス） | 要約サービス（Claude APIクライアント）、FCMクライアント | 2,3 |

---

## 6. メッセージプロトコル追加まとめ

| 方向 | type | ペイロード | フェーズ |
|---|---|---|---|
| アプリ→PC | `register_push` | `{fcm_token}` | 2 |
| PC→アプリ | `claude_knowledge` | `{diary:[..], notes:[..]}` | 3 |

既存（変更なし・参考）: `auth`/`auth_ok`、`claude_activity`、`claude_todos`、`claude_notify`、
`file_transfer`/`file_transfer_result`、`config_get`/`config`/`config_set`/`config_request`、`ping`/`pong`。

---

## 7. 留意点

- **データ量（最優先）**: リモートは要約/notifyなど小さいJSON中心。トラックパッド/スクショ系ページは
  リモート時に自動無効化 or 警告を推奨。cloudflared/FCM の待受トラフィックは小さい。
- **トークン強度（今回未対応・承知）**: 8文字hex（約32bit）をURLごと外部露出する構成。URL漏洩時の総当り耐性が低い。
  将来 Cloudflare Access（無料Zero Trust）を `/ws` 前段に置くか、ペアリングトークンを長い乱数化すれば大幅に堅くなる。
- **WS維持**: Kestrel KeepAlive 15s（`WsServer.cs:66`）が Cloudflare のWSアイドルタイムアウトより短く、散発pushでも維持見込み。
- **鍵管理**: FCMサービスアカウントJSON、Anthropic APIキーはトレイ設定/env に保持し**コミットしない**。
- **NDK回避**: `firebase_messaging` 追加時、ビルドログでNDK/CMakeダウンロード有無を確認（メモリ参照）。

---

## 8. 検証（Verification）

### Phase 1
1. PC: `cloudflared tunnel run pocketpad` ＋ トレイ(9013)起動。
2. 別回線（Wi-Fiオフ＝携帯回線）から `wscat -c wss://pocketpad.example.com/ws` が繋がり、
   `{"type":"auth","token":"<PairingToken>"}` 送信で `{"type":"auth_ok",...}` が返る。
3. 実機（メモリ: xs17pro / Wi-Fi adb）に改修版アプリを投入。携帯回線で
   リモート欄 `wss://pocketpad.example.com` ＋トークンで接続 → office ページで activity/todos/notify が反映。
4. **セキュリティ**: 外部から `https://pocketpad.example.com/` や `/api/claude-activity` が **404** で弾かれる。
5. LAN回帰: 同一Wi-Fiで素のIP接続が壊れていない。プロファイル切替＆バッジ（🟢/🟡）表示を確認。
6. 履歴: activityが複数来た時、直近N件が時系列表示される。

### Phase 2
- アプリを**閉じた状態**で、PCで Claude Code を stop 到達させる → 端末にシステム通知が出る → タップで office ページへ遷移。

### Phase 3
- Claude Code を一定時間動かし、`%APPDATA%\PocketPad\worklog\*.jsonl` が蓄積 →
  要約が `knowledge\*.md` に出力・アプリ資料室に「作業日誌／ナレッジ要点」が表示される。
- スマホ切断中もログが途切れないことを確認。
