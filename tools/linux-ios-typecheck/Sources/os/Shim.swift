public struct OSLogInterpolation: StringInterpolationProtocol {
    public init(literalCapacity: Int, interpolationCount: Int) {}
    public mutating func appendLiteral(_ literal: String) {}
    public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> String) {}
    public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> Int) {}
    public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> Int32) {}
    public mutating func appendInterpolation<T: CustomStringConvertible>(_ value: @autoclosure @escaping () -> T) {}
}
public struct OSLogMessage: ExpressibleByStringInterpolation {
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: OSLogInterpolation) {}
}
public struct Logger: Sendable {
    public init(subsystem: String, category: String) {}
    public func info(_ m: OSLogMessage) {}
    public func notice(_ m: OSLogMessage) {}
    public func error(_ m: OSLogMessage) {}
    public func debug(_ m: OSLogMessage) {}
    public func fault(_ m: OSLogMessage) {}
}
import Foundation
extension FileManager { public func containerURL(forSecurityApplicationGroupIdentifier id: String) -> URL? { nil } }
public class RelativeDateTimeFormatter {
    public enum UnitsStyle { case full, short, abbreviated }
    public init() {}
    public var unitsStyle: UnitsStyle = .full
    public func localizedString(for date: Date, relativeTo: Date) -> String { "" }
}
