import Foundation
import Synchronization

/// Hands the newest copy of a small value from one thread to another without
/// either of them ever waiting.
///
/// One writer, any number of readers. The writer bumps a sequence number
/// before and after it writes; a reader that sees the number change simply
/// tries again. Used both ways across the audio thread: knob positions going
/// in, meter levels and tape position coming out.
///
/// `Value` must be plain data — no references, nothing with a destructor.
nonisolated final class Mailbox<Value>: @unchecked Sendable {
    private let sequence = Atomic<UInt64>(0)
    private let storage: UnsafeMutablePointer<Value>

    init(_ initial: Value) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: initial)
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    /// Publishes a new value. Only ever call this from one thread.
    func post(_ value: Value) {
        sequence.wrappingAdd(1, ordering: .sequentiallyConsistent)
        storage.pointee = value
        sequence.wrappingAdd(1, ordering: .sequentiallyConsistent)
    }

    /// The latest value, or nil in the unlikely case that every attempt
    /// collided with a write.
    func read(attempts: Int = 6) -> Value? {
        for _ in 0..<attempts {
            let before = sequence.load(ordering: .sequentiallyConsistent)
            if before & 1 == 1 { continue }
            let copy = storage.pointee
            if sequence.load(ordering: .sequentiallyConsistent) == before { return copy }
        }
        return nil
    }
}

/// A wait-free queue for one producer and one consumer.
nonisolated final class EventQueue<Element>: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<Element>
    private let mask: Int
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    /// `capacity` is rounded up to a power of two.
    init(capacity: Int, filler: Element) {
        var size = 2
        while size < capacity { size <<= 1 }
        mask = size - 1
        buffer = .allocate(capacity: size)
        buffer.initialize(repeating: filler, count: size)
    }

    deinit {
        buffer.deinitialize(count: mask + 1)
        buffer.deallocate()
    }

    /// Returns false if the queue is full and the element was dropped.
    @discardableResult
    func push(_ element: Element) -> Bool {
        let write = tail.load(ordering: .relaxed)
        let read = head.load(ordering: .acquiring)
        guard write - read <= mask else { return false }
        buffer[write & mask] = element
        tail.store(write + 1, ordering: .releasing)
        return true
    }

    func pop() -> Element? {
        let read = head.load(ordering: .relaxed)
        let write = tail.load(ordering: .acquiring)
        guard read < write else { return nil }
        let element = buffer[read & mask]
        head.store(read + 1, ordering: .releasing)
        return element
    }
}
