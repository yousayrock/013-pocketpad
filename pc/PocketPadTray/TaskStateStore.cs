using System.Text.Json;

namespace PocketPadTray;

record TaskStateEntry(string Id, string Content, string Status, string ActiveForm);

record TaskSessionEntry(
    string SessionId,
    DateTime LastActivityUtc,
    List<string> Order,
    List<TaskStateEntry> Tasks);

record PersistedTaskState(string? LastActiveSessionId, List<TaskSessionEntry> Sessions);

/// <summary>
/// TaskCreated/TaskCompleted hooksから受け取った、セッション別のタスク状態を保存する。
/// 旧counter形式や不正なIDを含む状態は対応付け不能なので、移行せず空として扱う。
/// </summary>
static class TaskStateStore
{
    static readonly string Dir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PocketPad");

    public static readonly string FilePath = Path.Combine(Dir, "task_state.json");

    static readonly object Gate = new();

    public static PersistedTaskState Load()
    {
        lock (Gate)
        {
            try
            {
                if (!File.Exists(FilePath))
                    return Empty();

                using var doc = JsonDocument.Parse(File.ReadAllText(FilePath));
                var root = doc.RootElement;
                if (root.TryGetProperty("counter", out _)
                    || !root.TryGetProperty("version", out var version)
                    || version.ValueKind != JsonValueKind.Number
                    || version.GetInt32() != 2
                    || !root.TryGetProperty("sessions", out var sessionsEl)
                    || sessionsEl.ValueKind != JsonValueKind.Array)
                {
                    return Empty();
                }

                var sessions = new List<TaskSessionEntry>();
                foreach (var sessionEl in sessionsEl.EnumerateArray())
                {
                    if (!TryReadSession(sessionEl, out var session))
                        return Empty();
                    sessions.Add(session);
                }

                var lastActiveSessionId = root.TryGetProperty("lastActiveSessionId", out var last)
                    && last.ValueKind == JsonValueKind.String
                    ? last.GetString()
                    : null;
                if (lastActiveSessionId is not null
                    && sessions.All(x => x.SessionId != lastActiveSessionId))
                {
                    lastActiveSessionId = null;
                }
                return new PersistedTaskState(lastActiveSessionId, sessions);
            }
            catch (Exception ex)
            {
                ErrorLog.Append("TaskStateStore.Load", ex);
                return Empty();
            }
        }
    }

    public static void Save(string? lastActiveSessionId, List<TaskSessionEntry> sessions)
    {
        lock (Gate)
        {
            Directory.CreateDirectory(Dir);
            var payload = new
            {
                version = 2,
                lastActiveSessionId,
                sessions = sessions.Select(s => new
                {
                    sessionId = s.SessionId,
                    lastActivityUtc = s.LastActivityUtc,
                    order = s.Order,
                    tasks = s.Tasks.Select(t => new
                    {
                        id = t.Id,
                        content = t.Content,
                        status = t.Status,
                        activeForm = t.ActiveForm,
                    }),
                }),
            };
            var json = JsonSerializer.Serialize(payload);
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, json);
            File.Move(tmp, FilePath, overwrite: true);
        }
    }

    private static bool TryReadSession(JsonElement root, out TaskSessionEntry session)
    {
        session = null!;
        if (root.ValueKind != JsonValueKind.Object
            || !TryGetString(root, "sessionId", out var sessionId)
            || string.IsNullOrWhiteSpace(sessionId)
            || !root.TryGetProperty("lastActivityUtc", out var lastActivity)
            || lastActivity.ValueKind != JsonValueKind.String
            || !lastActivity.TryGetDateTime(out var lastActivityUtc)
            || !root.TryGetProperty("order", out var orderEl)
            || orderEl.ValueKind != JsonValueKind.Array
            || !root.TryGetProperty("tasks", out var tasksEl)
            || tasksEl.ValueKind != JsonValueKind.Array)
        {
            return false;
        }

        var order = new List<string>();
        foreach (var idEl in orderEl.EnumerateArray())
        {
            if (idEl.ValueKind != JsonValueKind.String || !IsClaudeTaskId(idEl.GetString()))
                return false;
            order.Add(idEl.GetString()!);
        }

        var tasks = new List<TaskStateEntry>();
        foreach (var taskEl in tasksEl.EnumerateArray())
        {
            if (!TryGetString(taskEl, "id", out var id) || !IsClaudeTaskId(id)
                || !TryGetString(taskEl, "content", out var content)
                || !TryGetString(taskEl, "status", out var status)
                || status is not ("pending" or "completed")
                || !TryGetString(taskEl, "activeForm", out var activeForm))
            {
                return false;
            }
            tasks.Add(new TaskStateEntry(id!, content!, status!, activeForm!));
        }

        if (order.Count != order.Distinct().Count()
            || tasks.Select(x => x.Id).Distinct().Count() != tasks.Count
            || !order.SequenceEqual(tasks.Select(x => x.Id)))
        {
            return false;
        }

        session = new TaskSessionEntry(sessionId!, lastActivityUtc.ToUniversalTime(), order, tasks);
        return true;
    }

    public static bool IsClaudeTaskId(string? id) =>
        !string.IsNullOrEmpty(id) && id.All(char.IsAsciiDigit);

    private static bool TryGetString(JsonElement root, string name, out string? value)
    {
        value = null;
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty(name, out var element)
            || element.ValueKind != JsonValueKind.String)
        {
            return false;
        }
        value = element.GetString();
        return value is not null;
    }

    private static PersistedTaskState Empty() => new(null, new List<TaskSessionEntry>());
}
