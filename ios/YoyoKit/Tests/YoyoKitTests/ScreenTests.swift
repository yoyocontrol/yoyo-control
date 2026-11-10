import Foundation
import Testing
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// The Mac's screen (PROTOCOL.md「屏幕」): lenient `ScreenStatus` decoding, the `screen.control` account event, the input
/// body and the stream part parser.
@Suite("Screen")
struct ScreenTests {
    private func decode(_ json: String) throws -> ScreenStatus { try JSONDecoder().decode(ScreenStatus.self, from: Data(json.utf8)) }

    // MARK: ScreenStatus

    @Test func decodesTheFullShape() throws {
        let s = try decode(#"""
        {"available":true,"screenRecording":true,"accessibility":true,
         "displays":[{"id":1,"width":1512,"height":982,"scale":2,"main":true},{"id":4294967295,"width":1920,"height":1080,"scale":1,"main":false}],
         "controller":"agent","controllerSince":1760000000000}
        """#)
        #expect(s.available && s.screenRecording && s.accessibility && s.reason == nil)
        #expect(s.displays.count == 2)
        #expect(s.displays[0] == ScreenDisplay(id: 1, width: 1512, height: 982, scale: 2, main: true))
        #expect(s.displays[1].id == UInt32.max && !s.displays[1].main)
        #expect(s.mainDisplay?.id == 1)
        #expect(s.controller == .agent && s.controllerSince == 1_760_000_000_000)
    }

    @Test func anOlderServerMissingFieldsDecodes() throws {
        let s = try decode(#"{"available":true,"screenRecording":true}"#)
        #expect(s.available && s.screenRecording)
        #expect(!s.accessibility && s.displays.isEmpty && s.controller == .none && s.controllerSince == nil)
        #expect(s.mainDisplay == nil)
        let empty = try decode("{}")
        #expect(empty == ScreenStatus())
    }

    @Test func nullsAndUnknownValuesFallBack() throws {
        let s = try decode(#"""
        {"available":null,"reason":null,"screenRecording":null,"accessibility":"yes","displays":null,
         "controller":"robot","controllerSince":null}
        """#)
        #expect(s == ScreenStatus())
        let u = try decode(#"{"available":false,"reason":"Another macOS user owns the screen","controller":null}"#)
        #expect(!u.available && u.reason == "Another macOS user owns the screen" && u.controller == .none)
    }

    @Test func anOlderServersOnConsoleIsIgnored() throws {
        // `onConsole` (a switched-away account's screen) is gone; an older server may still send it, in any shape
        let away = try decode(#"{"available":true,"onConsole":false,"screenRecording":false,"reason":"Yoyo Control has no Screen Recording permission"}"#)
        #expect(away == ScreenStatus(available: true, reason: "Yoyo Control has no Screen Recording permission"))
        for json in [#"{"available":true,"onConsole":true}"#, #"{"available":true,"onConsole":null}"#, #"{"available":true,"onConsole":"no"}"#] {
            #expect(try decode(json) == ScreenStatus(available: true))
        }
    }

    @Test func aMalformedDisplayIsDroppedNotTheList() throws {
        let s = try decode(#"""
        {"available":true,"displays":[{"width":10},{"id":2,"width":800,"height":600},"x",{"id":-1}],"controller":"user"}
        """#)
        #expect(s.displays.map(\.id) == [2])
        #expect(s.displays[0].scale == 1 && !s.displays[0].main)
        // no display marked main: the first one
        #expect(s.mainDisplay?.id == 2)
        #expect(s.controller == .user)
    }

    @Test func asleepDecodesAndMissingMeansAwake() throws {
        let s = try decode(#"""
        {"available":true,"displays":[{"id":1,"width":1512,"height":982,"main":true,"asleep":true},{"id":2,"width":800,"height":600,"asleep":null},{"id":3,"width":800,"height":600}]}
        """#)
        #expect(s.displays.map(\.asleep) == [true, false, false])
    }

    @Test func displayNameAndKindDecodeAndAUserFieldIsIgnored() throws {
        let s = try decode(#"""
        {"available":true,"user":"sam",
         "displays":[{"id":1,"width":1728,"height":1117,"scale":2,"main":true,"name":"Built-in Retina Display","kind":"builtin"},
                     {"id":5,"width":1920,"height":1080,"scale":1,"kind":"external"},
                     {"id":9,"width":1280,"height":800,"scale":2,"name":"Yoyo Control","kind":"virtual"}]}
        """#)
        #expect(s.displays.map(\.name) == ["Built-in Retina Display", nil, "Yoyo Control"])
        // an unknown kind: nil, the display kept
        #expect(s.displays.map(\.kind) == [.builtin, .external, nil])
    }

    @Test func aDisplayWithoutNameOrKindDecodes() throws {
        let s = try decode(#"{"available":true,"displays":[{"id":1,"width":1512,"height":982,"scale":2,"main":true,"label":"x"}]}"#)
        // an unknown field (`label`) is ignored
        #expect(s.displays.count == 1 && s.displays[0].name == nil && s.displays[0].kind == nil && s.displays[0].main)
    }

    @Test func unknownKindsEmptyNamesAndJunkFallBackToNil() throws {
        let s = try decode(#"""
        {"available":true,"user":"",
         "displays":[{"id":1,"width":800,"height":600,"name":"","kind":"projector"},
                     {"id":2,"width":800,"height":600,"name":null,"kind":null},
                     {"id":3,"width":800,"height":600,"name":7,"kind":true}]}
        """#)
        #expect(s.displays.map(\.id) == [1, 2, 3], "a bad name or kind drops the field, not the display")
        #expect(s.displays.allSatisfy { $0.name == nil && $0.kind == nil })
        for json in [#"{"available":true,"user":null}"#, #"{"available":true,"user":42}"#] {
            #expect(try decode(json).available)
        }
    }

    // MARK: My Computer's screen row

    @Test func focusDecodesLeniently() {
        func focus(_ json: String) -> ScreenFocus { ScreenFocus(json: Data(json.utf8)) }
        #expect(focus(#"{"editable":true,"role":"AXTextArea"}"#) == ScreenFocus(editable: true, role: "AXTextArea"))
        #expect(focus(#"{"editable":false,"role":null}"#) == ScreenFocus(editable: false))
        // missing / odd fields and bodies that aren't JSON objects: not editable, never a failure
        #expect(focus("{}") == ScreenFocus(editable: false))
        #expect(focus(#"{"editable":"yes","role":3}"#) == ScreenFocus(editable: false))
        #expect(focus(#"{"editable":1}"#) == ScreenFocus(editable: false))
        #expect(focus("[true]") == ScreenFocus(editable: false))
        #expect(focus("not json") == ScreenFocus(editable: false))
    }

    // MARK: Events

    @Test func decodesScreenControlEvents() throws {
        func event(_ json: String) throws -> YoyoEvent? { YoyoEvent(json: Data(json.utf8)) }
        #expect(try event(#"{"type":"screen.control","ts":1,"controller":"agent","controllerSince":1000}"#)
                == .control(controller: .agent, since: 1000))
        #expect(try event(#"{"type":"screen.control","ts":1,"controller":"none","controllerSince":null}"#)
                == .control(controller: .none, since: nil))
        #expect(try event(#"{"type":"screen.control","ts":1,"controller":"martian"}"#) == .control(controller: .none, since: nil))
        #expect(try event(#"{"type":"screen.control"}"#) == .control(controller: .none, since: nil))
    }

    // MARK: Input

    @Test func inputBody() {
        let click = ScreenInput.click(.rightClick, display: 3, at: CGPoint(x: 0.25, y: 0.5), modifiers: [.shift, .cmd])
        let j = click.json
        #expect(j["type"] as? String == "rightClick" && j["display"] as? Int == 3)
        #expect(j["x"] as? Double == 0.25 && j["y"] as? Double == 0.5)
        #expect(j["modifiers"] as? [String] == ["cmd", "shift"])
        let typed = ScreenInput(.type, text: "hi").json
        #expect(typed.keys.sorted() == ["text", "type"])
    }

    @MainActor
    @Test func keyNames() {
        #expect(YoyoScreenSession.keyName(for: "c") == ("c", false))
        #expect(YoyoScreenSession.keyName(for: "C") == ("c", true))
        #expect(YoyoScreenSession.keyName(for: " ") == ("space", false))
        #expect(YoyoScreenSession.keyName(for: "7") == ("7", false))
        #expect(YoyoScreenSession.keyName(for: "/") == ("/", false))
    }

    // MARK: Stream parts (StreamPartParser)

    private static let bodyA = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x2D, 0x2D, 0x0D, 0x0A, 0x41, 0xFF, 0xD9])
    private static let bodyB = Data([0xFF, 0xD8, 0x01, 0x02, 0x03, 0x0D, 0x0A, 0x2D, 0x2D, 0x78, 0xFF, 0xD9])

    private static func part(_ body: Data, boundary: String, length: Bool, size: (Int, Int)? = nil) -> Data {
        var d = Data("--\(boundary)\r\nContent-Type: video/h264\r\n".utf8)
        if length { d.append(Data("Content-Length: \(body.count)\r\n".utf8)) }
        if let size { d.append(Data("X-Frame-Width: \(size.0)\r\nX-Frame-Height: \(size.1)\r\n".utf8)) }
        d.append(Data("\r\n".utf8))
        d.append(body)
        d.append(Data("\r\n".utf8))
        return d
    }

    /// Two frames: a preamble, the first with Content-Length and a size, the second as given, then the closing boundary.
    private static func fixture(boundary: String = "frame", secondHasLength: Bool = true) -> Data {
        var d = Data("\r\n".utf8)
        d.append(part(bodyA, boundary: boundary, length: true, size: (1512, 982)))
        d.append(part(bodyB, boundary: boundary, length: secondHasLength))
        d.append(Data("--\(boundary)--\r\n".utf8))
        return d
    }

    /// A server that never ends a part's headers can't make the parser keep them.
    @Test func endlessPartHeadersAreDropped() {
        var p = StreamPartParser(boundary: "b")
        _ = p.feed(Data("--b\r\nX-Junk: ".utf8))
        for _ in 0..<4 { _ = p.feed(Data(repeating: 0x41, count: 4096)) }
        #expect(p.bufferedCount <= StreamPartParser.maxHeaderBytes)
        // and it recovers on the next part
        let frame = Data([0, 0, 0, 1, 0x65, 0x88])
        var part = Data("\r\n--b\r\nContent-Type: video/h264\r\nContent-Length: \(frame.count)\r\n\r\n".utf8)
        part.append(frame)
        part.append(Data("\r\n".utf8))
        #expect(p.feed(part).map(\.body) == [frame])
    }

    @Test func parsesTwoFramesInOneChunk() {
        var p = StreamPartParser(boundary: "frame")
        let frames = p.feed(Self.fixture())
        #expect(frames.map(\.body) == [Self.bodyA, Self.bodyB])
        #expect(frames.first?.width == 1512 && frames.first?.height == 982)
        #expect(frames.last?.width == nil)
    }

    @Test func parsesByteByByte() {
        for withLength in [true, false] {
            var p = StreamPartParser(boundary: "frame")
            var frames: [ScreenStreamPart] = []
            for byte in Self.fixture(secondHasLength: withLength) { frames += p.feed(Data([byte])) }
            #expect(frames.map(\.body) == [Self.bodyA, Self.bodyB])
            #expect(frames.first?.width == 1512)
        }
    }

    @Test func aPartWithoutContentLengthEndsAtTheNextBoundary() {
        var p = StreamPartParser(boundary: "frame")
        var data = Self.fixture(secondHasLength: false)
        // no closing boundary yet: the second frame isn't known to be complete
        let tail = Data("--frame--\r\n".utf8)
        data.removeLast(tail.count)
        #expect(p.feed(data).map(\.body) == [Self.bodyA])
        #expect(p.feed(tail).map(\.body) == [Self.bodyB])
    }

    @Test func parsesEveryChunkSplit() {
        let all = Self.fixture(secondHasLength: false)
        for cut in 1..<all.count {
            var p = StreamPartParser(boundary: "frame")
            let frames = p.feed(all.prefix(cut)) + p.feed(all.suffix(from: cut))
            #expect(frames.map(\.body) == [Self.bodyA, Self.bodyB], "split at \(cut)")
        }
    }

    @Test func keepsMemoryBounded() {
        var p = StreamPartParser(boundary: "b", maxBuffer: 64)
        // a part without length whose end never comes
        _ = p.feed(Data("--b\r\nContent-Type: video/h264\r\n\r\n".utf8))
        _ = p.feed(Data(repeating: 0x41, count: 100))
        #expect(p.bufferedCount == 0)
        // junk without any boundary only keeps a boundary's worth
        _ = p.feed(Data(repeating: 0x42, count: 50))
        #expect(p.bufferedCount <= 2)
        // and it recovers on the next part
        #expect(p.feed(Self.part(Self.bodyA, boundary: "b", length: true)).map(\.body) == [Self.bodyA])
    }

    @Test func readsTheBoundaryFromTheContentType() {
        #expect(StreamPartParser.boundary(fromContentType: "multipart/x-mixed-replace; boundary=frame") == "frame")
        #expect(StreamPartParser.boundary(fromContentType: #"multipart/x-mixed-replace;boundary="a b";charset=x"#) == "a b")
        #expect(StreamPartParser.boundary(fromContentType: "video/h264") == nil)
        #expect(StreamPartParser.boundary(fromContentType: nil) == nil)
    }

    // MARK: StreamPartAssembler (the raw body, or URLSession's own per-part split)

    @Test func assemblesTheRawBodyUnderOneResponse() throws {
        var a = StreamPartAssembler()
        #expect(try a.receive(status: 200, contentType: "application/vnd.yoyo-control.stream; boundary=frame", expectedLength: -1).isEmpty)
        let frames = a.feed(Self.fixture())
        #expect(frames.map(\.body) == [Self.bodyA, Self.bodyB])
        #expect(!a.split)
        #expect(a.finish().isEmpty)
    }

    /// URLSession splitting `multipart/x-mixed-replace` itself: a response per part, its bytes after it (not a second
    /// response that would be a failure).
    @Test func assemblesURLSessionsPerPartResponses() throws {
        var a = StreamPartAssembler()
        #expect(try a.receive(status: 200, contentType: "multipart/x-mixed-replace; boundary=frame", expectedLength: -1).isEmpty)
        // with Content-Length: each frame is out as soon as its bytes are, in chunks split anywhere
        #expect(try a.receive(status: 200, contentType: "video/h264", expectedLength: Int64(Self.bodyA.count), headers: ScreenPartHeaders(width: 1512, height: 982)).isEmpty)
        #expect(a.split)
        #expect(a.feed(Self.bodyA.prefix(3)).isEmpty)
        let first = a.feed(Self.bodyA.suffix(from: 3))
        #expect(first.map(\.body) == [Self.bodyA])
        #expect(first.first?.width == 1512 && first.first?.height == 982)
        // without a length: the part ends at the next response, or at the end of the stream
        #expect(try a.receive(status: 200, contentType: "video/h264", expectedLength: -1).isEmpty)
        #expect(a.feed(Self.bodyB).isEmpty)
        #expect(try a.receive(status: 200, contentType: "video/h264", expectedLength: -1).map(\.body) == [Self.bodyB])
        #expect(a.feed(Self.bodyA).isEmpty)
        #expect(a.finish().map(\.body) == [Self.bodyA])
    }

    @Test func aSplitPartShortOfItsLengthIsDroppedAndAHugeOneBounded() throws {
        var a = StreamPartAssembler(maxPart: 64)
        _ = try a.receive(status: 200, contentType: "multipart/x-mixed-replace; boundary=b", expectedLength: -1)
        _ = try a.receive(status: 200, contentType: "video/h264", expectedLength: 1000)
        #expect(a.feed(Data(repeating: 0x41, count: 10)).isEmpty)
        #expect(a.finish().isEmpty)
        var b = StreamPartAssembler(maxPart: 64)
        _ = try b.receive(status: 200, contentType: "multipart/x-mixed-replace; boundary=b", expectedLength: -1)
        _ = try b.receive(status: 200, contentType: "video/h264", expectedLength: -1)
        #expect(b.feed(Data(repeating: 0x41, count: 100)).isEmpty)
        #expect(b.finish().isEmpty)  // dropped past maxPart
    }

    @Test func aFirstResponseThatIsNotAStreamFails() {
        var a = StreamPartAssembler()
        #expect(throws: YoyoError.self) { try a.receive(status: 200, contentType: "application/json", expectedLength: 10) }
        var b = StreamPartAssembler()
        #expect(throws: YoyoError.self) { try b.receive(status: 401, contentType: "application/json", expectedLength: 10) }
        var c = StreamPartAssembler()
        #expect(throws: YoyoError.self) { try c.receive(status: 503, contentType: "multipart/x-mixed-replace; boundary=b", expectedLength: -1) }
    }
}
