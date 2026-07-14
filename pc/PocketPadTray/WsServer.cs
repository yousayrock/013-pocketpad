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

    /// <summary>認証済みのスマホ接続（1台想定）。ダッシュボードからの設定プッシュに使う。</summary>
    private volatile WebSocket? _client;

    /// <summary>同一ソケットへの並行SendAsync防止（受信ループ応答とダッシュボード起点のプッシュ）。</summary>
    private readonly SemaphoreSlim _sendLock = new(1, 1);

    public bool ClientConnected => _client is { State: WebSocketState.Open };

    public WsServer(int port) => Port = port;

    public void Start()
    {
        var builder = WebApplication.CreateBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseKestrel(o => o.ListenAnyIP(Port));
        _app = builder.Build();
        _app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = TimeSpan.FromSeconds(15) });
        _app.Map("/ws", HandleAsync);
        MapDashboard(_app);
        _ = _app.RunAsync();
    }

    // ─────────────────────────── 設定ダッシュボード（HTTP、localhost限定）

    private void MapDashboard(WebApplication app)
    {
        app.MapGet("/", async ctx =>
        {
            if (Reject(ctx)) return;
            ctx.Response.ContentType = "text/html; charset=utf-8";
            await ctx.Response.WriteAsync(LoadDashboardHtml());
        });

        app.MapGet("/api/config", async ctx =>
        {
            if (Reject(ctx)) return;
            var json = SettingsStore.Load();
            if (json is null) { ctx.Response.StatusCode = 404; return; }
            ctx.Response.ContentType = "application/json; charset=utf-8";
            await ctx.Response.WriteAsync(json);
        });

        app.MapPut("/api/config", async ctx =>
        {
            if (Reject(ctx)) return;
            using var ms = new MemoryStream();
            await ctx.Request.Body.CopyToAsync(ms);
            if (ms.Length > 512 * 1024) { ctx.Response.StatusCode = 413; return; }
            try
            {
                using var doc = JsonDocument.Parse(ms.ToArray());
                if (!SettingsStore.TryValidate(doc.RootElement, out var error))
                {
                    ctx.Response.StatusCode = 400;
                    await ctx.Response.WriteAsync(error);
                    return;
                }
                SettingsStore.Save(doc.RootElement);
                var pushed = await PushConfigAsync(doc.RootElement.GetRawText());
                ctx.Response.ContentType = "application/json";
                await ctx.Response.WriteAsync(JsonSerializer.Serialize(new { ok = true, pushed }));
            }
            catch (JsonException)
            {
                ctx.Response.StatusCode = 400;
                await ctx.Response.WriteAsync("invalid json");
            }
        });

        app.MapGet("/api/status", async ctx =>
        {
            if (Reject(ctx)) return;
            ctx.Response.ContentType = "application/json";
            await ctx.Response.WriteAsync(JsonSerializer.Serialize(new { connected = ClientConnected }));
        });
    }

    /// <summary>ダッシュボード/APIはlocalhostからのみ。LAN内の他端末には見せない。</summary>
    private static bool Reject(HttpContext ctx)
    {
        if (ctx.Connection.RemoteIpAddress is { } ip && System.Net.IPAddress.IsLoopback(ip))
            return false;
        ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
        return true;
    }

    /// <summary>ダッシュボードHTML。DEBUG時はソースのdashboard.htmlを毎回読む（編集→F5で反映）。</summary>
    private static string LoadDashboardHtml()
    {
#if DEBUG
        var src = Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "dashboard.html");
        if (File.Exists(src)) return File.ReadAllText(src);
