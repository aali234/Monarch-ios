import Foundation

enum ReceiptSharedConfig {
    static let groupID = "group.com.aali.monarch.sandbox"
    static let iCloudID = "iCloud.com.aali.monarch.sandbox"
    static let refreshTaskID = "com.aali.monarch.receipt-refresh"
    static let maximumBytes = 25 * 1024 * 1024
    static func inboxURL() throws -> URL {
        guard let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw NSError(domain: "MonarchReceipt", code: 1, userInfo: [NSLocalizedDescriptionKey: "The receipt Share Extension needs the shared App Group entitlement. You can still import files from inside Monarch."])
        }
        let directory = shared.appendingPathComponent("ReceiptInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        var directoryURL = directory, values = URLResourceValues(); values.isExcludedFromBackup = true
        try directoryURL.setResourceValues(values)
        return directory
    }
    static func safeName(_ text: String) -> String {
        let basename = (text as NSString).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        let safe = String(String.UnicodeScalarView(basename.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        return safe.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).isEmpty ? "receipt" : String(safe.prefix(160))
    }
    static func stage(_ data: Data, name: String) throws -> URL {
        guard data.count <= maximumBytes else { throw NSError(domain: "MonarchReceipt", code: 2, userInfo: [NSLocalizedDescriptionKey: "Choose a receipt file smaller than 25 MB."]) }
        let folder = try inboxURL().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        let file = folder.appendingPathComponent(safeName(name))
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        return file
    }
}
