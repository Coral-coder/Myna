import AVFoundation
import AudioToolbox
import Foundation

/// Decodes the bracelet's (already-decrypted) codec frames into PCM for the
/// speech pipeline.
///
/// AAC is decoded with AVAudioConverter, built into iOS. Opus has no system
/// decoder on iOS, so that path uses libopus via the YbridOpus framework, wired
/// through `OpusFrameDecoder`. Confirm the emitted codec with GetDeviceState
/// before relying on either; `SetBitrate` may change it.
///
/// Output is Float32 mono PCM at the codec's sample rate — the format
/// `SFSpeechAudioBufferRecognitionRequest` accepts.
final class BeeAudioDecoder {
    let codec: BeeCodec
    private(set) var sampleRate: Double
    private(set) var channels: UInt32
    private(set) var unavailableReason: String?

    private(set) var outputFormat: AVAudioFormat
    /// AAC arrives as an ADTS byte stream split across packets.
    private var adts = BeeADTSAssembler()
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
                unavailableReason = "Couldn't start the Opus decoder for this stream (unexpected sample rate or channel count)."
            }
        case .unknown:
            unavailableReason = "The bracelet's audio codec wasn't recognized."
        }
    }

    /// Decode one codec frame to PCM, or nil if it can't be decoded.
    /// Feed one decrypted packet; returns whatever PCM it completed. For AAC the
    /// ADTS frames are reassembled across packets and the decoder follows the
    /// stream's own sample rate and channel count from the ADTS header.
    func decodeStream(_ packet: Data) -> [AVAudioPCMBuffer] {
        switch codec {
        case .aac:
            return adts.append(packet).compactMap { frame in
                if converter == nil || frame.sampleRate != sampleRate || frame.channels != channels {
                    sampleRate = frame.sampleRate
                    channels = frame.channels
                    setupAAC()
                }
                return decodeAAC(frame.payload)
            }
        case .opus:
            return decode(packet).map { [$0] } ?? []
        case .unknown:
            return []
        }
    }

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
        // mFormatFlags MUST declare AAC-LC — with 0, AVAudioConverter refuses to
        // initialise ("Couldn't start the AAC decoder"). With the object type
        // set, the decoder reads everything it needs from the ASBD, so no magic
        // cookie is required (and a wrong one would break init).
        // If we already have a working converter, a failure to build a new one
        // (from a stray/garbage frame) must not wedge the whole decoder — keep
        // the one that works rather than marking audio unavailable.
        let hadWorkingConverter = (converter != nil)
        func fail(_ reason: String) {
            if !hadWorkingConverter { unavailableReason = reason }
        }
        let channelCount = min(2, max(1, channels))
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: AudioFormatFlags(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let input = AVAudioFormat(streamDescription: &asbd) else {
            fail("Couldn't build the AAC input format.")
            return
        }
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channelCount, interleaved: false) else {
            fail("Couldn't build the PCM output format.")
            return
        }
        guard let converter = AVAudioConverter(from: input, to: pcm) else {
            fail("iOS wouldn't start the AAC decoder (\(Int(sampleRate)) Hz, \(channelCount) ch).")
            return
        }
        outputFormat = pcm
        self.inputFormat = input
        self.converter = converter
        unavailableReason = nil
    }

    private func decodeAAC(_ frame: Data) -> AVAudioPCMBuffer? {
        guard let converter, let inputFormat,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: framesPerPacket * 2) else { return nil }

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

#if canImport(YbridOpus)
import YbridOpus

/// Decodes raw Opus packets to Float32 mono PCM with libopus (via the YbridOpus
/// binary framework). The bracelet sends bare Opus frames (no Ogg container), so
/// `opus_decode_float` is all that's needed. Mono only — matching wearable voice
/// capture and the decoder's non-interleaved output buffer.
final class OpusFrameDecoder {
    private let decoder: OpaquePointer
    /// Largest number of samples per channel an Opus frame can carry (120 ms).
    private let maxFrameSamples: Int

    init?(sampleRate: Double, channels: UInt32) {
        // Opus decodes only at these rates, and this path assumes mono.
        let fs = Int32(sampleRate)
        guard [8000, 12000, 16000, 24000, 48000].contains(fs), channels == 1 else { return nil }
        var err: Int32 = 0
        guard let created = opus_decoder_create(fs, 1, &err), err == 0 else { return nil }
        decoder = created
        maxFrameSamples = Int(sampleRate * 0.12)
    }

    deinit { opus_decoder_destroy(decoder) }

    func decode(_ frame: Data, into format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxFrameSamples)),
              let channelData = output.floatChannelData else { return nil }

        let decoded: Int32 = frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return opus_decode_float(decoder, base, Int32(frame.count), channelData[0], Int32(maxFrameSamples), 0)
        }
        guard decoded > 0 else { return nil }
        output.frameLength = AVAudioFrameCount(decoded)
        return output
    }
}
#else
/// libopus not linked in this build — Opus stays unavailable (AAC bracelets work).
struct OpusFrameDecoder {
    init?(sampleRate: Double, channels: UInt32) { return nil }
    func decode(_ frame: Data, into format: AVAudioFormat) -> AVAudioPCMBuffer? { nil }
}
#endif
