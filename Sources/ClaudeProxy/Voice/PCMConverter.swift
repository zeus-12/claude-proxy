import AVFoundation
import Foundation

/// Converts a client's PCM stream into the only format Claude's speech-to-text
/// socket accepts: 16 kHz mono linear16.
///
/// Deepgram clients declare their real capture format in the query string, and
/// it is frequently not 16 kHz — meeting recorders commonly run at 44.1 or
/// 48 kHz, and stereo when they capture microphone and system audio separately.
/// Forwarding those bytes unchanged would not fail loudly; it would produce a
/// confident, wrong transcript, so we convert rather than assume.
///
/// Downmixing is done here rather than by `AVAudioConverter` so the channel
/// handling is explicit and deterministic; the converter is used only for the
/// part it is genuinely good at, sample-rate conversion, and is kept alive
/// across chunks because that conversion is stateful.
final class PCMConverter {
    private let sourceRate: Double
    private let channels: Int
    private let converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat?
    private let outputFormat: AVAudioFormat

    /// Bytes left over when a chunk ends mid-frame. A client is free to split
    /// its writes anywhere, including between the two bytes of one sample.
    private var residual = Data()

    static let targetRate: Double = 16000

    init?(sourceRate: Double, channels: Int) {
        guard sourceRate > 0, channels >= 1 else { return nil }
        self.sourceRate = sourceRate
        self.channels = channels

        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Self.targetRate,
                                         channels: 1,
                                         interleaved: true) else { return nil }
        self.outputFormat = output

        if sourceRate == Self.targetRate {
            // Already at the target rate: downmixing alone is enough.
            self.inputFormat = nil
            self.converter = nil
        } else {
            guard let input = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: sourceRate,
                                            channels: 1,
                                            interleaved: true),
                  let converter = AVAudioConverter(from: input, to: output) else { return nil }
            self.inputFormat = input
            self.converter = converter
        }
    }

    /// True when the client's format already matches and no work is needed.
    var isPassthrough: Bool { converter == nil && channels == 1 }

    /// Converts one chunk. Returns 16 kHz mono linear16, or nil if the
    /// conversion failed (which the caller should surface, not swallow).
    func convert(_ chunk: Data) -> Data? {
        var input = residual
        input.append(chunk)
        residual = Data()

        // Keep only whole interleaved frames; stash any partial tail.
        let bytesPerFrame = 2 * channels
        let usableFrames = input.count / bytesPerFrame
        let usableBytes = usableFrames * bytesPerFrame
        if usableBytes < input.count {
            residual = input.subdata(in: (input.startIndex + usableBytes)..<input.endIndex)
            input = input.subdata(in: input.startIndex..<(input.startIndex + usableBytes))
        }
        guard usableFrames > 0 else { return Data() }

        let mono = channels == 1 ? input : downmix(input, frames: usableFrames)
        guard converter != nil else { return mono }
        return resample(mono)
    }

    /// Averages the interleaved channels into one. Accumulating in Int32 keeps
    /// the sum from overflowing before the divide.
    private func downmix(_ input: Data, frames: Int) -> Data {
        var out = Data(count: frames * 2)
        input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let samples = src.bindMemory(to: Int16.self)
                let mono = dst.bindMemory(to: Int16.self)
                for frame in 0..<frames {
                    var sum: Int32 = 0
                    for channel in 0..<channels {
                        sum += Int32(samples[frame * channels + channel])
                    }
                    mono[frame] = Int16(sum / Int32(channels))
                }
            }
        }
        return out
    }

    private func resample(_ mono: Data) -> Data? {
        guard let converter, let inputFormat else { return mono }
        let frames = mono.count / 2
        guard frames > 0 else { return Data() }

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                              frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        inBuffer.frameLength = AVAudioFrameCount(frames)
        mono.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, let dst = inBuffer.int16ChannelData else { return }
            memcpy(dst[0], base, mono.count)
        }

        // Round up, then leave room for samples the converter had buffered from
        // a previous chunk and is now able to emit.
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(frames) * ratio).rounded(.up)) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                               frameCapacity: capacity) else { return nil }

        var pending: AVAudioPCMBuffer? = inBuffer
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if let buffer = pending {
                pending = nil
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        guard status != .error else { return nil }
        guard outBuffer.frameLength > 0, let channelData = outBuffer.int16ChannelData else {
            return Data()
        }
        return Data(bytes: channelData[0], count: Int(outBuffer.frameLength) * 2)
    }
}
