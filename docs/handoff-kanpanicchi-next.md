# 引き継ぎ: かんぱにっち 次回作業メモ

> 2026-07-25 のセッション終了時点の引き継ぎ。前回（2026-07-24分）の内容は本ドキュメント末尾
> 「前回までにやったこと（〜2026-07-24）」に圧縮して残す。今回の変更点は
> 「今回やったこと（2026-07-25）」を参照。コミットは `9d11737`（資料室ナレッジ機能・
> リモート化Part A・エラーログ追加）まで。それ以降のUI修正（キャラのサイズ調整、部屋間隔、
> レベルアップ描画バグ修正、name/exp表示の入れ替え等）は**未コミット**（`git status`で
> `app/lib/kanpanicchi.dart` / `app/lib/settings.dart` / `pc/scripts/claude-notify.ps1` が
> 変更中のはず）。

## 今回の大きな方針転換: Codex実装がデフォルトに

2026-07-25、`--dangerously-bypass-approvals-and-sandbox` でCodex CLIがWindows環境でも
実際にファイルを書けることを確認した（会議室まわりの部屋レイアウト修正、レベルアップ
描画バグ修正の2件で実証）。**ユーザーの意向により、このリポジトリでは「Codexが実装
（bypassで）→クロがレビュー」が標準の進め方になった。** 詳細手順は
`~/.claude/skills/codex-build-review/SKILL.md` の「既知の環境事情（Windows）」を参照。
要点: フォアグラウンド実行必須（バックグラウンドだとハーネス側の事情でkilledになることが
あった）、bypass前にgitクリーンな状態を確認、実装後は必ず`git diff`と`flutter analyze`を
クロ自身で確認する。

## 次回やること（優先順、現在のタスクリストと対応）

### 1. レベルアップの演出・作り込み（#11、未着手）
ユーザー要望「レベルが上がったらどうなるとか、作り込みたい！みんながいつまでも遊べる
ゲームにしたい！」
- 現状: Lv5/10/20 でスプライトに ネクタイ/バッジ/王冠 が付く（`_tieredSprite`）＋
  LEVEL UP! バナー（`_LevelUpBanner`、今回`RepaintBoundary`でラップ済み）。
- 案: レベル帯ごとのアンロック要素（新しい部屋・家具・アニメーション）、レベルアップ時の
  紙吹雪などの演出強化、役職ごとの給料日イベント等。

### 2. 下半分タブの初期表示バグ（#14、未着手・要調査）
`_bottomTab = 0`（TODO）が初期値のはずが、アプリ再起動直後に実況側が表示されていた
ことが1回あった。再現条件未特定。今回、TODO/実況の切り替えをボタンからスワイプ
（`PageView` + `_bottomPageController`）に変更したため、再現条件が変わっている
可能性がある。次に見る時は新しいスワイプ実装を前提に調査すること。

### 3. 実況ログの永続化（#15、未着手）
実況ログ（`_commentLog`、最大30件）はアプリ内メモリのみで再起動すると消える。
TODOやナレッジと同じ「PC側で覚えて`_get`で復元」パターンが流用できる
（`_lastTodos`／`KnowledgeStore`と同型）。

### 4. TODOパネルのフェーズ折り畳み・優先度表示（#23、対応済み 2026-07-25）
**subjectの先頭にプレフィックスを書く運用**で実現した。PC側のスキーマ変更は不要。

```
[phase:資料室/P1] ナレッジから実況履歴を外す   ← フェーズ＋優先度
[フェーズ:資料室/P2] タイトル                   ← 日本語表記も可
[phase:資料室] タイトル                         ← フェーズのみ（優先度なし＝中位）
[P1] タイトル                                   ← 優先度のみ（未分類グループ）
タイトル                                        ← 従来どおり（未分類・優先度なし）
```

- フェーズごとにグループ化され、見出しタップで折り畳める（完了件数も見出しに表示）。
- 優先度は P1（🔴最優先）/ P2（🟡）/ P3（⚪いつか）。**優先度なしはマーク無しでP2と同列**
  （既存タスクが下に沈まないための設計）。
- グループ内の並び順: 実行中 → P1 → P2・指定なし → P3 → 完了。
- プレフィックスは表示時にタスク名から除去される。
- 実装: `app/lib/kanpanicchi.dart` の `_TodoPanelState`（`_phasePrefix` の正規表現）。

