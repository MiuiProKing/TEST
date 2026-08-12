import Foundation

struct IPAFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    var id: String { url.path }

    var name: String { url.lastPathComponent }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
