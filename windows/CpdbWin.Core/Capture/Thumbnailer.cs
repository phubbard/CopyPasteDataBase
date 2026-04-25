using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace CpdbWin.Core.Capture;

/// <summary>
/// Generates the small + large JPEG thumbnails the schema's
/// <c>previews</c> table holds (longest side ≤ 256 / ≤ 640 px,
/// quality 0.8) for any image format BitmapDecoder understands.
/// </summary>
public static class Thumbnailer
{
    public const uint SmallMaxSide = 256;
    public const uint LargeMaxSide = 640;
    public const double JpegQuality = 0.8;

    public readonly record struct Result(byte[]? Small, byte[]? Large);

    public static Result Generate(byte[] imageBytes)
    {
        if (imageBytes is null || imageBytes.Length == 0) return new Result(null, null);

        try
        {
            var inStream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(inStream))
            {
                writer.WriteBytes(imageBytes);
                writer.StoreAsync().AsTask().GetAwaiter().GetResult();
                writer.DetachStream();
            }
            inStream.Seek(0);

            var decoder = BitmapDecoder.CreateAsync(inStream)
                .AsTask().GetAwaiter().GetResult();
            var bitmap = decoder.GetSoftwareBitmapAsync()
                .AsTask().GetAwaiter().GetResult();

            var small = EncodeScaledJpeg(bitmap, SmallMaxSide);
            var large = EncodeScaledJpeg(bitmap, LargeMaxSide);
            return new Result(small, large);
        }
        catch
        {
            // Decoder rejection (corrupt source) — leave the entry without
            // thumbnails rather than failing the ingest transaction.
            return new Result(null, null);
        }
    }

    private static byte[] EncodeScaledJpeg(SoftwareBitmap bitmap, uint maxSide)
    {
        uint w = (uint)bitmap.PixelWidth;
        uint h = (uint)bitmap.PixelHeight;
        (uint outW, uint outH) = Fit(w, h, maxSide);

        using var outStream = new InMemoryRandomAccessStream();
        var props = new BitmapPropertySet
        {
            { "ImageQuality", new BitmapTypedValue(JpegQuality, Windows.Foundation.PropertyType.Single) },
        };
        var encoder = BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, outStream, props)
            .AsTask().GetAwaiter().GetResult();
        encoder.SetSoftwareBitmap(bitmap);
        encoder.BitmapTransform.ScaledWidth = outW;
        encoder.BitmapTransform.ScaledHeight = outH;
        encoder.IsThumbnailGenerated = false;
        encoder.FlushAsync().AsTask().GetAwaiter().GetResult();

        outStream.Seek(0);
        var size = (uint)outStream.Size;
        var buf = new byte[size];
        using (var reader = new DataReader(outStream))
        {
            reader.LoadAsync(size).AsTask().GetAwaiter().GetResult();
            reader.ReadBytes(buf);
            reader.DetachStream();
        }
        return buf;
    }

    private static (uint W, uint H) Fit(uint w, uint h, uint maxSide)
    {
        if (w <= maxSide && h <= maxSide) return (w, h);
        if (w >= h)
        {
            uint outW = maxSide;
            uint outH = (uint)Math.Max(1, Math.Round(h * (double)maxSide / w));
            return (outW, outH);
        }
        else
        {
            uint outH = maxSide;
            uint outW = (uint)Math.Max(1, Math.Round(w * (double)maxSide / h));
            return (outW, outH);
        }
    }
}
