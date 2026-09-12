import UIKit
import Darwin

// ===== 顶层代码（main.swift）：最早执行，先加载插件再启动 App =====
// 真机上由 TrollFools 注入加载；模拟器测试里用 dlopen 等效模拟（同样在 main 之前）。
let _dylibPath = Bundle.main.bundlePath + "/AdSkipper_sim.dylib"
let _handle = dlopen(_dylibPath, RTLD_NOW)
FileHandle.standardError.write(Data("dlopen(\(_dylibPath)) → \(_handle != nil ? "OK" : "FAILED")\n".utf8))

// ===== 最小测试宿主：假开屏广告 =====
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let win = UIWindow(frame: UIScreen.main.bounds)

        let ad = UIViewController()
        ad.view.backgroundColor = UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)

        let skip = UIButton(type: .system)
        skip.setTitle("跳过广告", for: .normal)
        skip.setTitleColor(.white, for: .normal)
        skip.titleLabel?.font = .boldSystemFont(ofSize: 22)
        skip.backgroundColor = UIColor(white: 0, alpha: 0.35)
        skip.frame = CGRect(x: 240, y: 90, width: 140, height: 48)
        skip.layer.cornerRadius = 8

        let close = UIButton(type: .system)
        close.setTitle("×", for: .normal)
        close.setTitleColor(.white, for: .normal)
        close.titleLabel?.font = .boldSystemFont(ofSize: 26)
        close.backgroundColor = UIColor(white: 0, alpha: 0.35)
        close.frame = CGRect(x: 340, y: 60, width: 44, height: 44)
        close.layer.cornerRadius = 22

        func goHome(_ who: String) {
            let home = UIViewController()
            home.view.backgroundColor = UIColor(red: 0.1, green: 0.6, blue: 0.2, alpha: 1)
            let lb = UILabel(frame: CGRect(x: 0, y: 380, width: UIScreen.main.bounds.width, height: 60))
            lb.text = "主页（广告已被 \(who) 关闭）"
            lb.textAlignment = .center
            lb.textColor = .white
            lb.font = .boldSystemFont(ofSize: 20)
            home.view.addSubview(lb)
            win.rootViewController = home
            FileHandle.standardError.write(Data("[TestHost] HOME_SHOWN via \(who)\n".utf8))
        }

        skip.addAction(UIAction { _ in
            FileHandle.standardError.write(Data("[TestHost] SKIP_TAPPED\n".utf8))
            goHome("跳过按钮")
        }, for: .touchUpInside)
        close.addAction(UIAction { _ in
            FileHandle.standardError.write(Data("[TestHost] CLOSE_TAPPED\n".utf8))
            goHome("×按钮")
        }, for: .touchUpInside)

        ad.view.addSubview(skip)
        ad.view.addSubview(close)
        win.rootViewController = ad
        win.makeKeyAndVisible()
        self.window = win
        FileHandle.standardError.write(Data("[TestHost] AD_SHOWN skip=(240,90,140x48) close=(340,60,44x44)\n".utf8))
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
