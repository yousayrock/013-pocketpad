using System.Text;

namespace PocketPadTray;

static class TaskHookLog
{
    private static readonly string Dir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PocketPad");

    public static readonly string FilePath = Path.Combine(Dir, "task_hook_dump.log");

    private static readonly object Gate = new();
    private const int MaxLines = 200;

    public static void Append(ReadOnlySpan<byte> json)
    {
        try
        {
            var line = $"[{DateTimeOffset.Now:O}] {Encoding.UTF8.GetString(json)}";
            lock (Gate)
            {
                Directory.CreateDirectory(Dir);
                var lines = File.Exists(FilePath)
                    ? File.ReadAllLines(FilePath).ToList()
                    : new List<string>();
                lines.Add(line);
                if (lines.Count > MaxLines)
                    lines.RemoveRange(0, lines.Count - MaxLines);

                var tempPath = FilePath + ".tmp";
                File.WriteAllLines(tempPath, lines);
                File.Move(tempPath, FilePath, overwrite: true);
            }
        }
        catch (Exception)
        {
            // Logging must never interfere with the hook request.
        }
    }
}
