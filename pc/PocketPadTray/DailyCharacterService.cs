using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace PocketPadTray;

static class DailyCharacterService
{
    static int _running;
    static readonly TimeSpan Cooldown = TimeSpan.FromMinutes(30);
    static readonly TimeSpan Timeout = TimeSpan.FromMinutes(8);
    static readonly Regex ColorRegex = new("^#[0-9A-Fa-f]{6}$", RegexOptions.Compiled);

    public static void EnsureToday()
    {
        var now = DateTimeOffset.Now;
        var current = DailyCharacterStore.Load();
        var today = DailyCharacterStore.DayKey(now.LocalDateTime);
        if (current.Date == today && current.Status == "ready") return;
        if (current.Date == today && current.Attempts >= 3) return;
        if (current.Date == today && ParseDate(current.LastAttemptAt) is { } last
            && last + Cooldown > now) return;
        StartGeneration(force: false, today, now);
    }

    public static void ForceRegenerate()
    {
        var now = DateTimeOffset.Now;
        StartGeneration(force: true, DailyCharacterStore.DayKey(now.LocalDateTime), now);
    }

    static void StartGeneration(bool force, string today, DateTimeOffset now)
    {
        if (Interlocked.CompareExchange(ref _running, 1, 0) != 0) return;
        _ = Task.Run(async () =>
        {
            try { await GenerateAsync(force, today, now); }
            catch (Exception ex) { RecordFailure(today, now, ex); }
            finally { Interlocked.Exchange(ref _running, 0); }
        });
    }

    static async Task GenerateAsync(bool force, string today, DateTimeOffset attemptAt)
    {
        var existing = DailyCharacterStore.Load();
        if (!force && existing.Date == today && existing.Status == "ready") return;

        var working = existing;
        if (working.Date != today)
        {
            working.Date = today;
            working.Attempts = 0;
        }
        working.Status = "generating";
        working.LastAttemptAt = attemptAt.ToString("O");
        working.LastError = null;
        DailyCharacterStore.Save(working);

        var tempDir = Path.Combine(Path.GetTempPath(), "PocketPadDailyCharacter", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempDir);
        var schemaPath = Path.Combine(tempDir, "schema.json");
        var outputPath = Path.Combine(tempDir, "output.json");
        try
        {
            await File.WriteAllTextAsync(schemaPath, OutputSchema);
            var prompt = BuildPrompt(attemptAt.LocalDateTime);

            // codexは.cmd/.ps1のnpmシムなので Process.Start から直接は起動できず、
            // かといって cmd.exe /c を挟むと ArgumentList の自動クォートと cmd の
            // クォート剥がしが噛み合わずパスが壊れる（実機で os error 123）。
            // シムの中身は node.exe に codex.js を渡しているだけなので、node を直接
            // 叩いて cmd.exe を排除する。これで ArgumentList が各引数を正しく
            // エスケープでき、パスに空白があっても壊れない。
            var (nodeExe, codexJs) = ResolveCodexEntry();
            var startInfo = new ProcessStartInfo
            {
                FileName = nodeExe,
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                // プロンプトは日本語を含む。既定だとシステムのレガシーコードページ(CP932)で
                // 書き込まれ、codexが "input is not valid UTF-8" で落ちる（実機で発生）。
                // 受け取り側・返す側ともUTF-8で固定する。
                StandardInputEncoding = new UTF8Encoding(false),
                StandardOutputEncoding = new UTF8Encoding(false),
                StandardErrorEncoding = new UTF8Encoding(false),
            };
            startInfo.ArgumentList.Add(codexJs);
            startInfo.ArgumentList.Add("exec");
            startInfo.ArgumentList.Add("--skip-git-repo-check");
            startInfo.ArgumentList.Add("-s");
            startInfo.ArgumentList.Add("read-only");
            startInfo.ArgumentList.Add("-c");
            startInfo.ArgumentList.Add("approval_policy=never");
            startInfo.ArgumentList.Add("--color");
            startInfo.ArgumentList.Add("never");
            startInfo.ArgumentList.Add("--output-schema");
            startInfo.ArgumentList.Add(schemaPath);
            startInfo.ArgumentList.Add("-o");
            startInfo.ArgumentList.Add(outputPath);
            startInfo.ArgumentList.Add("-");
            using var proc = Process.Start(startInfo)
                ?? throw new InvalidOperationException("codexプロセスを開始できませんでした");
            var stdout = proc.StandardOutput.ReadToEndAsync();
            var stderr = proc.StandardError.ReadToEndAsync();
            await proc.StandardInput.WriteAsync(prompt);
            proc.StandardInput.Close();

            using var timeout = new CancellationTokenSource(Timeout);
            try
            {
                await proc.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException)
            {
                try { proc.Kill(entireProcessTree: true); } catch (Exception) { }
                await Task.WhenAll(stdout, stderr);
                throw new TimeoutException("codexによるキャラクター生成がタイムアウトしました");
            }
            await Task.WhenAll(stdout, stderr);
            if (proc.ExitCode != 0)
                throw new InvalidOperationException(
                    $"codexが終了コード{proc.ExitCode}を返しました: {TrimTail(stderr.Result, 500)}");
            if (!File.Exists(outputPath))
                throw new InvalidOperationException("codexの出力ファイルがありません");

            var output = JsonSerializer.Deserialize<GeneratedDailyCharacter>(
                await File.ReadAllTextAsync(outputPath),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                ?? throw new InvalidDataException("生成JSONを読み取れません");
            var generated = ConvertGenerated(output);
            ValidateAndCompose(generated);
            generated.V = 1;
            generated.Date = today;
            generated.GeneratedAt = DateTimeOffset.Now.ToString("O");
            generated.Status = "ready";
            generated.Attempts = 0;
            generated.LastAttemptAt = attemptAt.ToString("O");
            generated.LastError = null;
            DailyCharacterStore.Save(generated);
        }
        finally
        {
            try { Directory.Delete(tempDir, recursive: true); }
            catch (Exception) { }
        }
    }

    static void RecordFailure(string today, DateTimeOffset attemptedAt, Exception ex)
    {
        ErrorLog.Append("DailyCharacterService.Generate", ex);
        var value = DailyCharacterStore.Load();
        if (value.Date != today) value = DailyCharacterStore.CreateDefault(today);
        value.Status = "default";
        value.Attempts++;
        value.LastAttemptAt = attemptedAt.ToString("O");
        value.LastError = TrimTail(ex.Message, 1000);
        DailyCharacterStore.Save(value);
    }

    static DateTimeOffset? ParseDate(string? value) =>
        DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var parsed)
            ? parsed : null;

