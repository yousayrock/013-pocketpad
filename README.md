# PocketPad — 未来ガジェット013号

> **Your PC. In Your Pocket.**
> スマホがPCのトラックパッド・キーボード・リモコンになるアプリ。
> ゲーム中・ソファ・布団の中から、PCを瞬時に操作。

![Platform](https://img.shields.io/badge/PC-Windows%2010%2F11-blue)
![Platform](https://img.shields.io/badge/Phone-Android-green)
![License](https://img.shields.io/badge/license-MIT-brightgreen)

---

## 🎮 これは何？

Androidスマホから、同じWiFi内のWindows PCを操作できるアプリです。

- 📱 **トラックパッド** — スマホの画面をなぞるとPCのマウスが動く
- ⌨️ **日本語入力** — スマホで文章を書いてEnter一発でPCに送信（スマホのIMEで変換できるので速い）
- 🖱️ **クリック・スクロール** — タップ=左クリック / 長押し=右クリック / 右端の帯で上下スクロール
- 🎹 **ショートカット** — Esc・Enter・Alt+Tab・Winキーをワンタップ
- 🎮 **FF11プレイヤー向けに開発中** — マクロパレット機能を今後追加予定

## 🧰 必要なもの

| 機材 | 条件 |
|------|------|
| PC | Windows 10 / 11（64bit） |
| スマホ | Android 8 以上 |
| ネットワーク | PCとスマホが**同じWiFi**につながっていること |

インストール不要のもの：.NETランタイム（EXEに同梱）／サーバー／アカウント登録。**すべて無料・LAN内で完結、クラウドに何も送りません。**

## 🚀 かんたんセットアップ

### ① PC側（1分）

1. [Releases](../../releases) から `PocketPadTray.exe` をダウンロード
   （まだReleaseがない場合は下の「開発者向け」の手順でビルドしてください）
2. ダブルクリックで起動
3. Windowsファイアウォールのダイアログが出たら「**プライベートネットワーク**」にチェックして許可
4. 画面右下のタスクトレイに常駐します。アイコンを**右クリック →「接続情報を表示」** で、IPアドレスとペアリングトークンをメモ

> 💡 トレイアイコンを右クリック →「**Windows起動時に自動起動**」にチェックを入れると、PC起動時に自動で立ち上がります（もう一度クリックで解除）。

### ② スマホ側（1分）

1. [Releases](../../releases) から `app-release.apk` をダウンロードしてインストール
   （「提供元不明のアプリ」の許可が必要です）
2. アプリを開いて、①でメモした **IPアドレス** と **トークン** を入力
3. 「接続」をタップ → トラックパッド画面になれば成功！

> 💡 2回目からはIPとトークンが保存されているので「接続」を押すだけです。

## 📖 使い方

| 操作 | 動作 |
|------|------|
| 画面をなぞる | マウスカーソル移動 |
| タップ | 左クリック |
| ダブルタップ | ダブルクリック |
| 長押し | 右クリック |
| 右端の帯を上下 | スクロール |
| 下部ボタン | 左・中・右クリック / Esc / Enter / Alt+Tab / Win |

**テキスト入力：** 右上のキーボードアイコン → 入力欄に文章を書いて **Enterで一気にPCへ**（PC側のEnterも自動で押されます）。スマホの日本語変換がそのまま使えるので、PCの前にいなくても長文が快適に打てます。

## 🛠️ 開発者向け（ソースからビルド）

```bash
git clone https://github.com/yousayrock/013-pocketpad.git
cd 013-pocketpad
```

**PC側（要 .NET 8 SDK）**

```bash
cd pc/PocketPadTray
dotnet run                      # そのまま起動
# 配布用の単一EXE（.NET不要版）を作る場合：
dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true
```

**スマホ側（要 Flutter SDK）**

```bash
cd app
flutter pub get
flutter build apk --release    # APK作成
flutter run                     # USB接続した実機で直接起動
```

> ⚠️ IPv6オンリー回線（一部のモバイル回線・テザリング）でGradleがタイムアウトする場合は、環境変数 `GRADLE_OPTS=-Djava.net.preferIPv6Addresses=true` を設定してください。本リポジトリの `gradle.properties` には設定済みです。

## 🏗️ アーキテクチャ

```
┌──────────────────┐
│ Android          │  Flutter
│  PocketPad App   │
└────────┬─────────┘
         │ WebSocket :9013（LAN内のみ）
         │  テキストフレーム＝JSON制御
         │  バイナリフレーム＝マウス移動/スクロール（5バイト・8ms間引き）
┌────────▼─────────┐
│ Windows          │  .NET 8 常駐トレイアプリ
│  PocketPadTray   │  Kestrel WebSocket + SendInput（P/Invoke）
└──────────────────┘
```

プロトコルの詳細は [docs/protocol.md](docs/protocol.md) を参照。

## 🗺️ ロードマップ

- [x] **Phase1コア** トラックパッド / クリック / スクロール / ショートカット / 日本語一括入力
- [ ] FF11マクロパレット（ゲーム用カスタムボタン）
- [ ] QRコード接続（IP・トークンの手入力を撲滅）
- [ ] トラックパッド感度調整
- [x] PCスタートアップ登録（トレイ右クリック →「Windows起動時に自動起動」）
- [ ] マクロエディタ / プロファイル自動切替 / iPhone対応（Phase2以降）

> ⚠️ **アンチチート搭載ゲーム（Valorant / Apex等）では使用しないでください。** 合成入力が検出されアカウント制裁のリスクがあります。FF11・Minecraft等では問題ありません。

## 🚢 プロジェクトについて

[寳家プロジェクト](https://github.com/yousayrock) の未来ガジェット研究所 013号。
「まず自分の困り事を解決する。自分が使って解決できたものを外に展開する。」

## ライセンス / License

MIT License
