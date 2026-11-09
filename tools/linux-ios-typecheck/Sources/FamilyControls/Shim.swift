import Foundation
import ManagedSettings
import Combine

public struct FamilyActivitySelection: Codable, Equatable {
    public init() {}
    public init(includeEntireCategory: Bool) {}
    public var applicationTokens: Set<ApplicationToken> = []
    public var categoryTokens: Set<ActivityCategoryToken> = []
    public var webDomainTokens: Set<WebDomainToken> = []
    public var includeEntireCategory: Bool = false
}
public enum AuthorizationStatus: Int, Codable { case notDetermined, denied, approved }
public enum FamilyControlsMember: Int { case child, individual }
public final class AuthorizationCenter: ObservableObject {
    public static let shared = AuthorizationCenter()
    @Published public private(set) var authorizationStatus: AuthorizationStatus = .notDetermined
    public func requestAuthorization(for member: FamilyControlsMember) async throws {}
    public func revokeAuthorization(completionHandler: @escaping (Result<Void, Error>) -> Void) {}
}
