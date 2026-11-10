import Foundation
import Testing
#if canImport(YoyoLinkClient)
@testable import YoyoLinkClient

/// The speed test's report as the kit hands it out: decoded from Link's JSON (docs/LINK.md「测速」), nulls and a
/// missing server half kept as nil.
@Suite("Link speed test")
struct LinkSpeedTestTests {
    @Test func theReportDecodesFromLinksJson() throws {
        let json = """
        {"transport":"rtc","path":"lan","iface":"other","durationMs":8000,"rttIdleMs":89.2,"rttP50Ms":102.5,
         "rttP90Ms":109.0,"frames":445,"receivedMbps":11.32,"peakMbps":20.44,"finalMbps":15.28,"finalFps":55.5,
         "lossPct":4.97,"fecRecovered":408,"nackRecovered":105,"lostFrames":0,"skippedFrames":0,"freezes":0,
         "freezeMs":0,"server":{"targetMbps":22.66,"maxTargetMbps":29.51,"encoderMbps":17.85,"fpsCap":60.0,
         "sentMbps":14.15,"frames":446,"bytes":11331413,"rateCuts":1,"rateLossCuts":0,"retransmits":219,
         "jitterMs":12.1,"reason":"done"}}
        """
        let r = try #require(YoyoLinkSpeedTest(json: Data(json.utf8)))
        #expect(r.path == "lan" && r.durationMs == 8000 && r.frames == 445)
        #expect(r.finalMbps == 15.28 && r.finalFps == 55.5 && r.rttIdleMs == 89.2)
        #expect(r.server?.maxTargetMbps == 29.51 && r.server?.fpsCap == 60 && r.server?.reason == "done")
    }

    @Test func unmeasuredValuesAreNil() throws {
        let json = """
        {"transport":"quic","path":"relay","iface":"cellular","durationMs":3000,"rttIdleMs":null,"rttP50Ms":null,
         "rttP90Ms":null,"frames":1,"receivedMbps":null,"peakMbps":null,"finalMbps":null,"finalFps":null,
         "lossPct":null,"fecRecovered":0,"nackRecovered":0,"lostFrames":0,"skippedFrames":0,"freezes":0,
         "freezeMs":0,"server":null}
        """
        let r = try #require(YoyoLinkSpeedTest(json: Data(json.utf8)))
        #expect(r.finalMbps == nil && r.server == nil && r.iface == "cellular")
        #expect(YoyoLinkSpeedTest(json: Data("{}".utf8)) == nil)
    }
}
#endif
