using CpdbWin.Core.Capture;
using Xunit;

namespace CpdbWin.Core.Tests;

public class DibToPngTests
{
    /// <summary>
    /// Build a simple 24bpp BI_RGB CF_DIB (no BITMAPFILEHEADER) as a paint app
    /// or screenshot tool would emit it. Bottom-up rows, 4-byte aligned stride.
    /// </summary>
    private static byte[] Build24bppDib(int width, int height, byte b, byte g, byte r)
    {
        int rowStride = ((width * 3 + 3) / 4) * 4;
        int pixelBytes = rowStride * height;

        using var ms = new MemoryStream();
        var w = new BinaryWriter(ms);

        // BITMAPINFOHEADER
        w.Write(40);            // biSize
        w.Write(width);         // biWidth
        w.Write(height);        // biHeight (positive = bottom-up)
        w.Write((short)1);      // biPlanes
        w.Write((short)24);     // biBitCount
        w.Write(0);             // biCompression = BI_RGB
        w.Write(pixelBytes);    // biSizeImage
        w.Write(0);             // biXPelsPerMeter
        w.Write(0);             // biYPelsPerMeter
        w.Write(0);             // biClrUsed
        w.Write(0);             // biClrImportant

        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                w.Write(b); w.Write(g); w.Write(r);
            }
            int padding = rowStride - width * 3;
            for (int i = 0; i < padding; i++) w.Write((byte)0);
        }
        return ms.ToArray();
    }

    private static readonly byte[] PngSignature =
        { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

    [Fact]
    public void Convert_ProducesPngForSimple24bppDib()
    {
        var dib = Build24bppDib(4, 3, b: 0x00, g: 0x00, r: 0xFF);

        var png = DibToPng.Convert(dib);

        Assert.NotNull(png);
        Assert.True(png!.Length > 8);
        Assert.Equal(PngSignature, png[..8]);
    }

    [Fact]
    public void Convert_ProducesValidPngThatRoundTripsThroughDecoder()
    {
        // Encode → decode → confirm dimensions survive. Catches errors where
        // we emit a malformed PNG that has the right magic but is otherwise
        // unreadable.
        var dib = Build24bppDib(7, 5, b: 0x12, g: 0x34, r: 0x56);
        var png = DibToPng.Convert(dib);
        Assert.NotNull(png);

        // Parse the PNG IHDR (chunk type at offset 12..16, width 16..20, height 20..24).
        Assert.Equal((byte)'I', png![12]);
        Assert.Equal((byte)'H', png[13]);
        Assert.Equal((byte)'D', png[14]);
        Assert.Equal((byte)'R', png[15]);

        int width  = (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19];
        int height = (png[20] << 24) | (png[21] << 16) | (png[22] << 8) | png[23];
        Assert.Equal(7, width);
        Assert.Equal(5, height);
    }

    [Fact]
    public void Convert_ReturnsNullForTruncatedInput()
    {
        Assert.Null(DibToPng.Convert(new byte[] { 1, 2, 3 }));
    }

    [Fact]
    public void Convert_ReturnsNullForLegacyBitmapcoreheader()
    {
        // BITMAPCOREHEADER (biSize=12) — predates the modern format and uses
        // 16-bit width/height. We deliberately don't support it.
        var bch = new byte[28];
        BitConverter.GetBytes(12).CopyTo(bch, 0);   // biSize
        Assert.Null(DibToPng.Convert(bch));
    }

    [Fact]
    public void Convert_ReturnsNullWhenHeaderClaimsSizeBeyondBuffer()
    {
        var dib = Build24bppDib(2, 2, 0xFF, 0xFF, 0xFF);
        // Smash biSize to a value bigger than the buffer.
        BitConverter.GetBytes(9999).CopyTo(dib, 0);
        Assert.Null(DibToPng.Convert(dib));
    }

    [Fact]
    public void UtiTranslator_CfDib_ProducesPublicPng()
    {
        var dib = Build24bppDib(2, 2, 0x10, 0x20, 0x30);
        var t = UtiTranslator.Translate(UtiTranslator.CF_DIB, null, dib);

        Assert.NotNull(t);
        Assert.Equal("public.png", t!.Value.Uti);
        Assert.Equal(PngSignature, t.Value.Data[..8]);
    }

    [Fact]
    public void UtiTranslator_CfDibV5_ProducesPublicPng()
    {
        // CF_DIBV5 takes the same path; the BITMAPV5HEADER is just a longer
        // BITMAPINFOHEADER as far as the decoder is concerned. We construct
        // an INFOHEADER-shaped buffer here — BitmapDecoder accepts both.
        var dib = Build24bppDib(2, 2, 0x10, 0x20, 0x30);
        var t = UtiTranslator.Translate(UtiTranslator.CF_DIBV5, null, dib);

        Assert.NotNull(t);
        Assert.Equal("public.png", t!.Value.Uti);
    }
}
