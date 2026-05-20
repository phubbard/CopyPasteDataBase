using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace CpdbWin.Core.Analysis;

/// <summary>
/// On-device image classifier — the Windows analogue of macOS Vision's
/// <c>VNClassifyImageRequest</c>. Runs a bundled MobileNetV2 ImageNet-1k
/// model through ONNX Runtime, top-K labels go into <c>image_tags</c>
/// and fold into the FTS5 search index alongside <c>ocr_text</c>.
///
/// <para>
/// Design notes:
/// </para>
/// <list type="bullet">
/// <item><b>Local, no network.</b> The model + labels ship in the
///       Velopack package under <c>Models\</c> next to the assembly;
///       resolved via <see cref="AppContext.BaseDirectory"/> so the
///       same code path works in the GUI install, the CLI, and the
///       xUnit runner.</item>
/// <item><b>Singleton session.</b> <see cref="InferenceSession"/>
///       creation is expensive (~tens to hundreds of ms); the lifetime
///       is naturally process-scoped, so we lazy-init a static shared
///       instance and reuse it across every classification.</item>
/// <item><b>Best-effort.</b> Every failure path (missing model, native
///       library load issue, undecodable image, inference throw)
///       returns <c>null</c> so a classifier mishap can never break the
///       OCR pass running alongside it. Only cancellation throws.</item>
/// </list>
/// </summary>
public static class ImageClassifier
{
    private const string ModelFileName  = "mobilenetv2-12.onnx";
    private const string LabelsFileName = "imagenet1k_labels.txt";

    // Input tensor: NCHW float32, 1×3×224×224. RGB, normalised with the
    // canonical ImageNet mean/std used to train MobileNetV2.
    private const int Width  = 224;
    private const int Height = 224;
    private static readonly float[] Mean  = { 0.485f, 0.456f, 0.406f };
    private static readonly float[] Stdev = { 0.229f, 0.224f, 0.225f };

    // Lazy singleton — the model load is too expensive to repeat per
    // image, and InferenceSession is documented thread-safe for Run().
    private static readonly Lazy<(InferenceSession? Session, string[] Labels)> _instance =
        new(LoadModel, isThreadSafe: true);

    /// <summary>True when the model + labels loaded successfully. Lets
    /// the service skip silently when the bundle is missing (a stripped
    /// build, dev sanity-check) instead of stamping a null tag on every
    /// image forever.</summary>
    public static bool IsAvailable =>
        _instance.Value.Session is not null && _instance.Value.Labels.Length == 1000;

    /// <summary>
    /// Top-<paramref name="topK"/> ImageNet labels for the image,
    /// space-separated for direct storage in
    /// <c>entries.image_tags</c> (FTS5 tokenizes on whitespace so
    /// search-by-tag works without further processing). Returns
    /// <c>null</c> when the classifier is unavailable or the image
    /// couldn't be processed — <i>never</i> throws (cancellation aside).
    /// </summary>
    public static async Task<string?> ClassifyAsync(
        byte[] imageBytes,
        int topK = 3,
        CancellationToken ct = default)
    {
        if (imageBytes is null || imageBytes.Length == 0) return null;
        var (session, labels) = _instance.Value;
        if (session is null || labels.Length != 1000) return null;

        try
        {
            var tensor = await DecodeToTensorAsync(imageBytes, ct).ConfigureAwait(false);
            if (tensor is null) return null;

            // Input/output names hard-coded to the model's actual graph
            // ("input" / "output" for ONNX Model Zoo mobilenetv2-12).
            var inputs = new[] {
                NamedOnnxValue.CreateFromTensor("input", tensor)
            };
            using var results = session.Run(inputs);
            var output = results[0].AsTensor<float>();   // [1, 1000] logits

            // Pick the top-K class indices. Softmax isn't strictly
            // needed — the argmax of logits matches the argmax of
            // softmax — and skipping it saves a pass.
            var scored = new (int idx, float logit)[output.Dimensions[1]];
            for (int i = 0; i < scored.Length; i++) scored[i] = (i, output[0, i]);
            Array.Sort(scored, (a, b) => b.logit.CompareTo(a.logit));

            var tags = new List<string>(topK);
            for (int i = 0; i < topK && i < scored.Length; i++)
            {
                int idx = scored[i].idx;
                if (idx < 0 || idx >= labels.Length) continue;
                var label = labels[idx];
                if (!string.IsNullOrWhiteSpace(label)) tags.Add(label);
            }
            if (tags.Count == 0) return null;
            // Comma-separated, not space-separated: ImageNet labels are
            // multi-word ("great white shark") so a space would make
            // "great white shark laptop" ambiguous to split. FTS5's
            // default tokenizer (unicode61) treats both ',' and ' ' as
            // separators, so search-by-tag still works either way.
            return string.Join(", ", tags);
        }
        catch (OperationCanceledException) { throw; }
        catch { return null; }
    }

