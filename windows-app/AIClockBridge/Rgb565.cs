using System.Drawing;
using System.Drawing.Imaging;

namespace AIClockBridge;

// Big-endian RGB565 decoder for the current device sprite resource stream.
static class Rgb565
{
    /// Big-endian RGB565 bytes -> 32bppRgb bitmap. `offset` is where the pixel
    /// data starts inside `data` (frames streams carry a 1-byte frame count).
    public static Bitmap Decode(byte[] data, int offset, int w, int h)
    {
        var frameBytes = w * h * 2;
        if (data.Length < offset + frameBytes) return null;
        var bmp = new Bitmap(w, h, PixelFormat.Format32bppRgb);
        var locked = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly,
                                  PixelFormat.Format32bppRgb);
        try
        {
            unsafe
            {
                for (int y = 0; y < h; y++)
                {
                    var row = (byte*)locked.Scan0 + y * locked.Stride;
                    for (int x = 0; x < w; x++)
                    {
                        int src = offset + (y * w + x) * 2;
                        ushort v = (ushort)((data[src] << 8) | data[src + 1]);
                        row[x * 4 + 0] = (byte)((v & 0x1F) << 3);         // B
                        row[x * 4 + 1] = (byte)(((v >> 5) & 0x3F) << 2);  // G
                        row[x * 4 + 2] = (byte)(((v >> 11) & 0x1F) << 3); // R
                        row[x * 4 + 3] = 255;
                    }
                }
            }
        }
        finally
        {
            bmp.UnlockBits(locked);
        }
        return bmp;
    }

    /// Wire format [1 byte frame count][RGB565 big-endian frames...] -> bitmaps.
    public static List<Bitmap> DecodeSpriteFrames(byte[] data, int w, int h)
    {
        var frames = new List<Bitmap>();
        if (data == null || data.Length < 1) return frames;
        int count = data[0];
        var frameBytes = w * h * 2;
        if (count <= 0 || data.Length < 1 + count * frameBytes) return frames;
        for (int f = 0; f < count; f++)
        {
            var bmp = Decode(data, 1 + f * frameBytes, w, h);
            if (bmp != null) frames.Add(bmp);
        }
        return frames;
    }
}