    /// <summary>codexのnpmシム（.cmd/.ps1）ではなく、その実体である node.exe と codex.js を
    /// 突き止める。シムはcmd.exe経由でしか起動できず、cmd経由だとクォート処理が壊れるため、
    /// nodeを直接叩けるようにする。見つからなければ例外（呼び出し元が既定キャラへ倒す）。</summary>
    static (string NodeExe, string CodexJs) ResolveCodexEntry()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var npmDir = Path.Combine(appData, "npm");
        var codexJs = Path.Combine(npmDir, "node_modules", "@openai", "codex", "bin", "codex.js");
        if (!File.Exists(codexJs))
        {
            throw new FileNotFoundException($"codex.jsが見つかりません: {codexJs}");
        }

        // シムと同じ解決順: npmディレクトリ同梱のnode.exe → PATH上のnode.exe。
        var bundledNode = Path.Combine(npmDir, "node.exe");
        if (File.Exists(bundledNode)) return (bundledNode, codexJs);

        var pathValue = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in pathValue.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var candidate = Path.Combine(dir.Trim('"'), "node.exe");
                if (File.Exists(candidate)) return (candidate, codexJs);
            }
            catch (Exception)
            {
                // PATHに不正な文字を含む要素があっても止めない
            }
        }

        throw new FileNotFoundException("node.exeが見つかりません（codexの起動に必要）");
    }

    static string BuildPrompt(DateTime localNow)
    {
        var workDate = DailyCharacterStore.DayKey(localNow.AddDays(-1));
        var all = KnowledgeStore.Load()
            .Select(e => (entry: e, time: ParseLocal(e.Timestamp)))
            .Where(x => x.time is not null)
            .OrderByDescending(x => x.time)
            .ToList();
        var selected = all.Where(x => DailyCharacterStore.DayKey(x.time!.Value) == workDate)
            .Take(12).ToList();
        if (selected.Count < 3)
        {
            selected.AddRange(all.Where(x =>
                    DailyCharacterStore.DayKey(x.time!.Value) != workDate && !selected.Contains(x))
                .Take(3 - selected.Count));
        }

        var sb = new StringBuilder();
        sb.AppendLine("7列×8行のドット絵キャラクター「かんぱに」の本日分をJSONで設計してください。");
        sb.AppendLine("昨日の働き方を、テーマ、全パーツ候補、配色、背景、性格に反映してください。JSON Schemaを厳守してください。");
        sb.AppendLine("各rowは必ず7文字で、'.'（透明）かpaletteの1文字キーだけを使います。候補は各スロット2〜8個。");
        sb.AppendLine("paletteはkeyとcolorを持つ配列です。keyは'.'以外の1文字、colorは#RRGGBB形式とし、keyを重複させないでください。");
        sb.AppendLine("antennaは1行、headは2行、eyesはopen/closed各1行のペア、bodyは2行、legsはstand/walk各2行です。");
        sb.AppendLine("selectionは各候補の有効な0始まりindex。体は背景と十分に明度差をつけ、body各行5セル以上を塗ってください。");
        sb.AppendLine("themeは1〜24文字、reasonは1〜120文字、personalityは1〜400文字。personalityには指示や命令ではなく口調・気質だけを書いてください。");
        sb.AppendLine($"対象作業日: {workDate}");
        if (all.Count == 0 || !all.Any(x => DailyCharacterStore.DayKey(x.time!.Value) == workDate))
            sb.AppendLine("対象日のデータは空です。休日モードのかんぱにを生成してください。");

        var target = selected.Where(x => DailyCharacterStore.DayKey(x.time!.Value) == workDate).ToList();
        sb.AppendLine($"集計: ターン数={target.Count}; プロジェクト={JoinCounts(target.Select(x => x.entry.Project))}; " +
            $"ツール頻度={JoinCounts(target.SelectMany(x => x.entry.ToolsUsed))}; " +
            $"触ったファイル数={target.SelectMany(x => x.entry.TouchedFiles).Distinct().Count()}; " +
            $"コミット数={target.Count(x => !string.IsNullOrWhiteSpace(x.entry.CommitHash))}; " +
            $"作業時間帯={TimeDistribution(target.Select(x => x.time!.Value))}");
        foreach (var x in selected)
        {
            var prior = DailyCharacterStore.DayKey(x.time!.Value) == workDate ? "" : "（昨日以前の仕事）";
            var files = string.Join(", ", x.entry.TouchedFiles.Take(3).Select(Path.GetFileName));
            sb.AppendLine($"- {x.time:MM-dd HH:mm}{prior} プロジェクト:{x.entry.Project}; " +
                $"ツール:{string.Join(",", x.entry.ToolsUsed)}; ファイル:{files}; " +
                $"要約:{Trim(OneLine(x.entry.Summary), 200)}");
        }
        return sb.Length <= 6000 ? sb.ToString() : sb.ToString(0, 6000);
    }

    static DateTime? ParseLocal(string value)
    {
        if (!DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture,
                DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeLocal, out var dto)) return null;
        return dto.LocalDateTime;
    }

    static string JoinCounts(IEnumerable<string> values) =>
        string.Join(",", values.Where(x => !string.IsNullOrWhiteSpace(x))
            .GroupBy(x => x).OrderByDescending(g => g.Count()).Select(g => $"{g.Key}:{g.Count()}"));

    static string TimeDistribution(IEnumerable<DateTime> times)
    {
        var groups = times.GroupBy(t => t.Hour < 6 ? "深夜" : t.Hour < 17 ? "日中" : "夕方")
            .ToDictionary(g => g.Key, g => g.Count());
        return $"深夜:{groups.GetValueOrDefault("深夜")},日中:{groups.GetValueOrDefault("日中")}," +
               $"夕方:{groups.GetValueOrDefault("夕方")}";
    }

    static void ValidateAndCompose(DailyCharacter value)
    {
        if (value.Palette is null || value.Parts is null || value.Selection is null
            || value.Parts.Antenna is null || value.Parts.Head is null
            || value.Parts.Eyes is null || value.Parts.Body is null || value.Parts.Legs is null)
            throw new InvalidDataException("必須のパーツまたは配色がありません");
        value.Theme = OneLine(value.Theme).Trim();
        value.Reason = OneLine(value.Reason).Trim();
        value.Personality = OneLine(value.Personality).Replace("`", "").Replace("<", "")
            .Replace(">", "").Replace("#", "").Trim();
        if (value.Theme.Length is < 1 or > 24 || value.Reason.Length is < 1 or > 120
            || value.Personality.Length is < 1 or > 400)
            throw new InvalidDataException("theme/reason/personalityの長さが不正です");
        if (value.Palette.Count == 0 || value.Palette.Any(x =>
                x.Key.Length != 1 || x.Key == "." || !ColorRegex.IsMatch(x.Value)))
            throw new InvalidDataException("paletteが不正です");
        if (!ColorRegex.IsMatch(value.Bg) || !ColorRegex.IsMatch(value.Dot))
            throw new InvalidDataException("背景色が不正です");

        CheckCandidates(value.Parts.Antenna, 1, value.Palette, "antenna");
        CheckCandidates(value.Parts.Head, 2, value.Palette, "head");
        CheckCandidates(value.Parts.Body, 2, value.Palette, "body");
        if (value.Parts.Eyes.Count is < 2 or > 8
            || value.Parts.Legs.Count is < 2 or > 8)
            throw new InvalidDataException("eyes/legsの候補数が不正です");
        foreach (var eyeCandidate in value.Parts.Eyes)
        {
            if (eyeCandidate is null)
                throw new InvalidDataException("eyesの候補が不正です");
            CheckRows(eyeCandidate.Open, 1, value.Palette, "eyes.open");
            CheckRows(eyeCandidate.Closed, 1, value.Palette, "eyes.closed");
        }
        foreach (var legCandidate in value.Parts.Legs)
        {
            if (legCandidate is null)
                throw new InvalidDataException("legsの候補が不正です");
            CheckRows(legCandidate.Stand, 2, value.Palette, "legs.stand");
            CheckRows(legCandidate.Walk, 2, value.Palette, "legs.walk");
        }
        var s = value.Selection;
        if (!InRange(s.Antenna, value.Parts.Antenna.Count) || !InRange(s.Head, value.Parts.Head.Count)
            || !InRange(s.Eyes, value.Parts.Eyes.Count) || !InRange(s.Body, value.Parts.Body.Count)
            || !InRange(s.Legs, value.Parts.Legs.Count))
            throw new InvalidDataException("selectionが範囲外です");

        var antenna = value.Parts.Antenna[s.Antenna];
        var head = value.Parts.Head[s.Head];
        var eyes = value.Parts.Eyes[s.Eyes];
        var body = value.Parts.Body[s.Body];
        var legs = value.Parts.Legs[s.Legs];
        if (body.Any(row => row.Count(c => c != '.') < 5))
            throw new InvalidDataException("bodyが細すぎます");
        value.Stand = antenna.Concat(head).Concat(eyes.Open).Concat(body).Concat(legs.Stand).ToArray();
        value.Walk = antenna.Concat(head).Concat(eyes.Open).Concat(body).Concat(legs.Walk).ToArray();
        value.Blink = antenna.Concat(head).Concat(eyes.Closed).Concat(body).Concat(legs.Stand).ToArray();
        if (value.Stand.Sum(row => row.Count(c => c != '.')) < 12
            || value.Walk.Sum(row => row.Count(c => c != '.')) < 12
            || value.Blink.Sum(row => row.Count(c => c != '.')) < 12)
            throw new InvalidDataException("合成後のキャラクターが透明すぎます");

        var bodyColors = body.SelectMany(x => x).Where(c => c != '.').Distinct()
            .Select(c => value.Palette[c.ToString()]);
        if (!bodyColors.Any(color => Math.Abs(Luminance(color) - Luminance(value.Bg)) >= 0.25))
            throw new InvalidDataException("背景色と体色の明度差が不足しています");
    }

    static DailyCharacter ConvertGenerated(GeneratedDailyCharacter source)
    {
        if (source.Palette is null)
            throw new InvalidDataException("paletteがありません");

        var palette = new Dictionary<string, string>();
        foreach (var entry in source.Palette)
        {
            if (entry is null || entry.Key.Length != 1)
                throw new InvalidDataException("paletteのkeyは1文字である必要があります");
            if (!palette.TryAdd(entry.Key, entry.Color))
                throw new InvalidDataException($"paletteのkeyが重複しています: {entry.Key}");
        }

        return new DailyCharacter
        {
            Theme = source.Theme,
            Reason = source.Reason,
            Personality = source.Personality,
            Palette = palette,
            Bg = source.Bg,
            Dot = source.Dot,
            Parts = source.Parts,
            Selection = source.Selection,
        };
    }

    static void CheckCandidates(List<string[]> candidates, int rows,
        Dictionary<string, string> palette, string name)
    {
        if (candidates.Count is < 2 or > 8)
            throw new InvalidDataException($"{name}の候補数が不正です");
        foreach (var candidate in candidates) CheckRows(candidate, rows, palette, name);
    }

    static void CheckRows(string[] rows, int count, Dictionary<string, string> palette, string name)
    {
        if (rows is null || rows.Length != count || rows.Any(row => row is null || row.Length != 7
            || row.Any(c => c != '.' && !palette.ContainsKey(c.ToString()))))
            throw new InvalidDataException($"{name}のrowが不正です");
    }

    static bool InRange(int value, int count) => value >= 0 && value < count;

    static double Luminance(string color)
    {
        static double Channel(int value)
        {
            var c = value / 255.0;
            return c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
        }
        var r = Convert.ToInt32(color.Substring(1, 2), 16);
        var g = Convert.ToInt32(color.Substring(3, 2), 16);
        var b = Convert.ToInt32(color.Substring(5, 2), 16);
        return 0.2126 * Channel(r) + 0.7152 * Channel(g) + 0.0722 * Channel(b);
    }

    static string OneLine(string? value) =>
        string.Join(" ", (value ?? "").Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries));
    static string Trim(string value, int max) => value.Length <= max ? value : value[..max];
    // Codexのstderrはプロンプトを先頭にエコーし、実際のAPIエラーを末尾に出すため末尾を保持する。
    static string TrimTail(string value, int max) => value.Length <= max ? value : value[^max..];

    const string OutputSchema = """
    {
      "type":"object","additionalProperties":false,
      "required":["theme","reason","personality","palette","bg","dot","parts","selection"],
      "properties":{
        "theme":{"type":"string"},"reason":{"type":"string"},"personality":{"type":"string"},
        "palette":{"type":"array","minItems":2,"maxItems":9,
          "items":{"type":"object","additionalProperties":false,
            "required":["key","color"],
            "properties":{"key":{"type":"string"},"color":{"type":"string"}}}},
        "bg":{"type":"string"},"dot":{"type":"string"},
        "parts":{"type":"object","additionalProperties":false,
          "required":["antenna","head","eyes","body","legs"],
          "properties":{
            "antenna":{"type":"array","minItems":2,"maxItems":8,"items":{"$ref":"#/$defs/rows1"}},
            "head":{"type":"array","minItems":2,"maxItems":8,"items":{"$ref":"#/$defs/rows2"}},
            "eyes":{"type":"array","minItems":2,"maxItems":8,"items":{"type":"object","additionalProperties":false,"required":["open","closed"],"properties":{"open":{"$ref":"#/$defs/rows1"},"closed":{"$ref":"#/$defs/rows1"}}}},
            "body":{"type":"array","minItems":2,"maxItems":8,"items":{"$ref":"#/$defs/rows2"}},
            "legs":{"type":"array","minItems":2,"maxItems":8,"items":{"type":"object","additionalProperties":false,"required":["stand","walk"],"properties":{"stand":{"$ref":"#/$defs/rows2"},"walk":{"$ref":"#/$defs/rows2"}}}}
          }},
        "selection":{"type":"object","additionalProperties":false,
          "required":["antenna","head","eyes","body","legs"],
          "properties":{"antenna":{"type":"integer"},"head":{"type":"integer"},"eyes":{"type":"integer"},"body":{"type":"integer"},"legs":{"type":"integer"}}}
      },
      "$defs":{
        "rows1":{"type":"array","minItems":1,"maxItems":1,"items":{"type":"string"}},
        "rows2":{"type":"array","minItems":2,"maxItems":2,"items":{"type":"string"}}
      }
    }
    """;

    sealed class GeneratedDailyCharacter
    {
        public string Theme { get; set; } = "";
        public string Reason { get; set; } = "";
        public string Personality { get; set; } = "";
        public List<GeneratedPaletteEntry>? Palette { get; set; }
        public string Bg { get; set; } = "";
        public string Dot { get; set; } = "";
        public DailyCharacterParts Parts { get; set; } = new();
        public DailyCharacterSelection Selection { get; set; } = new();
    }

    sealed class GeneratedPaletteEntry
    {
        public string Key { get; set; } = "";
        public string Color { get; set; } = "";
    }
}
