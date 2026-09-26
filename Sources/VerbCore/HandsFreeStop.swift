import Foundation

/// Consume the entire Space press, even after stopping has changed app state.
public struct HandsFreeStop: Sendable {
    private var consumingSpace = false
    public init() {}
    public struct Decision: Equatable, Sendable {
        public let consume: Bool
        public let finish: Bool
    }
    public mutating func handle(keyCode: Int64, down: Bool, modified: Bool, repeated: Bool, active: Bool) -> Decision {
        guard keyCode == 49 else { return Decision(consume: false, finish: false) }
        if consumingSpace {
            if !down { consumingSpace = false }
            return Decision(consume: true, finish: false)
        }
        guard down, active, !modified, !repeated else { return Decision(consume: false, finish: false) }
        consumingSpace = true
        return Decision(consume: true, finish: true)
    }
}
