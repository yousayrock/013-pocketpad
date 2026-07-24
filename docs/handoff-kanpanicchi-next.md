# 引き継ぎ: かんぱにっち 次回作業メモ

> 2026-07-24 のセッション終了時点の引き継ぎ。追記: 同日午後、トレイの多重起動バグを
> 修正済み（コミット a2db33a — 名前付きMutexで単一インスタンス化、起動時に古い
> インスタンスを自動Kill、ポート9013のbind失敗をエラーダイアログ化、tooltipに
> ビルド日時表示）。古い世代のexe（bin/Release/.../win-x64, publish）は削除済み。実装済みの全体像は `docs/protocol.md` と
> 本ドキュメント末尾の「今回やったこと」を参照。リモート化の大型仕様は
> `docs/spec-remote-kanpanicchi.md`（クロ作・別立て）にあり、本メモとは独立。

## 次回やること（優先順）

### 1. レベルアップの演出・作り込み（未着手）
ユーザー要望「レベルが上がったらどうなるとか、作り込みたい！みんながいつまでも遊べるゲームにしたい！」
- 現状: Lv5/10/20 でスプライトに ネクタイ/バッジ/王冠 が付く（`_tieredSprite`）＋ LEVEL UP! バナーのみ。
- 案: レベル帯ごとのアンロック要素（新しい部屋・家具・アニメーション）、レベルアップ時の
  紙吹雪などの演出強化、役職ごとの給料日イベント等。バナーは `_LevelUpBanner`
  （自己完結OverlayEntry方式）を拡張する。

### 2. キャラと部屋カードの重なり（軽微・見た目）
会議室（右下）にいる時、スプライトが部屋カードに少し重なる。
`kanpanicchi.dart` の AnimatedAlign 内 `Transform.translate`（dx=±46, dy=±30）は
Align の子サイズ差の影響を受けるため、部屋ごとに個別オフセットにするのが確実。

### 3. 下半分タブの初期表示が「実況」になることがある（軽微・要調査）
`_bottomTab = 0`（TODO）が初期値のはずが、アプリ再起動直後に実況側が
表示されていたことが1回あった。再現条件未特定。`_bottomTab` は未永続化。

### 4. Haiku実況の運用改善
- 実況は**ツール呼び出し1回ごとにHaiku APIを1回**叩く（PC側 `GenerateHaikuCommentaryAsync`）。
  コストは軽微だが、設定でON/OFFできるようにすると安心（トレイメニュー or ダッシュボード）。
- 実況ログ（`_commentLog`、最大30件）はアプリ内メモリのみ。再起動で消える。
  TODOと同じくPC側で覚えて `_get` で復元する手もある。
- APIキーはユーザー環境変数 `ANTHROPIC_API_KEY`（プロセス→User→Machine の順でフォールバック読込）。

### 5. クロの仕様書（docs/spec-remote-kanpanicchi.md）
Cloudflare Tunnelでのリモート化（Phase1）→ FCMプッシュ（Phase2）→ 資料室ナレッジ化（Phase3）。
**注意: 仕様書内の行番号は commit 08e929f 時点のもので、今回の改修で大きくズレている。**
特に「資料室ナレッジ化」のHaiku要約は、今回入れたHaiku実況とは別物（あちらはセッション終了時の
まとめ生成）。実装時は今回の `GenerateHaikuCommentaryAsync` / `PushClaudeActivityCommentaryAsync`
のパターンが流用できる。

## 既知の注意点
- **PocketPadTrayは管理者権限常駐**。再ビルド反映には UAC 承認つきの停止→起動が必要。
- **実機xs17proはWi-Fi adb**（ワイヤレスデバッグ、ポート可変、画面スリープで切断される）。
- 一部端末（MediaTek系GPU）の描画崩れ対策として **Impeller無効化**（AndroidManifest）＋
  オフィスパネルの `RepaintBoundary` を入れてある。外す時は実機で要確認。
- 切断時のクラッシュ（`_dependents.isEmpty`）は `_disconnected()` の
  `popUntil(isFirst)` で修正済み。切断系をいじる時はシート/ダイアログを開いたまま
  切断するテストを必ずすること。
- `file_picker` は KGP警告が出るが動作OK（v10系、compileSdk 36要求のためv8から更新済み）。

## 今回やったこと（2026-07-24）
- 音声入力: 認識エラー時に結果が消えるバグ修正（コミット 6e7249f）
- LP作成・公開: https://yousayrock.github.io/013-pocketpad/ （トロピカルデイ配色）
- 「AI社員」→「かんぱにっち」全面改修: XP/レベル/役職、スプライト進化、部屋カード、
  レベルアップバナー、プレイヤーステータス→TODOリスト表示、名前カスタム（4文字制限、
  デフォルト「かんぱに」）、部屋タップ詳細（平易な言葉＋具体的な対象）、
  サーバー室からのファイル転送（→ PC `Downloads\PocketPad`）
- Haiku実況: PC側でツール活動をClaude Haikuに渡して一言実況を生成→
  `claude_activity_comment` で中継→下半分の実況タブに時系列表示（TODOとタップ切替）
- TODO同期のスマホ主導pull化（`claude_todos_get`、接続直後の取りこぼし対策）
- 描画崩れ（ゴースト）対策: Impeller無効化 + RepaintBoundary
- 切断時クラッシュ修正（popUntil）
