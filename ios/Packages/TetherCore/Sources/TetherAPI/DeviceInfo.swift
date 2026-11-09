import Foundation

/// Plain values describing this device (filled in by the app; no UIKit here).
public struct DeviceInfo: Sendable, Hashable {
    public var name: String
    public var model: String
    public var osVersion: String
    public var appVersion: String
    public init(name: String, model: String, osVersion: String, appVersion: String) {
        self.name = name; self.model = model; self.osVersion = osVersion; self.appVersion = appVersion
    }
}
