import Foundation

enum EXIFOrientation: UInt16, Sendable, CaseIterable {
    case identity = 1
    case mirroredHorizontally = 2
    case rotated180 = 3
    case mirroredVertically = 4
    case transposed = 5
    case rotated90Clockwise = 6
    case mirroredAcrossAntiDiagonal = 7
    case rotated90Counterclockwise = 8

    init?(jpegData: Data) {
        guard let orientation = jpegData.withUnsafeBytes(Self.readJPEGOrientation) else {
            return nil
        }
        self = orientation
    }

    var swapsAxes: Bool {
        switch self {
        case .transposed,
             .rotated90Clockwise,
             .mirroredAcrossAntiDiagonal,
             .rotated90Counterclockwise:
            return true
        case .identity,
             .mirroredHorizontally,
             .rotated180,
             .mirroredVertically:
            return false
        }
    }

    func destination(
        sourceX: Int,
        sourceY: Int,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> (x: Int, y: Int) {
        switch self {
        case .identity:
            return (sourceX, sourceY)
        case .mirroredHorizontally:
            return (sourceWidth - 1 - sourceX, sourceY)
        case .rotated180:
            return (sourceWidth - 1 - sourceX, sourceHeight - 1 - sourceY)
        case .mirroredVertically:
            return (sourceX, sourceHeight - 1 - sourceY)
        case .transposed:
            return (sourceY, sourceX)
        case .rotated90Clockwise:
            return (sourceHeight - 1 - sourceY, sourceX)
        case .mirroredAcrossAntiDiagonal:
            return (sourceHeight - 1 - sourceY, sourceWidth - 1 - sourceX)
        case .rotated90Counterclockwise:
            return (sourceY, sourceWidth - 1 - sourceX)
        }
    }

    private enum TIFFByteOrder {
        case littleEndian
        case bigEndian
    }

    private static let exifSignature: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]

    private static func readJPEGOrientation(
        _ bytes: UnsafeRawBufferPointer
    ) -> EXIFOrientation? {
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            return nil
        }

        var offset = 2
        while offset < bytes.count {
            while offset < bytes.count, bytes[offset] != 0xFF {
                offset += 1
            }
            while offset < bytes.count, bytes[offset] == 0xFF {
                offset += 1
            }
            guard offset < bytes.count else { return nil }

            let marker = bytes[offset]
            offset += 1
            if marker == 0xD9 || marker == 0xDA {
                return nil
            }
            if marker == 0x01 || marker == 0xD8 || (0xD0...0xD7).contains(marker) {
                continue
            }

            guard let segmentLength = readUInt16BigEndian(bytes, at: offset),
                  segmentLength >= 2
            else {
                return nil
            }
            let payloadStart = offset + 2
            let payloadEnd = payloadStart + Int(segmentLength) - 2
            guard payloadEnd <= bytes.count else { return nil }

            if marker == 0xE1,
               let orientation = readEXIFOrientation(
                   bytes,
                   payloadStart: payloadStart,
                   payloadEnd: payloadEnd
               ) {
                return orientation
            }
            offset = payloadEnd
        }
        return nil
    }

    private static func readEXIFOrientation(
        _ bytes: UnsafeRawBufferPointer,
        payloadStart: Int,
        payloadEnd: Int
    ) -> EXIFOrientation? {
        guard payloadEnd - payloadStart >= exifSignature.count + 8 else { return nil }
        for (index, byte) in exifSignature.enumerated() {
            guard bytes[payloadStart + index] == byte else { return nil }
        }

        let tiffStart = payloadStart + exifSignature.count
        let byteOrder: TIFFByteOrder
        switch (bytes[tiffStart], bytes[tiffStart + 1]) {
        case (0x49, 0x49):
            byteOrder = .littleEndian
        case (0x4D, 0x4D):
            byteOrder = .bigEndian
        default:
            return nil
        }
        guard readUInt16(bytes, at: tiffStart + 2, byteOrder: byteOrder) == 42,
              let firstIFDOffset = readUInt32(
                  bytes,
                  at: tiffStart + 4,
                  byteOrder: byteOrder
              )
        else {
            return nil
        }

        let firstIFD = tiffStart + Int(firstIFDOffset)
        guard firstIFD + 2 <= payloadEnd,
              let entryCount = readUInt16(bytes, at: firstIFD, byteOrder: byteOrder)
        else {
            return nil
        }

        for entryIndex in 0..<Int(entryCount) {
            let entry = firstIFD + 2 + entryIndex * 12
            guard entry + 12 <= payloadEnd else { return nil }
            guard readUInt16(bytes, at: entry, byteOrder: byteOrder) == 0x0112 else {
                continue
            }
            guard readUInt16(bytes, at: entry + 2, byteOrder: byteOrder) == 3,
                  readUInt32(bytes, at: entry + 4, byteOrder: byteOrder) == 1,
                  let rawOrientation = readUInt16(
                      bytes,
                      at: entry + 8,
                      byteOrder: byteOrder
                  )
            else {
                return nil
            }
            return EXIFOrientation(rawValue: rawOrientation)
        }
        return nil
    }

    private static func readUInt16BigEndian(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int
    ) -> UInt16? {
        guard offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func readUInt16(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int,
        byteOrder: TIFFByteOrder
    ) -> UInt16? {
        guard offset + 2 <= bytes.count else { return nil }
        switch byteOrder {
        case .littleEndian:
            return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        case .bigEndian:
            return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }
    }

    private static func readUInt32(
        _ bytes: UnsafeRawBufferPointer,
        at offset: Int,
        byteOrder: TIFFByteOrder
    ) -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        switch byteOrder {
        case .littleEndian:
            return UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        case .bigEndian:
            return UInt32(bytes[offset]) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
        }
    }
}
