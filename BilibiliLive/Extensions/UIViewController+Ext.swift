//
//  UIViewController+Ext.swift
//  BilibiliLive
//
//  Created by yicheng on 2022/8/20.
//

import UIKit

extension UIViewController {
    func topMostViewController() -> UIViewController {
        if let presented = presentedViewController {
            return presented.topMostViewController()
        }

        if let navigation = self as? UINavigationController {
            return navigation.visibleViewController?.topMostViewController() ?? navigation
        }

        if let tab = self as? UITabBarController {
            return tab.selectedViewController?.topMostViewController() ?? tab
        }

        return self
    }

    static func topMostViewController() -> UIViewController {
        return AppDelegate.shared.window!.rootViewController!.topMostViewController()
    }
}

// Gate account actions before changing button state or sending requests.
extension UIViewController {
    @discardableResult
    func requireLivingAccount() -> Bool {
        guard !ApiRequest.isLogin() else { return true }
        let alert = UIAlertController(title: "登录后使用", message: "点赞、投币、收藏和关注需要登录。游客仍可搜索、看视频和弹幕。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "继续游客浏览", style: .cancel))
        alert.addAction(UIAlertAction(title: "扫码登录", style: .default) { _ in
            AppDelegate.shared.showLogin()
        })
        let presenter = AppDelegate.shared.window?.rootViewController?.topMostViewController() ?? self
        if !(presenter is UIAlertController) { presenter.present(alert, animated: true) }
        return false
    }
}
