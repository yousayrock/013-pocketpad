using System.Text.Json;

namespace PocketPadTray;

/// <summary>資料室の日誌1件。ターン完了時のClaude自身の最終応答をそのまま保存する
/// （追加のAI要約は行わない）。</summary>
record KnowledgeEntry(
    string Project,
    string Summary,
    string Timestamp,
    string[] ToolsUsed,
    string[] TouchedFiles,
    string? CommitHash);

/// <summary>
/// 資料室ナレッジ（%APPDATA%\PocketPad\knowledge.json）の読み書き。
/// SettingsStore/HaikuSettingsStoreと同じatomic writeパターン。
/// ターン完了ごとに1件追記される「作業の日誌」で、生ログの蓄積はしない軽量方針。
/// </summary>
static class KnowledgeStore
{
    static readonly string Dir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PocketPad");

    static readonly string FilePath = Path.Combine(Dir, "knowledge.json");

    static readonly object Gate = new();

    const int MaxEntries = 500;

    /// <summary>保存済みの全エントリ（古い順）。壊れている/存在しなければ空リスト。</summary>
    public static List<KnowledgeEntry> Load()
    {
        lock (Gate)
        {
            try
            {
                if (!File.Exists(FilePath)) return new List<KnowledgeEntry>();
                var text = File.ReadAllText(FilePath);
                using var doc = JsonDocument.Parse(text);
                if (!doc.RootElement.TryGetProperty("entries", out var arr) || arr.ValueKind != JsonValueKind.Array)
                    return new List<KnowledgeEntry>();

                var result = new List<KnowledgeEntry>();
                foreach (var e in arr.EnumerateArray())
                {
                    if (e.ValueKind != JsonValueKind.Object) continue;
                    string? Get(string name) =>
                        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
                    string[] GetArr(string name)
                    {
                        if (!e.TryGetProperty(name, out var v) || v.ValueKind != JsonValueKind.Array)
                            return Array.Empty<string>();
                        return v.EnumerateArray()
                            .Where(x => x.ValueKind == JsonValueKind.String)
                            .Select(x => x.GetString() ?? "")
                            .ToArray();
                    }

                    result.Add(new KnowledgeEntry(
                        Project: Get("project") ?? "(不明)",
                        Summary: Get("summary") ?? "",
                        Timestamp: Get("timestamp") ?? "",
                        ToolsUsed: GetArr("toolsUsed"),
                        TouchedFiles: GetArr("touchedFiles"),
                        CommitHash: Get("commitHash")));
                }
                return result;
            }
            catch (Exception ex)
            {
                ErrorLog.Append("KnowledgeStore.Load", ex);
                return new List<KnowledgeEntry>();
            }
        }
    }

    /// <summary>1件追記する。上限(<see cref="MaxEntries"/>)を超えたら古いものから削除する。</summary>
    public static void Append(KnowledgeEntry entry)
    {
        lock (Gate)
        {
            var entries = LoadLocked();
            entries.Add(entry);
            while (entries.Count > MaxEntries) entries.RemoveAt(0);
            SaveLocked(entries);
        }
    }

    static List<KnowledgeEntry> LoadLocked()
    {
        // Load()は自前でロックを取るため、Gate保持中に呼ぶと再入(reentrant)ロックが必要になる。
        // Monitorは同一スレッドからの再入を許すので問題ないが、意図を明確にするため専用の
        // ロックなし版をここに複製せず、Loadをそのまま呼ぶ（.NETのlockはスレッド単位で再入可能）。
        return Load();
    }

    static void SaveLocked(List<KnowledgeEntry> entries)
    {
        Directory.CreateDirectory(Dir);
        var payload = new
        {
            entries = entries.Select(e => new
            {
                project = e.Project,
                summary = e.Summary,
                timestamp = e.Timestamp,
                toolsUsed = e.ToolsUsed,
                touchedFiles = e.TouchedFiles,
                commitHash = e.CommitHash,
            }),
        };
        var json = JsonSerializer.Serialize(payload);
        var tmp = FilePath + ".tmp";
        File.WriteAllText(tmp, json);
        File.Move(tmp, FilePath, overwrite: true);
    }
}
