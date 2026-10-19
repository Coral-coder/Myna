import AVFoundation
import AudioToolbox
import Foundation

/// Decodes the bracelet's (already-decrypted) codec frames into PCM for the
/// speech pipeline.
///
/// AAC is decoded with AVAudioConverter, built into iOS. Opus has no system
/// decoder on iOS, so that path needs libopus added to the app (SPM or an
/// xcframework) wired to `OpusFrameDecoder`; until then an Opus stream surfaces
/// `unavailableReason` rather than silently dropping. Confirm the emitted codec
/// with GetDeviceState before relying on either; `SetBitrate` may change it.
///
/// Output is Float32 mono PCM at the codec's sample rate — the format
/// `SFSpeechAudioBufferRecognitionRequest` accepts.
final class BeeAudioDecoder {
    let codec: BeeCodec
    let sampleRate: Double
    let channels: UInt32
    private(set) var unavailableReason: String?

    let outputFormat: AVAudioFormat
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var opusDecoder: OpusFrameDecoder?

    /// One AAC access unit. Confirm on device; AAC-LC is 1024.
    private let framesPerPacket: AVAudioFrameCount = 1024

    /// Defaults (16 kHz mono) match wearable voice capture; confirm on device.
    init(codec: BeeCodec, sampleRate: Double = 16_000, channels: UInt32 = 1) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!

        switch codec {
        case .aac:
            setupAAC()
        case .opus:
            if let decoder = OpusFrameDecoder(sampleRate: sampleRate, channels: channels) {
                opusDecoder = decoder
            } else {
                unavailableReason = "This bracelet is streaming Opus, which needs libopus added to Myna. Switch the device to AAC, or add the Opus library."
            }
        case .unknown:
            unavailableReason = "The bracelet's audio codec wasn't recognized."
        }
    }

    /// Decode one codec frame to PCM, or nil if it can't be decoded.
    func decode(_ frame: Data) -> AVAudioPCMBuffer? {
        guard !frame.isEmpty else { return nil }
        switch codec {
        case .aac: return decodeAAC(frame)
        case .opus: return opusDecoder?.decode(frame, into: outputFormat)
        case .unknown: return nil
        }
    }

    // MARK: - AAC

    private func setupAAC() {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let converter = AVAudioConverter(from: input, to: outputFormat) else {
            unavailableReason = "Couldn't start the AAC decoder."
            return
        }
        self.inputFormat = input
        self.converter = converter
    }

    private func decodeAAC(_ frame: Data) -> AVAudioPCMBuffer? {
        guard let converter, let inputFormat,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: framesPerPacket) else { return nil }

        let compressed = AVAudioCompressedBuffer(
            format: inputFormat,
            packetCapacity: 1,
            maximumPacketSize: frame.count
        )
        compressed.byteLength = UInt32(frame.count)
        compressed.packetCount = 1
        frame.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                compressed.data.copyMemory(from: base, byteCount: frame.count)
            }
        }
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(frame.count)
        )

        var handedOver = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if handedOver {
                outStatus.pointee = .noDataNow
                return nil
            }
            handedOver = true
            outStatus.pointee = .haveData
            return compressed
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Seam for an Opus decoder. Returns nil from `init` until libopus is wired in,
/// which is what makes `BeeAudioDecoder` report Opus as unavailable rather than
/// dropping the stream. Implement this against libopus (or a C shim) to enable
/// Opus bracelets.
struct OpusFrameDecoder {
    init?(sampleRate: Double, channels: UInt32) {
        return nil
    }

    func decode(_ frame: Data, into format: AVAudioFormat) -> AVAudioPCMBuffer? {
        nil
    }
}
