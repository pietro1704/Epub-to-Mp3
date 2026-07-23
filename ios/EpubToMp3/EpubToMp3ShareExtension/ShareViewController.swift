#if os(iOS)
import UIKit
import UniformTypeIdentifiers
import MobileCoreServices

/// Share Extension entry point. Hosted inside the host app (Apple
/// Books, Files, Safari, Mail, …) when the user picks `EpubToMp3`
/// from the system Share Sheet.
///
/// Responsibilities:
///   1. Walk every `NSExtensionItem` attached to the request.
///   2. For each attachment matching an EPUB or PDF UTI, materialise
///      the payload to a temp file (the host app's URL is often a
///      `NSItemProvider` callback, not a disk path).
///   3. Copy that temp file into the shared App Group `Inbox`.
///   4. Dismiss with a 1-second "Imported" confirmation.
///
/// We deliberately avoid SwiftUI here — the extension UI must be
/// trivially fast and the project's minimum iOS is 15. UIKit is
/// 30 KB of overhead vs SwiftUI's hosting controller chain.
final class ShareViewController: UIViewController {

    // MARK: - UTIs we accept

    /// Identifiers matched against the incoming `NSItemProvider`.
    /// Mirrors `LibraryDropHandler.dropTypes`. The legacy IDPF id is
    /// kept because Apple Books historically exports EPUBs under that
    /// type rather than `org.idpf.epub`.
    static let acceptedTypeIdentifiers: [String] = [
        UTType.epub.identifier,
        "org.idpf.epub-container",
        UTType.pdf.identifier,
    ]

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        installConfirmationUI(message: "Importing to EpubToMp3…")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await processSharedItems() }
    }

    // MARK: - Item processing

    /// Walk every attachment, materialise it, and copy into the App
    /// Group inbox. Completes the extension request when done.
    @MainActor
    private func processSharedItems() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        var imported = 0
        var firstError: String?

        for item in items {
            let providers = item.attachments ?? []
            for provider in providers {
                guard let typeID = Self.matchedTypeIdentifier(in: provider) else {
                    continue
                }
                do {
                    let materialized = try await Self.loadFileURL(
                        from: provider,
                        typeIdentifier: typeID
                    )
                    _ = try SharedContainerInbox.dropIntoInbox(
                        source: materialized
                    )
                    imported += 1
                } catch {
                    if firstError == nil {
                        firstError = error.localizedDescription
                    }
                }
            }
        }

        // Show the result for ~0.8 s so the user sees confirmation.
        // The host app stays frozen behind us; longer than this and
        // it starts to feel sluggish.
        let summary: String
        if imported > 0 {
            summary = imported == 1
                ? "1 book imported to EpubToMp3"
                : "\(imported) books imported to EpubToMp3"
        } else if let err = firstError {
            summary = "Import failed: \(err)"
        } else {
            summary = "Nothing to import (no EPUB or PDF attached)"
        }
        installConfirmationUI(message: summary)
        try? await Task.sleep(nanoseconds: 800_000_000)
        completeRequest()
    }

    /// Pick the first UTI on the provider that matches one of our
    /// accepted identifiers. Returns `nil` when nothing matches.
    private static func matchedTypeIdentifier(
        in provider: NSItemProvider
    ) -> String? {
        for id in acceptedTypeIdentifiers {
            if provider.hasItemConformingToTypeIdentifier(id) {
                return id
            }
        }
        return nil
    }

    /// Load the attachment as a `URL` regardless of whether the host
    /// app handed us a real disk path or an in-memory `Data` blob.
    /// We always end up with a URL inside the extension's
    /// `temporaryDirectory` (`NSTemporaryDirectory()`).
    static func loadFileURL(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            provider.loadItem(
                forTypeIdentifier: typeIdentifier,
                options: nil
            ) { coercedItem, error in
                if let error = error {
                    cont.resume(throwing: error)
                    return
                }
                if let url = coercedItem as? URL {
                    // The host gave us a disk URL but it may be in
                    // the host's sandbox — copy into our tmp first.
                    do {
                        let copy = try Self.copyToTemp(source: url)
                        cont.resume(returning: copy)
                    } catch {
                        cont.resume(throwing: error)
                    }
                    return
                }
                if let data = coercedItem as? Data {
                    do {
                        let ext = typeIdentifier == UTType.pdf.identifier ? "pdf" : "epub"
                        let tmp = Self.tempURL(extension: ext)
                        try data.write(to: tmp)
                        cont.resume(returning: tmp)
                    } catch {
                        cont.resume(throwing: error)
                    }
                    return
                }
                cont.resume(throwing: NSError(
                    domain: "ShareViewController",
                    code: 100,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Unsupported attachment payload (\(type(of: coercedItem)))."]
                ))
            }
        }
    }

    private static func copyToTemp(source: URL) throws -> URL {
        let ext = source.pathExtension.isEmpty ? "epub" : source.pathExtension
        let dest = tempURL(extension: ext, suggested: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    private static func tempURL(extension ext: String, suggested: String? = nil) -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let name: String
        if let suggested, !suggested.isEmpty {
            name = "\(UUID().uuidString)-\(suggested)"
        } else {
            name = "\(UUID().uuidString).\(ext)"
        }
        return tmp.appendingPathComponent(name)
    }

    // MARK: - UI

    private func installConfirmationUI(message: String) {
        view.subviews.forEach { $0.removeFromSuperview() }
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let icon = UIImageView(image: UIImage(systemName: "books.vertical.fill"))
        icon.tintColor = .label
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let label = UILabel()
        label.text = message
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .headline)

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }

    private func completeRequest() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
#endif
