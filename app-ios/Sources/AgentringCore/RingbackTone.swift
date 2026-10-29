import Foundation

/// Two local ringback bursts before creating a new phone-to-agent call.
enum RingbackTone {
    static let preferenceKey = "agentring.outgoing-ring-count"
    static let sampleRate = 16_000
    static let duration = 4.0

    static func ringCount(defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: preferenceKey) == nil ? 2 : (defaults.integer(forKey: preferenceKey) == 0 ? 0 : 2)
    }

    static func waveData() -> Data {
        let count = Int(Double(sampleRate) * duration)
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); number(UInt32(36 + count * 2)); text("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(sampleRate)); number(UInt32(sampleRate * 2))
        number(UInt16(2)); number(UInt16(16)); text("data"); number(UInt32(count * 2))
        for index in 0..<count {
            let time = Double(index) / Double(sampleRate)
            let local = time >= 3 ? time - 3 : time
            // One second on, two seconds off, one second on. Fade edges to avoid clicks.
            let envelope = local < 1 ? max(0, min(1, local / 0.01, (1 - local) / 0.01)) : 0
            let value = sin(2 * .pi * 425 * time) * envelope * 0.24
            number(Int16(value * Double(Int16.max)))
        }
        return data
    }
}
