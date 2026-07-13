using System.Drawing.Imaging;

namespace PocketPadTray;

/// <summary>
/// PC画面をキャプチャしてJPEG(base64)で返す。スマホへ転送してスマホ側で
/// 完結（表示・保存・トリミング）できるようにする。
/// </summary>
static class ScreenCapture
{
    /// <summary>全モニタを含む仮想画面全体をJPEGでキャプチャしbase64で返す。</summary>
    public static string CaptureJpegBase64(int quality = 80)
    {
        var bounds = SystemInformation.VirtualScreen;
        using var bmp = new Bitmap(bounds.Width, bounds.Height);
        using (var g = Graphics.FromImage(bmp))
        {
            g.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size);
        }

        var jpegCodec = ImageCodecInfo.GetImageEncoders()
            .First(c => c.FormatID == ImageFormat.Jpeg.Guid);
        using var ep = new EncoderParameters(1);
        ep.Param[0] = new EncoderParameter(Encoder.Quality, (long)quality);

        using var ms = new MemoryStream();
        bmp.Save(ms, jpegCodec, ep);
        return Convert.ToBase64String(ms.ToArray());
    }
}
