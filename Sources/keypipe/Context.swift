import Foundation

public struct MatchContext: Codable, Equatable {
    public var appBundleId: String?
    public var processName: String?

    public init(appBundleId: String? = nil, processName: String? = nil) {
        self.appBundleId = appBundleId
        self.processName = processName
    }

    public func matches(_ app: MatchContext?) -> Bool {
        contextMatches(self, app: app)
    }
}

public func contextMatches(_ context: MatchContext?, app: MatchContext?) -> Bool {
    true
}
