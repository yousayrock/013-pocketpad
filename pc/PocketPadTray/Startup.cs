using System.Diagnostics;

namespace PocketPadTray;

/// <summary>
/// Windowsスタートアップ登録。タスクスケジューラ方式（/RL HIGHEST・ログオン時トリガー）。
/// レジストリRunキー方式だと非昇格起動になり、app.manifestのrequireAdministratorと
/// 組み合わせるとログオンのたびにUACプロンプトが出てしまう。タスクスケジューラの
/// 「最上位の特権で実行」はログオントリガーでは無音昇格されるため、この形にしている。
/// </summary>
static class Startup
{
    private const string TaskName = "PocketPad";

    private static string ExePath => Environment.ProcessPath
        ?? Application.ExecutablePath;

    public static bool IsEnabled() => RunSchtasks("/Query", "/TN", TaskName, "/NH") == 0;

    /// <summary>登録⇔解除を切り替え、切替後の状態を返す。</summary>
    public static bool Toggle()
    {
        if (IsEnabled())
        {
            RunSchtasks("/Delete", "/TN", TaskName, "/F");
            return false;
        }
        // パスにスペースが含まれても壊れないよう、/TRの値自体に埋め込みの引用符を付ける
        // （schtasksは/TRの値を「実行コマンドライン」として独自解釈するため必須）。
        RunSchtasks(
            "/Create", "/TN", TaskName, "/TR", $"\"{ExePath}\"",
            "/SC", "ONLOGON", "/RL", "HIGHEST", "/F");
        return true;
    }

    private static int RunSchtasks(params string[] args)
    {
        var psi = new ProcessStartInfo("schtasks.exe")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        using var p = Process.Start(psi);
        if (p is null) return -1;
        p.WaitForExit();
        return p.ExitCode;
    }
}
