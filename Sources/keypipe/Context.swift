import Foundation

public struct MatchContext: Codable, Equatable {
    public var appBundleId: String?
    public var processName: String?

    public init(appBundleId: String? = nil, processName: String? = nil) {
        self.appBundleId = appBundleId
        self.processName = processName
    }

}
