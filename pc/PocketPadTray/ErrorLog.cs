using System.Linq;

namespace PocketPadTray;

/// <summary>
/// 「失敗しても無視する」おまけ機能（Haiku実況・資料室ナレッジ等）の例外を、
/// 黙って握りつぶすのではなく %APPDATA%\PocketPad\error.log に残すための簡易ロガー。
/// 動作自体は変えない（引き続き非致命的に扱う）が、後から「何が起きていたか」を追える。
/// </summary>
static class ErrorLog
{
    static readonly string Dir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PocketPad");

    static readonly string FilePath = Path.Combine(Dir, "error.log");

    static readonly object Gate = new();

    const int MaxLines = 500;

    /// <summary>1件記録する。書き込み自体の失敗はここで飲み込む（ロガーが例外を出したら本末転倒）。</summary>
    public static void Append(string context, Exception ex)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(Dir);
                var line = $"[{DateTimeOffset.Now:O}] {context}: {ex.GetType().Name}: {ex.Message}";
                var lines = File.Exists(FilePath) ? File.ReadAllLines(FilePath).ToList() : new List<string>();
                lines.Add(line);
                while (lines.Count > MaxLines) lines.RemoveAt(0);
                File.WriteAllLines(FilePath, lines);
            }
        }
        catch (Exception)
        {
            // ロガー自体の失敗は握りつぶす。
        }
    }
}
