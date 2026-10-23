import UIKit
import SwiftUI
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private var importing = false
    override func viewDidLoad() {
        super.viewDidLoad()
        let button = UIButton(type: .system)
        button.setTitle("Save receipt to Monarch", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.addTarget(self, action: #selector(save), for: .touchUpInside)
        let label = UILabel(); label.text = "Save this email, PDF, image, or shared text.\nOpen Monarch to review the extracted details."; label.numberOfLines = 0; label.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [label, button]); stack.axis = .vertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack); view.backgroundColor = .systemBackground
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
    }
    @objc private func save() {
        guard !importing else { return }; importing = true
        Task { @MainActor in
            do {
                let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
                let providers = items.flatMap { $0.attachments ?? [] }
                guard !providers.isEmpty, providers.count <= 10 else { throw NSError(domain: "MonarchReceipt", code: 6, userInfo: [NSLocalizedDescriptionKey: "Share one to ten receipt files at a time."]) }
                for provider in providers { try await stage(provider) }
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                importing = false
                let alert = UIAlertController(title: "Receipt was not saved", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
            }
        }
    }
    private func stage(_ provider: NSItemProvider) async throws {
        let imageType = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
        let binary = [UTType.pdf.identifier, "public.email-message", imageType].compactMap { $0 }
        if let type = binary.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    do {
                        if let error { throw error }; guard let url else { throw CocoaError(.fileReadUnknown) }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= ReceiptSharedConfig.maximumBytes else { throw CocoaError(.fileReadTooLarge) }
                        // The provider URL is valid only inside this callback.
                        let fileExtension = UTType(type)?.preferredFilenameExtension ?? url.pathExtension
                        var name = provider.suggestedName ?? url.lastPathComponent
                        if !fileExtension.isEmpty && (name as NSString).pathExtension.lowercased() != fileExtension.lowercased() { name += "." + fileExtension }
                        continuation.resume(returning: try ReceiptSharedConfig.stage(Data(contentsOf: url), name: name))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            return
        }
        let type = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) ? UTType.plainText.identifier : UTType.url.identifier
        let value: NSSecureCoding = try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
        }
        let text: String
        if let string = value as? String { text = string }
        else if let url = value as? URL, url.isFileURL {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= ReceiptSharedConfig.maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            _ = try ReceiptSharedConfig.stage(Data(contentsOf: url), name: url.lastPathComponent); return
        } else if let url = value as? URL { text = url.absoluteString }
        else if let data = value as? Data { text = String(decoding: data, as: UTF8.self) }
        else { throw CocoaError(.fileReadUnknown) }
        _ = try ReceiptSharedConfig.stage(Data(text.utf8), name: "shared-receipt.txt")
    }
}
