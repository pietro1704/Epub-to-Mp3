#if os(iOS)
import SwiftUI
import UIKit

struct IOSTabBarVisibilityBridge: UIViewControllerRepresentable {
    let visible: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ viewController: UIViewController, context: Context) {
        DispatchQueue.main.async {
            viewController.tabBarController?.tabBar.isHidden = !visible
        }
    }

    static func dismantleUIViewController(_ viewController: UIViewController, coordinator: ()) {
        viewController.tabBarController?.tabBar.isHidden = false
    }
}
#endif
