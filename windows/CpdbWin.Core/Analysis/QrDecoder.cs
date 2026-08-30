using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using ZXing;
using ZXing.Common;

namespace CpdbWin.Core.Analysis;

/// <summary>
/// QR / barcode decoder for the image-analysis sweeper. Windows port of
/// the <c>VNDetectBarcodesRequest</c> pass in macOS <c>ImageAnalyzer</c>.
///
/// <para>
/// Decode path: PNG/JPEG bytes → WinRT <see cref="BitmapDecoder"/>
/// → BGRA8 pixel buffer → ZXing <see cref="RGBLuminanceSource"/> →
/// <see cref="MultiFormatReader"/> (or its multi-code sibling). All
/// pure-managed after the WinRT decode, so no <c>System.Drawing</c>
/// dependency — <c>CpdbWin.Core</c> stays framework-neutral for
/// unit tests that don't want to spin up a UI dispatcher.
/// </para>
///
/// <para>
/// Fail-soft on every step: a corrupt image, an unsupported codec, a
/// no-QR-found result — all just return an empty list. Detection is
/// best-effort and must never throw from the sweeper's hot loop.
/// </para>
/// </summary>
public static class QrDecoder
{
    /// <summary>
    /// Decode QR + supported 1D/2D barcodes in <paramref name="imageBytes"/>.
    /// Returns the raw payload strings in detection order, empty when
    /// nothing decoded. Deliberately synchronous — the WinRT decode
    /// step is async on the surface but its await points inside a
    /// try/GetAwaiter().GetResult() are safe because we're already off
    /// the UI thread (the sweeper runs on a Timer callback / worker
    /// thread) and the whole operation is bounded by the image size,
    /// not by I/O.
    /// </summary>
    public static IReadOnlyList<string> Decode(byte[] imageBytes)
    {
        if (imageBytes is null || imageBytes.Length == 0) return Array.Empty<string>();
        try
        {
            var (pixels, width, height) = DecodeToBgra8(imageBytes);
            if (pixels is null || width <= 0 || height <= 0) return Array.Empty<string>();
            return ReadBarcodes(pixels, width, height);
        }
        catch
        {
            // Corrupt image / unsupported codec / ZXing hiccup — the
            // sweep continues. QR is an opportunistic pass, not
            // load-bearing for OCR or tagging.
            return Array.Empty<string>();
        }
    }

    private static (byte[]? Pixels, int Width, int Height) DecodeToBgra8(byte[] imageBytes)
    {
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream))
        {
            writer.WriteBytes(imageBytes);
            writer.StoreAsync().AsTask().GetAwaiter().GetResult();
            writer.DetachStream();
        }
        stream.Seek(0);

        var decoder = BitmapDecoder.CreateAsync(stream).AsTask().GetAwaiter().GetResult();
        var transform = new BitmapTransform();
        var pixelProvider = decoder.GetPixelDataAsync(
            BitmapPixelFormat.Bgra8,
            BitmapAlphaMode.Ignore,
            transform,
            ExifOrientationMode.RespectExifOrientation,
            ColorManagementMode.ColorManageToSRgb).AsTask().GetAwaiter().GetResult();

        var pixels = pixelProvider.DetachPixelData();
        return (pixels, (int)decoder.PixelWidth, (int)decoder.PixelHeight);
    }

    private static IReadOnlyList<string> ReadBarcodes(byte[] bgra, int width, int height)
    {
        var lum = new RGBLuminanceSource(bgra, width, height, RGBLuminanceSource.BitmapFormat.BGRA32);
        var binarized = new BinaryBitmap(new HybridBinarizer(lum));

        var hints = new Dictionary<DecodeHintType, object>
        {
            [DecodeHintType.TRY_HARDER] = true,
            // Only scan for QR + a couple of common 1D codes — narrower
            // scope than macOS's "everything Vision supports" but the
            // usual suspects for a screenshot (QR poster, receipt
            // barcode, retail UPC/EAN).
            [DecodeHintType.POSSIBLE_FORMATS] = new List<BarcodeFormat>
            {
                BarcodeFormat.QR_CODE,
                BarcodeFormat.DATA_MATRIX,
                BarcodeFormat.EAN_13,
                BarcodeFormat.EAN_8,
                BarcodeFormat.UPC_A,
                BarcodeFormat.CODE_128,
            },
        };

        var reader = new MultiFormatReader();
        // Single-decode first: cheapest path when the screenshot has
        // exactly one code. Per-image screenshots rarely carry more
        // than one and the first hit is usually the interesting one.
        try
        {
            var result = reader.decode(binarized, hints);
            var text = result?.Text;
            return string.IsNullOrWhiteSpace(text) ? Array.Empty<string>() : new[] { text };
        }
        catch (ReaderException)
        {
            return Array.Empty<string>();
        }
    }
}
