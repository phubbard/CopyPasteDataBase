using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace CpdbWin.Core.Analysis;

/// <summary>
/// On-device OCR for image entries via Windows' built-in
/// <see cref="OcrEngine"/> (Windows.Media.Ocr) — no model bundling, no
/// network, no third-party dependency. This is the Windows analogue of
/// the macOS Vision <c>VNRecognizeTextRequest</c> pass; the recognised
/// text is folded into the same FTS5 index so screenshots become
/// searchable by their contents.
///
/// <para>
/// Image classification / tags (macOS <c>VNClassifyImageRequest</c>)
/// has no built-in Windows equivalent and is deliberately out of scope
/// for this pass — <c>image_tags</c> stays NULL (tracked ⏳ in
/// <c>docs/parity.md</c>).
/// </para>
///
/// <para>
/// Best-effort: every failure path (no language pack / OcrEngine
/// unavailable, undecodable bytes, oversized image) returns
/// <c>null</c> rather than throwing — the caller stamps
/// <c>analyzed_at</c> regardless so a bad image isn't retried forever.
/// </para>
/// </summary>
public static class ImageOcr
{
    /// <summary>
    /// Recognise text in <paramref name="imageBytes"/> (PNG/JPEG/BMP —
    /// anything <see cref="BitmapDecoder"/> understands). Returns the
    /// joined text (one line per recognised line), or <c>null</c> when
    /// nothing was recognised or OCR is unavailable.
    /// </summary>
    public static async Task<string?> RecognizeAsync(
        byte[] imageBytes,
        CancellationToken ct = default)
    {
        if (imageBytes is null || imageBytes.Length == 0) return null;

        try
        {
            // OcrEngine uses the user's profile languages; fall back to
            // en-US. Null means no OCR language pack is installed —
            // nothing we can do, treat as "analyzed, no text".
            var engine = OcrEngine.TryCreateFromUserProfileLanguages()
                      ?? OcrEngine.TryCreateFromLanguage(
                             new Windows.Globalization.Language("en-US"));
            if (engine is null) return null;

            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream))
            {
                writer.WriteBytes(imageBytes);
                await writer.StoreAsync().AsTask(ct).ConfigureAwait(false);
                await writer.FlushAsync().AsTask(ct).ConfigureAwait(false);
                writer.DetachStream();
            }
            stream.Seek(0);

            var decoder = await BitmapDecoder
                .CreateAsync(stream).AsTask(ct).ConfigureAwait(false);

            // OcrEngine rejects images whose larger side exceeds
            // MaxImageDimension; scale down on decode if needed (keeps
            // aspect ratio — OCR cares about legibility, not 1:1 px).
            uint w = decoder.PixelWidth, h = decoder.PixelHeight;
            uint max = OcrEngine.MaxImageDimension;
            var transform = new BitmapTransform();
            if (w > max || h > max)
            {
                double scale = (double)max / Math.Max(w, h);
                transform.ScaledWidth  = (uint)Math.Max(1, w * scale);
                transform.ScaledHeight = (uint)Math.Max(1, h * scale);
                transform.InterpolationMode = BitmapInterpolationMode.Linear;
            }

            using var bmp = await decoder.GetSoftwareBitmapAsync(
                BitmapPixelFormat.Bgra8,
                BitmapAlphaMode.Premultiplied,
                transform,
                ExifOrientationMode.RespectExifOrientation,
                ColorManagementMode.DoNotColorManage)
                .AsTask(ct).ConfigureAwait(false);

            var result = await engine.RecognizeAsync(bmp).AsTask(ct).ConfigureAwait(false);

            if (result?.Lines is null || result.Lines.Count == 0) return null;
            var text = string.Join("\n", result.Lines.Select(l => l.Text)).Trim();
            return string.IsNullOrWhiteSpace(text) ? null : text;
        }
        catch (OperationCanceledException)
        {
            throw; // cancellation isn't a failure — let the loop unwind
        }
        catch
        {
            return null; // undecodable / unsupported / engine quirk
        }
    }
}
