using Microsoft.Win32;

namespace PocketPadTray;

/// <summary>
/// Windowsスタートアップ登録。HKCUのRunキー方式（管理者権限不要・ユーザー単位）。
/// </summary>
static class Startup
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "PocketPad";

    private static string ExePath => Environment.ProcessPath
        ?? Application.ExecutablePath;

    public static bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
        return key?.GetValue(ValueName) is string;
    }

    /// <summary>登録⇔解除を切り替え、切替後の状態を返す。</summary>
    public static bool Toggle()
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath);
        if (key.GetValue(ValueName) is string)
        {
            key.DeleteValue(ValueName, throwOnMissingValue: false);
            return false;
        }
        // パスにスペースが含まれても壊れないよう引用符で囲む。
        // EXEを移動した後に再登録すれば新パスで上書きされる。
        key.SetValue(ValueName, $"\"{ExePath}\"");
        return true;
    }
}
