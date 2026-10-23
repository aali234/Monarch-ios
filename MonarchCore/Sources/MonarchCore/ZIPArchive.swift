import Foundation

public enum ZIPFailure: Error, LocalizedError, Equatable {
    case invalidName, tooLarge
    public var errorDescription: String? { self == .invalidName ? "An export filename is invalid." : "This export exceeds the supported ZIP size. Export fewer receipt files." }
}
public struct ZIPFile: Sendable {
    public var name: String
    public var url: URL
    public init(name: String, url: URL) { self.name = name; self.url = url }
}
/// Streaming ZIP32 writer using the standard STORE method and CRC-32. No upload or compression service.
public enum ZIPArchive {
    private static let table: [UInt32] = (0..<256).map { value in (0..<8).reduce(UInt32(value)) { crc, _ in (crc & 1) == 1 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1 } }
    public static func write(_ files: [ZIPFile], to destination: URL) throws {
        guard files.count <= 65535, Set(files.map(\.name)).count == files.count else { throw ZIPFailure.tooLarge }
        for file in files {
            guard !file.name.hasPrefix("/"), !file.name.contains("\\"), !file.name.components(separatedBy: "/").contains(".."), !file.name.contains("\0"), file.name.utf8.count <= 65535 else { throw ZIPFailure.invalidName }
        }
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)
        var central = Data(), offset: UInt64 = 0
        func u16(_ value: UInt16) -> Data { var raw = value.littleEndian; return withUnsafeBytes(of: &raw) { Data($0) } }
        func u32(_ value: UInt32) -> Data { var raw = value.littleEndian; return withUnsafeBytes(of: &raw) { Data($0) } }
        func header(_ values: [Data]) -> Data { values.reduce(into: Data()) { $0.append($1) } }
        for file in files {
            let input = try FileHandle(forReadingFrom: file.url)
            var crc: UInt32 = 0xFFFFFFFF, size: UInt64 = 0
            while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
                size += UInt64(chunk.count); guard size <= UInt32.max else { try input.close(); throw ZIPFailure.tooLarge }
                for byte in chunk { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
            }
            crc ^= 0xFFFFFFFF
            guard offset <= UInt32.max else { try input.close(); throw ZIPFailure.tooLarge }
            let name = Data(file.name.utf8), count = UInt32(size)
            let local = header([u32(0x04034B50), u16(20), u16(0x0800), u16(0), u16(0), u16(33), u32(crc), u32(count), u32(count), u16(UInt16(name.count)), u16(0), name])
            try output.write(contentsOf: local)
            try input.seek(toOffset: 0)
            while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty { try output.write(contentsOf: chunk) }
            try input.close()
            central.append(header([u32(0x02014B50), u16(20), u16(20), u16(0x0800), u16(0), u16(0), u16(33), u32(crc), u32(count), u32(count), u16(UInt16(name.count)), u16(0), u16(0), u16(0), u16(0), u32(0), u32(UInt32(offset)), name]))
            offset += UInt64(local.count) + size
        }
        guard offset <= UInt32.max, central.count <= UInt32.max else { throw ZIPFailure.tooLarge }
        try output.write(contentsOf: central)
        try output.write(contentsOf: header([u32(0x06054B50), u16(0), u16(0), u16(UInt16(files.count)), u16(UInt16(files.count)), u32(UInt32(central.count)), u32(UInt32(offset)), u16(0)]))
    }
}
