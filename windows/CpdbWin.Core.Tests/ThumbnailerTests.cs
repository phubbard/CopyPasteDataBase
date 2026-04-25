using CpdbWin.Core.Capture;
using Xunit;

namespace CpdbWin.Core.Tests;

public class ThumbnailerTests
{
    /// <summary>
    /// Build a real PNG by routing a synthetic DIB through DibToPng — same
    /// codec stack the production capture path uses.
    /// </summary>
    private static byte[] BuildPng(int width, int height)
    {
        int rowStride = ((width * 3 + 3) / 4) * 4;
        int pixelBytes = rowStride * height;
        using var ms = new MemoryStream();
        var w = new BinaryWriter(ms);
        w.Write(40);
        w.Write(width); w.Write(height);
        w.Write((short)1); w.Write((short)24);
        w.Write(0); w.Write(pixelBytes);
        w.Write(0); w.Write(0); w.Write(0); w.Write(0);
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                w.Write((byte)(x & 0xFF));
                w.Write((byte)(y & 0xFF));
                w.Write((byte)((x + y) & 0xFF));
            }
            int pad = rowStride - width * 3;
            for (int i = 0; i < pad; i++) w.Write((byte)0);
        }
        return DibToPng.Convert(ms.ToArray())
            ?? throw new InvalidOperationException("Test fixture build failed");
    }

    private static readonly byte[] JpegSoi = { 0xFF, 0xD8, 0xFF };

    [Fact]
    public void Generate_ProducesSmallAndLargeJpegs()
    {
        var png = BuildPng(800, 600);

        var thumbs = Thumbnailer.Generate(png);

        Assert.NotNull(thumbs.Small);
        Assert.NotNull(thumbs.Large);
        Assert.Equal(JpegSoi, thumbs.Small![..3]);
        Assert.Equal(JpegSoi, thumbs.Large![..3]);
    }

    [Fact]
    public void Generate_ScalesDownWithLongestSide_RespectingLimits()
    {
        var png = BuildPng(800, 600);
        var thumbs = Thumbnailer.Generate(png);

        var (sw, sh) = ReadJpegDims(thumbs.Small!);
        var (lw, lh) = ReadJpegDims(thumbs.Large!);

        Assert.True(Math.Max(sw, sh) <= Thumbnailer.SmallMaxSide,
            $"small longest side should be ≤ {Thumbnailer.SmallMaxSide}; got {sw}x{sh}");
        Assert.True(Math.Max(lw, lh) <= Thumbnailer.LargeMaxSide);
        // Aspect ratio should be preserved within rounding.
        Assert.InRange(sw / (double)sh, 800.0 / 600 - 0.05, 800.0 / 600 + 0.05);
    }

    [Fact]
    public void Generate_DoesNotUpscaleSmallSources()
    {
        var png = BuildPng(40, 30);  // already smaller than SmallMaxSide
        var thumbs = Thumbnailer.Generate(png);

        var (sw, sh) = ReadJpegDims(thumbs.Small!);
        Assert.Equal(40u, sw);
        Assert.Equal(30u, sh);
    }

    [Fact]
    public void Generate_ReturnsNullsForCorruptInput()
    {
        var thumbs = Thumbnailer.Generate(new byte[] { 1, 2, 3, 4, 5 });
        Assert.Null(thumbs.Small);
        Assert.Null(thumbs.Large);
    }

    [Fact]
    public void Generate_ReturnsNullsForEmpty()
    {
        var thumbs = Thumbnailer.Generate(Array.Empty<byte>());
        Assert.Null(thumbs.Small);
        Assert.Null(thumbs.Large);
    }

    /// <summary>
    /// Skim the JPEG SOFn marker to read width/height. JPEG markers are
    /// 0xFFCn for n in {0,1,2,3,5,6,7,9,10,11,13,14,15}; the next 16 bits
    /// are length, then 1 byte sample precision, then 16-bit height,
    /// 16-bit width.
    /// </summary>
    private static (uint W, uint H) ReadJpegDims(byte[] jpeg)
    {
        int p = 2; // skip SOI
        while (p < jpeg.Length - 8)
        {
            if (jpeg[p] != 0xFF) { p++; continue; }
            byte marker = jpeg[p + 1];
            if (marker >= 0xC0 && marker <= 0xCF
                && marker != 0xC4 && marker != 0xC8 && marker != 0xCC)
            {
                ushort h = (ushort)((jpeg[p + 5] << 8) | jpeg[p + 6]);
                ushort w = (ushort)((jpeg[p + 7] << 8) | jpeg[p + 8]);
                return (w, h);
            }
            ushort segLen = (ushort)((jpeg[p + 2] << 8) | jpeg[p + 3]);
            p += 2 + segLen;
        }
        throw new InvalidOperationException("No SOFn marker in JPEG");
    }
}
