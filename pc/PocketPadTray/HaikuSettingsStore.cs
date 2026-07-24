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
                if (!File.Exists(FilePath)) return new HaikuSettings(false, null);
                var text = File.ReadAllText(FilePath);
                using var doc = JsonDocument.Parse(text);
                var root = doc.RootElement;
                var enabled = root.TryGetProperty("enabled", out var e) && e.ValueKind == JsonValueKind.True;
                string? apiKey = null;
                if (root.TryGetProperty("apiKeyProtected", out var k) && k.ValueKind == JsonValueKind.String)
                {
                    var protectedBytes = Convert.FromBase64String(k.GetString() ?? "");
                    var plainBytes = ProtectedData.Unprotect(protectedBytes, null, DataProtectionScope.CurrentUser);
                    apiKey = Encoding.UTF8.GetString(plainBytes);
                }
                return new HaikuSettings(enabled, string.IsNullOrEmpty(apiKey) ? null : apiKey);
            }
            catch (Exception)
            {
                return new HaikuSettings(false, null);
            }
        }
    }

    /// <summary>設定を保存。apiKeyがnullなら既存の暗号化済みキーをそのまま維持する。</summary>
    public static void Save(bool enabled, string? apiKey)
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
                // 既存の暗号化済みキーを維持する
                if (File.Exists(FilePath))
                {
                    try
                    {
                        using var doc = JsonDocument.Parse(File.ReadAllText(FilePath));
                        if (doc.RootElement.TryGetProperty("apiKeyProtected", out var k)
                            && k.ValueKind == JsonValueKind.String)
                        {
                            apiKeyProtected = k.GetString();
                        }
                    }
                    catch (Exception) { /* 壊れていれば無視して新規扱い */ }
                }
            }

            Directory.CreateDirectory(Dir);
            var json = JsonSerializer.Serialize(new { enabled, apiKeyProtected });
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, json);
            File.Move(tmp, FilePath, overwrite: true);
        }
    }
}

record HaikuSettings(bool Enabled, string? ApiKey);
