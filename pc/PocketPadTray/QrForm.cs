using System.Net;
using System.Net.Sockets;
using QRCoder;

namespace PocketPadTray;

/// <summary>
/// 接続用QRコードを表示するウィンドウ。スマホアプリの「QRコードで接続」で読み取ると
/// IP・ポート・トークンの手入力なしで接続できる。
/// ペイロードはアプリ側パーサーと同じ "PP|IP|PORT|TOKEN" 形式（データ量最小・読み取り高速）。
/// レイアウトは自動サイズのTableLayoutPanelで組む（座標決め打ちだと見切れるため）。
/// </summary>
class QrForm : Form
{
    // アプリ側と同じサイバーパンク配色（kBg / kAccent）
    private static readonly Color Bg = Color.FromArgb(5, 8, 16);
    private static readonly Color Accent = Color.FromArgb(0, 245, 255);
    private static readonly Color TextGray = Color.FromArgb(150, 160, 180);

    private readonly WsServer _server;

    public QrForm(WsServer server)
    {
        _server = server;
        _server.ClientAuthenticated += OnClientAuthenticated; // 接続されたら自動で閉じる

        var ip = PrimaryIPv4();
        var payload = $"PP|{ip}|{server.Port}|{server.PairingToken}";

        using var generator = new QRCodeGenerator();
        using var qrData = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.Q);
        // PNG内蔵の余白（クワイエットゾーン）は外し、白パネルのPaddingを余白として使う
        // （余白の二重取りでQR本体が小さくなるのを防ぐ）
        var png = new PngByteQRCode(qrData).GetGraphic(20,
            new byte[] { 0, 0, 0, 255 }, new byte[] { 255, 255, 255, 255 },
            drawQuietZones: false);

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
            Padding = new Padding(32, 20, 32, 24),
        };

        var title = MakeLabel("PocketPad",
            new Font("Segoe UI", 22, FontStyle.Bold), Accent);

        // QRは読み取り信頼性のため白背景・黒モジュールのまま。枠だけシアンで光らせる
        var qrPanel = new Panel
        {
            BackColor = Color.White,
            Padding = new Padding(24), // 読み取りに必要な白余白（約2モジュール分）
            Size = new Size(390, 390),
            Anchor = AnchorStyles.None,
            Margin = new Padding(0, 14, 0, 14),
        };
        qrPanel.Paint += (_, e) =>
        {
            using var pen = new Pen(Accent, 3);
            e.Graphics.DrawRectangle(pen, 1, 1, qrPanel.Width - 3, qrPanel.Height - 3);
        };
        qrPanel.Controls.Add(new PictureBox
        {
            Image = Image.FromStream(new MemoryStream(png)),
            SizeMode = PictureBoxSizeMode.Zoom,
            Dock = DockStyle.Fill,
            BackColor = Color.White,
        });

        // 自動折り返しに任せると「）」だけ落ちる等バランスが崩れるため明示的に改行する
        var guide = MakeLabel("スマホの「QRコードで接続」で読み取り\n（PCと同じWiFiに接続してください）",
            new Font("Segoe UI", 10), Color.White);

        var manual = MakeLabel(
            $"手動入力用　IP {ip} : {server.Port}\nトークン {server.PairingToken}",
            new Font("Segoe UI", 9), TextGray);

        layout.Controls.Add(title);
        layout.Controls.Add(qrPanel);
        layout.Controls.Add(guide);
        layout.Controls.Add(manual);
        Controls.Add(layout);
    }

    /// <summary>
    /// 外向き通信に使われるIPv4を返す（実際に送信はしない）。
    /// 仮想アダプタ等が複数あってもLAN側のIPを選べる。
    /// </summary>
    private static string PrimaryIPv4()
    {
        try
        {
            using var s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, 0);
            s.Connect("8.8.8.8", 65530);
            return ((IPEndPoint)s.LocalEndPoint!).Address.ToString();
        }
        catch
        {
            return Dns.GetHostAddresses(Dns.GetHostName())
                .FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork
                    && !IPAddress.IsLoopback(a))?.ToString() ?? "127.0.0.1";
        }
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
        MaximumSize = new Size(420, 0), // 折り返し上限（QRパネル幅に合わせる）。高さは自動
        TextAlign = ContentAlignment.MiddleCenter,
        Anchor = AnchorStyles.None,     // セル内で中央寄せ
        Margin = new Padding(0, 5, 0, 5),
    };
}
