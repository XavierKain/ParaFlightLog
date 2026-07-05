//
//  BackupViews.swift
//  ParaFlightLog
//
//  Backup export screen + document picker + share sheet wrappers.
//  Split from SettingsViews.swift (Lot C).
//  Target: iOS only
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - BackupExportView (dedicated export screen)

struct BackupExportView: View {
    let wings: [Wing]
    let flights: [Flight]

    @State private var exportStatus: ExportStatus = .idle
    @State private var backupURL: URL?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    enum ExportStatus {
        case idle
        case exporting
        case completed
        case failed
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon and status
            Group {
                switch exportStatus {
                case .idle:
                    Image(systemName: "archivebox")
                        .font(.system(size: 80))
                        .foregroundStyle(.blue)

                case .exporting:
                    ProgressView()
                        .scaleEffect(2)
                        .tint(.blue)

                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.green)

                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.red)
                }
            }
            .frame(height: 100)

            // Status text
            Group {
                switch exportStatus {
                case .idle:
                    Text("Ready to export")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("\(wings.count) wings • \(flights.count) flights")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                case .exporting:
                    Text("Creating backup...")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Please wait")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                case .completed:
                    Text("Backup created!")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Ready to share")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                case .failed:
                    Text("Error")
                        .font(.title2)
                        .fontWeight(.semibold)
                    if let error = errorMessage {
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }

            Spacer()

            // Action buttons
            VStack(spacing: 16) {
                if exportStatus == .idle {
                    Button {
                        startExport()
                    } label: {
                        Label("Create Backup", systemImage: "arrow.down.doc")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .cornerRadius(12)
                    }
                } else if exportStatus == .completed, let url = backupURL {
                    Button {
                        shareBackup(url: url)
                    } label: {
                        Label("Share / Save", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundStyle(.white)
                            .cornerRadius(12)
                    }
                } else if exportStatus == .failed {
                    Button {
                        dismiss()
                    } label: {
                        Text("Back")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.gray.opacity(0.2))
                            .foregroundStyle(.primary)
                            .cornerRadius(12)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .navigationTitle("Export Backup")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func startExport() {
        exportStatus = .exporting

        BackupManager.exportBackup(wings: Array(wings), flights: Array(flights)) { result in
            switch result {
            case .success(let url):
                self.backupURL = url
                self.exportStatus = .completed

            case .failure(let error):
                self.errorMessage = error.localizedDescription
                self.exportStatus = .failed
            }
        }
    }

    private func shareBackup(url: URL) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let rootViewController = window.rootViewController else {
            return
        }

        let activityVC = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )

        // iPad support
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        rootViewController.present(activityVC, animated: true)
    }
}

// MARK: - DocumentPicker (backup import)

struct DocumentPicker: UIViewControllerRepresentable {
    let onDocumentPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .paraflightlog backups are folder bundles (v2 JSON or legacy v1 CSV)
        var contentTypes: [UTType] = [
            .folder,
            .package
        ]
        if let backupType = UTType(filenameExtension: "paraflightlog") {
            contentTypes.append(backupType)
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDocumentPicked: onDocumentPicked)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDocumentPicked: (URL) -> Void

        init(onDocumentPicked: @escaping (URL) -> Void) {
            self.onDocumentPicked = onDocumentPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onDocumentPicked(url)
        }
    }
}

// MARK: - ShareSheet (share files/folders)

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let activityVC = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )

        activityVC.completionWithItemsHandler = { _, completed, _, error in
            if let error = error {
                logError("Share error: \(error)", category: .general)
            }
            onComplete(completed)
        }

        return activityVC
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
