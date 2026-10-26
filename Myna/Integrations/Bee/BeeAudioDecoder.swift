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
    private var opusDecoder: OpusFrameDecoder?

    /// Apple's AAC decoder, driven directly (not via AVAudioConverter) so we can
    /// set the decompression magic cookie — the AudioSpecificConfig — which the
    /// decoder needs to actually produce PCM. AVAudioConverter can't carry it,
    /// which is why the AAC path initialised but emitted nothing.
    private var aacConverter: AudioConverterRef?
    private var aacOutputFormat: AVAudioFormat?
    private var cfgRateIndex = -1
    private var cfgChannels = -1
    private var cfgObjectType = -1

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
            // The AAC converter is built lazily from the first ADTS frame's
            // config, so there's nothing to set up here.
            break
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
            return adts.append(packet).compactMap { decodeAAC($0) }
        case .opus:
            return decode(packet).map { [$0] } ?? []
        case .unknown:
            return []
        }
    }

    func decode(_ frame: Data) -> AVAudioPCMBuffer? {
        guard !frame.isEmpty else { return nil }
        switch codec {
        case .aac: return nil // AAC goes through decodeStream (needs ADTS framing)
        case .opus: return opusDecoder?.decode(frame, into: outputFormat)
        case .unknown: return nil
        }
    }

    deinit { releaseAAC() }

    // MARK: - AAC

    /// Holds one compressed packet for the AudioConverter input callback. The
    /// bytes must stay put for the duration of the fill call, so they live in a
    /// caller-owned allocation referenced here.
    private final class AACInput {
        let data: UnsafeMutableRawPointer
        let byteCount: Int
        let channels: UInt32
        let descPtr: UnsafeMutablePointer<AudioStreamPacketDescription>
        var consumed = false
        init(data: UnsafeMutableRawPointer, byteCount: Int, channels: UInt32) {
            self.data = data
            self.byteCount = byteCount
            self.channels = channels
            descPtr = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
            descPtr.initialize(to: AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(byteCount)))
        }
        deinit { descPtr.deinitialize(count: 1); descPtr.deallocate() }
    }

    /// Supplies the single compressed packet to the decoder, then reports "no
    /// more" so the fill call returns what it decoded from that one frame.
    private static let aacInputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData in
        guard let inUserData else { ioNumberDataPackets.pointee = 0; return noErr }
        let ctx = Unmanaged<AACInput>.fromOpaque(inUserData).takeUnretainedValue()
        if ctx.consumed {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        ctx.consumed = true
        ioNumberDataPackets.pointee = 1
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = ctx.channels
        ioData.pointee.mBuffers.mDataByteSize = UInt32(ctx.byteCount)
        ioData.pointee.mBuffers.mData = ctx.data
        outDataPacketDescription?.pointee = ctx.descPtr
        return noErr
    }

    private func releaseAAC() {
        if let c = aacConverter { AudioConverterDispose(c) }
        aacConverter = nil
    }

    /// Build the decoder for this frame's config and install the magic cookie
    /// (AudioSpecificConfig), exactly the two bytes Bee sets as MediaCodec's
    /// `csd-0`. Without it Apple's decoder stays silent.
    private func buildAAC(for frame: BeeADTSAssembler.Frame) {
        let hadWorking = (aacConverter != nil)
        func fail(_ reason: String) { if !hadWorking { unavailableReason = reason } }

        let ch = UInt32(min(2, max(1, Int(frame.channels))))
        let sr = frame.sampleRate
        var inASBD = AudioStreamBasicDescription(
            mSampleRate: sr, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket,
            mBytesPerFrame: 0, mChannelsPerFrame: ch, mBitsPerChannel: 0, mReserved: 0)
        var outASBD = AudioStreamBasicDescription(
            mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * ch, mFramesPerPacket: 1,
            mBytesPerFrame: 4 * ch, mChannelsPerFrame: ch, mBitsPerChannel: 32, mReserved: 0)

        var conv: AudioConverterRef?
        let st = AudioConverterNew(&inASBD, &outASBD, &conv)
        guard st == noErr, let conv else {
            fail("iOS wouldn't start the AAC decoder (status \(st)).")
            return
        }
        // AudioSpecificConfig: 5 bits objectType, 4 bits sampleRateIndex,
        // 4 bits channelConfig, 3 bits zero → 2 bytes. Same as Bee's csd-0.
        let cookie: [UInt8] = [
            UInt8((frame.objectType << 3) | (frame.sampleRateIndex >> 1)),
            UInt8(((frame.sampleRateIndex & 1) << 7) | (Int(ch) << 3))
        ]
        let cookieStatus = cookie.withUnsafeBytes {
            AudioConverterSetProperty(conv, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!)
        }
        guard cookieStatus == noErr else {
            AudioConverterDispose(conv)
            fail("iOS rejected the AAC config (status \(cookieStatus)).")
            return
        }

        releaseAAC()
        aacConverter = conv
        cfgRateIndex = frame.sampleRateIndex
        cfgChannels = Int(ch)
        cfgObjectType = frame.objectType
        sampleRate = sr
        channels = ch
        aacOutputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: AVAudioChannelCount(ch), interleaved: true)
        if let f = aacOutputFormat { outputFormat = f }
        unavailableReason = nil
    }

    private func decodeAAC(_ frame: BeeADTSAssembler.Frame) -> AVAudioPCMBuffer? {
        guard !frame.payload.isEmpty else { return nil }
        let ch = min(2, max(1, Int(frame.channels)))
        if aacConverter == nil || frame.sampleRateIndex != cfgRateIndex || ch != cfgChannels || frame.objectType != cfgObjectType {
            buildAAC(for: frame)
        }
        guard let converter = aacConverter, let outFormat = aacOutputFormat else { return nil }

        let byteCount = frame.payload.count
        let inputPtr = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 1)
        defer { inputPtr.deallocate() }
        frame.payload.copyBytes(to: inputPtr.assumingMemoryBound(to: UInt8.self), count: byteCount)

        let ctx = AACInput(data: inputPtr, byteCount: byteCount, channels: UInt32(cfgChannels))
        let ctxPtr = Unmanaged.passUnretained(ctx).toOpaque()

        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: framesPerPacket * 2) else { return nil }
        let abl = output.mutableAudioBufferList
        abl.pointee.mBuffers.mDataByteSize = output.frameCapacity * UInt32(4 * cfgChannels)

        var packets = output.frameCapacity
        _ = withExtendedLifetime(ctx) {
            AudioConverterFillComplexBuffer(converter, BeeAudioDecoder.aacInputProc, ctxPtr, &packets, abl, nil)
        }
        // Our input proc reports "no more data" after one packet, so the fill
        // call returns a non-zero status by design; any PCM it produced first is
        // valid, so trust the frame count rather than the status.
        guard packets > 0 else { return nil }
        output.frameLength = packets
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
