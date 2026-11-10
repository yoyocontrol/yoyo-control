import AppKit
import XCTest
@testable import YoyoServer

/// The clipboard's pure parts (Clipboard.swift): kind detection from pasteboard types, the preview, the text cut, the JSON
/// shapes, writing text / files, and the monitor's bookkeeping — on a named pasteboard, so the user's own clipboard is
/// untouched.
final class ClipboardTests: XCTestCase {
    private var pb: NSPasteboard!
    private var dir: URL!

    override func setUpWithError() throws {
        pb = NSPasteboard(name: NSPasteboard.Name("ca.sarria.yoyocontrol.tests.clipboard.\(UUID().uuidString)"))
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("yoyo-clipboard-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        pb.releaseGlobally()
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String, bytes: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// A `w`×`h` PNG.
    private func png(width w: Int, height h: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    // MARK: kinds

    func testTextItem() {
        let count = Clipboard.write(pb, text: "hello\nworld")
        let item = Clipboard.read(pb, includeText: true)
        XCTAssertEqual(item.changeCount, count)
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.text, "hello\nworld")
        XCTAssertEqual(item.preview, "hello⏎ world")
        XCTAssertEqual(item.size, 11)
        XCTAssertFalse(item.truncated)
        XCTAssertNil(item.source)
        // the summary path leaves the text out
        XCTAssertNil(Clipboard.read(pb, includeText: false).text)
    }

    func testImageItemFromPNGAndFromTIFF() throws {
        let data = try png(width: 4, height: 3)
        pb.clearContents()
        pb.setData(data, forType: .png)
        var item = Clipboard.read(pb, includeText: true)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.width, 4)
        XCTAssertEqual(item.height, 3)
        XCTAssertEqual(item.size, data.count)
        XCTAssertEqual(item.preview, "")
        XCTAssertNil(item.text)
        XCTAssertEqual(try XCTUnwrap(Clipboard.pngData(pb)).data, data)

        // TIFF only: the PNG is made from it
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: data)?.tiffRepresentation)
        pb.clearContents()
        pb.setData(tiff, forType: .tiff)
        item = Clipboard.read(pb, includeText: true)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.width, 4)
        XCTAssertEqual(item.height, 3)
        let made = try XCTUnwrap(Clipboard.pngData(pb))
        XCTAssertEqual(NSBitmapImageRep(data: made.data)?.pixelsWide, 4)
        XCTAssertEqual(item.size, made.data.count)
    }

    func testFilesItemListsNamesSizesAndFolders() throws {
        let a = try file("a.txt", bytes: 5)
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let b = try file("b.bin", bytes: 7)
        Clipboard.write(pb, files: [a, sub, b])
        let item = Clipboard.read(pb, includeText: true)
        XCTAssertEqual(item.kind, .files)
        XCTAssertEqual(item.files, [
            ClipboardFileInfo(name: "a.txt", size: 5, dir: false),
            ClipboardFileInfo(name: "sub", size: nil, dir: true),
            ClipboardFileInfo(name: "b.bin", size: 7, dir: false),
        ])
        XCTAssertEqual(item.size, 12)
        XCTAssertNil(item.moreFiles)
        XCTAssertEqual(item.preview, "a.txt, sub, b.bin")
        XCTAssertEqual(item.fileURLs.map(\.lastPathComponent), ["a.txt", "sub", "b.bin"])
        // several files: no image data rides along
        XCTAssertNil(pb.pasteboardItems?.first?.data(forType: .png))
    }

    func testMoreThanTwentyFilesAreCounted() throws {
        let urls = try (0..<25).map { try file("f\($0).txt", bytes: 1) }
        Clipboard.write(pb, files: urls)
        let item = Clipboard.read(pb, includeText: false)
        XCTAssertEqual(item.files?.count, 20)
        XCTAssertEqual(item.moreFiles, 5)
        XCTAssertEqual(item.size, 25)
        XCTAssertEqual(item.fileURLs.count, 25)
    }

    func testSingleImageFileCarriesItsData() throws {
        let data = try png(width: 2, height: 2)
        let url = dir.appendingPathComponent("pic.png")
        try data.write(to: url)
        Clipboard.write(pb, files: [url])
        let item = Clipboard.read(pb, includeText: false)
        XCTAssertEqual(item.kind, .files, "a file URL wins over the image data on the same item")
        XCTAssertEqual(pb.pasteboardItems?.first?.data(forType: .png), data)
        XCTAssertEqual(pb.pasteboardItems?.first?.string(forType: .fileURL), url.absoluteString)
    }

    func testConcealedItemsAreNotRead() {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("hunter2", forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.writeObjects([item])
        let read = Clipboard.read(pb, includeText: true)
        XCTAssertEqual(read.kind, .concealed)
        XCTAssertEqual(read.preview, "")
        XCTAssertNil(read.text)
        XCTAssertNil(read.size)
        XCTAssertNil(read.json["text"])
        XCTAssertTrue(read.json["size"] is NSNull)

        pb.clearContents()
        let transient = NSPasteboardItem()
        transient.setString("x", forType: .string)
        transient.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([transient])
        XCTAssertEqual(Clipboard.read(pb, includeText: true).kind, .concealed)
    }

    func testEmptyAndOther() {
        pb.clearContents()
        XCTAssertEqual(Clipboard.read(pb, includeText: true).kind, .empty)
        let item = NSPasteboardItem()
        item.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.private"))
        pb.writeObjects([item])
        let other = Clipboard.read(pb, includeText: true)
        XCTAssertEqual(other.kind, .other)
        XCTAssertEqual(other.preview, "")
        XCTAssertNil(other.size)
    }

    // MARK: preview and text cut

    func testPreviewCollapsesNewlinesAndCutsAt160() {
        XCTAssertEqual(Clipboard.preview("one\r\n\n  two  \rthree"), "one⏎ two⏎ three")
        XCTAssertEqual(Clipboard.preview("  \n\n"), "")
        let long = String(repeating: "a", count: 200)
        let p = Clipboard.preview(long)
        XCTAssertEqual(p.count, 160)
        XCTAssertTrue(p.hasSuffix("…"))
        XCTAssertEqual(Clipboard.preview(String(repeating: "b", count: 160)).count, 160)
        XCTAssertFalse(Clipboard.preview(String(repeating: "b", count: 160)).hasSuffix("…"))
        // files: names joined, same cap
        XCTAssertEqual(Clipboard.filesPreview(["a.pdf", "b.jpg"]), "a.pdf, b.jpg")
        XCTAssertEqual(Clipboard.filesPreview(Array(repeating: "0123456789", count: 30)).count, 160)
    }

    func testTextIsCutAtACharacterBoundary() {
        let (same, cut0) = Clipboard.clipText("héllo", maxBytes: 100)
        XCTAssertEqual(same, "héllo")
        XCTAssertFalse(cut0)
        // "é" is 2 bytes: a cut inside it moves back to before it
        let (cut, truncated) = Clipboard.clipText("héllo", maxBytes: 2)
        XCTAssertEqual(cut, "h")
        XCTAssertTrue(truncated)
        let (emoji, t2) = Clipboard.clipText("ab😀cd", maxBytes: 5)
        XCTAssertEqual(emoji, "ab")
        XCTAssertTrue(t2)
    }

    // MARK: JSON

    func testJSONShapes() throws {
        Clipboard.write(pb, text: "hi")
        let item = Clipboard.read(pb, includeText: true)
        let json = item.json
        XCTAssertEqual(json["kind"] as? String, "text")
        XCTAssertEqual(json["text"] as? String, "hi")
        XCTAssertEqual(json["size"] as? Int, 2)
        XCTAssertEqual(json["changeCount"] as? Int, item.changeCount)
        XCTAssertNotNil(json["at"] as? Double)
        XCTAssertNil(json["source"])
        XCTAssertNil(json["truncated"])
        XCTAssertNil(json["width"])
        XCTAssertNil(json["files"])

        let line = try XCTUnwrap(JSONSerialization.jsonObject(with: Clipboard.eventLine(item).dropLast()) as? [String: Any])
        XCTAssertEqual(line["type"] as? String, "clipboard")
        XCTAssertEqual(line["preview"] as? String, "hi")
        XCTAssertNil(line["text"], "the event carries the summary only")
        XCTAssertEqual(Clipboard.eventLine(item).last, 10)

        let a = try file("a.txt", bytes: 3)
        Clipboard.write(pb, files: [a])
        let files = Clipboard.read(pb, includeText: false).json
        let list = try XCTUnwrap(files["files"] as? [[String: Any]])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["name"] as? String, "a.txt")
        XCTAssertEqual(list[0]["size"] as? Int, 3)
        XCTAssertEqual(list[0]["dir"] as? Bool, false)
        XCTAssertNil(files["text"])
    }

    // MARK: monitor

    func testMonitorSeesChangesAndRemembersOwnWrites() {
        let changes = Counter()
        let monitor = ClipboardMonitor(pasteboard: pb, onChange: { changes.bump() })
        Clipboard.write(pb, text: "first")
        monitor.poll()
        XCTAssertEqual(changes.value, 1)
        XCTAssertEqual(monitor.latestSummary?.preview, "first")
        XCTAssertNil(monitor.latestSummary?.text)
        monitor.poll()
        XCTAssertEqual(changes.value, 1, "no change, no wake")

        let at = monitor.latestSummary!.at
        let count = Clipboard.write(pb, text: "second")
        monitor.noteOwnWrite(changeCount: count, source: "phone")
        monitor.poll()
        XCTAssertEqual(changes.value, 2)
        XCTAssertEqual(monitor.latestSummary?.changeCount, count)
        XCTAssertEqual(monitor.latestSummary?.source, "phone")
        XCTAssertGreaterThanOrEqual(monitor.latestSummary!.at, at)
        // a read through the monitor agrees, and the Mac's own later change has no source
        XCTAssertEqual(Clipboard.read(pb, includeText: false, monitor: monitor).source, "phone")
        Clipboard.write(pb, text: "third")
        monitor.poll()
        XCTAssertNil(monitor.latestSummary?.source)
        XCTAssertEqual(changes.value, 3)
    }

    func testMonitorCachesThePNGPerChangeCount() throws {
        let monitor = ClipboardMonitor(pasteboard: pb, onChange: {})
        var made = 0
        let data = try png(width: 1, height: 1)
        let make = { () -> (data: Data, width: Int, height: Int)? in
            made += 1
            return (data, 1, 1)
        }
        XCTAssertEqual(monitor.png(for: 7, make: make)?.data, data)
        XCTAssertEqual(monitor.png(for: 7, make: make)?.data, data)
        XCTAssertEqual(made, 1)
        _ = monitor.png(for: 8, make: make)
        XCTAssertEqual(made, 2)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}
