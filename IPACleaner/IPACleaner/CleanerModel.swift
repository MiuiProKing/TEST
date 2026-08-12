import Foundation

@MainActor
final class CleanerModel: ObservableObject {
    @Published var files: [IPAFile] = []
    @Published var selected = Set<String>()
    @Published var isScanning = false
    @Published var status = "Выберите папку для поиска IPA"
    @Published var errorMessage: String?
    @Published var folderURL: URL?

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
    var selectedFiles: [IPAFile] { files.filter { selected.contains($0.id) } }
    var selectedSize: Int64 { selectedFiles.reduce(0) { $0 + $1.size } }

    func setFolder(_ url: URL) {
        folderURL = url
        scan()
    }

    func scan() {
        guard let folderURL else { return }
        isScanning = true
        files = []
        selected = []
        status = "Сканирование…"
        errorMessage = nil

        Task.detached(priority: .userInitiated) {
            let access = folderURL.startAccessingSecurityScopedResource()
            defer {
                if access { folderURL.stopAccessingSecurityScopedResource() }
            }

            var found: [IPAFile] = []
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            let fm = FileManager.default

            if let enumerator = fm.enumerator(
                at: folderURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) {
                for case let fileURL as URL in enumerator {
                    guard fileURL.pathExtension.lowercased() == "ipa" else { continue }
                    let values = try? fileURL.resourceValues(forKeys: Set(keys))
                    guard values?.isRegularFile == true else { continue }
                    let size = Int64(values?.fileSize ?? 0)
                    found.append(IPAFile(url: fileURL, size: size))
                }
            }

            found.sort { $0.size > $1.size }

            await MainActor.run {
                self.files = found
                self.isScanning = false
                self.status = found.isEmpty
                    ? "IPA-файлы не найдены в выбранной папке"
                    : "Найдено: \(found.count)"
            }
        }
    }

    func toggle(_ file: IPAFile) {
        if selected.contains(file.id) {
            selected.remove(file.id)
        } else {
            selected.insert(file.id)
        }
    }

    func selectAll() {
        selected = Set(files.map(\.id))
    }

    func clearSelection() {
        selected.removeAll()
    }

    func deleteSelected() {
        guard let folderURL, !selectedFiles.isEmpty else { return }
        let toDelete = selectedFiles
        isScanning = true
        errorMessage = nil

        Task.detached(priority: .userInitiated) {
            let access = folderURL.startAccessingSecurityScopedResource()
            defer {
                if access { folderURL.stopAccessingSecurityScopedResource() }
            }

            var failed: [String] = []
            for file in toDelete {
                var coordinationError: NSError?
                var deletionError: Error?
                let coordinator = NSFileCoordinator(filePresenter: nil)
                coordinator.coordinate(
                    writingItemAt: file.url,
                    options: .forDeleting,
                    error: &coordinationError
                ) { coordinatedURL in
                    do {
                        try FileManager.default.removeItem(at: coordinatedURL)
                    } catch {
                        deletionError = error
                    }
                }

                if coordinationError != nil || deletionError != nil {
                    failed.append(file.name)
                }
            }

            await MainActor.run {
                self.isScanning = false
                if failed.isEmpty {
                    self.status = "Удалено: \(toDelete.count)"
                } else {
                    self.errorMessage = "Не удалось удалить: \(failed.joined(separator: ", "))"
                }
                self.scan()
            }
        }
    }
}
