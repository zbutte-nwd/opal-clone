// Fake ManagedSettings mirroring the iOS 17/18 SDK surface we use.
import Foundation

public struct Token<T>: Codable, Hashable, Equatable { public init() {} }
public typealias ApplicationToken = Token<Application>
public typealias ActivityCategoryToken = Token<ActivityCategory>
public typealias WebDomainToken = Token<WebDomain>

public struct Application: Codable, Hashable {
    public let token: ApplicationToken?
    public let bundleIdentifier: String?
    public let localizedDisplayName: String?
    public init(bundleIdentifier: String) { token = nil; self.bundleIdentifier = bundleIdentifier; localizedDisplayName = nil }
    public init(token: ApplicationToken) { self.token = token; bundleIdentifier = nil; localizedDisplayName = nil }
}
public struct ActivityCategory: Codable, Hashable {
    public let token: ActivityCategoryToken?
    public let localizedDisplayName: String?
    public init(token: ActivityCategoryToken) { self.token = token; localizedDisplayName = nil }
}
public struct WebDomain: Codable, Hashable {
    public let token: WebDomainToken?
    public let domain: String?
    public init(domain: String) { self.domain = domain; token = nil }
    public init(token: WebDomainToken) { self.token = token; domain = nil }
}

public enum ActivityCategoryPolicy<Category>: Equatable {
    case none
    case all(except: Set<Token<Category>> = [])
    case specific(Set<ActivityCategoryToken>, except: Set<Token<Category>> = [])
}

public struct ShieldSettings: Equatable {
    public typealias ActivityCategoryPolicy<C> = ManagedSettings.ActivityCategoryPolicy<C>
    public var applications: Set<ApplicationToken>?
    public var applicationCategories: ActivityCategoryPolicy<Application>?
    public var webDomains: Set<WebDomainToken>?
    public var webDomainCategories: ActivityCategoryPolicy<WebDomain>?
}
public struct WebContentSettings {
    public enum FilterPolicy: Equatable {
        case none
        case auto(Set<WebDomain> = [], except: Set<WebDomain> = [])
        case specific(Set<WebDomain>)
        case all(except: Set<WebDomain> = [])
    }
    public var blockedByFilter: FilterPolicy?
}
public struct ApplicationSettings {
    public var blockedApplications: Set<Application>?
    public var denyAppRemoval: Bool?
}

open class ManagedSettingsStore {
    public struct Name: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
    }
    public init() {}
    public init(named name: Name) {}
    public var shield = ShieldSettings()
    public var application = ApplicationSettings()
    public var webContent = WebContentSettings()
    public func clearAllSettings() {}
}

public enum ShieldAction { case primaryButtonPressed, secondaryButtonPressed }
public enum ShieldActionResponse { case none, close, `defer` }

open class ShieldActionDelegate: NSObject {
    public override init() {}
    open func handle(action: ShieldAction, for application: ApplicationToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {}
    open func handle(action: ShieldAction, for webDomain: WebDomainToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {}
    open func handle(action: ShieldAction, for category: ActivityCategoryToken, completionHandler: @escaping (ShieldActionResponse) -> Void) {}
}
