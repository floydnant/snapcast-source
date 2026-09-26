import Foundation

/// Fixed-capacity FIFO of whole PCM frames between the audio thread and the network.
///
/// Overflow drops the OLDEST audio. When the network stalls, what the listener wants
/// on recovery is the live signal, not a backlog that would add permanent latency;
/// snapserver's buffer is the latency budget, and this must not quietly add to it.
///
/// Every write and every drop is a whole number of frames, so a stall can never leave
/// the stream misaligned by a byte (which would come out as full-scale noise).
public final class ByteRing {
    private let storage: UnsafeMutablePointer<UInt8>
    public let capacity: Int
    private let frameBytes: Int
    private var head = 0
    private var count = 0
    private var lock = os_unfair_lock()
    public private(set) var droppedBytes = 0

    public init(capacity: Int, frameBytes: Int = RelayProtocol.bytesPerFrame) {
        precondition(capacity % frameBytes == 0, "capacity must be whole frames")
        self.capacity = capacity
        self.frameBytes = frameBytes
        storage = .allocate(capacity: capacity)
    }

    deinit { storage.deallocate() }

    public var available: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return count
    }

    /// Safe to call from a realtime thread: no allocation, one uncontended-in-practice
    /// unfair lock, bounded memcpy.
    public func write(_ src: UnsafeRawPointer, _ length: Int) {
        precondition(length % frameBytes == 0, "writes must be whole frames")
        var src = src.assumingMemoryBound(to: UInt8.self)
        var length = length
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }

        if length > capacity {
            // Keep only the newest `capacity` bytes of an oversized write.
            let skip = length - capacity
            droppedBytes += skip
            src += skip
            length = capacity
        }
        let overflow = count + length - capacity
        if overflow > 0 {
            droppedBytes += overflow
            head = (head + overflow) % capacity
            count -= overflow
        }
        let tail = (head + count) % capacity
        let first = min(length, capacity - tail)
        memcpy(storage + tail, src, first)
        if first < length { memcpy(storage, src + first, length - first) }
        count += length
    }

    /// Removes up to `maxLength` bytes (rounded down to whole frames).
    public func read(maxLength: Int) -> Data? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let n = min(count, maxLength) / frameBytes * frameBytes
        guard n > 0 else { return nil }
        var out = Data(count: n)
        out.withUnsafeMutableBytes { dst in
            let d = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let first = min(n, capacity - head)
            memcpy(d, storage + head, first)
            if first < n { memcpy(d + first, storage, n - first) }
        }
        head = (head + n) % capacity
        count -= n
        return out
    }

    public func reset() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        head = 0
        count = 0
    }
}
