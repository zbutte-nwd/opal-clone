import Foundation
public protocol ObservableObject: AnyObject {}
public final class AnyCancellable { public init() {} }
public struct PublishedPublisher<Output> {
    public func receive(on queue: DispatchQueue) -> PublishedPublisher<Output> { self }
    public func sink(receiveValue: @escaping (Output) -> Void) -> AnyCancellable { AnyCancellable() }
}
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public var projectedValue: PublishedPublisher<Value> { PublishedPublisher() }
}
