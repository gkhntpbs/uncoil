import XCTest
@testable import Uncoil

/// `fd_set` is a C bitfield Uncoil writes by hand, and the descriptor it is
/// handed is whatever the kernel gave out — a number that climbs as a
/// long-running process opens and closes files. Every bit in the set has to be
/// reachable, because the one that is not is the one an app crashes on hours
/// after it started.
final class FDSetTests: XCTestCase {

    /// Reads a bit back out, the way `FD_ISSET` would.
    private func isSet(_ fd: Int32, _ set: inout fd_set) -> Bool {
        withUnsafeBytes(of: &set.fds_bits) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Int32.self) else {
                return false
            }
            let word = UInt32(bitPattern: base[Int(fd) / 32])
            return word & (UInt32(1) << UInt32(Int(fd) % 32)) != 0
        }
    }

    /// The crash this file exists for: bit 31 of a word is the sign bit, and
    /// converting `1 << 31` into `Int32` traps instead of wrapping.
    func testTheSignBitOfAWordCanBeSet() {
        var set = fd_set()
        fdZero(&set)
        fdSet(31, &set)
        XCTAssertTrue(isSet(31, &set))
    }

    func testEveryDescriptorInTheSetIsReachable() {
        for fd in Int32(0)..<Int32(FD_SETSIZE) {
            var set = fd_set()
            fdZero(&set)
            fdSet(fd, &set)
            XCTAssertTrue(isSet(fd, &set), "fd \(fd) did not survive the round trip")
        }
    }

    func testSettingOneDescriptorLeavesTheOthersAlone() {
        var set = fd_set()
        fdZero(&set)
        fdSet(31, &set)
        XCTAssertFalse(isSet(30, &set))
        XCTAssertFalse(isSet(32, &set))
        XCTAssertFalse(isSet(63, &set))
    }

    func testDescriptorsOutsideTheSetAreRefusedRatherThanWritten() {
        var set = fd_set()
        fdZero(&set)
        fdSet(Int32(FD_SETSIZE), &set)
        fdSet(Int32(FD_SETSIZE) + 700, &set)
        fdSet(-1, &set)

        // Nothing was written anywhere in the set: an out-of-range descriptor
        // has no bit to set, and inventing one would land outside the struct.
        var touched = false
        withUnsafeBytes(of: &set.fds_bits) { raw in
            touched = raw.contains { $0 != 0 }
        }
        XCTAssertFalse(touched)
    }

    func testZeroClearsASetThatWasWrittenTo() {
        var set = fd_set()
        fdZero(&set)
        for fd in Int32(0)..<Int32(64) { fdSet(fd, &set) }
        fdZero(&set)
        for fd in Int32(0)..<Int32(64) { XCTAssertFalse(isSet(fd, &set)) }
    }
}
