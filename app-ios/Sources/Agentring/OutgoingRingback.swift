import AVFAudio
import Foundation

/// Uses the audio session owned by CallKit; never activates a separate session.
@MainActor
final class OutgoingRingback: NSObject, @preconcurrency AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var completed = false

    func prepare() throws {
        stop()
        let next = try AVAudioPlayer(data: RingbackTone.waveData())
        next.delegate = self
        next.volume = 0.8
        guard next.prepareToPlay() else {
            throw NSError(domain: "AgentringAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not prepare calling tones. You can disable them in Settings."])
        }
        player = next
    }

    func start() {
        guard let player, !player.isPlaying else { return }
        if !player.play() { stop() }
    }

    func pause() { player?.pause() }

    func waitForCompletion() async -> Bool {
        guard player != nil else { return completed }
        return await withCheckedContinuation { waiter = $0 }
    }

    func stop() { finish(success: false) }

    private func finish(success: Bool) {
        player?.delegate = nil
        player?.stop()
        player = nil
        completed = success
        let continuation = waiter
        waiter = nil
        continuation?.resume(returning: success)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        finish(success: flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard self.player === player else { return }
        stop()
    }
}
