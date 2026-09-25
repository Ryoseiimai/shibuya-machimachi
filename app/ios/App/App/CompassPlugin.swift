import Foundation
import CoreLocation
import Capacitor

/// 端末のコンパス(CoreLocationの方位)をWeb画面に届ける、このアプリ独自のCapacitorプラグイン。
/// 待ち合わせ画面の矢印を「相手の方角 − 自分の向き」で回すのに使う(worker/public/assets/js/app.js の
/// startOrientation → window.MachimachiHost.watchHeading → Capacitor.Plugins.Compass)。
/// Webの DeviceOrientationEvent と違い、許可ボタンを押さなくても真北基準の方位が取れる。
/// 方位は端末の中だけで使い、どこにも送信しない。
@objc(CompassPlugin)
public class CompassPlugin: CAPPlugin, CAPBridgedPlugin, CLLocationManagerDelegate {
    public let identifier = "CompassPlugin"
    public let jsName = "Compass"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise)
    ]

    /// 何度変わったら通知するか(細かすぎる更新でWeb側の再描画が詰まらないように)
    private static let headingFilterDegrees: CLLocationDegrees = 2

    private var manager: CLLocationManager?

    @objc func start(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard CLLocationManager.headingAvailable() else {
                call.resolve(["available": false])
                return
            }
            let manager = self.manager ?? CLLocationManager()
            manager.delegate = self
            manager.headingFilter = Self.headingFilterDegrees
            manager.headingOrientation = .portrait
            manager.startUpdatingHeading()
            self.manager = manager
            call.resolve(["available": true])
        }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.manager?.stopUpdatingHeading()
            call.resolve()
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // trueHeading は位置情報が使えるときだけ有効(負の値なら磁北基準で代用する)
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard heading >= 0 else { return }
        notifyListeners("heading", data: ["heading": heading, "accuracy": newHeading.headingAccuracy])
    }
}

/// アプリ独自プラグイン(Compass)を登録するための CAPBridgeViewController。SceneDelegate から使う。
class MainViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(CompassPlugin())
    }
}
