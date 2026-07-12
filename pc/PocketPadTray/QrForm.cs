using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using QRCoder;

namespace PocketPadTray;

/// <summary>
/// 接続用QRコードを表示するウィンドウ。スマホアプリの「QRコードで接続」で読み取ると
/// IP・ポート・トークンの手入力なしで接続できる。
/// レイアウトは自動サイズのTableLayoutPanelで組む（座標決め打ちだと見切れるため）。
/// </summary>
class QrForm : Form
{
    private static readonly Color Bg = Color.FromArgb(5, 8, 16);
    private static readonly Color Accent = Color.FromArgb(0, 245, 255);
    private static readonly Color TextGray = Color.FromArgb(150, 160, 180);

    private readonly WsServer _server;

    public QrForm(WsServer server)
    {
        _server = server;
        _server.ClientAuthenticated += OnClientAuthenticated; // 接続されたら自動で閉じる
        var ips = Dns.GetHostAddresses(Dns.GetHostName())
            .Where(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a))
            .Select(a => a.ToString())
            .ToArray();

        var payload = JsonSerializer.Serialize(new
        {
            v = 1,
            app = "pocketpad",
            hosts = ips,
            port = server.Port,
            token = server.PairingToken,
        });

        using var generator = new QRCodeGenerator();
        using var qrData = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.Q);
        var png = new PngByteQRCode(qrData).GetGraphic(10);

        Text = "PocketPad — 接続QR";
        Icon = IconFactory.CreateAppIcon();
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true;
        BackColor = Bg;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;

        var layout = new TableLayoutPanel
        {
            ColumnCount = 1,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            BackColor = Bg,
            Padding = new Padding(32, 18, 32, 22),
        };

        var title = MakeLabel("PocketPad",
            new Font("Segoe UI", 22, FontStyle.Bold), Accent);
        var subtitle = MakeLabel("スマホアプリの「QRコードで接続」で読み取ってください",
            new Font("Segoe UI", 10), Color.White);

        // QRは白背景が必須（コントラスト確保）なので白パネルに載せる
        var qrPanel = new Panel
        {
            BackColor = Color.White,
            Padding = new Padding(14),
            Size = new Size(330, 330),
            Anchor = AnchorStyles.None,
            Margin = new Padding(0, 12, 0, 12),
        };
        qrPanel.Controls.Add(new PictureBox
        {
            Image = Image.FromStream(new MemoryStream(png)),
            SizeMode = PictureBoxSizeMode.Zoom,
            Dock = DockStyle.Fill,
            BackColor = Color.White,
        });

        var status = MakeLabel($"● ポート {server.Port} で待機中",
            new Font("Segoe UI", 10, FontStyle.Bold), Accent);

        var info = MakeLabel(
            $"手動入力用　IP: {string.Join(" / ", ips)}\n" +
            $"ポート: {server.Port}　トークン: {server.PairingToken}",
            new Font("Segoe UI", 9), TextGray);

        var hint = MakeLabel("※ スマホとPCを同じWiFiに接続してください",
            new Font("Segoe UI", 9), TextGray);

        layout.Controls.Add(title);
        layout.Controls.Add(subtitle);
        layout.Controls.Add(qrPanel);
        layout.Controls.Add(status);
        layout.Controls.Add(info);
        layout.Controls.Add(hint);
        Controls.Add(layout);
    }

    private void OnClientAuthenticated()
    {
        if (IsDisposed || !IsHandleCreated) return;
        try
        {
            BeginInvoke(Close); // WSスレッドから呼ばれるためUIスレッドへ
        }
        catch (ObjectDisposedException)
        {
            // クローズ競合は無視
        }
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        _server.ClientAuthenticated -= OnClientAuthenticated;
        base.OnFormClosed(e);
    }

    private static Label MakeLabel(string text, Font font, Color color) => new()
    {
        Text = text,
        Font = font,
        ForeColor = color,
        AutoSize = true,
        MaximumSize = new Size(360, 0), // 折り返し上限。高さは自動
        TextAlign = ContentAlignment.MiddleCenter,
        Anchor = AnchorStyles.None,     // セル内で中央寄せ
        Margin = new Padding(0, 5, 0, 5),
    };
}