#endif
        using var stream = System.Reflection.Assembly.GetExecutingAssembly()
            .GetManifestResourceStream("PocketPadTray.dashboard.html");
        if (stream is null) return "<h1>dashboard.html not embedded</h1>";
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    /// <summary>接続中のスマホへ設定をプッシュ。未接続・送信失敗は false。</summary>
    public async Task<bool> PushConfigAsync(string settingsJson)
    {
        var ws = _client;
        if (ws is not { State: WebSocketState.Open }) return false;
        try
        {
            await SendTextAsync(ws, "{\"type\":\"config\",\"settings\":" + settingsJson + "}");
            return true;
        }
        catch (Exception)
        {
            return false;
        }
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
        finally
        {
            // この接続が「現在の認証済みクライアント」なら参照を外す。
            // 新しい接続に置き換わった後に旧接続が切れたケースでは消さない。
            if (ReferenceEquals(_client, ws)) _client = null;
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

        // デバッグ用受信ログ（pingと、設定全文を含んで巨大になるconfig_setは除く）
        if (type is not ("ping" or "config_set"))
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
                _client = ws; // 設定プッシュ用に保持（1台想定、新しい接続が常に勝つ）
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
                RunShortcut(ReadStringArray(root, "keys"));
                break;

            case "launch":
                LaunchApp(root.GetProperty("target").GetString() ?? "");
                break;

            case "screenshot":
                // 全画面をキャプチャしてスマホへ返す（スマホ側で表示・保存できる）
                try
                {
                    var jpeg = ScreenCapture.CaptureJpegBase64();
                    await SendJsonAsync(ws, new { type = "screenshot_result", jpeg });
                }
                catch (Exception)
                {
                    await SendJsonAsync(ws, new { type = "screenshot_error" });
                }
                break;

            case "macro":
                // steps: [{type:"shortcut",keys:[...]}, {type:"text",text:"..."}, {type:"delay",ms:200}, ...]
                if (root.TryGetProperty("steps", out var steps) && steps.ValueKind == JsonValueKind.Array)
                {
                    await RunMacroAsync(steps);
                }
                break;

            case "config_get":
                // 設定同期（スマホ主導）。PCに保存があれば配り、なければスマホの現在設定を要求する
                var saved = SettingsStore.Load();
                if (saved is not null)
                {
                    await SendTextAsync(ws, "{\"type\":\"config\",\"settings\":" + saved + "}");
                }
                else
                {
                    await SendJsonAsync(ws, new { type = "config_request" });
                }
                break;

            case "config_set":
                // スマホの設定をPCへ保存（初回シード／スマホ側での変更）。返信もプッシュもしない
                if (root.TryGetProperty("settings", out var incoming)
                    && SettingsStore.TryValidate(incoming, out _))
                {
                    SettingsStore.Save(incoming);
                }
                break;

            case "power":
                // スマホ側で確認ダイアログを挟んでから送られてくる
                RunPowerAction(root.TryGetProperty("action", out var pa) ? pa.GetString() ?? "" : "");
                break;
        }
        return authed;
    }

    private static void RunPowerAction(string action)
    {
        try
        {
            switch (action)
            {
                case "sleep":
                    SetSuspendState(false, false, false);
                    break;
                case "shutdown":
                    System.Diagnostics.Process.Start("shutdown", "/s /t 0");
                    break;
                case "restart":
                    System.Diagnostics.Process.Start("shutdown", "/r /t 0");
                    break;
            }
        }
        catch (Exception)
        {
            // 電源操作の失敗でサーバーを落とさない
        }
    }

    [System.Runtime.InteropServices.DllImport("powrprof.dll", SetLastError = true)]
    private static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);

    private static void RunShortcut(string[] keys)
    {
        if (keys.Length == 0) return;
        var vk = VkFromName(keys[^1]);
        if (vk != 0) InputInjector.Shortcut(vk, keys[..^1]);
    }

    /// <summary>アプリ/URL/ファイルを起動。ShellExecuteで.exe・URL・フォルダ何でも開ける。</summary>
    private static void LaunchApp(string target)
    {
        if (string.IsNullOrWhiteSpace(target)) return;
        try
        {
            System.Diagnostics.Process.Start(
                new System.Diagnostics.ProcessStartInfo(target) { UseShellExecute = true });
        }
        catch (Exception)
        {
            // 存在しないパス等は握りつぶす（PCを落とさない）
        }
    }

    private static async Task RunMacroAsync(JsonElement steps)
    {
        foreach (var step in steps.EnumerateArray())
        {
            var t = step.GetProperty("type").GetString();
            switch (t)
            {
                case "shortcut":
                    RunShortcut(ReadStringArray(step, "keys"));
                    break;
                case "text":
                    InputInjector.Text(step.GetProperty("text").GetString() ?? "");
                    break;
                case "launch":
                    LaunchApp(step.GetProperty("target").GetString() ?? "");
                    break;
                case "delay":
                    await Task.Delay(step.TryGetProperty("ms", out var ms) ? ms.GetInt32() : 100);
                    break;
            }
        }
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
        "prtsc" => 0x2C, // PrintScreen（全画面キャプチャ）
        "up" => 0x26,
        "down" => 0x28,
        "left" => 0x25,
        "right" => 0x27,
        "home" => 0x24,
        "end" => 0x23,
        "pageup" => 0x21,
        "pagedown" => 0x22,
        "insert" => 0x2D,
        "apps" => 0x5D, // アプリケーションキー（右クリックメニュー）
        // メディアキー（システム全体に効く。ブラウザ内jkl操作とは別物）
        "volup" => 0xAF,
        "voldown" => 0xAE,
        "mute" => 0xAD,
        "playpause" => 0xB3,
        "nexttrack" => 0xB0,
        "prevtrack" => 0xB1,
        // 記号（US/JP配列共通で使える主要どころ。ctrl+plus/minus のズーム用）
        "plus" => 0xBB,   // VK_OEM_PLUS
        "minus" => 0xBD,  // VK_OEM_MINUS
        "period" => 0xBE, // VK_OEM_PERIOD
        "comma" => 0xBC,  // VK_OEM_COMMA
        // 半角/全角（IME切替）。環境によりSendInputで効かない場合は 0xF3/0xF4 を試す
        "kanji" => 0x19,
        var s when s.Length == 1 && s[0] is >= 'a' and <= 'z' => (ushort)(s[0] - 'a' + 0x41),
        var s when s.Length == 1 && s[0] is >= '0' and <= '9' => (ushort)(s[0] - '0' + 0x30),
        var s when s.StartsWith('f') && int.TryParse(s[1..], out var f) && f is >= 1 and <= 24 => (ushort)(0x70 + f - 1),
        _ => (ushort)0,
    };

    private Task SendJsonAsync(WebSocket ws, object obj) =>
        SendTextAsync(ws, JsonSerializer.Serialize(obj));

    /// <summary>_sendLockで直列化して送信。受信ループの応答とダッシュボード起点の
    /// configプッシュが同じソケットに並行して SendAsync しないようにする。</summary>
    private async Task SendTextAsync(WebSocket ws, string json)
    {
        await _sendLock.WaitAsync();
        try
        {
            await ws.SendAsync(
                Encoding.UTF8.GetBytes(json),
                WebSocketMessageType.Text,
                endOfMessage: true,
                CancellationToken.None);
        }
        finally
        {
            _sendLock.Release();
        }
    }
}
