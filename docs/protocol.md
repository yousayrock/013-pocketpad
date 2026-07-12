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
| `shortcut` | 📱→PC | `keys` (例 ["ctrl","shift","esc"]) | ショートカット一括 |

### 状態

| type | 方向 | フィールド | 説明 |
|------|------|-----------|------|
| `ping` / `pong` | 双方向 | `ts` | 死活監視（5秒間隔） |
| `layout` | PC→📱 | `buttons` [] | FF11マクロパレット定義の配信 |

## バイナリフレーム（高頻度入力）

リトルエンディアン。クライアント側で **8ms間隔に集約**して送信する。

| byte 0 | 内容 | ペイロード | 合計 |
|--------|------|-----------|------|
| `0x01` | mouse_move | int16 dx, int16 dy（相対移動量） | 5 bytes |
| `0x02` | scroll | int16 delta_v, int16 delta_h | 5 bytes |

## セキュリティ（Phase1）

- LAN内のみ（外部公開なし）
- pairing_token はQR表示ごとにランダム生成・5分で失効
- device_secret は 256bit ランダム。PC側はSQLiteに、スマホ側は flutter_secure_storage に保存
- TLSはPhase1では見送り（LAN内・自己署名証明書の複雑さ回避）。Phase2でQRに公開鍵フィンガープリントを含めるピン留め方式を検討
