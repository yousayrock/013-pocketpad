using System.Text.Json;

namespace PocketPadTray;

sealed class DailyCharacter
{
    public int V { get; set; } = 1;
    public string Date { get; set; } = "";
    public string GeneratedAt { get; set; } = "";
    public string Status { get; set; } = "default";
    public int Attempts { get; set; }
    public string? LastAttemptAt { get; set; }
    public string? LastError { get; set; }
    public string Theme { get; set; } = "";
    public string Reason { get; set; } = "";
    public string Personality { get; set; } = "";
    public Dictionary<string, string> Palette { get; set; } = new();
    public string Bg { get; set; } = "#070B16";
    public string Dot { get; set; } = "#FFFFFF";
    public string[] Stand { get; set; } = Array.Empty<string>();
    public string[] Walk { get; set; } = Array.Empty<string>();
    public string[] Blink { get; set; } = Array.Empty<string>();
    public DailyCharacterParts Parts { get; set; } = new();
    public DailyCharacterSelection Selection { get; set; } = new();
}

sealed class DailyCharacterParts
{
    public List<string[]> Antenna { get; set; } = new();
    public List<string[]> Head { get; set; } = new();
    public List<DailyCharacterEyes> Eyes { get; set; } = new();
    public List<string[]> Body { get; set; } = new();
    public List<DailyCharacterLegs> Legs { get; set; } = new();
}

sealed class DailyCharacterEyes
{
    public string[] Open { get; set; } = Array.Empty<string>();
    public string[] Closed { get; set; } = Array.Empty<string>();
}

sealed class DailyCharacterLegs
{
    public string[] Stand { get; set; } = Array.Empty<string>();
    public string[] Walk { get; set; } = Array.Empty<string>();
}

sealed class DailyCharacterSelection
{
    public int Antenna { get; set; }
    public int Head { get; set; }
    public int Eyes { get; set; }
    public int Body { get; set; }
    public int Legs { get; set; }
}

static class DailyCharacterStore
{
    internal const int DayRolloverHour = 4;

    static readonly string Dir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PocketPad");
    static readonly string FilePath = Path.Combine(Dir, "daily_character.json");
    static readonly object Gate = new();
    static DailyCharacter? _cache;

    static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false,
    };

    internal static string DayKey(DateTime local) =>
        local.AddHours(-DayRolloverHour).ToString("yyyy-MM-dd");

    public static DailyCharacter Load()
    {
        lock (Gate)
        {
            if (_cache is not null) return Clone(_cache);
            try
            {
                if (File.Exists(FilePath))
                {
                    var value = JsonSerializer.Deserialize<DailyCharacter>(
                        File.ReadAllText(FilePath), JsonOptions);
                    if (value is not null && HasValidComposedSprite(value))
                    {
                        _cache = value;
                        return Clone(value);
                    }
                    ErrorLog.Append(
                        "DailyCharacterStore.Load",
                        new InvalidDataException("daily_character.jsonに有効なキャラクターがありません"));
                }
            }
            catch (Exception ex)
            {
                ErrorLog.Append("DailyCharacterStore.Load", ex);
            }

            _cache = CreateDefault(DayKey(DateTime.Now));
            return Clone(_cache);
        }
    }

    public static void Save(DailyCharacter value)
    {
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Dir);
                var tmp = FilePath + ".tmp";
                File.WriteAllText(tmp, JsonSerializer.Serialize(value, JsonOptions));
                File.Move(tmp, FilePath, overwrite: true);
                _cache = null;
            }
            catch (Exception ex)
            {
                ErrorLog.Append("DailyCharacterStore.Save", ex);
                _cache = null;
            }
        }
    }

    public static DailyCharacter CreateDefault(string date) => new()
    {
        Date = date,
        GeneratedAt = DateTimeOffset.Now.ToString("O"),
        Status = "default",
        Palette = new Dictionary<string, string>
        {
            ["0"] = "#000000",
            ["1"] = "#00F5FF",
            ["2"] = "#FF006E",
        },
        Bg = "#070B16",
        Dot = "#FFFFFF",
        Stand =
        [
            "...2...", ".11111.", "1111111", "1101011",
            "1111111", ".11111.", "..1.1..", "..1.1..",
        ],
        Walk =
        [
            "...2...", ".11111.", "1111111", "1101011",
            "1111111", ".11111.", ".1...1.", "1.....1",
        ],
        Blink =
        [
            "...2...", ".11111.", "1111111", "1111111",
            "1111111", ".11111.", "..1.1..", "..1.1..",
        ],
    };

    static bool HasValidComposedSprite(DailyCharacter value)
    {
        if (value.Stand?.Length != 8 || value.Walk?.Length != 8 || value.Blink?.Length != 8)
            return false;
        var keys = value.Palette?.Keys.ToHashSet() ?? new HashSet<string>();
        return value.Stand.Concat(value.Walk).Concat(value.Blink).All(row =>
            row is { Length: 7 } && row.All(c => c == '.' || keys.Contains(c.ToString())));
    }

    static DailyCharacter Clone(DailyCharacter value) =>
        JsonSerializer.Deserialize<DailyCharacter>(
            JsonSerializer.Serialize(value, JsonOptions), JsonOptions)
        ?? CreateDefault(DayKey(DateTime.Now));
}
