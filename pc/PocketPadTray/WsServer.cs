using System.Buffers.Binary;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace PocketPadTray;

/// <summary>
/// Kestrelベースの WebSocket サーバー（docs/protocol.md v1 準拠）。
/// テキストフレーム＝JSON制御、バイナリフレーム＝高頻度入力（0x01 mouse_move / 0x02 scroll）。
/// </summary>
class WsServer
{
    public int Port { get; }
    public string PairingToken { get; } = LoadOrCreateToken();

    /// <summary>スマホの認証成功時に発火。QRウィンドウの自動クローズなどに使う。</summary>
    public event Action? ClientAuthenticated;

    /// <summary>トークンを%APPDATA%\PocketPadに永続化。再起動しても同じトークンで再接続できる。</summary>
    private static string LoadOrCreateToken()
    {
        var dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PocketPad");
        var file = Path.Combine(dir, "pairing_token.txt");
        if (File.Exists(file))
        {
            var existing = File.ReadAllText(file).Trim();
            if (existing.Length > 0) return existing;
        }
        Directory.CreateDirectory(dir);
        var token = RandomNumberGenerator.GetHexString(8, lowercase: true);
        File.WriteAllText(file, token);
        return token;
    }

    private WebApplication? _app;

    public WsServer(int port) => Port = port;

    public void Start()
    {
        var builder = WebApplication.CreateBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseKestrel(o => o.ListenAnyIP(Port));
        _app = builder.Build();
        _app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = TimeSpan.FromSeconds(15) });
        _app.Map("/ws", HandleAsync);
        _ = _app.RunAsync();
    }

    private async Task HandleAsync(HttpContext ctx)
    {
        if (!ctx.WebSockets.IsWebSocketRequest)
        {
            ctx.Response.StatusCode = StatusCodes.Status400BadRequest;
            return;
        }

        using var ws = await ctx.WebSockets.AcceptWebSocketAsync();
        var authed = false;
        var buf = new byte[8192];
        var assembly = new MemoryStream(); // 分割フレームの組み立て用

        try
        {
            while (ws.State == WebSocketState.Open)
            {
                var r = await ws.ReceiveAsync(buf, CancellationToken.None);
                if (r.MessageType == WebSocketMessageType.Close) break;

                // 長いテキストは複数フレームに分割されて届くことがある。
                // EndOfMessageまで貯めてから処理しないとJSONが途中で切れる。
                assembly.Write(buf, 0, r.Count);
                if (!r.EndOfMessage) continue;

                var message = assembly.ToArray();
                assembly.SetLength(0);

                if (r.MessageType == WebSocketMessageType.Binary)
                {
                    if (authed) HandleBinary(message);
                    continue;
                }

                authed = await HandleJsonAsync(ws, message, authed);
            }
        }
        catch (WebSocketException)
        {
            // 切断は正常系として扱う（スマホのスリープ等）
        }
    }

    private static void HandleBinary(ReadOnlySpan<byte> s)
    {
        if (s.Length < 5) return;
        var a = BinaryPrimitives.ReadInt16LittleEndian(s[1..]);
        var b = BinaryPrimitives.ReadInt16LittleEndian(s[3..]);
        switch (s[0])
        {
            case 0x01: InputInjector.MouseMove(a, b); break;
            case 0x02: InputInjector.Scroll(a, b); break;
        }
    }

    private static readonly string LogFile = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PocketPad", "recv.log");

    /// <returns>処理後の認証状態</returns>
    private async Task<bool> HandleJsonAsync(WebSocket ws, ReadOnlyMemory<byte> payload, bool authed)
    {
        using var doc = JsonDocument.Parse(payload);
        var root = doc.RootElement;
        var type = root.GetProperty("type").GetString();

        // デバッグ用受信ログ（ping以外）
        if (type != "ping")
        {
            try
            {
                File.AppendAllText(
                    LogFile,
                    $"{DateTime.Now:HH:mm:ss.fff} {Encoding.UTF8.GetString(payload.Span)}\n");
            }
            catch (IOException)
            {
                // ログ失敗は無視（本処理を止めない）
            }
        }

        if (type == "ping")
        {
            await SendJsonAsync(ws, new { type = "pong", ts = root.TryGetProperty("ts", out var ts) ? ts.GetInt64() : 0 });
            return authed;
        }

        if (type == "auth")
        {
            // Phase1簡易版：トークン一致で認証。PIN確認とdevice_secret永続化はPhase1後半で実装。
            if (root.TryGetProperty("token", out var t) && t.GetString() == PairingToken)
            {
                await SendJsonAsync(ws, new { type = "auth_ok", device_secret = RandomNumberGenerator.GetHexString(64, lowercase: true) });
                ClientAuthenticated?.Invoke();
                return true;
            }
            await SendJsonAsync(ws, new { type = "auth_ng", reason = "invalid_token" });
            return false;
        }

        if (!authed) return false;

        switch (type)
        {
            case "click":
                InputInjector.Click(
                    root.GetProperty("button").GetString() ?? "left",
                    root.TryGetProperty("action", out var ca) ? ca.GetString() ?? "tap" : "tap");
                break;

            case "key":
                InputInjector.Key(
                    (ushort)root.GetProperty("vk").GetInt32(),
                    root.TryGetProperty("action", out var ka) ? ka.GetString() ?? "tap" : "tap",
                    ReadStringArray(root, "modifiers"));
                break;

            case "text":
                InputInjector.Text(root.GetProperty("text").GetString() ?? "");
                break;

            case "shortcut":
                var keys = ReadStringArray(root, "keys");
                if (keys.Length > 0)
                {
                    var vk = VkFromName(keys[^1]);
                    if (vk != 0) InputInjector.Shortcut(vk, keys[..^1]);
                }
                break;
        }
        return authed;
    }

    private static string[] ReadStringArray(JsonElement root, string name) =>
        root.TryGetProperty(name, out var el) && el.ValueKind == JsonValueKind.Array
            ? el.EnumerateArray().Select(e => e.GetString() ?? "").ToArray()
            : Array.Empty<string>();

    private static ushort VkFromName(string name) => name.ToLowerInvariant() switch
    {
        // 修飾キーも単独押しできるようにする（win単独=スタートメニュー等）
        "win" => 0x5B,
        "ctrl" => 0x11,
        "shift" => 0x10,
        "alt" => 0x12,
        "esc" => 0x1B,
        "enter" => 0x0D,
        "tab" => 0x09,
        "space" => 0x20,
        "backspace" => 0x08,
        "delete" => 0x2E,
        "up" => 0x26,
        "down" => 0x28,
        "left" => 0x25,
        "right" => 0x27,
        var s when s.Length == 1 && s[0] is >= 'a' and <= 'z' => (ushort)(s[0] - 'a' + 0x41),
        var s when s.Length == 1 && s[0] is >= '0' and <= '9' => (ushort)(s[0] - '0' + 0x30),
        var s when s.StartsWith('f') && int.TryParse(s[1..], out var f) && f is >= 1 and <= 24 => (ushort)(0x70 + f - 1),
        _ => (ushort)0,
    };

    private static Task SendJsonAsync(WebSocket ws, object obj) =>
        ws.SendAsync(
            Encoding.UTF8.GetBytes(JsonSerializer.Serialize(obj)),
            WebSocketMessageType.Text,
            endOfMessage: true,
            CancellationToken.None);
}
