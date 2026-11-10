import ImageIO
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import YoyoCore

/// Moving clipboard content between the phone and the computer (UIKit side of `ClipboardActions`): reading
/// `UIPasteboard.general` or pasted item providers into a `PhoneContent`, sending a payload, putting the computer's
/// item on the phone's clipboard, fetching its image / files.
@MainActor
package enum ClipboardTransfer {
    /// What the phone has copied, read once (the pasteboard is only read on a tap: iOS shows a paste notice otherwise).
    package static func phoneContent() -> ClipboardActions.PhoneContent {
        let board = UIPasteboard.general
        var c = ClipboardActions.PhoneContent()
        if board.hasImages, let image = board.image { c.image = imageFile(image, data: board.data(forPasteboardType: UTType.png.identifier)) }
        if board.hasStrings { c.string = board.string }
        if board.hasURLs { c.url = board.url }
        return c
    }

    /// Pasted item providers (`UIPasteControl`): images as files, file providers as files, else the string or the URL.
    package static func content(from providers: [NSItemProvider]) async -> ClipboardActions.PhoneContent {
        var c = ClipboardActions.PhoneContent()
        for p in providers.map(ClipboardProvider.init) {
            let types = p.value.registeredContentTypes
            if types.contains(where: { $0.conforms(to: .image) }), let data = try? await p.imageData(),
               let file = imageFile(data: data, name: p.value.suggestedName ?? "Image") {
                if c.image == nil { c.image = file } else { c.files.append(file) }
            } else if types.contains(where: { $0.conforms(to: .fileURL) || ($0.conforms(to: .data) && !$0.conforms(to: .text) && !$0.conforms(to: .url)) }),
                      let url = try? await p.keptFile(name: p.value.suggestedName ?? "file") {
                if let file = try? ClipboardFiles.upload(url) { c.files.append(file) }
            } else if types.contains(where: { $0.conforms(to: .url) }), let url = try? await p.url() {
                if c.url == nil { c.url = url }
            } else if types.contains(where: { $0.conforms(to: .text) }), let s = try? await p.string() {
                if c.string == nil { c.string = s }
            }
        }
        // one image and more files: all files
        if let image = c.image, !c.files.isEmpty { c.files.insert(image, at: 0); c.image = nil }
        return c
    }

    /// A pasteboard image as a file: its PNG when the pasteboard has one (keeps transparency), else JPEG.
    package static func imageFile(_ image: UIImage, data png: Data?) -> YoyoUpload? {
        if let png { return YoyoUpload(data: png, filename: "Pasted image.png", mime: "image/png") }
        guard let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
        return YoyoUpload(data: jpeg, filename: "Pasted image.jpg", mime: "image/jpeg")
    }

    /// Image bytes as they came (PNG / JPEG / HEIC…), named by their type.
    package static func imageFile(data: Data, name: String) -> YoyoUpload? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String?,
              let ut = UTType(type) else { return nil }
        let base = (name as NSString).deletingPathExtension
        let ext = ut.preferredFilenameExtension ?? "img"
        return YoyoUpload(data: data, filename: (base.isEmpty ? "Image" : base) + "." + ext, mime: ut.preferredMIMEType ?? "application/octet-stream")
    }

    /// What to say once the payload is on the computer: "Copied to the Mac" (text), "Sent to the Mac · saved in
    /// Downloads".
    package static func sentMessage(_ payload: ClipboardActions.Payload, _ r: ClipboardPutResponse, computer: YoyoComputer = .mac) -> String {
        if case .text = payload { return computer.copiedTo }
        return computer.sent(savedIn: r.savedFolderName)
    }

    /// What to say when sending failed (413: too large; else the server's reason).
    package static func failureMessage(_ error: Error, _ payload: ClipboardActions.Payload, limit: Int) -> String {
        if case YoyoError.http(413, _) = error {
            if case .text = payload { return L("Too long to copy (max 1 MB).") }
            return L("The file is too large (\(ClipboardActions.sizeText(limit)) max).")
        }
        return message(error)
    }

    package static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// The payload onto the computer's clipboard (a text, or files).
    package static func send(_ payload: ClipboardActions.Payload, backend: any YoyoBackend,
                             progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ClipboardPutResponse {
        switch payload {
        case .text(let s): return try await backend.putClipboard(text: s)
        case .files(let files): return try await backend.putClipboard(files: files, progress: progress)
        }
    }

    private static var images: [String: Data] = [:]

    /// The computer's image item (kept for the run, so the thumbnail, Copy, Share and Save use the same bytes).
    package static func image(changeCount: Int, backend: any YoyoBackend) async throws -> Data {
        let key = "\(backend.cacheScope):\(changeCount)"
        if let data = images[key] { return data }
        let data = try await backend.clipboardImage(changeCount: changeCount)
        // only the latest few (an image may be large)
        if images.count >= 4 { images.removeAll() }
        images[key] = data
        return data
    }

    /// The picture onto the phone's clipboard (as PNG data and as an image: apps take either).
    package static func putOnPhone(imageData data: Data) {
        var item: [String: Any] = [UTType.png.identifier: data]
        if let image = UIImage(data: data) { item["public.image"] = image }
        UIPasteboard.general.items = [item]
    }

    package static func putOnPhone(text: String) {
        UIPasteboard.general.string = text
    }

    /// Into the photo library (add-only access; the prompt comes once).
    package static func saveToPhotos(_ data: Data) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard status == .authorized || status == .limited else { throw SaveError.noPhotosAccess }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    package enum SaveError: Error, LocalizedError {
        case noPhotosAccess
        package var errorDescription: String? {
            let app = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ""
            return L("Allow \(app) to add to your photo library in Settings to save images.")
        }
    }

    /// The regular files of a files item downloaded into a temporary folder, one after another (`progress`: index done,
    /// total). Folders are skipped (the computer can't send them); over-size files are refused by the server (413).
    package static func downloadFiles(_ item: ClipboardItem, backend: any YoyoBackend,
                                      progress: @escaping @MainActor (_ done: Int, _ total: Int, _ fraction: Double) -> Void) async throws -> [URL] {
        let regular = item.summary.files.enumerated().filter { !$0.element.dir }
        var urls: [URL] = []
        for (n, (index, file)) in regular.enumerated() {
            progress(n, regular.count, 0)
            let got = try await backend.clipboardFile(index: index, changeCount: item.changeCount) { f in
                Task { @MainActor in progress(n, regular.count, f) }
            }
            let name = got.name.flatMap { $0.isEmpty ? nil : $0 } ?? file.name
            let data = got.data
            urls.append(try await Task.detached { try ClipboardFiles.write(data, name: name) }.value)
        }
        progress(regular.count, regular.count, 1)
        return urls
    }
}

