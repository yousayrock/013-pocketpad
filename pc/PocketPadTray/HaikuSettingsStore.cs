using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace PocketPadTray;

/// <summary>
/// Haiku実況機能専用の設定（%APPDATA%\PocketPad\haiku_settings.json）の読み書き。
/// スマホ同期される SettingsStore とは完全に別ファイル・別スキーマ。APIキーは
/// DPAPI（CurrentUserスコープ）で暗号化して保存し、平文では残さない。
/// </summary>
static class HaikuSettingsStore
{
    static readonly string Dir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PocketPad");

    static readonly string FilePath = Path.Combine(Dir, "haiku_settings.json");

    static readonly object Gate = new();

    public static HaikuSettings Load()
    {
        lock (Gate)
        {
            try
            {
                if (!File.Exists(FilePath)) return new HaikuSettings(false, null, false, null, 0);
                // BOM付きで書かれている場合に備え、文字列ではなくバイト列で渡す
                // （文字列だと先頭のBOMでパースに失敗し、設定が黙って初期値に戻る）。
                using var doc = JsonDocument.Parse(File.ReadAllBytes(FilePath));
                var root = doc.RootElement;
                var enabled = root.TryGetProperty("enabled", out var e) && e.ValueKind == JsonValueKind.True;
                string? apiKey = null;
                if (root.TryGetProperty("apiKeyProtected", out var k) && k.ValueKind == JsonValueKind.String)
                {
                    var protectedBytes = Convert.FromBase64String(k.GetString() ?? "");
                    var plainBytes = ProtectedData.Unprotect(protectedBytes, null, DataProtectionScope.CurrentUser);
                    apiKey = Encoding.UTF8.GetString(plainBytes);
                }
                var paused = root.TryGetProperty("paused", out var p) && p.ValueKind == JsonValueKind.True;
                var pauseReason = root.TryGetProperty("pauseReason", out var r) && r.ValueKind == JsonValueKind.String
                    ? r.GetString()
                    : null;
                var consecutiveFailures = root.TryGetProperty("consecutiveFailures", out var f)
                    && f.TryGetInt32(out var count) ? count : 0;
                return new HaikuSettings(
                    enabled,
                    string.IsNullOrEmpty(apiKey) ? null : apiKey,
                    paused,
                    pauseReason,
                    consecutiveFailures);
            }
            catch (Exception)
            {
                return new HaikuSettings(false, null, false, null, 0);
            }
        }
    }

    /// <summary>設定を保存。apiKeyがnullなら既存の暗号化済みキーをそのまま維持する。</summary>
    public static void Save(
        bool enabled,
        string? apiKey,
        bool? paused = null,
        string? pauseReason = null,
        int? consecutiveFailures = null)
    {
        lock (Gate)
        {
            string? apiKeyProtected = null;
            if (apiKey is not null)
            {
                var plainBytes = Encoding.UTF8.GetBytes(apiKey);
                var protectedBytes = ProtectedData.Protect(plainBytes, null, DataProtectionScope.CurrentUser);
                apiKeyProtected = Convert.ToBase64String(protectedBytes);
            }
            else
            {
                // 既存の暗号化済みキーを維持する。
                // ファイルにBOMが付いている場合、文字列を JsonDocument.Parse に渡すと
                // 先頭のBOMで失敗し、catchに落ちてキーが黙って消える（実機で発生）。
                // バイト列で読めば JsonDocument 側がBOMを正しく読み飛ばす。
                if (File.Exists(FilePath))
                {
                    try
                    {
                        using var doc = JsonDocument.Parse(File.ReadAllBytes(FilePath));
                        if (doc.RootElement.TryGetProperty("apiKeyProtected", out var k)
                            && k.ValueKind == JsonValueKind.String)
                        {
                            apiKeyProtected = k.GetString();
                        }
                    }
                    catch (Exception ex)
                    {
                        // キーを失うのは実害が大きいので、握り潰さず記録する。
                        ErrorLog.Append("HaikuSettingsStore.Save(keep existing key)", ex);
                    }
                }
            }

            var current = Load();
            var effectivePaused = paused ?? current.Paused;
            var effectiveReason = effectivePaused ? pauseReason ?? current.PauseReason : null;
            var effectiveFailures = consecutiveFailures ?? current.ConsecutiveFailures;
            Directory.CreateDirectory(Dir);
            var json = JsonSerializer.Serialize(new
            {
                enabled,
                apiKeyProtected,
                paused = effectivePaused,
                pauseReason = effectiveReason,
                consecutiveFailures = effectiveFailures,
            });
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, json);
            File.Move(tmp, FilePath, overwrite: true);
        }
    }
}

record HaikuSettings(
    bool Enabled,
    string? ApiKey,
    bool Paused,
    string? PauseReason,
    int ConsecutiveFailures)
{
    public bool Available => Enabled && !Paused && !string.IsNullOrEmpty(ApiKey);
}
