using System.Text.Json;

namespace PocketPadTray;

/// <summary>
/// スマホアプリの設定（%APPDATA%\PocketPad\settings.json）の読み書き。
/// スキーマはスマホ側 AppSettings.toJson() と同一（docs/protocol.md 参照）。
/// 設定の正はこのファイルで、Last-write-wins で同期する。
/// </summary>
static class SettingsStore
{
    static readonly string Dir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PocketPad");

    static readonly string FilePath = Path.Combine(Dir, "settings.json");

    static readonly object Gate = new();

    /// <summary>保存済み設定のJSON文字列。無い/読めないなら null。</summary>
    public static string? Load()
    {
        lock (Gate)
        {
            try
            {
                if (!File.Exists(FilePath)) return null;
                var text = File.ReadAllText(FilePath);
                // 壊れたファイルを配らないよう、パースできるかだけ確認する
                using var _ = JsonDocument.Parse(text);
                return text;
            }
            catch (Exception)
            {
                return null;
            }
        }
    }

    /// <summary>一時ファイル経由で書き込み（書き込み中クラッシュで壊さない）。</summary>
    public static void Save(JsonElement settings)
    {
        lock (Gate)
        {
            Directory.CreateDirectory(Dir);
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, settings.GetRawText());
            File.Move(tmp, FilePath, overwrite: true);
        }
    }

    /// <summary>
    /// 構造の検証（形だけ）。細かい補正はスマホ側 AppSettings.fromJson が行うので、
    /// ここでは「設定として成立しない/別物のJSON」を弾ければよい。
    /// </summary>
    public static bool TryValidate(JsonElement s, out string error)
    {
        error = "";
        if (s.ValueKind != JsonValueKind.Object) { error = "not an object"; return false; }
        if (!s.TryGetProperty("v", out var v) || v.ValueKind != JsonValueKind.Number)
        { error = "missing v"; return false; }
        if (!s.TryGetProperty("sensitivity", out var sens) || sens.ValueKind != JsonValueKind.Number)
        { error = "missing sensitivity"; return false; }
        if (!IsToggleArray(s, "pages", out error)) return false;
        if (!IsToggleArray(s, "bottomButtons", out error)) return false;

        if (!s.TryGetProperty("deck", out var deck) || deck.ValueKind != JsonValueKind.Array)
        { error = "missing deck"; return false; }
        foreach (var b in deck.EnumerateArray())
        {
            if (b.ValueKind != JsonValueKind.Object
                || !b.TryGetProperty("label", out var label) || label.ValueKind != JsonValueKind.String
                || !b.TryGetProperty("icon", out var icon) || icon.ValueKind != JsonValueKind.String
                || !b.TryGetProperty("color", out var color) || color.ValueKind != JsonValueKind.Number
                || !b.TryGetProperty("message", out var msg) || msg.ValueKind != JsonValueKind.Object
                || !msg.TryGetProperty("type", out var mt) || mt.ValueKind != JsonValueKind.String)
            { error = "invalid deck entry"; return false; }
        }
        return true;
    }

    static bool IsToggleArray(JsonElement s, string name, out string error)
    {
        error = "";
        if (!s.TryGetProperty(name, out var arr) || arr.ValueKind != JsonValueKind.Array)
        { error = $"missing {name}"; return false; }
        foreach (var e in arr.EnumerateArray())
        {
            if (e.ValueKind != JsonValueKind.Object
                || !e.TryGetProperty("id", out var id) || id.ValueKind != JsonValueKind.String
                || !e.TryGetProperty("enabled", out var en)
                || en.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            { error = $"invalid {name} entry"; return false; }
        }
        return true;
    }
}
