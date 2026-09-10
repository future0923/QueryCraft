import Foundation
import QueryCraftFeature
import Testing
@testable import QueryCraftRedisDriver

struct RedisReplyValueDriverTests {
    @Test
    func formatsIntegralRESP3DoublesWithoutDecimalSuffix() {
        #expect(RedisReplyValue.double(92).stringValue == "92")
        #expect(RedisReplyValue.double(-7).stringValue == "-7")
        #expect(RedisReplyValue.double(-0).stringValue == "0")
    }

    @Test
    func preservesFractionalRESP3DoublePrecision() {
        #expect(RedisReplyValue.double(92.5).stringValue == "92.5")
        #expect(RedisReplyValue.double(0.125).stringValue == "0.125")
    }

    @Test
    func rawBlobKeepsEmbeddedNULAndInvalidUTF8Bytes() {
        let bytes = Data([0x41, 0x00, 0xff, 0x42])
        let reply = RedisRawReplyValue.blob(bytes)

        #expect(reply.dataValue == bytes)
        #expect(reply.dataValue?.count == 4)
    }

    @Test
    func collectionContinuationsPreserveCursorProgressAndMatchCount() {
        let offset = OffsetContinuation(
            RedisCollectionContinuation(rawValue: "2400:2400:37")
        )
        #expect(offset.offset == 2_400)
        #expect(offset.scanned == 2_400)
        #expect(offset.matched == 37)
        #expect(offset.continuation.rawValue == "2400:2400:37")

        let scan = ScanContinuation(
            RedisCollectionContinuation(rawValue: "91:12000:500")
        )
        #expect(scan.cursor == 91)
        #expect(scan.scanned == 12_000)
        #expect(scan.matched == 500)
        #expect(scan.continuation.rawValue == "91:12000:500")
    }
}
