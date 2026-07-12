using System.Drawing.Drawing2D;

namespace PocketPadTray;

/// <summary>
/// トレイ・ウィンドウ用アイコンをコードから描画する（画像アセット不要）。
/// 近黒サークル＋シアンリング＋「P」。アプリの配色（#050810 × #00F5FF）と統一。
/// </summary>
static class IconFactory
{
    public static Icon CreateAppIcon()
    {
        var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
            g.Clear(Color.Transparent);

            using var bg = new SolidBrush(Color.FromArgb(5, 8, 16));
            g.FillEllipse(bg, 1, 1, 30, 30);

            // 外側にほんのりグロー、内側にくっきりリング
            using var glow = new Pen(Color.FromArgb(90, 0, 245, 255), 4f);
            g.DrawEllipse(glow, 2, 2, 28, 28);
            using var ring = new Pen(Color.FromArgb(0, 245, 255), 2f);
            g.DrawEllipse(ring, 3, 3, 26, 26);

            using var font = new Font("Segoe UI", 16, FontStyle.Bold, GraphicsUnit.Pixel);
            using var text = new SolidBrush(Color.FromArgb(0, 245, 255));
            var format = new StringFormat
            {
                Alignment = StringAlignment.Center,
                LineAlignment = StringAlignment.Center,
            };
            g.DrawString("P", font, text, new RectangleF(0, 1, 32, 32), format);
        }
        // GetHiconのハンドルはアプリ存続中ずっと使うため解放しない
        return Icon.FromHandle(bmp.GetHicon());
    }
}
