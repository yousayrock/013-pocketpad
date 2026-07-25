<#
  Claude Code の Stop/Notification フックから呼ばれる中継スクリプト。
  stdinでフックのJSONペイロードを受け取り、PocketPadTray（ローカル常駐アプリ）の
  POST /api/claude-notify へ転送する。PocketPadTrayが起動していない・PC上で
  何らかの理由で失敗しても、Claude Codeの動作を止めないよう常にexit 0で終える。
#>

$ErrorActionPreference = 'SilentlyContinue'

try {
    # [Console]::In は既定だとシステムのレガシーコードページ（日本語環境だとCP932等）
    # で読むため、Claude CodeがUTF-8で書いてくるフックのJSON（日本語の最終応答等を含む）
    # を稀に誤読して文字化けさせる（資料室のナレッジに文字化けが記録される不具合として発覚）。
    # 明示的にUTF-8として読み直す。
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $raw = [Console]::In.ReadToEnd()
    $payload = $raw | ConvertFrom-Json

    # notification_type（英語の内部名）はそのまま出さず日本語ラベルに変換する
    $typeLabels = @{
        'permission_prompt'  = '許可が必要です'
        'idle_prompt'        = '入力待ちです'
        'auth_success'       = '認証に成功しました'
        'elicitation_dialog' = '確認が必要です'
        'agent_needs_input'  = '入力が必要です'
    }

    $event = $payload.hook_event_name
    if ($event -eq 'Stop') {
        $message = $payload.last_assistant_message
        $fullMessage = $message
    } else {
        $label = $typeLabels[[string]$payload.notification_type]
        $detail = $payload.message
        if ($label -and $detail) { $message = "${label}: $detail" }
        elseif ($label) { $message = $label }
        else { $message = $detail }
    }
    # message/last_assistant_messageが空の場合のフォールバックも日本語にする
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = if ($event -eq 'Stop') { '応答が完了しました' } else { 'Claude Codeから通知があります' }
        if ($event -eq 'Stop') { $fullMessage = $message }
    }

    # 日誌用全文は、JSONで最悪1文字が\uXXXX（6バイト）に展開されても既存の64KB上限に
    # 十分収まるよう8000文字までにする（通知文・JSON項目分を含めても約50KB程度）。
    if ($event -eq 'Stop' -and $fullMessage.Length -gt 8000) {
        $fullMessage = $fullMessage.Substring(0, 8000) + '…'
    }

    # 通知本文が長すぎるとスマホ側の表示が崩れるので適度に切り詰める
    if ($message.Length -gt 300) { $message = $message.Substring(0, 300) + '…' }

    $body = @{
        event      = $event
        message    = $message
        session_id = $payload.session_id
        cwd        = $payload.cwd
    }
    # Notificationの通知文を日誌経路へ持ち込まないよう、全文はStopのときだけ送る。
    if ($event -eq 'Stop') { $body.full_message = $fullMessage }
    $body = $body | ConvertTo-Json -Compress

    Invoke-RestMethod -Uri 'http://localhost:9013/api/claude-notify' `
        -Method Post -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
        -TimeoutSec 2 | Out-Null
} catch {
    # PocketPadTray未起動・タイムアウト等はすべて握りつぶす
}

exit 0