### 5. 会議室(委任中ゾーン)の要否検討（#24、未着手）
会議室は`Task`ツール（サブエージェント委任）使用時のみ点灯する作りだが、直接実装
中心のワークスタイルだとほとんど使われない。チャトピにも意見を聞きながら、別の
部屋に置き換えるか検討する。

### 6. リモート化 Part A-1（インフラ構築、ユーザー側作業・未着手）
アプリ・PC側のコードは実装済み（後述）。cloudflared のインストール・トンネル作成・
Cloudflare Access アプリケーション設定（Service Token方式）はユーザー側の作業として
未実施。手順は本ドキュメントの旧版（このコミット履歴で遡れる）または
`docs/spec-remote-kanpanicchi.md` のPhase1相当を参照しつつ、実際にはPart Aの設計
（本ドキュメント末尾）に従うこと。

## 既知の注意点
- **PocketPadTrayは管理者権限常駐**。再ビルド反映には UAC 承認つきの停止→起動が必要。
  ビルド出力は `bin/Release/net8.0-windows/PocketPadTray.exe`（Windows起動時自動起動の
  登録先もこちら）。
- **実機テストはWi-Fi adb接続**（型番 "A25"、MediaTek系。旧メモの「xs17pro」と同一機体の
  可能性が高いが未確認）。ワイヤレスデバッグは接続が頻繁に切れる（`adb devices`で
  `offline`/`error: closed`になったら`adb connect <ip>:<port>`で再接続、それでもダメなら
  `adb kill-server && adb start-server`）。
- **`flutter build apk --debug`はバックグラウンド実行だと理由不明で`killed`になることが
  複数回あった。フォアグラウンド実行（`run_in_background`なし）の方が確実。**
- shared_preferencesを直接書き換えてテストする場合、`adb shell run-as <package> cp ...`は
  MSYS/Git Bashのパス変換で`/data/...`が壊れるため`MSYS_NO_PATHCONV=1`を必ず付ける。
- adbでの日本語混じりテキスト入力（`input text`）はGboardの予測変換でアルファベット単体が
  かな変換されて文字化けすることがある（例: `0245a432`の`a`が`あ`になる）。確実に入れたい
  時は`input keyevent`で1文字ずつ叩くか、SharedPreferences/設定ファイルを直接書き換える方が速い。
- 一部端末（MediaTek系GPU）の描画崩れ対策として **Impeller無効化**（AndroidManifest）＋
  `RepaintBoundary`を要所に入れてある（トラックパッドパネル、レベルアップバナー）。
  今後似た「前のフレームが残る」系のゴーストバグが出たら同じパターンで対処する。
- Haiku実況のAPIキーは`%APPDATA%\PocketPad\haiku_settings.json`（DPAPI暗号化）。
  User環境変数運用は誤課金インシデントを受けて廃止済み。
- **PowerShellのstdin読み取りエンコーディングに注意**（`claude-notify.ps1`で今回発覚）。
  `[Console]::In.ReadToEnd()`は既定でシステムのレガシーコードページを使うため、
  Claude CodeがUTF-8で渡す日本語（最終応答文など）を稀に誤読して文字化けさせる。
  修正済み（`[Console]::InputEncoding = [System.Text.Encoding]::UTF8`を先頭に追加）。
  同様にstdin/stdoutを扱うPowerShellスクリプトを新設する時は同じ対処を最初から入れること。

## 今回やったこと（2026-07-25）

### 資料室ナレッジ機能（軽量版、コミット済み）
- PC: `KnowledgeStore.cs`新設。ターン完了（stop）ごとに実際の最終応答をそのまま
  `%APPDATA%\PocketPad\knowledge.json`へ1件追記（新しいAI要約は行わない）。
  `toolsUsed`/`touchedFiles`（Edit/Write/NotebookEditのdetailから収集）/`commitHash`
  （git commit検出時best-effort）も同梱。
- PC: `claude_knowledge_get`（pull）/`claude_knowledge`（push、常に全件）をWsServerに追加。
- アプリ: `KnowledgeEntry`モデル、資料室の「ナレッジを見る」ボタン→プロジェクト×日付で
  グループ化した日誌一覧ページ（`_KnowledgeShelfPage`）。

### リモート化 Part A（アプリ側コードのみ、コミット済み。インフラ未構築）
- `IOWebSocketChannel.connect(uri, headers:)`でCloudflare Access用ヘッダー
  （`CF-Access-Client-Id`/`Secret`）付き接続に対応。
