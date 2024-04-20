import Foundation

/// Atomic<T> class
/// - seealso: https://www.objc.io/blog/2018/12/18/atomic-variables/
public struct Atomic<A> {
    private let queue = DispatchQueue(label: "com.haishinkit.HaishinKit.Atomic", attributes: .concurrent)
    private var _value: A

    public var value: A {
        queue.sync { self._value }
    }

    public init(_ value: A) {
        _value = value
    }

    public mutating func mutate(_ transform: (inout A) -> Void) {
        queue.sync(flags: .barrier) {
            transform(&self._value)
        }
    }
}