using System.Text.Json;

namespace PocketPadTray;

record TaskRecord(
    string Id,
    string Content,
    string ActiveForm,
    string Status,
    string Source,
    string? SessionId,
    DateTime CreatedUtc,
    DateTime UpdatedUtc,
    DateTime? CompletedUtc);

record PersistedTaskState(List<TaskRecord> Tasks, List<string> Order);

/// <summary>
/// タスクをセッションから独立させ、全体で一意なIDとともに保存する。
/// 不正なタスクは個別に除外し、正常なタスクを残す。
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

                if (root.ValueKind != JsonValueKind.Object
                    || root.TryGetProperty("counter", out _)
                    || !root.TryGetProperty("version", out var version)
                    || version.ValueKind != JsonValueKind.Number
                    || !version.TryGetInt32(out var versionNumber))
                {
                    return Empty();
                }

                return versionNumber switch
                {
                    3 => ReadVersion3(root),
                    2 => MigrateVersion2(root),
                    _ => Empty(),
                };
            }
            catch (Exception ex)
            {
                ErrorLog.Append("TaskStateStore.Load", ex);
                return Empty();
            }
        }
    }

    public static void Save(List<TaskRecord> tasks, List<string> order)
    {
        lock (Gate)
        {
            Directory.CreateDirectory(Dir);
            var payload = new
            {
                version = 3,
                tasks = tasks.Select(t => new
                {
                    id = t.Id,
                    content = t.Content,
                    activeForm = t.ActiveForm,
                    status = t.Status,
                    source = t.Source,
                    sessionId = t.SessionId,
                    createdUtc = t.CreatedUtc.ToUniversalTime(),
                    updatedUtc = t.UpdatedUtc.ToUniversalTime(),
                    completedUtc = t.CompletedUtc?.ToUniversalTime(),
                }),
                order,
            };
            var json = JsonSerializer.Serialize(payload);
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, json);
            File.Move(tmp, FilePath, overwrite: true);
        }
    }

    /// <summary>Claude Code由来のタスクIDを、セッションをまたいで一意な形へ張り替える。</summary>
    public static string MakeClaudeTaskId(string sessionId, string claudeTaskId) =>
        $"cc-{sessionId}-{claudeTaskId}";

    /// <summary>手動追加のタスクIDを作る。</summary>
    public static string NewManualTaskId() =>
        "m-" + Guid.NewGuid().ToString("n");

    public static bool IsClaudeTaskId(string? id) =>
        !string.IsNullOrEmpty(id) && id.All(char.IsAsciiDigit);

    private static PersistedTaskState ReadVersion3(JsonElement root)
    {
        if (!root.TryGetProperty("tasks", out var tasksEl)
            || tasksEl.ValueKind != JsonValueKind.Array
            || !root.TryGetProperty("order", out var orderEl)
            || orderEl.ValueKind != JsonValueKind.Array)
        {
            return Empty();
        }

        var tasks = new List<TaskRecord>();
        var taskIds = new HashSet<string>(StringComparer.Ordinal);

        foreach (var taskEl in tasksEl.EnumerateArray())
        {
            if (!TryReadVersion3Task(taskEl, out var task, out var reason))
            {
                LogSkippedTask("TaskStateStore.Load.v3", reason);
                continue;
            }

            if (!taskIds.Add(task.Id))
            {
                LogSkippedTask(
                    "TaskStateStore.Load.v3",
                    $"タスクIDが重複しています: {task.Id}");
                continue;
            }

            tasks.Add(task);
        }

        var order = NormalizeOrder(orderEl, tasks);
        return new PersistedTaskState(tasks, order);
    }

    private static PersistedTaskState MigrateVersion2(JsonElement root)
    {
        if (!root.TryGetProperty("sessions", out var sessionsEl)
            || sessionsEl.ValueKind != JsonValueKind.Array)
        {
            return Empty();
        }

        BackupVersion2();

        var sessions = new List<Version2Session>();
        var sessionIndex = 0;

        foreach (var sessionEl in sessionsEl.EnumerateArray())
        {
            if (!TryReadVersion2Session(sessionEl, sessionIndex, out var session))
            {
                LogSkippedTask(
                    "TaskStateStore.Load.v2",
                    $"不正なセッションをスキップしました（位置: {sessionIndex}）");
            }
            else
            {
                sessions.Add(session);
            }

            sessionIndex++;
        }

        var tasks = new List<TaskRecord>();
        var order = new List<string>();
        var taskIds = new HashSet<string>(StringComparer.Ordinal);

        foreach (var session in sessions
                     .OrderByDescending(s => s.LastActivityUtc)
                     .ThenBy(s => s.Index))
        {
            var migratedByOldId = new Dictionary<string, TaskRecord>(StringComparer.Ordinal);

            foreach (var oldTask in session.Tasks)
            {
                var id = MakeClaudeTaskId(session.SessionId, oldTask.Id);
                if (!taskIds.Add(id))
                {
                    LogSkippedTask(
                        "TaskStateStore.Load.v2",
                        $"移行後のタスクIDが重複しています: {id}");
                    continue;
                }

                DateTime? completedUtc = oldTask.Status == "completed"
                    ? session.LastActivityUtc
                    : null;

                var task = new TaskRecord(
                    id,
                    oldTask.Content,
                    oldTask.ActiveForm,
                    oldTask.Status,
                    "claude-code",
                    session.SessionId,
                    session.LastActivityUtc,
                    session.LastActivityUtc,
                    completedUtc);

                tasks.Add(task);
                migratedByOldId[oldTask.Id] = task;
            }

            var orderedIds = new HashSet<string>(StringComparer.Ordinal);
            foreach (var oldId in session.Order)
            {
                if (migratedByOldId.TryGetValue(oldId, out var task)
                    && orderedIds.Add(task.Id))
                {
                    order.Add(task.Id);
                }
            }

            foreach (var oldTask in session.Tasks)
            {
                if (migratedByOldId.TryGetValue(oldTask.Id, out var task)
                    && orderedIds.Add(task.Id))
                {
                    order.Add(task.Id);
                }
            }
        }

        return new PersistedTaskState(tasks, order);
    }

    private static bool TryReadVersion3Task(
        JsonElement root,
        out TaskRecord task,
        out string reason)
    {
        task = null!;
        reason = "タスクの形式が不正です";

        if (root.ValueKind != JsonValueKind.Object
            || !TryGetString(root, "id", out var id)
            || string.IsNullOrWhiteSpace(id)
            || !TryGetString(root, "content", out var content)
            || !TryGetString(root, "activeForm", out var activeForm)
            || !TryGetString(root, "status", out var status)
            || status is not ("pending" or "in_progress" or "completed")
            || !TryGetString(root, "source", out var source)
            || source is not ("claude-code" or "manual" or "gadget")
            || !TryGetUtcDateTime(root, "createdUtc", out var createdUtc)
            || !TryGetUtcDateTime(root, "updatedUtc", out var updatedUtc)
            || !TryGetNullableUtcDateTime(root, "completedUtc", out var completedUtc))
        {
            return false;
        }

        string? sessionId = null;
        if (root.TryGetProperty("sessionId", out var sessionIdEl))
        {
            if (sessionIdEl.ValueKind == JsonValueKind.String)
            {
                sessionId = sessionIdEl.GetString();
            }
            else if (sessionIdEl.ValueKind != JsonValueKind.Null)
            {
                return false;
            }
        }

        if (source == "claude-code")
        {
            if (string.IsNullOrWhiteSpace(sessionId))
            {
                reason = $"Claude CodeタスクのsessionIdがありません: {id}";
                return false;
            }
        }
        else if (sessionId is not null)
        {
            reason = $"Claude Code以外のタスクにsessionIdがあります: {id}";
            return false;
        }

        task = new TaskRecord(
            id,
            content,
            activeForm,
            status,
            source,
            sessionId,
            createdUtc,
            updatedUtc,
            completedUtc);
        return true;
    }

    private static bool TryReadVersion2Session(
        JsonElement root,
        int index,
        out Version2Session session)
    {
        session = null!;

        if (root.ValueKind != JsonValueKind.Object
            || !TryGetString(root, "sessionId", out var sessionId)
            || string.IsNullOrWhiteSpace(sessionId)
            || !TryGetUtcDateTime(root, "lastActivityUtc", out var lastActivityUtc)
            || !root.TryGetProperty("tasks", out var tasksEl)
            || tasksEl.ValueKind != JsonValueKind.Array)
        {
            return false;
        }

        var tasks = new List<Version2Task>();
        var taskIds = new HashSet<string>(StringComparer.Ordinal);

        foreach (var taskEl in tasksEl.EnumerateArray())
        {
            if (!TryReadVersion2Task(taskEl, out var task, out var reason))
            {
                LogSkippedTask("TaskStateStore.Load.v2", reason);
                continue;
            }

            if (!taskIds.Add(task.Id))
            {
                LogSkippedTask(
                    "TaskStateStore.Load.v2",
                    $"セッション内のタスクIDが重複しています: {sessionId}/{task.Id}");
                continue;
            }

            tasks.Add(task);
        }

        var order = new List<string>();
        if (root.TryGetProperty("order", out var orderEl)
            && orderEl.ValueKind == JsonValueKind.Array)
        {
            foreach (var idEl in orderEl.EnumerateArray())
            {
                if (idEl.ValueKind == JsonValueKind.String
                    && idEl.GetString() is { Length: > 0 } id)
                {
                    order.Add(id);
                }
            }
        }

        session = new Version2Session(
            sessionId,
            lastActivityUtc,
            order,
            tasks,
            index);
        return true;
    }

    private static bool TryReadVersion2Task(
        JsonElement root,
        out Version2Task task,
        out string reason)
    {
        task = null!;
        reason = "v2タスクの形式が不正です";

        if (root.ValueKind != JsonValueKind.Object
            || !TryGetString(root, "id", out var id)
            || !IsClaudeTaskId(id)
            || !TryGetString(root, "content", out var content)
            || !TryGetString(root, "status", out var status)
            || status is not ("pending" or "in_progress" or "completed")
            || !TryGetString(root, "activeForm", out var activeForm))
        {
            return false;
        }

        task = new Version2Task(id, content, status, activeForm);
        return true;
    }

    private static List<string> NormalizeOrder(
        JsonElement orderEl,
        List<TaskRecord> tasks)
    {
        var taskIds = tasks.Select(t => t.Id).ToHashSet(StringComparer.Ordinal);
        var added = new HashSet<string>(StringComparer.Ordinal);
        var order = new List<string>();

        foreach (var idEl in orderEl.EnumerateArray())
        {
            if (idEl.ValueKind == JsonValueKind.String
                && idEl.GetString() is { } id
                && taskIds.Contains(id)
                && added.Add(id))
            {
                order.Add(id);
            }
        }

        foreach (var task in tasks)
        {
            if (added.Add(task.Id))
                order.Add(task.Id);
        }

        return order;
    }

    private static void BackupVersion2()
    {
        try
        {
            Directory.CreateDirectory(Dir);
            var backupPath = Path.Combine(Dir, "task_state.v2.bak");
            File.Copy(FilePath, backupPath, overwrite: true);
        }
        catch (Exception ex)
        {
            ErrorLog.Append("TaskStateStore.Load.v2.Backup", ex);
        }
    }

    private static void LogSkippedTask(string context, string reason) =>
        ErrorLog.Append(context, new InvalidDataException(reason));

    private static bool TryGetString(
        JsonElement root,
        string name,
        out string value)
    {
        value = string.Empty;
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty(name, out var element)
            || element.ValueKind != JsonValueKind.String
            || element.GetString() is not { } text)
        {
            return false;
        }

        value = text;
        return true;
    }

    private static bool TryGetUtcDateTime(
        JsonElement root,
        string name,
        out DateTime value)
    {
        value = default;
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty(name, out var element)
            || element.ValueKind != JsonValueKind.String
            || !element.TryGetDateTime(out var parsed))
        {
            return false;
        }

        value = parsed.ToUniversalTime();
        return true;
    }

    private static bool TryGetNullableUtcDateTime(
        JsonElement root,
        string name,
        out DateTime? value)
    {
        value = null;
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty(name, out var element))
        {
            return false;
        }

        if (element.ValueKind == JsonValueKind.Null)
            return true;

        if (element.ValueKind != JsonValueKind.String
            || !element.TryGetDateTime(out var parsed))
        {
            return false;
        }

        value = parsed.ToUniversalTime();
        return true;
    }

    private static PersistedTaskState Empty() =>
        new(new List<TaskRecord>(), new List<string>());

    private sealed record Version2Task(
        string Id,
        string Content,
        string Status,
        string ActiveForm);

    private sealed record Version2Session(
        string SessionId,
        DateTime LastActivityUtc,
        List<string> Order,
        List<Version2Task> Tasks,
        int Index);
}