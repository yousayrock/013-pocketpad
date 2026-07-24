using System.Diagnostics;
using System.Net;
using System.Net.Sockets;

namespace PocketPadTray;

static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();

        // 単一インスタンスガード。取得できなければガード入りの別インスタンスが
        // 生きているので黙って引き下がる。ownedのままApplication.Run終了まで保持する。
        using var mutex = new Mutex(initiallyOwned: true, @"Global\PocketPadTray", out var isFirst);
        if (!isFirst) return;

        // ガードの無い古いビルドが残っていたら新しい側から排除する（管理者権限常駐なので可能）。
        // Kestrelがポート9013を掴む前に解放させる必要があるため server.Start() より先。
        KillOtherInstances();

        var server = new WsServer(port: 9013);
        try
        {
            server.Start();
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                $"サーバーを起動できませんでした（ポート{server.Port}が使用中の可能性）。\n" +
                $"既存のPocketPadTrayや他アプリを終了してから再度起動してください。\n\n{ex.Message}",
                "PocketPad 起動エラー",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return;
        }
        // --qr: 起動と同時に接続QRを表示（ショートカット用）
        Application.Run(new TrayContext(server, showQr: args.Contains("--qr")));
        GC.KeepAlive(mutex);
    }

    private static void KillOtherInstances()
    {
        var me = Environment.ProcessId;
        foreach (var p in Process.GetProcessesByName("PocketPadTray"))
        {
            using (p)
            {
                if (p.Id == me) continue;
                try
                {
                    p.Kill();
                    p.WaitForExit(5000);
                }
                catch (Exception)
                {
                    // 既に終了していた・権限不足等。起動は続行し、ポート衝突なら
                    // server.Start()の失敗として表面化する。
                }
            }
        }
    }
}

/// <summary>
/// 常駐トレイアプリ本体。Windows Serviceは不可（Session 0隔離でSendInputが
/// ユーザーデスクトップに届かない）ため、この形態が仕様v1.1の確定構成。
/// </summary>
class TrayContext : ApplicationContext
{
    private readonly NotifyIcon _icon;

    private QrForm? _qrForm;

    public TrayContext(WsServer server, bool showQr = false)
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("接続QRを表示", null, (_, _) => ShowQr(server));
        menu.Items.Add("接続情報を表示（テキスト）", null, (_, _) => ShowInfo(server));
        menu.Items.Add("設定ダッシュボードを開く", null, (_, _) =>
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(
                $"http://localhost:{server.Port}/") { UseShellExecute = true }));
        menu.Items.Add(new ToolStripSeparator());
        var startupItem = new ToolStripMenuItem("Windows起動時に自動起動")
        {
            Checked = Startup.IsEnabled(),
        };
        startupItem.Click += (_, _) => startupItem.Checked = Startup.Toggle();
        menu.Items.Add(startupItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("終了", null, (_, _) => ExitThread());

        // ビルド日時をtooltipに出す（古いバージョンの多重起動を一目で見分けるため）
        var build = Environment.ProcessPath is { } exe
            ? File.GetLastWriteTime(exe).ToString("MM/dd HH:mm")
            : "?";
        _icon = new NotifyIcon
        {
            Icon = IconFactory.CreateAppIcon(),
            Text = $"PocketPad ({build}) — クリックでQR表示",
            Visible = true,
            ContextMenuStrip = menu,
        };
        // 左クリック（シングル）で即QR表示。右クリックは従来どおりメニュー
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) ShowQr(server);
        };
        _icon.BalloonTipTitle = "PocketPad 起動";
        _icon.BalloonTipText = "アイコンをクリックすると接続QRが表示されます";
        _icon.ShowBalloonTip(3000);
        if (showQr) ShowQr(server);
    }

    private void ShowQr(WsServer server)
    {
        if (_qrForm is { IsDisposed: false })
        {
            _qrForm.Activate();
            return;
        }
        _qrForm = new QrForm(server);
        _qrForm.Show();
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
            "スマホアプリの接続画面にこのトークンを入力してください。",
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
