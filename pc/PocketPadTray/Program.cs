using System.Net;
using System.Net.Sockets;

namespace PocketPadTray;

static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();
        var server = new WsServer(port: 9013);
        server.Start();
        Application.Run(new TrayContext(server));
    }
}

/// <summary>
/// 常駐トレイアプリ本体。Windows Serviceは不可（Session 0隔離でSendInputが
/// ユーザーデスクトップに届かない）ため、この形態が仕様v1.1の確定構成。
/// </summary>
class TrayContext : ApplicationContext
{
    private readonly NotifyIcon _icon;

    public TrayContext(WsServer server)
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("接続情報を表示", null, (_, _) => ShowInfo(server));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("終了", null, (_, _) => ExitThread());

        _icon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "PocketPad — 未来ガジェット013号",
            Visible = true,
            ContextMenuStrip = menu,
        };
        _icon.BalloonTipTitle = "PocketPad 起動";
        _icon.BalloonTipText = $"ポート {server.Port} で待機中。右クリック→接続情報を表示";
        _icon.ShowBalloonTip(3000);
    }

    private static void ShowInfo(WsServer server)
    {
        var ips = Dns.GetHostAddresses(Dns.GetHostName())
            .Where(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a))
            .Select(a => a.ToString())
            .ToArray();
        MessageBox.Show(
            $"接続先: ws://{string.Join(" または ", ips)}:{server.Port}/ws\n" +
            $"ペアリングトークン: {server.PairingToken}\n\n" +
            "スマホアプリの接続画面にこのトークンを入力してください。\n（QRコード表示はPhase1後半で実装）",
            "PocketPad 接続情報",
            MessageBoxButtons.OK,
            MessageBoxIcon.Information);
    }

    protected override void ExitThreadCore()
    {
        _icon.Visible = false;
        _icon.Dispose();
        base.ExitThreadCore();
    }
}
