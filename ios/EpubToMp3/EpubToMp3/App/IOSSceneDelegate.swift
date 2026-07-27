#if os(iOS)
import UIKit

final class IOSSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene,
              let appDelegate = UIApplication.shared.delegate as? EpubToMp3App else {
            return
        }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = appDelegate.makeIOSRootController()
        window.makeKeyAndVisible()
        self.window = window
        appDelegate.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        (UIApplication.shared.delegate as? EpubToMp3App)?.activateRuntimeForScene()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        (UIApplication.shared.delegate as? EpubToMp3App)?.deactivateRuntimeForScene()
    }
}
#endif
