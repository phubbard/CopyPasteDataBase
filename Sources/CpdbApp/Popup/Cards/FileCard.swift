import SwiftUI
import AppKit
import CpdbCore
import CpdbShared

/// Rendering for `file` entries. We don't own the file's bytes; we own the
/// `public.file-url` flavor, which points at the real file on disk.
///
/// If the file still exists and looks like an image, we render the image
/// itself so the user sees *what* file they copied, not just a generic
/// document icon. Otherwise we fall back to `NSWorkspace.icon(forFile:)`.
struct FileCard: View {
    let row: EntryRepository.EntryRow

    /// File extensions that `NSImage(contentsOf:)` can decode reliably on
    /// macOS 14+.
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif",
        "bmp", "webp", "avif",
    ]

    var body: some View {
        VStack(spacing: 10) {
            mainPreview

            Text(filename)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            if let parent = parentDir {
                Text(parent)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Either the actual image (for image files that still exist) or a
    /// large system icon.
    @ViewBuilder
    private var mainPreview: some View {
        if let image = imagePreview {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                // Fill most of the card vertically; `.clipped()` prevents
                // oversized aspect ratios from spilling into the filename.
                .frame(maxWidth: .infinity, maxHeight: 220)
                .padding(.horizontal, 10)
                .padding(.top, 10)
        } else {
            Image(nsImage: fileIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .padding(.top, 14)
        }
    }

    private var fileURL: URL? {
        guard let text = row.entry.textPreview, let url = URL(string: text) else { return nil }
        return url
    }

    private var filename: String {
        fileURL?.lastPathComponent ?? row.entry.title ?? "(file)"
    }

    private var parentDir: String? {
        fileURL?.deletingLastPathComponent().path
    }

    private var fileIcon: NSImage {
        if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    /// Attempt to load the file as an image. Returns nil for non-image
    /// files, missing files, or decode failures (all fall back to the
    /// generic icon path).
    private var imagePreview: NSImage? {
        guard let url = fileURL else { return nil }
        let ext = url.pathExtension.lowercased()
        guard Self.imageExtensions.contains(ext) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }
}
