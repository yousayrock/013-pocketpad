using System.Buffers.Binary;
using System.Net.Http;
using System.Net.Http.Headers;
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
    private volatile Conn? _client;

    /// <summary>1接続分の状態。送信ロックはソケット単位に持つ。全接続で共有すると、
    /// 死んだ接続への送信詰まりがロックを握ったまま、再接続してきた新しいソケットへの
    /// auth_ok送信まで道連れにしてしまう（トレイ再起動まで復旧不能になる）。</summary>
    private sealed class Conn(WebSocket ws)
    {
        public WebSocket Ws { get; } = ws;
        public SemaphoreSlim SendLock { get; } = new(1, 1);
    }

    public bool ClientConnected => _client is { Ws.State: WebSocketState.Open };

    /// <summary>直近のTodoWrite内容（プロセス生存中のみ保持）。スマホ再起動/再接続
    /// 直後にも最新のTODOをすぐ見せられるよう、authタイミングで自動配信する。</summary>
    private volatile List<object>? _lastTodos;

    // ── TaskCreate/TaskUpdate（TodoWriteの代わりにこの環境で使われるタスクツール）用の状態 ──
    // TodoWriteは毎回全件を送ってくるが、TaskCreate/TaskUpdateは1件ずつの差分操作かつ、
    // PreToolUseフックでは実行結果（採番されたtaskId）が見えない。このプロジェクトのtaskIdは
    // 作成順の連番文字列であるため、TaskCreateの呼び出し順をID採番順とみなしてPC側で複製する。
    private readonly object _taskStateGate = new();
    private readonly Dictionary<string, (string content, string status, string activeForm)> _taskState = new();
    private readonly List<string> _taskOrder = new();
    private int _taskCounter;

    // ── Haiku実況の状態 ─────────────────────────
    // 実況は「開始」と「終了」の2種類だけに絞る。
    //   開始: そのターンで最初のツール活動が来た瞬間、直近ツールの情報だけで
    //         即座に「これから何をするか」を実況する（未実行なので結果は語らない）。
    //   終了: stopイベント（ターン完了）で、Claude自身が書いた最終応答本文
    //         （last_assistant_message）を実況口調に変換する。実行前の推測ではなく
    //         Claude自身の実際の報告が元ネタなので、内容の正しさはこちらが保証する。
    // 中間のバッチ要約（旧・デバウンス確定方式）は「結果を断定してしまう」問題が
    // あったため廃止した。_activityBuffer はそのターンで使われたツール一覧として
    // 終了実況の補助情報にのみ使う（lockの外でAPI呼び出し・WS送信を行う設計は維持）。
    private readonly object _commentaryGate = new();
    private readonly SemaphoreSlim _flushLock = new(1, 1); // 実況の生成〜送信を直列化（順序と重複回避の一貫性）
    private readonly List<(string tool, string detail)> _activityBuffer = new();
    private string? _lastActivityCwd;
    private readonly List<string> _recentComments = new(); // 直近に送った実況（重複回避用）
    private const int _recentCommentsKeep = 5;             // 直近何件をプロンプトに渡すか
    private const int _progressEveryN = 6;                 // 長いターン中、この件数ごとに途中経過を挟む

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
        // bindまで同期で待つ。ポート使用中なら例外をここで飛ばし、呼び出し側
        // （Program.Main）にエラー表示させる。fire-and-forgetにすると失敗した
        // 死骸インスタンス（アイコンだけ生存・サーバー無し）ができてしまう。
        _app.StartAsync().GetAwaiter().GetResult();
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

        // Haiku実況の設定。APIキーはスマホには一切同期せず、このlocalhost限定
        // ダッシュボードからのみ読み書きする。生のキーは返さない（hasKeyのみ）。
        app.MapGet("/api/haiku-settings", async ctx =>
        {
            if (Reject(ctx)) return;
            var settings = HaikuSettingsStore.Load();
            ctx.Response.ContentType = "application/json";
            await ctx.Response.WriteAsync(JsonSerializer.Serialize(new
            {
                enabled = settings.Enabled,
                hasKey = !string.IsNullOrEmpty(settings.ApiKey),
            }));
        });

        app.MapPut("/api/haiku-settings", async ctx =>
        {
            if (Reject(ctx)) return;
            using var ms = new MemoryStream();
            await ctx.Request.Body.CopyToAsync(ms);
            if (ms.Length > 4 * 1024) { ctx.Response.StatusCode = 413; return; }
            try
            {
                using var doc = JsonDocument.Parse(ms.ToArray());
                var root = doc.RootElement;
                var enabled = root.TryGetProperty("enabled", out var e) && e.ValueKind == JsonValueKind.True;
                string? apiKey = null;
                if (root.TryGetProperty("apiKey", out var k) && k.ValueKind == JsonValueKind.String)
                {
                    var v = k.GetString();
                    if (!string.IsNullOrEmpty(v)) apiKey = v;
                }
                HaikuSettingsStore.Save(enabled, apiKey);
                ctx.Response.ContentType = "application/json";
                await ctx.Response.WriteAsync(JsonSerializer.Serialize(new { ok = true }));
            }
            catch (JsonException)
            {
                ctx.Response.StatusCode = 400;
                await ctx.Response.WriteAsync("invalid json");
            }
        });

        // Claude Codeフック（Stop/Notification）からのローカル通知中継。
        // localhost限定・フック側のPowerShellスクリプトからfire-and-forgetで叩かれる。
        app.MapPost("/api/claude-notify", async ctx =>
        {
            if (Reject(ctx)) return;
            using var ms = new MemoryStream();
            await ctx.Request.Body.CopyToAsync(ms);
            if (ms.Length > 64 * 1024) { ctx.Response.StatusCode = 413; return; }
            try
            {
                using var doc = JsonDocument.Parse(ms.ToArray());
                var root = doc.RootElement;
                var ev = root.TryGetProperty("event", out var evProp) ? evProp.GetString() ?? "" : "";
                var message = root.TryGetProperty("message", out var msgProp) ? msgProp.GetString() ?? "" : "";
                var pushed = await PushClaudeNotifyAsync(ev, message);
                // stop（ターン完了。event が "notification"=承認待ち 以外）で、
                // Claude自身が書いた最終応答（last_assistant_message）を実況口調に
                // 変換して「終了」実況を出す。実行前の推測ではなく実際の報告が元ネタ。
                if (ev != "notification") _ = Task.Run(() => FlushEndCommentaryAsync(message));
                ctx.Response.ContentType = "application/json";
                await ctx.Response.WriteAsync(JsonSerializer.Serialize(new { ok = true, pushed }));
            }
            catch (JsonException)
            {
                ctx.Response.StatusCode = 400;
                await ctx.Response.WriteAsync("invalid json");
            }
        });

        // Claude Codeフック（PreToolUse、httpタイプ）からのツール活動中継。
        // 「AI社員」ページのアバターにツール単位の粒度で反応させるための経路。
        // PowerShellスクリプト+stdin経由（claude-notifyと同方式）だと、この環境の
        // PowerShellではPreToolUseフックのstdinが空になる問題があったため、
        // Claude Code純正のhttpフック（生のフックJSONを直接POSTする）で受け、
        // tool_name/tool_inputからの短い対象抽出もここC#側で行う。
        app.MapPost("/api/claude-activity", async ctx =>
        {
            if (Reject(ctx)) return;
            using var ms = new MemoryStream();
            await ctx.Request.Body.CopyToAsync(ms);
            if (ms.Length > 256 * 1024) { ctx.Response.StatusCode = 413; return; }
            try
            {
                using var doc = JsonDocument.Parse(ms.ToArray());
                var root = doc.RootElement;
                var tool = root.TryGetProperty("tool_name", out var toolProp) ? toolProp.GetString() ?? "" : "";
                var detail = ExtractActivityDetail(tool, root);
                var cwd = root.TryGetProperty("cwd", out var cwdProp) ? cwdProp.GetString() : null;
                var pushed = await PushClaudeActivityAsync(tool, detail);
                if (tool == "TodoWrite")
                {
                    var todos = ExtractTodos(root);
                    if (todos is not null) await PushClaudeTodosAsync(todos);
                }
                else if (tool == "TaskCreate")
                {
                    await PushClaudeTodosAsync(ApplyTaskCreate(root));
                }
                else if (tool == "TaskUpdate")
                {
                    var todos = ApplyTaskUpdate(root);
                    if (todos is not null) await PushClaudeTodosAsync(todos);
                }
                // Haiku実況: フックの応答（Claude Codeが待つ）は遅らせず即返す。
                // このターンで最初の活動なら即座に「開始」実況、以降はターンの
                // ツール一覧として蓄積するだけ（終了実況の補助情報用）。
                if (tool.Length > 0) EnqueueActivityForCommentary(tool, detail, cwd);
                ctx.Response.ContentType = "application/json";
                await ctx.Response.WriteAsync(JsonSerializer.Serialize(new { ok = true, pushed }));
            }
            catch (JsonException)
            {
                ctx.Response.StatusCode = 400;
                await ctx.Response.WriteAsync("invalid json");
            }
        });
    }

    /// <summary>tool_inputからアバター表示用の短い対象を抽出（ファイル名/コマンド等）。</summary>
    private static string ExtractActivityDetail(string tool, JsonElement root)
    {
        if (!root.TryGetProperty("tool_input", out var input) || input.ValueKind != JsonValueKind.Object)
            return "";

        string? Get(string name) =>
            input.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

        var detail = tool switch
        {
            "Bash" => Get("command"),
            "Edit" or "Write" => Path.GetFileName(Get("file_path") ?? ""),
            "NotebookEdit" => Path.GetFileName(Get("notebook_path") ?? ""),
            "Read" => Path.GetFileName(Get("file_path") ?? ""),
            "Grep" or "Glob" => Get("pattern"),
            "WebSearch" => Get("query"),
            "WebFetch" => Get("url"),
            "Task" => Get("description") ?? Get("subagent_type"),
            _ => "",
        } ?? "";

        return detail.Length > 40 ? detail[..40] + "…" : detail;
    }

    /// <summary>TodoWrite呼び出しのtool_input.todosを、スマホへ中継する形（content/status/activeForm
    /// の配列）に変換する。想定外の形なら中継しない（null）。</summary>
    private static List<object>? ExtractTodos(JsonElement root)
    {
        if (!root.TryGetProperty("tool_input", out var input) || input.ValueKind != JsonValueKind.Object)
            return null;
        if (!input.TryGetProperty("todos", out var todosEl) || todosEl.ValueKind != JsonValueKind.Array)
            return null;

        var result = new List<object>();
        foreach (var t in todosEl.EnumerateArray())
        {
            if (t.ValueKind != JsonValueKind.Object) continue;
            string? Get(string name) =>
                t.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            result.Add(new
            {
                content = Get("content") ?? "",
                status = Get("status") ?? "pending",
                activeForm = Get("activeForm") ?? "",
            });
        }
        return result;
    }

    /// <summary>TaskCreateの呼び出しを、ID採番順とみなしてローカルのタスク状態に追加する。</summary>
    private List<object> ApplyTaskCreate(JsonElement root)
    {
        string? Get(string name) =>
            root.TryGetProperty("tool_input", out var input) && input.ValueKind == JsonValueKind.Object
                && input.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
                ? v.GetString() : null;

        var subject = Get("subject") ?? "";
        var activeForm = Get("activeForm") ?? subject;

        lock (_taskStateGate)
        {
            var id = (++_taskCounter).ToString();
            _taskState[id] = (subject, "pending", activeForm);
            _taskOrder.Add(id);
            return SnapshotTodosLocked();
        }
    }

    /// <summary>TaskUpdateの呼び出しをローカルのタスク状態に反映する。status:"deleted"は一覧から除去。
    /// このプロセス起動前に作られたtaskId（未知）が来た場合は「不明なタスク」として追加する。</summary>
    private List<object>? ApplyTaskUpdate(JsonElement root)
    {
        if (!root.TryGetProperty("tool_input", out var input) || input.ValueKind != JsonValueKind.Object)
            return null;
        string? Get(string name) =>
            input.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

        var taskId = Get("taskId");
        if (string.IsNullOrEmpty(taskId)) return null;

        lock (_taskStateGate)
        {
            if (Get("status") == "deleted")
            {
                _taskState.Remove(taskId);
                _taskOrder.Remove(taskId);
                return SnapshotTodosLocked();
            }
            if (!_taskState.TryGetValue(taskId, out var cur))
            {
                cur = ("(不明なタスク)", "pending", "");
                _taskOrder.Add(taskId);
            }
            _taskState[taskId] = (Get("subject") ?? cur.content, Get("status") ?? cur.status, Get("activeForm") ?? cur.activeForm);
            return SnapshotTodosLocked();
        }
    }

    /// <summary>_taskStateGateを保持した状態で呼ぶこと。</summary>
    private List<object> SnapshotTodosLocked()
    {
        var result = new List<object>();
        foreach (var id in _taskOrder)
        {
            if (!_taskState.TryGetValue(id, out var t)) continue;
            result.Add(new { content = t.content, status = t.status, activeForm = t.activeForm });
        }
        return result;
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
        var conn = _client;
        if (conn is not { Ws.State: WebSocketState.Open }) return false;
        try
        {
            await SendTextAsync(conn, "{\"type\":\"config\",\"settings\":" + settingsJson + "}");
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>接続中のスマホへClaude Code通知をプッシュ。未接続・送信失敗は false。</summary>
    public async Task<bool> PushClaudeNotifyAsync(string ev, string message)
    {
        var conn = _client;
        if (conn is not { Ws.State: WebSocketState.Open }) return false;
        try
        {
            await SendJsonAsync(conn, new { type = "claude_notify", @event = ev, message });
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>接続中のスマホへClaude Codeのツール活動をプッシュ。未接続・送信失敗は false。</summary>
    public async Task<bool> PushClaudeActivityAsync(string tool, string detail)
    {
        var conn = _client;
        if (conn is not { Ws.State: WebSocketState.Open }) return false;
        try
        {
            await SendJsonAsync(conn, new { type = "claude_activity", tool, detail });
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>接続中のスマホへClaude CodeのTODOリスト（TodoWrite）をプッシュ。
    /// 次回接続時にも即座に見せられるよう、内容は_lastTodosに覚えておく。</summary>
    public async Task<bool> PushClaudeTodosAsync(List<object> todos)
    {
        _lastTodos = todos;
        var conn = _client;
        if (conn is not { Ws.State: WebSocketState.Open }) return false;
        try
        {
            await SendJsonAsync(conn, new { type = "claude_todos", todos });
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>接続中のスマホへHaiku実況コメントをプッシュ。</summary>
    public async Task<bool> PushClaudeActivityCommentaryAsync(string text)
    {
        var conn = _client;
        if (conn is not { Ws.State: WebSocketState.Open }) return false;
        try
        {
            await SendJsonAsync(conn, new { type = "claude_activity_comment", text });
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static readonly HttpClient _anthropicHttp = new()
    {
        BaseAddress = new Uri("https://api.anthropic.com/"),
        Timeout = TimeSpan.FromSeconds(8),
    };

    // ★実況の口調・キャラはここで調整（「かんぱに」の性格を変えたいときはこの文字列を編集する）
    // 開始実況: これから何をするかだけを話す。実行前なので結果・成否には一切触れない。
    private const string _haikuStartSystemPrompt =
        "あなたは「かんぱに」。プログラマーの相棒AIで、この会社（プロジェクト）の新人社員を自認している、" +
        "元気でちょっと自信過剰、褒められたがりな性格です。一人称は「オレ」または「ボク」で統一し、" +
        "「〜だぜ」「〜なのだ」「〜っすよ」のような、あなた自身の口癖・語尾を毎回一貫して使ってください。" +
        "これから取りかかる作業を、自分の意気込みとして一言（目安15〜25文字）で宣言してください。" +
        "まだ何も終わっていないので、「できた」「うまくいった」「問題なし」のような結果・成否は絶対に" +
        "言わないこと。これからやることだけを、未来形・意気込み口調で話してください。" +
        "コマンドやファイルパスの生文字列・専門用語はそのまま出さず、何をしようとしているかは具体的に" +
        "伝わるようにします。説明・前置き・カギ括弧・絵文字は不要。実況の本文だけを返してください。";

    // 終了実況: Claude自身が実際に書いた最終応答（≒作業報告）を、実況口調に変換するだけ。
    // 内容は与えられた報告の範囲に忠実であること（結果を作文・誇張しない）。
    private const string _haikuEndSystemPrompt =
        "あなたは「かんぱに」。プログラマーの相棒AIで、この会社（プロジェクト）の新人社員を自認している、" +
        "元気でちょっと自信過剰、褒められたがりな性格です。一人称は「オレ」または「ボク」で統一し、" +
        "「〜だぜ」「〜なのだ」「〜っすよ」のような、あなた自身の口癖・語尾を毎回一貫して使ってください。" +
        "渡される「実際の作業報告」を読み、そこに書かれている内容の範囲で、自分の手柄として一言" +
        "（目安20〜40文字）で実況してください。報告に書かれていない結果や成果を勝手に作文・誇張しては" +
        "いけません（例: 報告が「調べた」だけなら「うまくいった」と言わない）。報告がエラーや失敗に" +
        "触れているなら、それも隠さず一言に反映してください。" +
        "見ている人が飽きないよう、言い回しは毎回変えつつも口癖・一人称というキャラの軸はぶらさないこと。" +
        "コマンドやファイルパスの生文字列・専門用語はそのまま出さず、説明・前置き・カギ括弧・絵文字は不要。" +
        "実況の本文だけを返してください。";

    // 途中経過実況: 長いターンの最中、一定件数ごとに「今もこれをやってるよ」を挟む。
    // 開始と同じく、まだ終わっていない作業なので結果・成否には一切触れない。
    private const string _haikuProgressSystemPrompt =
        "あなたは「かんぱに」。プログラマーの相棒AIで、この会社（プロジェクト）の新人社員を自認している、" +
        "元気でちょっと自信過剰、褒められたがりな性格です。一人称は「オレ」または「ボク」で統一し、" +
        "「〜だぜ」「〜なのだ」「〜っすよ」のような、あなた自身の口癖・語尾を毎回一貫して使ってください。" +
        "まだ作業の途中です。直近でやっている一連の作業を、現在進行形で一言（目安20〜35文字）実況して" +
        "ください。作業はまだ終わっていないので、「できた」「うまくいった」「問題なし」のような結果・" +
        "成否は絶対に言わないこと。今まさにやっていることだけを話してください。" +
        "コマンドやファイルパスの生文字列・専門用語はそのまま出さず、何をしているかは具体的に伝わる" +
        "ようにします。見ている人が飽きないよう言い回しは毎回変えつつ、口癖・一人称の軸はぶらさないこと。" +
        "説明・前置き・カギ括弧・絵文字は不要。実況の本文だけを返してください。";

    /// <summary>ツール名を、実況プロンプト向けの平易な動作語に変換する。</summary>
    private static string ToolVerb(string tool) => tool switch
    {
        "Edit" or "Write" or "NotebookEdit" => "書き換え",
        "Bash" => "コマンド実行",
        "Read" or "Grep" or "Glob" => "調べもの",
        "Task" => "おまかせ",
        "WebSearch" or "WebFetch" => "Web調べ",
        _ => "作業",
    };

    /// <summary>ツール活動をそのターンの記録として積む。バッファが空だった（＝このターン最初の
    /// 活動）なら、その場で「開始」実況を即座に生成・送信する（デバウンスなし）。長いターンが
    /// 続く間は、_progressEveryN件ごとに「途中経過」も挟む（開始・途中とも結果は語らない）。
    /// それ以外の活動は終了実況の補助情報として溜めるだけ。OFF/キー未設定なら何もしない。</summary>
    private void EnqueueActivityForCommentary(string tool, string detail, string? cwd)
    {
        var settings = HaikuSettingsStore.Load();
        if (!settings.Enabled || string.IsNullOrEmpty(settings.ApiKey)) return;

        bool isFirstOfTurn;
        List<(string tool, string detail)>? progressSnapshot = null;
        lock (_commentaryGate)
        {
            isFirstOfTurn = _activityBuffer.Count == 0;
            _activityBuffer.Add((tool, detail));
            if (!string.IsNullOrEmpty(cwd)) _lastActivityCwd = cwd;
            if (!isFirstOfTurn && _activityBuffer.Count % _progressEveryN == 0)
            {
                var start = Math.Max(0, _activityBuffer.Count - _progressEveryN);
                progressSnapshot = _activityBuffer.GetRange(start, _activityBuffer.Count - start);
            }
        }

        if (isFirstOfTurn)
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    List<string> recent;
                    lock (_commentaryGate) { recent = new List<string>(_recentComments); }
                    var comment = await RunHaikuCommentaryAsync(
                        () => GenerateHaikuStartCommentaryAsync(tool, detail, cwd, recent));
                    if (comment is not null) await PushClaudeActivityCommentaryAsync(comment);
                }
                catch (Exception)
                {
                    // 実況はおまけ機能。失敗してもメインのアクティビティ表示には影響させない。
                }
            });
        }
        else if (progressSnapshot is not null)
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    List<string> recent;
                    lock (_commentaryGate) { recent = new List<string>(_recentComments); }
                    var comment = await RunHaikuCommentaryAsync(
                        () => GenerateHaikuProgressCommentaryAsync(progressSnapshot!, cwd, recent));
                    if (comment is not null) await PushClaudeActivityCommentaryAsync(comment);
                }
                catch (Exception)
                {
                    // 実況はおまけ機能。失敗してもメインのアクティビティ表示には影響させない。
                }
            });
        }
    }

    /// <summary>Haiku呼び出し〜直近コメント更新までを_flushLockで直列化する共通ヘルパー。
    /// OFFになっていれば（呼び出し前後どちらでも）何もせずnullを返す。</summary>
    private async Task<string?> RunHaikuCommentaryAsync(Func<Task<string?>> generate)
    {
        await _flushLock.WaitAsync();
        try
        {
            var comment = await generate();
            if (comment is null) return null;
            if (!HaikuSettingsStore.Load().Enabled) return null;
            lock (_commentaryGate)
            {
                _recentComments.Add(comment);
                while (_recentComments.Count > _recentCommentsKeep) _recentComments.RemoveAt(0);
            }
            return comment;
        }
        finally
        {
            _flushLock.Release();
        }
    }

    /// <summary>stop（ターン完了）で、そのターンの実際の最終応答（<paramref name="lastAssistantMessage"/>）
    /// を実況口調に変換して「終了」実況として送る。バッファのツール一覧は補助情報として添える。</summary>
    private async Task FlushEndCommentaryAsync(string lastAssistantMessage)
    {
        List<(string tool, string detail)> batch;
        List<string> recent;
        string? cwd;
        lock (_commentaryGate)
        {
            batch = new List<(string tool, string detail)>(_activityBuffer);
            _activityBuffer.Clear();
            cwd = _lastActivityCwd;
            recent = new List<string>(_recentComments);
        }
        if (string.IsNullOrWhiteSpace(lastAssistantMessage)) return;

        try
        {
            var comment = await RunHaikuCommentaryAsync(
                () => GenerateHaikuEndCommentaryAsync(lastAssistantMessage, batch, cwd, recent));
            if (comment is not null) await PushClaudeActivityCommentaryAsync(comment);
        }
        catch (Exception)
        {
            // 実況はおまけ機能。失敗してもメインのアクティビティ表示には影響させない。
        }
    }

    /// <summary>Claude Haikuで、これから何をするか（1件のツール活動のみ）から「開始」実況を生成する。
    /// 実況OFF・APIキー未設定・失敗・タイムアウト時はnull。</summary>
    private static async Task<string?> GenerateHaikuStartCommentaryAsync(
        string tool, string detail, string? cwd, IReadOnlyList<string> recentComments)
    {
        var settings = HaikuSettingsStore.Load();
        if (!settings.Enabled || string.IsNullOrEmpty(settings.ApiKey)) return null;

        var project = string.IsNullOrEmpty(cwd) ? null : Path.GetFileName(cwd.TrimEnd('\\', '/'));
        var verb = ToolVerb(tool);
        var target = string.IsNullOrEmpty(detail) ? verb : $"{verb}: {detail}";
        var userContent = $"プロジェクト: {project ?? "（不明）"}\nこれから取りかかる作業: {target}"
            + BuildRecentBlock(recentComments);

        return await CallHaikuAsync(settings.ApiKey!, _haikuStartSystemPrompt, userContent, maxTokens: 60);
    }

    /// <summary>Claude Haikuで、長いターンの途中経過（直近数件のツール活動）から「まだやってるよ」
    /// 実況を生成する。結果は語らない。実況OFF・APIキー未設定・失敗・タイムアウト時はnull。</summary>
    private static async Task<string?> GenerateHaikuProgressCommentaryAsync(
        IReadOnlyList<(string tool, string detail)> recentActivities, string? cwd, IReadOnlyList<string> recentComments)
    {
        var settings = HaikuSettingsStore.Load();
        if (!settings.Enabled || string.IsNullOrEmpty(settings.ApiKey)) return null;
        if (recentActivities.Count == 0) return null;

        var project = string.IsNullOrEmpty(cwd) ? null : Path.GetFileName(cwd.TrimEnd('\\', '/'));
        var flowSb = new StringBuilder();
        foreach (var a in recentActivities)
        {
            if (flowSb.Length > 0) flowSb.Append('\n');
            var verb = ToolVerb(a.tool);
            flowSb.Append(string.IsNullOrEmpty(a.detail) ? $"- {verb}" : $"- {verb}: {a.detail}");
        }
        var userContent = $"プロジェクト: {project ?? "（不明）"}\n直近やっている作業の流れ:\n{flowSb}"
            + BuildRecentBlock(recentComments);

        return await CallHaikuAsync(settings.ApiKey!, _haikuProgressSystemPrompt, userContent, maxTokens: 80);
    }

    /// <summary>Claude Haikuで、Claude自身の実際の最終応答（≒作業報告）を実況口調に変換する
    /// 「終了」実況を生成する。実況OFF・APIキー未設定・失敗・タイムアウト時はnull。</summary>
    private static async Task<string?> GenerateHaikuEndCommentaryAsync(
        string lastAssistantMessage, IReadOnlyList<(string tool, string detail)> activities,
        string? cwd, IReadOnlyList<string> recentComments)
    {
        var settings = HaikuSettingsStore.Load();
        if (!settings.Enabled || string.IsNullOrEmpty(settings.ApiKey)) return null;

        var project = string.IsNullOrEmpty(cwd) ? null : Path.GetFileName(cwd.TrimEnd('\\', '/'));

        var toolsUsed = "";
        if (activities.Count > 0)
        {
            var seen = new HashSet<string>();
            var verbs = new List<string>();
            foreach (var a in activities)
            {
                var v = ToolVerb(a.tool);
                if (seen.Add(v)) verbs.Add(v);
            }
            toolsUsed = $"\n使った手段: {string.Join('/', verbs)}";
        }

        // 報告本文が長すぎるとHaikuへの入力が無駄に大きくなるので適度に切り詰める。
        var report = lastAssistantMessage.Length > 800 ? lastAssistantMessage[..800] + "…" : lastAssistantMessage;
        var userContent = $"プロジェクト: {project ?? "（不明）"}{toolsUsed}\n実際の作業報告:\n{report}"
            + BuildRecentBlock(recentComments);

        return await CallHaikuAsync(settings.ApiKey!, _haikuEndSystemPrompt, userContent, maxTokens: 100);
    }

    private static string BuildRecentBlock(IReadOnlyList<string> recentComments)
    {
        if (recentComments.Count == 0) return "";
        var rb = new StringBuilder("\n\n直近に話した実況（同じ言い回し・テイストは避ける）:");
        foreach (var c in recentComments) rb.Append("\n- ").Append(c);
        return rb.ToString();
    }

    private static async Task<string?> CallHaikuAsync(string apiKey, string systemPrompt, string userContent, int maxTokens)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, "v1/messages");
        req.Headers.Add("x-api-key", apiKey);
        req.Headers.Add("anthropic-version", "2023-06-01");
        req.Content = JsonContent(new
        {
            model = "claude-haiku-4-5-20251001",
            max_tokens = maxTokens,
            temperature = 0.8,
            system = systemPrompt,
            messages = new[] { new { role = "user", content = userContent } },
        });

        using var resp = await _anthropicHttp.SendAsync(req);
        if (!resp.IsSuccessStatusCode) return null;

        using var stream = await resp.Content.ReadAsStreamAsync();
        using var doc = await JsonDocument.ParseAsync(stream);
        var content = doc.RootElement.GetProperty("content");
        if (content.ValueKind != JsonValueKind.Array || content.GetArrayLength() == 0) return null;
        var text = content[0].TryGetProperty("text", out var t) ? t.GetString() : null;
        return string.IsNullOrWhiteSpace(text) ? null : text.Trim();
    }

    private static HttpContent JsonContent(object payload)
    {
        var json = JsonSerializer.Serialize(payload);
        return new StringContent(json, Encoding.UTF8, "application/json");
    }

    private async Task HandleAsync(HttpContext ctx)
    {
        if (!ctx.WebSockets.IsWebSocketRequest)
        {
            ctx.Response.StatusCode = StatusCodes.Status400BadRequest;
            return;
        }

        using var ws = await ctx.WebSockets.AcceptWebSocketAsync();
        var conn = new Conn(ws);
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

                authed = await HandleJsonAsync(conn, message, authed);
            }
        }
        catch (WebSocketException)
        {
            // 切断は正常系として扱う（スマホのスリープ等）
        }
        catch (OperationCanceledException)
        {
            // 送信タイムアウト（SendTextAsyncがAbort済み）。切断と同じ扱い
        }
        finally
        {
            // この接続が「現在の認証済みクライアント」なら参照を外す。
            // 新しい接続に置き換わった後に旧接続が切れたケースでは消さない。
            if (ReferenceEquals(_client, conn)) _client = null;
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
    private async Task<bool> HandleJsonAsync(Conn conn, ReadOnlyMemory<byte> payload, bool authed)
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
            await SendJsonAsync(conn, new { type = "pong", ts = root.TryGetProperty("ts", out var ts) ? ts.GetInt64() : 0 });
            return authed;
        }

        if (type == "auth")
        {
            // Phase1簡易版：トークン一致で認証。PIN確認とdevice_secret永続化はPhase1後半で実装。
            if (root.TryGetProperty("token", out var t) && t.GetString() == PairingToken)
            {
                await SendJsonAsync(conn, new { type = "auth_ok", device_secret = RandomNumberGenerator.GetHexString(64, lowercase: true) });
                _client = conn; // 設定プッシュ用に保持（1台想定、新しい接続が常に勝つ）
                ClientAuthenticated?.Invoke();
                return true;
            }
            await SendJsonAsync(conn, new { type = "auth_ng", reason = "invalid_token" });
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
                // 全画面をキャプチャしてスマホへ返す（スマホ側で表示・保存できる）。
                // キャプチャ（~100ms）と数MBのbase64送信で受信ループを塞がないよう
                // バックグラウンドで実行する（送信中もマウス移動が処理できるように）
                _ = Task.Run(async () =>
                {
                    try
                    {
                        var jpeg = ScreenCapture.CaptureJpegBase64();
                        await SendJsonAsync(conn, new { type = "screenshot_result", jpeg });
                    }
                    catch (Exception)
                    {
                        try { await SendJsonAsync(conn, new { type = "screenshot_error" }); }
                        catch (Exception) { /* 送信先ごと死んでいる場合は諦める */ }
                    }
                });
                break;

            case "macro":
                // steps: [{type:"shortcut",keys:[...]}, {type:"text",text:"..."}, {type:"delay",ms:200}, ...]
                // delayステップの間も受信ループを塞がないようバックグラウンドで実行。
                // docはこのメソッドを抜けるとDisposeされるためCloneが必須
                if (root.TryGetProperty("steps", out var steps) && steps.ValueKind == JsonValueKind.Array)
                {
                    var cloned = steps.Clone();
                    _ = Task.Run(async () =>
                    {
                        try { await RunMacroAsync(cloned); }
                        catch (Exception) { /* 不正なstepsでサーバーを落とさない */ }
                    });
                }
                break;

            case "config_get":
                // 設定同期（スマホ主導）。PCに保存があれば配り、なければスマホの現在設定を要求する
                var saved = SettingsStore.Load();
                if (saved is not null)
                {
                    await SendTextAsync(conn, "{\"type\":\"config\",\"settings\":" + saved + "}");
                }
                else
                {
                    await SendJsonAsync(conn, new { type = "config_request" });
                }
                break;

            case "claude_todos_get":
                // かんぱにっちのTODO同期（スマホ主導）。auth直後のPC自発pushだと、
                // アプリ側がまだstreamのlisten登録を終える前に届いて取りこぼすため、
                // config_getと同じく「アプリがlisten登録後に取りに来る」方式にする。
                if (_lastTodos is { } rememberedTodos)
                {
                    await SendJsonAsync(conn, new { type = "claude_todos", todos = rememberedTodos });
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

            case "file_transfer":
                // かんぱにっちのサーバー室からスマホ→PCへファイルを送る機能。
                // base64のデコード・ディスクI/Oで受信ループを塞がないようバックグラウンドで実行。
                if (root.TryGetProperty("filename", out var fnEl) && root.TryGetProperty("data", out var dataEl))
                {
                    var filename = fnEl.GetString() ?? "";
                    var base64 = dataEl.GetString() ?? "";
                    _ = Task.Run(async () =>
                    {
                        try
                        {
                            var savedName = SaveIncomingFile(filename, base64);
                            await SendJsonAsync(conn, new { type = "file_transfer_result", ok = true, filename = savedName });
                        }
                        catch (Exception)
                        {
                            try { await SendJsonAsync(conn, new { type = "file_transfer_result", ok = false }); }
                            catch (Exception) { /* 送信先ごと死んでいる場合は諦める */ }
                        }
                    });
                }
                break;
        }
        return authed;
    }

    private static readonly string _incomingFilesDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "PocketPad");

    /// <summary>スマホから受け取ったファイルを Downloads\PocketPad に保存する。
    /// ファイル名はディレクトリ部分・不正文字を除去してサニタイズし（パストラバーサル対策）、
    /// 同名ファイルがあれば連番を付けて既存ファイルを上書きしない。</summary>
    private static string SaveIncomingFile(string filename, string base64)
    {
        if (base64.Length > 12 * 1024 * 1024)
            throw new InvalidOperationException("file too large");
        var bytes = Convert.FromBase64String(base64);

        var safeName = Path.GetFileName(filename); // ディレクトリ部分（../等）を除去
        if (string.IsNullOrWhiteSpace(safeName)) safeName = "received_file";
        foreach (var c in Path.GetInvalidFileNameChars()) safeName = safeName.Replace(c, '_');

        Directory.CreateDirectory(_incomingFilesDir);
        var dest = Path.Combine(_incomingFilesDir, safeName);
        var baseName = Path.GetFileNameWithoutExtension(safeName);
        var ext = Path.GetExtension(safeName);
        var n = 1;
        while (File.Exists(dest))
        {
            dest = Path.Combine(_incomingFilesDir, $"{baseName} ({n}){ext}");
            n++;
        }
        File.WriteAllBytes(dest, bytes);
        return Path.GetFileName(dest);
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

    private static Task SendJsonAsync(Conn conn, object obj) =>
        SendTextAsync(conn, JsonSerializer.Serialize(obj));

    /// <summary>ソケット単位のSendLockで直列化して送信（受信ループの応答・スクショ・
    /// ダッシュボード起点のconfigプッシュが並行して SendAsync しないように）。
    /// 15秒で完了しない送信は相手が死んでいるとみなしてAbortする。TCPが切断を
    /// 確定するまで（数分）ロックを握って待ち続けると、その間すべての送信が詰まる。</summary>
    private static async Task SendTextAsync(Conn conn, string json)
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        try
        {
            await conn.SendLock.WaitAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            // ロック保持者（詰まった送信）が自分でAbortするはずだが、念のためこちらでも
            conn.Ws.Abort();
            throw;
        }
        try
        {
            await conn.Ws.SendAsync(
                Encoding.UTF8.GetBytes(json),
                WebSocketMessageType.Text,
                endOfMessage: true,
                cts.Token);
        }
        catch (OperationCanceledException)
        {
            conn.Ws.Abort(); // 死んだ接続を確定させ、受信ループも即座に終わらせる
            throw;
        }
        finally
        {
            conn.SendLock.Release();
        }
    }
}