/// Photos… / Files… for the computer's clipboard (the Clipboard page, the Screen page's clipboard menu and its Paste
/// key): presents the picker, reads what was picked into files (≤ 20, each ≤ the backend's limit; originals), and hands
/// them over. The presenter keeps it while it works.
@MainActor
package final class ClipboardPicker: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    package enum Source: Sendable { case photos, files }

    /// Reading the picked items: "Reading 2 of 3…" (nil: done).
    package var onProgress: ((String?) -> Void)?
    /// The picked items as files, or why they couldn't be read (a too-large file names itself).
    package var onPicked: ((Result<[YoyoUpload], Error>) -> Void)?
    package private(set) var reading = false
    /// The largest file taken (bytes).
    package var limit = 95_000_000

    package override init() { super.init() }

    package func present(_ source: Source, from vc: UIViewController) {
        switch source {
        case .photos:
            var config = PHPickerConfiguration()
            config.filter = .any(of: [.images, .videos])
            config.selectionLimit = ClipboardLimits.filesPerItem
            // the originals (HEIC / HEVC): this is a copy onto the computer
            config.preferredAssetRepresentationMode = .current
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            vc.present(picker, animated: true)
        case .files:
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
            picker.allowsMultipleSelection = true
            picker.delegate = self
            vc.present(picker, animated: true)
        }
    }

    package func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let limit = self.limit
        collect(urls.map { url in { @Sendable in
            try ClipboardTooLarge.check(url, limit: limit)
            let copy = try ClipboardFiles.keepCopy(of: url, name: url.lastPathComponent)
            return try ClipboardFiles.upload(copy)
        } })
    }

    package func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let limit = self.limit
        collect(results.map { r in
            let provider = ClipboardProvider(r.itemProvider)
            return { @Sendable in
                let url = try await provider.keptFile(name: provider.value.suggestedName ?? "Photo")
                do {
                    try ClipboardTooLarge.check(url, limit: limit)
                } catch {
                    ClipboardFiles.discard(url)
                    throw error
                }
                return try ClipboardFiles.upload(url)
            }
        })
    }

    /// The picked items read one after another (the progress counting), then handed over.
    private func collect(_ makers: [@Sendable () async throws -> YoyoUpload]) {
        guard !makers.isEmpty, !reading else { return }
        reading = true
        onProgress?(L("Reading 1 of \(makers.count)…"))
        Task {
            var files: [YoyoUpload] = []
            var failure: Error?
            for (i, make) in makers.enumerated() {
                onProgress?(L("Reading \(i + 1) of \(makers.count)…"))
                do { files.append(try await make()) } catch { failure = error; break }
            }
            reading = false
            onProgress?(nil)
            if let failure { onPicked?(.failure(failure)) } else { onPicked?(.success(files)) }
        }
    }

    /// What to say when picked items couldn't be read.
    package func message(_ error: Error) -> String {
        (error as? ClipboardTooLarge).map { L("\($0.filename) is too large (max \(ClipboardActions.sizeText(limit))).") }
            ?? ClipboardTransfer.message(error)
    }
}
