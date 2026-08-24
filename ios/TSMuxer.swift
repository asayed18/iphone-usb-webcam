import Foundation

/// Minimal MPEG-TS muxer for a single H.264 PID.
/// Emits spec-correct 188-byte packets: PAT/PMT resend periodically, PCR on video PID,
/// PES with PTS, AF-based stuffing. OBS/ffmpeg can join mid-stream.
final class TSMuxer {
    private let pmtPID: UInt16 = 0x1000
    private let videoPID: UInt16 = 0x0100
    private let tablesEveryAUs = 50

    private var videoCC: UInt8 = 0
    private var patCC: UInt8 = 0
    private var pmtCC: UInt8 = 0
    private var ausSinceTables = 0

    /// Packetize one Annex-B access unit. Returns complete TS bytes for the AU.
    func packetize(accessUnit: Data, pts90k: UInt64, isIDR: Bool) -> Data {
        var out = Data()

        if ausSinceTables >= tablesEveryAUs {
            out.append(psiPacket(pid: 0x0000, cc: &patCC, section: Self.patSection(pmtPID: pmtPID)))
            out.append(psiPacket(pid: pmtPID, cc: &pmtCC, section: Self.pmtSection(programNumber: 1, pcrAndVideoPID: videoPID)))
            ausSinceTables = 0
        }
        ausSinceTables += 1

        // Split large access units across multiple PES packets; only the last carries the PTS.
        let maxPESBody = 65_535 - 3 - 5 // PES_packet_length excludes prefix + length bytes; reserve PTS header
        var chunks: [(Data, Bool)] = [] // (body, carriesPTS)
        if accessUnit.count <= maxPESBody {
            chunks = [(accessUnit, true)]
        } else {
            var offset = 0
            while offset < accessUnit.count {
                let end = min(offset + maxPESBody, accessUnit.count)
                chunks.append((accessUnit.subdata(in: offset..<end), end == accessUnit.count))
                offset = end
            }
        }

        for chunk in chunks {
            let isLastPES = chunk.1
            let pes = Self.pesHeader(streamID: 0xE0, body: chunk.0, pts90k: isLastPES ? pts90k : nil)
            emitPES(pes, pid: videoPID,
                    pcrBase: (isLastPES && isIDR) ? pts90k : nil,
                    randomAccess: isLastPES && isIDR,
                    into: &out)
        }
        return out
    }

    // MARK: - Packet emission

    private func bump() -> UInt8 {
        defer { videoCC = (videoCC &+ 1) & 0x0F }
        return videoCC
    }

    private func bumpPSI(_ cc: inout UInt8) -> UInt8 {
        defer { cc = (cc &+ 1) & 0x0F }
        return cc
    }

    /// Emit one Annex-B PES packet as one or more TS packets.
    private func emitPES(_ pes: Data, pid: UInt16, pcrBase: UInt64?, randomAccess: Bool, into out: inout Data) {
        var offset = 0
        var first = true

        while offset < pes.count {
            var afWire = Data()          // full AF block as it goes on the wire (incl. length byte)
            var afConsumes = 0

            if first && (randomAccess || pcrBase != nil) {
                var body = Data()
                var flags: UInt8 = 0x00
                if randomAccess { flags |= 0x40 }
                if pcrBase != nil {
                    flags |= 0x10
                    body.append(contentsOf: Self.encodePCR(pcrBase!))
                }
                afWire.append(flags)              // length patched below
                afWire.append(body)
                afWire[0] = UInt8(body.count)     // length counts flags + options
                afConsumes = afWire.count         // 1 + body.count
            }

            let available = 184 - afConsumes
            let remaining = pes.count - offset

            // Need stuffing?
            if remaining < available {
                let stuff = available - remaining
                if afConsumes == 0 {
                    // Introduce an empty AF purely for stuffing.
                    if stuff == 1 {
                        afWire = Data([0x00])     // length 0: no flags
                        afConsumes = 1
                    } else {
                        afWire = Data([UInt8(stuff - 1), 0x00])
                        afWire.append(contentsOf: repeatElement(0xFF, count: stuff - 2))
                        afConsumes = stuff
                    }
                } else {
                    // Extend existing AF; padding lives inside AF as 0xFF.
                    afWire.append(contentsOf: repeatElement(0xFF, count: stuff))
                    afWire[0] = UInt8(Int(afWire[0]) + stuff)
                    afConsumes += stuff
                }
            }

            let available2 = 184 - afConsumes
            let take = min(pes.count - offset, available2)
            var pkt = Data(capacity: 188)
            pkt.append(0x47)
            pkt.append((first ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F) | (afConsumes > 0 ? 0x20 : 0x00))
            pkt.append(UInt8(pid & 0xFF))
            pkt.append((afConsumes > 0 ? 0x30 : 0x10) | (first ? bump() : bump()))
            if afConsumes > 0 { pkt.append(afWire) }
            pkt.append(pes.subdata(in: offset..<(offset + take)))
            out.append(pkt)
            precondition(pkt.count <= 188)

            offset += take
            first = false
            if take == 0 { break } // safety
        }
    }

