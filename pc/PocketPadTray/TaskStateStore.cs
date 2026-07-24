using System.Text.Json;

namespace PocketPadTray;

/// <summary>TaskCreate/TaskUpdateから複製したタスク一覧1件分。</summary>
record TaskStateEntry(string Id, string Content, string Status, string ActiveForm);

/// <summary>
/// WsServerがTaskCreate/TaskUpdateから複製しているタスク状態（%APPDATA%\PocketPad\task_state.json）
/// の読み書き。トレイ再起動をまたいでも直前の一覧・採番カウンタを保つことで、再起動直後の
/// TaskUpdateが「(不明なタスク)」になる問題を避ける（ただしこのプロセスが一度も観測していない
/// taskIdは元々分からないため、それ自体は解消しない。あくまで「このトレイの記録」の永続化）。
/// </summary>
static class TaskStateStore
{
    static readonly string Dir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PocketPad");

    static readonly string FilePath = Path.Combine(Dir, "task_state.json");

    static readonly object Gate = new();

    public static (int counter, List<string> order, List<TaskStateEntry> tasks) Load()
    {
        lock (Gate)
        {
            try
            {
                if (!File.Exists(FilePath)) return (0, new List<string>(), new List<TaskStateEntry>());
                using var doc = JsonDocument.Parse(File.ReadAllText(FilePath));
                var root = doc.RootElement;
                var counter = root.TryGetProperty("counter", out var c) && c.ValueKind == JsonValueKind.Number
                    ? c.GetInt32() : 0;

                var order = new List<string>();
                if (root.TryGetProperty("order", out var orderEl) && orderEl.ValueKind == JsonValueKind.Array)
                {
                    foreach (var o in orderEl.EnumerateArray())
                        if (o.ValueKind == JsonValueKind.String) order.Add(o.GetString() ?? "");
                }

                var tasks = new List<TaskStateEntry>();
                if (root.TryGetProperty("tasks", out var tasksEl) && tasksEl.ValueKind == JsonValueKind.Array)
                {
                    foreach (var t in tasksEl.EnumerateArray())
                    {
                        if (t.ValueKind != JsonValueKind.Object) continue;
                        string? Get(string name) =>
                            t.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
                                ? v.GetString() : null;
                        var id = Get("id");
                        if (string.IsNullOrEmpty(id)) continue;
                        tasks.Add(new TaskStateEntry(id, Get("content") ?? "", Get("status") ?? "pending", Get("activeForm") ?? ""));
                    }
                }
                return (counter, order, tasks);
            }
            catch (Exception ex)
            {
                ErrorLog.Append("TaskStateStore.Load", ex);
                return (0, new List<string>(), new List<TaskStateEntry>());
            }
        }
    }

    public static void Save(int counter, List<string> order, List<TaskStateEntry> tasks)
    {
        lock (Gate)
        {
            Directory.CreateDirectory(Dir);
            var payload = new
            {
                counter,
                order,
                tasks = tasks.Select(t => new { id = t.Id, content = t.Content, status = t.Status, activeForm = t.ActiveForm }),
            };
            var json = JsonSerializer.Serialize(payload);
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, json);
            File.Move(tmp, FilePath, overwrite: true);
        }
    }
}
