import Foundation
import PadGuest
import Testing

@Test func guestDiskCreatesSparseRawFileOutsideBackup() throws {
    let applicationSupportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("padguest-disk-tests-\(UUID())", isDirectory: true)
    defer {
        do {
            try FileManager.default.removeItem(at: applicationSupportURL)
        } catch {
            Issue.record("Could not remove the temporary guest disk test directory.")
        }
    }
    let disk = GuestDisk(applicationSupportURL: applicationSupportURL)
    let sizeBytes: UInt64 = 64 * 1024 * 1024

    let diskURL = try disk.createIfNeeded(sizeBytes: sizeBytes)

    #expect(diskURL.path == applicationSupportURL.appendingPathComponent("PadServer/GuestDisk/guest.raw").path)
    let attributes = try FileManager.default.attributesOfItem(atPath: diskURL.path)
    #expect(attributes[.size] as? UInt64 == sizeBytes)
    let directoryURL = diskURL.deletingLastPathComponent()
    let values = try directoryURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
    let allocatedSize = try #require(
        diskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize)
    #expect(UInt64(allocatedSize) < sizeBytes)
}

@Test func guestDiskDoesNotReplaceExistingFileOnSecondLaunch() throws {
    let applicationSupportURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("padguest-disk-tests-\(UUID())", isDirectory: true)
    defer {
        do {
            try FileManager.default.removeItem(at: applicationSupportURL)
        } catch {
            Issue.record("Could not remove the temporary guest disk test directory.")
        }
    }
    let disk = GuestDisk(applicationSupportURL: applicationSupportURL)
    let originalSize: UInt64 = 8 * 1024 * 1024
    let diskURL = try disk.createIfNeeded(sizeBytes: originalSize)
    let file = try FileHandle(forWritingTo: diskURL)
    try file.write(contentsOf: Data([0xA5]))
    try file.close()

    let secondURL = try disk.createIfNeeded(sizeBytes: originalSize * 2)

    #expect(secondURL == diskURL)
    let contents = try FileHandle(forReadingFrom: secondURL)
    #expect(try contents.read(upToCount: 1) == Data([0xA5]))
    try contents.close()
    let attributes = try FileManager.default.attributesOfItem(atPath: secondURL.path)
    #expect(attributes[.size] as? UInt64 == originalSize)
}
