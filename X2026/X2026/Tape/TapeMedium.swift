import Foundation

/// The magnetic tape itself: four tracks of 16-bit audio, memory-mapped
/// straight from the cassette's file on disk.
///
/// There is no save and no undo. Whatever the record head writes lands in the
/// file, exactly like oxide on a real tape. The file is sparse, so a blank
/// C-90 costs nothing until you record on it.
///
/// Frames are addressed *logically*, in the direction of tape travel. Flipping
/// the cassette over reverses both the direction and the track order, which
/// is what makes the backwards-guitar trick work.
nonisolated final class TapeMedium: @unchecked Sendable {
    enum Failure: Error {
        case cannotOpen(String, Int32)
        case cannotSize(Int32)
        case cannotMap(Int32)
    }

    static let trackCount = CassetteStandard.trackCount

    /// Number of 4-track frames on the tape.
    let frameCount: Int
    /// True when side B is facing up.
    let flipped: Bool

    private let base: UnsafeMutablePointer<Int16>
    private let byteCount: Int
    private let descriptor: Int32

    /// Opens (creating if needed) the tape file at `url`.
    init(url: URL, frameCount: Int, flipped: Bool = false) throws {
        self.frameCount = frameCount
        self.flipped = flipped
        byteCount = frameCount * Self.trackCount * MemoryLayout<Int16>.stride

        let fd = open(url.path(percentEncoded: false), O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw Failure.cannotOpen(url.path(percentEncoded: false), errno) }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            throw Failure.cannotSize(code)
        }
        if Int(info.st_size) != byteCount {
            // Extending with ftruncate leaves a hole: blank tape takes no disk space.
            guard ftruncate(fd, off_t(byteCount)) == 0 else {
                let code = errno
                close(fd)
                throw Failure.cannotSize(code)
            }
        }

        guard let mapping = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              mapping != MAP_FAILED
        else {
            let code = errno
            close(fd)
            throw Failure.cannotMap(code)
        }
        descriptor = fd
        base = mapping.bindMemory(to: Int16.self, capacity: frameCount * Self.trackCount)
    }

    deinit {
        msync(base, byteCount, MS_SYNC)
        munmap(base, byteCount)
        close(descriptor)
    }

    // MARK: - Real-time access

    @inline(__always)
    private func slot(track: Int, frame: Int) -> Int {
        flipped
            ? (frameCount - 1 - frame) * Self.trackCount + (Self.trackCount - 1 - track)
            : frame * Self.trackCount + track
    }

    /// Magnetisation at `frame` of `track`, in the range -1...1. Zero off the ends.
    @inline(__always)
    func read(track: Int, frame: Int) -> Float {
        guard frame >= 0, frame < frameCount else { return 0 }
        return Float(base[slot(track: track, frame: frame)]) * (1.0 / 32767.0)
    }

    /// Magnetises `frame` of `track`. Writes off the ends land on the leader and vanish.
    @inline(__always)
    func write(track: Int, frame: Int, value: Float) {
        guard frame >= 0, frame < frameCount else { return }
        let clamped = max(-1, min(1, value))
        base[slot(track: track, frame: frame)] = Int16((clamped * 32767).rounded())
    }

    /// Wipes `frame` of `track`. Skips already-blank tape so untouched regions
    /// of the sparse file are never allocated.
    @inline(__always)
    func erase(track: Int, frame: Int) {
        guard frame >= 0, frame < frameCount else { return }
        let index = slot(track: track, frame: frame)
        if base[index] != 0 { base[index] = 0 }
    }

    // MARK: - Housekeeping (never call from the audio thread)

    /// Asks the kernel to page in the stretch of tape the head is about to reach.
    func prefetch(frames range: Range<Int>) {
        let lower = max(0, min(frameCount, range.lowerBound))
        let upper = max(lower, min(frameCount, range.upperBound))
        guard upper > lower else { return }
        let stride = Self.trackCount * MemoryLayout<Int16>.stride
        let (first, last) = flipped
            ? (frameCount - upper, frameCount - lower)
            : (lower, upper)
        let pageSize = Int(getpagesize())
        let start = (first * stride) / pageSize * pageSize
        let length = min(byteCount, last * stride) - start
        guard length > 0 else { return }
        madvise(UnsafeMutableRawPointer(base).advanced(by: start), length, MADV_WILLNEED)
    }

    /// Pushes recorded audio out to disk.
    func flush(wait: Bool = false) {
        msync(base, byteCount, wait ? MS_SYNC : MS_ASYNC)
    }
}