    /// Single-packet PSI: pointer_field + section + 0xFF stuffing.
    private func psiPacket(pid: UInt16, cc: inout UInt8, section: Data) -> Data {
        var pkt = Data(capacity: 188)
        pkt.append(0x47)
        pkt.append(0x40 | UInt8((pid >> 8) & 0x1F)) // PUSI, no AF
        pkt.append(UInt8(pid & 0xFF))
        pkt.append(0x10 | bumpPSI(&cc))
        pkt.append(0x00) // pointer_field
        pkt.append(section)
        while pkt.count < 188 { pkt.append(0xFF) }
        return pkt
    }

    // MARK: - Headers

    static func pesHeader(streamID: UInt8, body: Data, pts90k: UInt64?) -> Data {
        var h = Data([0x00, 0x00, 0x01, streamID])
        if let pts = pts90k.map({ $0 & 0x1_FFFF_FFFF }) {
            let length = 3 + 5 + body.count
            h.append(UInt8((length >> 8) & 0xFF))
            h.append(UInt8(length & 0xFF))
            h.append(0x84) // data alignment indicator + PTS present
            h.append(0x80) // PTS_DTS_flags = '10'
            h.append(contentsOf: encodePTS(pts, prefix: 0b0010))
        } else {
            let length = 3 + 3 + body.count
            h.append(UInt8((length >> 8) & 0xFF))
            h.append(UInt8(length & 0xFF))
            h.append(0x04) // data alignment indicator only
            h.append(0x00)
            h.append(0x0F) // ES_rate flag pattern filler
        }
        return h + body
    }

    static func encodePTS(_ pts: UInt64, prefix: UInt8) -> [UInt8] {
        [
            (prefix << 4) | UInt8((pts >> 29) & 0x0E) | 0x01,
            UInt8((pts >> 22) & 0xFF),
            UInt8((pts >> 14) & 0xFE) | 0x01,
            UInt8((pts >> 7) & 0xFF),
            UInt8((pts << 1) & 0xFE) | 0x01,
        ]
    }

    static func encodePCR(_ base90k: UInt64) -> [UInt8] {
        let base = base90k & 0x1_FFFF_FFFF
        return [
            UInt8((base >> 25) & 0xFF),
            UInt8((base >> 17) & 0xFF),
            UInt8((base >> 9) & 0xFF),
            UInt8((base >> 1) & 0xFF),
            UInt8(((base & 0x01) << 7) | 0x7E),
            0x00,
        ]
    }

    // MARK: - PSI tables

    static func patSection(pmtPID: UInt16) -> Data {
        var s = Data()
        s.append(0x00)                                   // table_id
        s.append(0xB0); s.append(0x0D)                   // section_syntax=1,0 + length = 13
        s.append(0x00); s.append(0x01)                   // transport_stream_id
        s.append(0xC1)                                   // reserved, version 0, current_next
        s.append(0x00)                                   // section_number
        s.append(0x00)                                   // last_section_number
        s.append(0x00); s.append(0x01)                   // program_number = 1
        s.append(0xE0 | UInt8((pmtPID >> 8) & 0x1F))
        s.append(UInt8(pmtPID & 0xFF))
        s.append(contentsOf: crcBytes(crc32MPEG(s.prefix(13))))
        return s
    }

    static func pmtSection(programNumber: UInt16, pcrAndVideoPID: UInt16) -> Data {
        var s = Data()
        s.append(0x02)                                   // table_id
        s.append(0xB0); s.append(0x12)                   // length = 18
        s.append(UInt8((programNumber >> 8) & 0xFF))
        s.append(UInt8(programNumber & 0xFF))
        s.append(0xC1)
        s.append(0x00); s.append(0x00)
        s.append(0xE0 | UInt8((pcrAndVideoPID >> 8) & 0x1F)); s.append(UInt8(pcrAndVideoPID & 0xFF)) // PCR PID
        s.append(0xF0); s.append(0x00)                   // program_info_length = 0
        s.append(0x1B)                                   // stream_type: H.264
        s.append(0xE0 | UInt8((pcrAndVideoPID >> 8) & 0x1F)); s.append(UInt8(pcrAndVideoPID & 0xFF)) // ES PID
        s.append(0xF0); s.append(0x00)                   // ES_info_length = 0
        s.append(contentsOf: crcBytes(crc32MPEG(s.prefix(18))))
        return s
    }

    static func crcBytes(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// CRC-32/MPEG-2 (poly 0x04C11DB7, init 0xFFFFFFFF, no reflection, no final xor).
    static func crc32MPEG<D: Sequence>(_ bytes: D) -> UInt32 where D.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : (crc << 1)
            }
        }
        return crc
    }
}
