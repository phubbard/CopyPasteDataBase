using System.Buffers.Binary;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace CpdbWin.Core.Capture;

/// <summary>
/// Re-encodes a CF_DIB / CF_DIBV5 byte buffer as a PNG. CF_DIB lacks the
/// 14-byte <c>BITMAPFILEHEADER</c> that WinRT's <c>BitmapDecoder</c> wants
/// to see at the front of a BMP, so we synthesize one and concatenate.
///
/// Decoder + encoder come from <c>Windows.Graphics.Imaging</c> — no third-
/// party deps; the same APIs Windows.Media.Ocr uses, so the OCR pipeline
/// later inherits this codec stack.
/// </summary>
public static class DibToPng
{
    /// <summary>Returns PNG bytes, or null if the DIB is malformed / can't be decoded.</summary>
    public static byte[]? Convert(ReadOnlySpan<byte> dib)
    {
        var bmpFile = WrapAsBmpFile(dib);
        if (bmpFile is null) return null;

        try
        {
            return EncodeAsPng(bmpFile);
        }
        catch
        {
            // BitmapDecoder throws for unsupported DIB shapes (rare custom
            // compressions, etc.). Drop the flavor; the caller will simply
            // skip it.
            return null;
        }
    }

    private static byte[]? WrapAsBmpFile(ReadOnlySpan<byte> dib)
    {
        // BITMAPINFOHEADER is 40 bytes; BITMAPV4HEADER 108; BITMAPV5HEADER
        // 124. Reject the legacy BITMAPCOREHEADER (12 bytes) since modern
        // clipboard sources don't use it and its different layout would
        // need its own parser.
        if (dib.Length < 40) return null;

        int biSize = BinaryPrimitives.ReadInt32LittleEndian(dib[..4]);
        if (biSize < 40 || biSize > dib.Length) return null;

        int biBitCount    = BinaryPrimitives.ReadInt16LittleEndian(dib.Slice(14, 2));
        int biCompression = BinaryPrimitives.ReadInt32LittleEndian(dib.Slice(16, 4));
        int biClrUsed     = BinaryPrimitives.ReadInt32LittleEndian(dib.Slice(32, 4));

        // Palette is only present for 1/4/8 bpp images; biClrUsed=0 means
        // "use the maximum (2^bpp) entries".
        int paletteEntries = 0;
        if (biBitCount > 0 && biBitCount <= 8)
            paletteEntries = biClrUsed != 0 ? biClrUsed : (1 << biBitCount);
        int paletteBytes = paletteEntries * 4;

        // BI_BITFIELDS / BI_ALPHABITFIELDS pad three or four DWORDs of
        // colour masks after the basic BITMAPINFOHEADER. Larger headers
        // (V4/V5) carry the masks inline, so no extra bytes needed there.
        const int BI_BITFIELDS = 3;
        const int BI_ALPHABITFIELDS = 6;
        int bitfieldsExtra = 0;
        if (biSize == 40)
        {
            if (biCompression == BI_BITFIELDS) bitfieldsExtra = 12;
            else if (biCompression == BI_ALPHABITFIELDS) bitfieldsExtra = 16;
        }

        int bfOffBits = 14 + biSize + paletteBytes + bitfieldsExtra;
        if (bfOffBits > 14 + dib.Length) return null;

        int bfSize = 14 + dib.Length;
        var bmp = new byte[bfSize];
        bmp[0] = (byte)'B';
        bmp[1] = (byte)'M';
        BinaryPrimitives.WriteInt32LittleEndian(bmp.AsSpan(2, 4),  bfSize);
        // bytes 6..10: bfReserved1, bfReserved2 — zero
        BinaryPrimitives.WriteInt32LittleEndian(bmp.AsSpan(10, 4), bfOffBits);
        dib.CopyTo(bmp.AsSpan(14));
        return bmp;
    }

    private static byte[] EncodeAsPng(byte[] bmpFile)
    {
        using var inStream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(inStream))
        {
            writer.WriteBytes(bmpFile);
            writer.StoreAsync().AsTask().GetAwaiter().GetResult();
            // Detach so disposing the writer doesn't take the stream with it.
            writer.DetachStream();
        }
        inStream.Seek(0);

        var decoder = BitmapDecoder.CreateAsync(BitmapDecoder.BmpDecoderId, inStream)
            .AsTask().GetAwaiter().GetResult();
        var bitmap = decoder.GetSoftwareBitmapAsync().AsTask().GetAwaiter().GetResult();

        using var outStream = new InMemoryRandomAccessStream();
        var encoder = BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, outStream)
            .AsTask().GetAwaiter().GetResult();
        encoder.SetSoftwareBitmap(bitmap);
        encoder.FlushAsync().AsTask().GetAwaiter().GetResult();

        outStream.Seek(0);
        uint size = (uint)outStream.Size;
        var result = new byte[size];
        using (var reader = new DataReader(outStream))
        {
            reader.LoadAsync(size).AsTask().GetAwaiter().GetResult();
            reader.ReadBytes(result);
            reader.DetachStream();
        }
        return result;
    }
}