    // ─── Model + labels load ────────────────────────────────────────────

    private static (InferenceSession?, string[]) LoadModel()
    {
        try
        {
            var dir = AppContext.BaseDirectory;
            var modelPath  = Path.Combine(dir, "Models", ModelFileName);
            var labelsPath = Path.Combine(dir, "Models", LabelsFileName);
            if (!File.Exists(modelPath) || !File.Exists(labelsPath))
                return (null, Array.Empty<string>());

            var labels = File.ReadAllLines(labelsPath);
            if (labels.Length != 1000) return (null, Array.Empty<string>());

            // Default SessionOptions = CPU provider, single thread per
            // session. Fine for a 14 MB MobileNetV2: a single inference
            // is tens of ms on modern hardware, and the analysis loop
            // already batches at 3 images per cycle.
            var session = new InferenceSession(modelPath);
            return (session, labels);
        }
        catch
        {
            // The classifier is best-effort: if the native libs fail to
            // load (oddball arch, locked-down VDI), OCR keeps working.
            return (null, Array.Empty<string>());
        }
    }

    // ─── Preprocessing: bytes → BitmapDecoder → 224×224 RGB NCHW tensor ─

    private static async Task<DenseTensor<float>?> DecodeToTensorAsync(
        byte[] imageBytes, CancellationToken ct)
    {
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream))
        {
            writer.WriteBytes(imageBytes);
            await writer.StoreAsync().AsTask(ct).ConfigureAwait(false);
            await writer.FlushAsync().AsTask(ct).ConfigureAwait(false);
            writer.DetachStream();
        }
        stream.Seek(0);

        var decoder = await BitmapDecoder.CreateAsync(stream).AsTask(ct).ConfigureAwait(false);

        // Resize during decode (cheaper than a post-decode re-sample)
        // and force Bgra8 so the pixel layout is predictable.
        var transform = new BitmapTransform
        {
            ScaledWidth         = Width,
            ScaledHeight        = Height,
            InterpolationMode   = BitmapInterpolationMode.Linear,
        };
        using var bmp = await decoder.GetSoftwareBitmapAsync(
            BitmapPixelFormat.Bgra8,
            BitmapAlphaMode.Premultiplied,
            transform,
            ExifOrientationMode.RespectExifOrientation,
            ColorManagementMode.DoNotColorManage)
            .AsTask(ct).ConfigureAwait(false);

        // Pull the BGRA8 byte buffer once; convert + normalise inline
        // into the NCHW float tensor. Three planes (R, G, B), each
        // 224×224, stored as (idx == c*H*W + y*W + x).
        var px = new byte[Width * Height * 4];
        bmp.CopyToBuffer(px.AsBuffer());

        var tensor = new DenseTensor<float>(new[] { 1, 3, Height, Width });
        int planeSize = Height * Width;
        for (int y = 0; y < Height; y++)
        {
            int rowBase = y * Width;
            for (int x = 0; x < Width; x++)
            {
                int i = (rowBase + x) * 4;     // BGRA
                float b = px[i + 0] / 255f;
                float g = px[i + 1] / 255f;
                float r = px[i + 2] / 255f;
                int n = rowBase + x;
                tensor.Buffer.Span[0 * planeSize + n] = (r - Mean[0]) / Stdev[0];
                tensor.Buffer.Span[1 * planeSize + n] = (g - Mean[1]) / Stdev[1];
                tensor.Buffer.Span[2 * planeSize + n] = (b - Mean[2]) / Stdev[2];
            }
        }
        return tensor;
    }
}
