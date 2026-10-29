import XCTest
@testable import AgentringCore

final class RingbackToneTests: XCTestCase {
    func testAudioIsAPlayableFourSecondMonoPCMFile() {
        let data = RingbackTone.waveData()
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<16], encoding: .ascii), "WAVEfmt ")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(data.count, 44 + 16_000 * 4 * 2)
        XCTAssertEqual(Array(data[22..<24]), [1, 0]) // mono
        XCTAssertEqual(Array(data[34..<36]), [16, 0]) // 16-bit PCM
    }

    func testExactlyTwoAudibleBurstsSeparatedBySilence() {
        let bytes = Array(RingbackTone.waveData().dropFirst(44))
        let samples = stride(from: 0, to: bytes.count, by: 2).map {
            Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
        }
        XCTAssertTrue(samples[16_000..<48_000].allSatisfy { $0 == 0 })
        for range in [800..<15_200, 48_800..<63_200] {
            let energy = range.reduce(0.0) { $0 + pow(Double(samples[$1]), 2) } / Double(range.count)
            XCTAssertGreaterThan(sqrt(energy), 4_000)
        }
        XCTAssertEqual(samples.first, 0)
        XCTAssertLessThan(abs(Int(samples.last!)), 100)
    }

    func testPreferenceDefaultsToTwoAndCanDisableAllTones() throws {
        let suite = "agentring.ringback-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(RingbackTone.ringCount(defaults: defaults), 2)
        defaults.set(0, forKey: RingbackTone.preferenceKey)
        XCTAssertEqual(RingbackTone.ringCount(defaults: defaults), 0)
        defaults.set(2, forKey: RingbackTone.preferenceKey)
        XCTAssertEqual(RingbackTone.ringCount(defaults: defaults), 2)
    }
}
