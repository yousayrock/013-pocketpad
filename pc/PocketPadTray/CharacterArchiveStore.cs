using System.Globalization;
using System.Text.Json;

namespace PocketPadTray;

sealed class ArchivedCharacter
{
    public int ArchiveVersion { get; set; } = 1;
    public string Date { get; set; } = "";
    public string Theme { get; set; } = "";
    public string Reason { get; set; } = "";
    public string Personality { get; set; } = "";
    public string Status { get; set; } = "";
    public string[] Stand { get; set; } = Array.Empty<string>();
    public string[] Walk { get; set; } = Array.Empty<string>();
    public string[] Blink { get; set; } = Array.Empty<string>();
    public Dictionary<string, string> Palette { get; set; } = new();
    public string Bg { get; set; } = "";
    public string Dot { get; set; } = "";
    public string? Message { get; set; }
}

sealed class ArchivedCharacterSummary
{
    public string Date { get; set; } = "";
    public string Theme { get; set; } = "";
    public string Status { get; set; } = "";
    public string[] Stand { get; set; } = Array.Empty<string>();
    public Dictionary<string, string> Palette { get; set; } = new();
}

static class CharacterArchiveStore
{
    static readonly string Root = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PocketPad", "archive");
    static readonly object Gate = new();
    static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false,
    };

    public static void Save(DailyCharacter character, string? message)
    {
        if (character.Status is not ("ready" or "holiday"))
            throw new ArgumentException("図鑑には完成したキャラクターだけを保存できます", nameof(character));
        if (!TryParseDate(character.Date, out var date))
            throw new ArgumentException("キャラクターの日付が不正です", nameof(character));

        // 診断項目を持たない専用型へ写すことで、DailyCharacterに項目が増えても図鑑へ混入させない。
        var archived = new ArchivedCharacter
        {
            Date = character.Date,
            Theme = character.Theme,
            Reason = character.Reason,
            Personality = character.Personality,
            Status = character.Status,
            Stand = character.Stand,
            Walk = character.Walk,
            Blink = character.Blink,
            Palette = character.Palette,
            Bg = character.Bg,
            Dot = character.Dot,
            Message = string.IsNullOrWhiteSpace(message) ? null : message.Trim(),
        };

        lock (Gate)
        {
            var yearDir = Path.Combine(Root, date.Year.ToString(CultureInfo.InvariantCulture));
            Directory.CreateDirectory(yearDir);
            var path = Path.Combine(yearDir, $"{character.Date}.json");
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(archived, JsonOptions));
            File.Move(tmp, path, overwrite: true);
        }
    }

    public static List<ArchivedCharacterSummary> LoadMonth(string month)
    {
        if (!DateTime.TryParseExact(month, "yyyy-MM", CultureInfo.InvariantCulture,
                DateTimeStyles.None, out var parsed))
            return new();

        lock (Gate)
        {
            var dir = Path.Combine(Root, parsed.Year.ToString(CultureInfo.InvariantCulture));
            if (!Directory.Exists(dir)) return new();
            var result = new List<ArchivedCharacterSummary>();
            foreach (var path in Directory.EnumerateFiles(dir, $"{month}-??.json").OrderByDescending(x => x))
            {
                try
                {
                    var item = JsonSerializer.Deserialize<ArchivedCharacter>(
                        File.ReadAllText(path), JsonOptions);
                    if (item is null) continue;
                    result.Add(new()
                    {
                        Date = item.Date,
                        Theme = item.Theme,
                        Status = item.Status,
                        Stand = item.Stand,
                        Palette = item.Palette,
                    });
                }
                catch (Exception ex)
                {
                    // 1件の破損で、その月の正常なキャラクターまで見えなくしない。
                    ErrorLog.Append("CharacterArchiveStore.LoadMonth", ex);
                }
            }
            return result;
        }
    }

    public static ArchivedCharacter? LoadDetail(string date)
    {
        if (!TryParseDate(date, out var parsed)) return null;
        lock (Gate)
        {
            try
            {
                var path = Path.Combine(Root, parsed.Year.ToString(CultureInfo.InvariantCulture),
                    $"{date}.json");
                if (!File.Exists(path)) return null;
                return JsonSerializer.Deserialize<ArchivedCharacter>(File.ReadAllText(path), JsonOptions);
            }
            catch (Exception ex)
            {
                ErrorLog.Append("CharacterArchiveStore.LoadDetail", ex);
                return null;
            }
        }
    }

    public static List<string> LoadRecentThemes(int maximum = 60)
    {
        lock (Gate)
        {
            if (!Directory.Exists(Root)) return new();
            var result = new List<string>();
            foreach (var path in Directory.EnumerateFiles(Root, "*.json", SearchOption.AllDirectories)
                         .OrderByDescending(Path.GetFileName).Take(Math.Clamp(maximum, 30, 60)))
            {
                try
                {
                    var item = JsonSerializer.Deserialize<ArchivedCharacter>(
                        File.ReadAllText(path), JsonOptions);
                    if (!string.IsNullOrWhiteSpace(item?.Theme)) result.Add(item.Theme);
                }
                catch (Exception ex)
                {
                    ErrorLog.Append("CharacterArchiveStore.LoadRecentThemes", ex);
                }
            }
            return result;
        }
    }

    static bool TryParseDate(string value, out DateTime date) =>
        DateTime.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture,
            DateTimeStyles.None, out date);
}
