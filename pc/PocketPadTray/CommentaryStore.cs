using System.Text.Json;

namespace PocketPadTray;

record CommentaryEntry(string Text, string Timestamp);

/// <summary>短期の実況履歴。資料室の日誌とは別ファイルで直近100件だけを保持する。</summary>
static class CommentaryStore
{
    static readonly string Dir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PocketPad");
    static readonly string FilePath = Path.Combine(Dir, "commentary.json");
    static readonly object Gate = new();
    const int MaxEntries = 100;

    public static List<CommentaryEntry> Load()
    {
        lock (Gate)
        {
            try
            {
                if (!File.Exists(FilePath)) return new();
                using var doc = JsonDocument.Parse(File.ReadAllText(FilePath));
                if (!doc.RootElement.TryGetProperty("entries", out var arr)
                    || arr.ValueKind != JsonValueKind.Array) return new();
                return arr.EnumerateArray()
                    .Where(e => e.ValueKind == JsonValueKind.Object)
                    .Select(e => new CommentaryEntry(
                        e.TryGetProperty("text", out var text) ? text.GetString() ?? "" : "",
                        e.TryGetProperty("timestamp", out var timestamp) ? timestamp.GetString() ?? "" : ""))
                    .Where(e => !string.IsNullOrWhiteSpace(e.Text))
                    .TakeLast(MaxEntries)
                    .ToList();
            }
            catch (Exception ex)
            {
                ErrorLog.Append("CommentaryStore.Load", ex);
                return new();
            }
        }
    }

    public static void Append(CommentaryEntry entry)
    {
        lock (Gate)
        {
            var entries = Load();
            entries.Add(entry);
            while (entries.Count > MaxEntries) entries.RemoveAt(0);
            Directory.CreateDirectory(Dir);
            var json = JsonSerializer.Serialize(new
            {
                entries = entries.Select(e => new { text = e.Text, timestamp = e.Timestamp }),
            });
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, json);
            File.Move(tmp, FilePath, overwrite: true);
        }
    }
}
