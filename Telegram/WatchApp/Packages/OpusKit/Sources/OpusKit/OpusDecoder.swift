import AVFoundation
import COgg
import COpus

public enum OpusDecoderError: Swift.Error {
    case fileNotFound
    case notOggOpus
    case decode(String)
}

/// The decoded PCM buffer.
///
/// `@unchecked Sendable` because `AVAudioPCMBuffer` is a reference type that
/// isn't Sendable in the SDK; we treat the buffer as immutable after construction
/// and never hand a `DecodedOpus` to a callee that mutates it.
public struct DecodedOpus: @unchecked Sendable {
    public let pcm: AVAudioPCMBuffer

    public init(pcm: AVAudioPCMBuffer) {
        self.pcm = pcm
    }
}

public enum OpusDecoder {

    public static func decodePCM(url: URL) throws -> DecodedOpus {
        let decoded = try decodeFile(url: url, sampleRate: 48000)
        let left = decoded.left, right = decoded.right
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: AVAudioChannelCount(decoded.channelCount),
            interleaved: false
        ),
        let pcm = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(left.count)
        ) else {
            throw OpusDecoderError.decode("AVAudioPCMBuffer alloc failed")
        }
        pcm.frameLength = AVAudioFrameCount(left.count)
        guard let channels = pcm.floatChannelData else {
            throw OpusDecoderError.decode("pcm.floatChannelData nil")
        }
        _ = left.withUnsafeBufferPointer { src in
            memcpy(channels[0], src.baseAddress, left.count * MemoryLayout<Float>.size)
        }
        if decoded.channelCount == 2 {
            _ = right.withUnsafeBufferPointer { src in
                memcpy(channels[1], src.baseAddress, right.count * MemoryLayout<Float>.size)
            }
        }
        return DecodedOpus(pcm: pcm)
    }

    /// Mono samples at `sampleRate` (8, 12, 16, 24 or 48 kHz). libopus decodes
    /// straight to that rate, so a speech recognizer wanting 16 kHz needs no
    /// resampling pass; stereo is averaged down to mono.
    public static func decodeMonoSamples(url: URL, sampleRate: Int32) throws -> [Float] {
        let decoded = try decodeFile(url: url, sampleRate: sampleRate)
        guard decoded.channelCount == 2 else { return decoded.left }
        let count = min(decoded.left.count, decoded.right.count)
        return (0..<count).map { (decoded.left[$0] + decoded.right[$0]) * 0.5 }
    }

    // MARK: - Implementation

    private struct DecodedChannels {
        var left: [Float]
        var right: [Float]
        var channelCount: Int32
    }

    private static func decodeFile(url: URL, sampleRate: Int32) throws -> DecodedChannels {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OpusDecoderError.fileNotFound
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw OpusDecoderError.fileNotFound
        }
        guard data.count >= 4, data[0] == 0x4F, data[1] == 0x67,
              data[2] == 0x67, data[3] == 0x53 else {
            throw OpusDecoderError.notOggOpus
        }
        return try data.withUnsafeBytes { raw -> DecodedChannels in
            guard let base = raw.baseAddress else {
                throw OpusDecoderError.notOggOpus
            }
            return try decodeFromMappedBytes(base, count: raw.count, sampleRate: sampleRate)
        }
    }

    private static func decodeFromMappedBytes(
        _ base: UnsafeRawPointer,
        count: Int,
        sampleRate: Int32
    ) throws -> DecodedChannels {
        var sync = ogg_sync_state()
        ogg_sync_init(&sync)
        defer { ogg_sync_clear(&sync) }

        guard let dst = ogg_sync_buffer(&sync, count) else {
            throw OpusDecoderError.decode("ogg_sync_buffer failed")
        }
        memcpy(dst, base, count)
        ogg_sync_wrote(&sync, count)

        var stream = ogg_stream_state()
        var streamInitialized = false
        defer { if streamInitialized { ogg_stream_clear(&stream) } }

        var page = ogg_page()
        var packet = ogg_packet()

        var decoder: OpaquePointer? = nil
        defer { if let d = decoder { opus_decoder_destroy(d) } }

        var channelCount: Int32 = 0
        var preSkip: Int32 = 0

        // Output PCM accumulators (deinterleaved). Sized generously; will grow
        // if needed. 30 s of voice at 48 kHz is ~1.44 M samples — fine in memory.
        var leftSamples: [Float] = []
        var rightSamples: [Float] = []
        leftSamples.reserveCapacity(Int(sampleRate) * 30)

        // Per-packet decode buffer; sized for 120 ms × 48 kHz × stereo.
        let maxFramesPerPacket = 5760
        var packetBuf = [Float](repeating: 0, count: maxFramesPerPacket * 2)

        var packetIndex = 0   // 0 = ID header, 1 = comment header, ≥2 = audio

        // libogg pageout: 1 = page extracted, 0 = need more data (never here — fully buffered),
        // -1 = sync lost / hole. On sync loss, skip and continue per libogg convention rather
        // than treating it as EOF (which would silently truncate a partially-corrupted file).
        pageLoop: while true {
            let pr = ogg_sync_pageout(&sync, &page)
            if pr == 0 { break pageLoop }
            if pr < 0 { continue pageLoop }
            if !streamInitialized {
                let serial = ogg_page_serialno(&page)
                ogg_stream_init(&stream, serial)
                streamInitialized = true
            }
            ogg_stream_pagein(&stream, &page)

            while ogg_stream_packetout(&stream, &packet) == 1 {
                guard let pktPtr = packet.packet else {
                    throw OpusDecoderError.notOggOpus
                }
                let pktBytes = UnsafeBufferPointer(
                    start: pktPtr, count: Int(packet.bytes)
                )

                if packetIndex == 0 {
                    // OpusHead: "OpusHead" magic (8), version (1), channelCount (1),
                    // preSkip (2 LE), inputSampleRate (4 LE), outputGain (2),
                    // channelMappingFamily (1), …
                    guard pktBytes.count >= 19,
                          pktBytes[0] == 0x4F, pktBytes[1] == 0x70,
                          pktBytes[2] == 0x75, pktBytes[3] == 0x73,
                          pktBytes[4] == 0x48, pktBytes[5] == 0x65,
                          pktBytes[6] == 0x61, pktBytes[7] == 0x64 else {
                        throw OpusDecoderError.notOggOpus
                    }
                    channelCount = Int32(pktBytes[9])
                    preSkip = Int32(pktBytes[10]) | (Int32(pktBytes[11]) << 8)
                    // The standard Opus decoder supports mono and stereo only;
                    // multichannel uses opus_multistream_decoder which we don't expose.
                    // The deinterleave branch below assumes channelCount ∈ {1, 2}.
                    guard channelCount == 1 || channelCount == 2 else {
                        throw OpusDecoderError.notOggOpus
                    }

                    var err: Int32 = 0
                    decoder = opus_decoder_create(sampleRate, channelCount, &err)
                    guard err == OPUS_OK, decoder != nil else {
                        throw OpusDecoderError.decode("opus_decoder_create err=\(err)")
                    }
                    packetIndex += 1
                    continue
                }
                if packetIndex == 1 {
                    // OpusTags comment header — skipped.
                    packetIndex += 1
                    continue
                }
                guard let d = decoder else {
                    throw OpusDecoderError.decode("no decoder")
                }
                let nframes = packetBuf.withUnsafeMutableBufferPointer { outBuf -> Int32 in
                    opus_decode_float(
                        d,
                        packet.packet,
                        Int32(packet.bytes),
                        outBuf.baseAddress!,
                        Int32(maxFramesPerPacket),
                        0
                    )
                }
                if nframes < 0 {
                    throw OpusDecoderError.decode("opus_decode_float err=\(nframes)")
                }
                if channelCount == 1 {
                    for f in 0..<Int(nframes) {
                        leftSamples.append(packetBuf[f])
                    }
                } else {
                    for f in 0..<Int(nframes) {
                        leftSamples.append(packetBuf[f * 2 + 0])
                        rightSamples.append(packetBuf[f * 2 + 1])
                    }
                }
                packetIndex += 1
            }
        }

        guard packetIndex >= 2, channelCount > 0 else {
            throw OpusDecoderError.notOggOpus
        }

        // Drop pre-skip frames per Opus spec (counted at 48 kHz).
        let skip = min(Int(preSkip) * Int(sampleRate) / 48000, leftSamples.count)
        leftSamples.removeFirst(skip)
        if channelCount == 2 {
            rightSamples.removeFirst(min(skip, rightSamples.count))
        }

        return DecodedChannels(left: leftSamples, right: rightSamples, channelCount: channelCount)
    }
}
