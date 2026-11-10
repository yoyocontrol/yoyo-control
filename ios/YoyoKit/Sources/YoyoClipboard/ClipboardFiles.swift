import ImageIO
import UIKit
import UniformTypeIdentifiers
import YoyoCore

/// The files the clipboard's moves keep for a moment: copies of picked items before they are sent, the computer's
/// files before they are shared or saved. In the app's temporary folder, one folder per file (its name kept).
package enum ClipboardFiles {
    package static var root: URL { FileManager.default.temporaryDirectory.appending(path: "YoyoClipboard", directoryHint: .isDirectory) }

    /// A new file named `name` (made safe) in a folder of its own.
    package static func url(name: String) throws -> URL {
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var safe = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        if safe.isEmpty || safe == "." || safe == ".." { safe = "file" }
        return folder.appending(path: safe)
    }

    /// `data` written as `name`.
    package static func write(_ data: Data, name: String) throws -> URL {
        let url = try url(name: name)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A copy of `url` (a picker's file that goes away after its callback) as `name`.
    package static func keepCopy(of url: URL, name: String) throws -> URL {
        let ext = url.pathExtension
        let base = (name as NSString).deletingPathExtension
        let copy = try self.url(name: ext.isEmpty ? name : (base.isEmpty ? "file" : base) + "." + ext)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    /// A copy made by `keepCopy` / `write` goes (its folder too).
    package static func discard(_ url: URL) {
        guard url.path.hasPrefix(root.path) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// The MIME type of a file extension.
    package static func mimeType(for ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// A file of this phone as an upload (its size read from disk).
    package static func upload(_ url: URL, name: String? = nil) throws -> YoyoUpload {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return YoyoUpload(file: url, filename: name ?? url.lastPathComponent, mime: mimeType(for: url.pathExtension), size: size)
    }

    /// An SF Symbol for a file by its name's type.
    static func symbol(name: String) -> String {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }

    /// Downscaled, orientation-applied decode (ImageIO thumbnailing: never decodes the full image).
    package static func thumbnail(data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// A file the computer can't take (bigger than the backend's `clipboardFileLimit`).
package struct ClipboardTooLarge: Error, Equatable {
    package let filename: String

    package static func check(_ url: URL, limit: Int) throws {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit {
            throw ClipboardTooLarge(filename: url.lastPathComponent)
        }
    }
}

/// An item provider carried across the concurrency boundary (`NSItemProvider` isn't `Sendable`; each is used from one
/// task at a time).
package struct ClipboardProvider: @unchecked Sendable {
    package let value: NSItemProvider
    package init(_ value: NSItemProvider) { self.value = value }

    package enum Failure: Error { case unreadable }

    package func imageData() async throws -> Data {
        try await withCheckedThrowingContinuation { c in
            _ = value.loadDataRepresentation(for: .image) { data, error in
                if let data { c.resume(returning: data) } else { c.resume(throwing: error ?? Failure.unreadable) }
            }
        }
    }

    /// The item as a file of our own (`ClipboardFiles.keepCopy`; discard it when done).
    package func keptFile(name: String, type: UTType? = nil) async throws -> URL {
        let type = type ?? value.registeredContentTypes.first ?? .data
        return try await withCheckedThrowingContinuation { c in
            _ = value.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else { c.resume(throwing: error ?? Failure.unreadable); return }
                c.resume(with: Result { try ClipboardFiles.keepCopy(of: url, name: name) })
            }
        }
    }

    package func string() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            _ = value.loadObject(ofClass: NSString.self) { s, error in
                if let s = s as? String { c.resume(returning: s) } else { c.resume(throwing: error ?? Failure.unreadable) }
            }
        }
    }

    package func url() async throws -> URL {
        try await withCheckedThrowingContinuation { c in
            _ = value.loadObject(ofClass: NSURL.self) { u, error in
                if let u = u as? URL { c.resume(returning: u) } else { c.resume(throwing: error ?? Failure.unreadable) }
            }
        }
    }
}