- 自宅LAN/外出先の接続プロファイル切替UI、`profile_lan_host`/`profile_remote_host`の
  prefsキー分離（旧`host`キーからの移行あり）。
- 接続種別バッジ（🟢LAN/🟡リモート、`ConnKind`enum）をオフィス画面隅に表示。

### タスク状態の永続化（コミット済み）
- `TaskStateStore.cs`新設。PC側トレイが複製しているTaskCreate/TaskUpdate状態を
  `%APPDATA%\PocketPad\task_state.json`へ永続化。トレイ再起動をまたいでTODO一覧を保つ
  （ただしトレイが一度も観測していないtaskIdはそもそも復元不能で「(不明なタスク)」表示になる、
  これは仕様上の制約）。

### エラーログ（コミット済み）
- PC: `ErrorLog.cs`新設。「おまけ機能なので失敗を握りつぶす」系のcatch節（Haiku実況・
  資料室記録）にログ出力を追加。`%APPDATA%\PocketPad\error.log`、トレイメニュー
  「エラーログを開く」から確認可能。`Program.cs`にAppDomain/ThreadExceptionの
  グローバルハンドラも追加。
- アプリ: `FlutterError.onError`/`PlatformDispatcher.instance.onError`でSharedPreferences
  （`error_log`キー、最大50件）に記録。新規パッケージは追加していない。

### UI修正（一部未コミット、実機確認済み）
- 名前が長い役職と同居して見切れる問題 → 一度バーの下に退避 → ユーザーフィードバックで
  「レベルは名前の横のままでよい、経験値の数字をバーの下に」に再修正（現在の形）。
- TODOパネル: 状態別ソート（実行中→未着手→完了）＋進捗バー・件数表示。
- TODO/実況ログの切替をボタンから横スワイプ（`PageView`）に変更。
- 会議室でキャラがタップを吸ってしまう問題 → キャラに`IgnorePointer`。
- **部屋カードとキャラクターの重なりバグ（実機で複数回発覚・修正）**: 真因はキャラの
  ドット絵サイズ（等倍だと約42px幅）が部屋カード間の隙間（実測約43px）とほぼ同じで、
  Alignmentの位置調整だけでは原理的に避けられなかったこと。`_PixelSprite`に
  `pixelSize`パラメータを追加してオフィス床では`3.5`（等倍は`6.0`のまま）に縮小、
  かつ部屋カード自体の`align.y`を`±0.6→±0.8`に広げて行間を確保（後者はCodex実装）。
  実機でピクセル計測して重なりが無いことを確認済み。
- レベルアップバナーの描画ゴースト対策として`_LevelUpBanner`を`RepaintBoundary`で
  ラップ（Codex実装、トラックパッドパネルと同じ対策パターン）。
- Haiku実況の直近履歴保持数を5→20に拡張。
- デフォルトの初期表示ページを「かんぱにっち(office)」に変更（`kPageNames`の並び順、
  および実機の`settings.json`を直接書き換えて反映済み）。

### 開発ツール
- `~/.claude/skills/codex-imagegen/SKILL.md`新設。Codex CLI（`$imagegen`スキル/
  GPT Image 2）を使ったUIモックアップ生成の手順（生成物のコピーがCodex自身の
  サンドボックスで拒否されるため、Claude側でコピーする回避策込み）。
  `docs/mockups/`にサンプル画像あり。

## 前回までにやったこと（〜2026-07-24、圧縮）
- 音声入力: 認識エラー時に結果が消えるバグ修正
- LP作成・公開: https://yousayrock.github.io/013-pocketpad/
- 「AI社員」→「かんぱにっち」全面改修（XP/レベル/役職、スプライト進化、部屋カード、
  レベルアップバナー、名前カスタム、部屋タップ詳細、サーバー室からのファイル転送）
- Haiku実況の導入（開始/途中経過/終了の3種、実際の最終応答ベースに再設計）
- TODO同期のスマホ主導pull化
- 描画崩れ（ゴースト）対策の初期版（Impeller無効化 + RepaintBoundary）
- 切断時クラッシュ修正（popUntil）
- トレイの多重起動防止（名前付きMutex、bind失敗のエラーダイアログ化）
- Haiku実況APIキーをUser環境変数からDPAPI暗号化ローカル設定へ移行（誤課金インシデント対応）
