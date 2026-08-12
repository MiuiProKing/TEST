import UIKit
import UniformTypeIdentifiers

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let browserDelegate = IPABrowserDelegate()

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let ipaType = UTType(importedAs: "com.miuiproking.ipacleaner.ipa", conformingTo: .data)
        let browser = UIDocumentBrowserViewController(forOpening: [ipaType])
        browser.delegate = browserDelegate
        browser.allowsDocumentCreation = false
        browser.allowsPickingMultipleItems = true
        browser.title = "IPA Cleaner"

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = browser
        self.window = window
        window.makeKeyAndVisible()
    }
}

final class IPABrowserDelegate: NSObject, UIDocumentBrowserViewControllerDelegate {
    func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt documentURLs: [URL]) {
        let ipaURLs = documentURLs.filter { $0.pathExtension.lowercased() == "ipa" }
        guard !ipaURLs.isEmpty else { return }

        let totalBytes = ipaURLs.reduce(Int64(0)) { partial, url in
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return partial + Int64(values?.fileSize ?? 0)
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: totalBytes)

        let message: String
        if ipaURLs.count == 1 {
            message = "Удалить файл «\(ipaURLs[0].lastPathComponent)»?\nРазмер: \(size)"
        } else {
            message = "Удалить выбранные IPA: \(ipaURLs.count) шт.?\nОбщий размер: \(size)"
        }

        let alert = UIAlertController(title: "Удаление IPA", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { _ in
            var deleted = 0
            var failed = 0

            for url in ipaURLs {
                let started = url.startAccessingSecurityScopedResource()
                defer { if started { url.stopAccessingSecurityScopedResource() } }

                do {
                    try FileManager.default.removeItem(at: url)
                    deleted += 1
                } catch {
                    failed += 1
                }
            }

            let resultMessage = failed == 0
                ? "Удалено: \(deleted)"
                : "Удалено: \(deleted)\nНе удалось удалить: \(failed)"

            let result = UIAlertController(title: "Готово", message: resultMessage, preferredStyle: .alert)
            result.addAction(UIAlertAction(title: "OK", style: .default))
            controller.present(result, animated: true)
        })

        controller.present(alert, animated: true)
    }
}
