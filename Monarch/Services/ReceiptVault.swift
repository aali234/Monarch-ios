import Foundation
import CryptoKit
import MonarchCore

actor ReceiptVault {
    static let keyName = "receipt-vault-key.v1"
    private let local: URL
    private let cloudEnabled: Bool
    init(localURL: URL? = nil, cloudEnabled: Bool = true) {
        local = localURL ?? URL.applicationSupportDirectory.appendingPathComponent("Monarch/ReceiptFiles", isDirectory: true)
        self.cloudEnabled = cloudEnabled
    }
    private func key() throws -> SymmetricKey {
        if let data = try SecureStore.data(for: Self.keyName) { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try SecureStore.setData(key.withUnsafeBytes { Data($0) }, for: Self.keyName)
        return key
    }
    private func cloudBase() -> URL? { cloudEnabled ? FileManager.default.url(forUbiquityContainerIdentifier: ReceiptSharedConfig.iCloudID)?.appendingPathComponent("Documents", isDirectory: true) : nil }
    private func protectedDirectory(_ url: URL, excluded: Bool) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        if excluded { var location = url, values = URLResourceValues(); values.isExcludedFromBackup = true; try location.setResourceValues(values) }
    }
    func store(data: Data, name: String, type: String, receiptID: String, date: Date, role: String = "original", encrypted: Bool = true) throws -> ReceiptFile {
        guard data.count <= ReceiptSharedConfig.maximumBytes else { throw MailFailure.tooLarge }
        let safe = ReceiptSharedConfig.safeName(name)
        let storedName = UUID().uuidString + (encrypted ? ".sealed" : "-" + safe)
        let relative = "Receipts/\(LedgerDate.string(date, format: "yyyy/MM"))/\(receiptID)/\(storedName)"
        let localFile = try resolve(relative, base: local)
        try protectedDirectory(localFile.deletingLastPathComponent(), excluded: true)
        let content: Data
        if encrypted {
            let box = try AES.GCM.seal(data, using: key(), authenticating: Data("MonarchReceipt/v1".utf8))
            guard let sealed = box.combined else { throw BackupFailure.invalidFile }
            content = Data("MRCP1".utf8) + sealed
        } else { content = data }
        try content.write(to: localFile, options: [.atomic, .completeFileProtection])
        var location = "local"
        if let cloud = cloudBase() {
            let cloudFile = try resolve(relative, base: cloud)
            do {
                try protectedDirectory(cloudFile.deletingLastPathComponent(), excluded: false)
                try content.write(to: cloudFile, options: [.atomic, .completeFileProtection])
                location = "icloud"
            } catch { /* Keep the durable local copy. The app offers a retry and shows local status. */ }
        }
        return ReceiptFile(relativePath: relative, originalName: safe, contentType: type, role: role, location: location, encrypted: encrypted)
    }
    private func resolve(_ relative: String, base: URL) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.components(separatedBy: "/").contains(".."), !relative.contains("\\") else { throw BackupFailure.invalidReferences }
        let result = base.appendingPathComponent(relative).standardizedFileURL
        guard result.path.hasPrefix(base.standardizedFileURL.path + "/") else { throw BackupFailure.invalidReferences }
        return result
    }
    func storedData(_ file: ReceiptFile) throws -> Data {
        let localFile = try resolve(file.relativePath, base: local)
        let content: Data
        if FileManager.default.fileExists(atPath: localFile.path) { content = try Data(contentsOf: localFile) }
        else if let cloud = cloudBase() {
            let url = try resolve(file.relativePath, base: cloud)
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            var error: NSError?, result: Data?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { result = try? Data(contentsOf: $0) }
            guard let data = result else { throw error ?? NSError(domain: "MonarchReceipt", code: 3, userInfo: [NSLocalizedDescriptionKey: "The receipt is downloading from iCloud. Try opening it again shortly."]) }
            content = data
        } else { throw NSError(domain: "MonarchReceipt", code: 4, userInfo: [NSLocalizedDescriptionKey: "This receipt is not available on this device. Sign in to the original iCloud account and retry."]) }
        return content
    }
    func read(_ file: ReceiptFile) throws -> Data {
        let content = try storedData(file)
        guard file.encrypted else { return content }
        guard content.starts(with: Data("MRCP1".utf8)), let stored = try SecureStore.data(for: Self.keyName) else { throw BackupFailure.wrongPassphrase }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: content.dropFirst(5)), using: SymmetricKey(data: stored), authenticating: Data("MonarchReceipt/v1".utf8))
    }
    func restoreStoredFile(_ file: ReceiptFile, data: Data) throws {
        let destination = try resolve(file.relativePath, base: local)
        try protectedDirectory(destination.deletingLastPathComponent(), excluded: true)
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
    }
    func verifyCloudUpload(_ file: ReceiptFile) throws {
        guard file.location == "icloud", let cloud = cloudBase() else {
            throw ProxyError(errorCode: "ICLOUD_RECEIPTS_REQUIRED", message: "File every receipt in iCloud Drive before creating a backup without receipt file data.")
        }
        let url = try resolve(file.relativePath, base: cloud)
        guard try url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey]).ubiquitousItemIsUploaded == true else {
            throw ProxyError(errorCode: "ICLOUD_UPLOAD_PENDING", message: "iCloud is still uploading a receipt. Wait for the upload to finish, or include receipt file data in the backup.")
        }
    }
    func preview(_ file: ReceiptFile) throws -> URL {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent(ReceiptSharedConfig.safeName(file.originalName))
        try read(file).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
    func fileToCloud(_ file: ReceiptFile) throws -> ReceiptFile {
        guard let cloud = cloudBase() else { throw NSError(domain: "MonarchReceipt", code: 5, userInfo: [NSLocalizedDescriptionKey: "iCloud Drive is unavailable. Your original receipt is saved on this iPhone."]) }
        let source = try resolve(file.relativePath, base: local), destination = try resolve(file.relativePath, base: cloud)
        try protectedDirectory(destination.deletingLastPathComponent(), excluded: false)
        if FileManager.default.fileExists(atPath: source.path) { try Data(contentsOf: source).write(to: destination, options: [.atomic, .completeFileProtection]) }
        else if !FileManager.default.fileExists(atPath: destination.path) { throw MailFailure.invalidMessage }
        var result = file; result.location = "icloud"; return result
    }
    func temporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("MonarchReceiptExports", isDirectory: true)
        try protectedDirectory(base, excluded: true)
        // Decrypted previews and explicitly requested readable exports are short-lived.
        for item in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            if let created = try? item.resourceValues(forKeys: [.creationDateKey]).creationDate, Date.now.timeIntervalSince(created) > 3600 { try? FileManager.default.removeItem(at: item) }
        }
        let result = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try protectedDirectory(result, excluded: true); return result
    }
    func exportHSA(_ receipts: [ReceiptValue], year: Int) throws -> [URL] {
        let directory = try temporaryDirectory(), csv = directory.appendingPathComponent("HSA-\(year).csv"), zip = directory.appendingPathComponent("HSA-\(year).zip")
        try Data(HSAExport.csv(receipts, year: year).utf8).write(to: csv, options: [.atomic, .completeFileProtection])
        var files = [ZIPFile(name: "HSA-\(year).csv", url: csv)]
        for receipt in HSAExport.receipts(receipts, year: year) {
            let folderName = LedgerDate.string(receipt.date) + "-" + receipt.id
            let folder = directory.appendingPathComponent(folderName, isDirectory: true)
            try protectedDirectory(folder, excluded: true)
            for (index, file) in receipt.files.enumerated() {
                let name = "\(index + 1)-" + ReceiptSharedConfig.safeName(file.originalName), url = folder.appendingPathComponent(name)
                try read(file).write(to: url, options: [.atomic, .completeFileProtection])
                files.append(ZIPFile(name: "Receipts/\(folderName)/\(name)", url: url))
            }
        }
        try ZIPArchive.write(files, to: zip)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: zip.path)
        return [zip, csv]
    }
}
