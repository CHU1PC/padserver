import Foundation
import PadApplication
import PadDomain

public actor FileReleaseStore {
    public enum Failure: Error {
        case invalidRelease
        case releaseNotFound
    }

    private struct Record: Codable, Sendable {
        let release: Release
        let manifest: ReleaseManifest
    }

    private let fileURL: URL
    private let writeData: @Sendable (Data, URL) throws -> Void

    public init(directory: URL) {
        self.init(
            directory: directory,
            writeData: { data, url in
                try data.write(to: url, options: .atomic)
            })
    }

    init(directory: URL, writeData: @escaping @Sendable (Data, URL) throws -> Void) {
        fileURL = directory.appendingPathComponent("releases.json")
        self.writeData = writeData
    }

    public func listReleases() throws -> [Release] {
        try readRecords().map(\.release)
    }

    public func releaseManifest(for releaseID: ReleaseID) throws -> ReleaseManifest {
        guard let record = try readRecords().first(where: { $0.release.id == releaseID }) else {
            throw Failure.releaseNotFound
        }
        return record.manifest
    }

    public func saveRelease(_ release: Release, manifest: ReleaseManifest) throws {
        var records = try readRecords()
        guard release.state == .preparing, !records.contains(where: { $0.release.id == release.id }) else {
            throw Failure.invalidRelease
        }
        records.append(Record(release: release, manifest: manifest))
        try saveRecords(records)
    }

    public func activateRelease(_ releaseID: ReleaseID, for project: ProjectName) throws {
        let records = try readRecords()
        guard let target = records.first(where: { $0.release.id == releaseID }),
            target.release.project == project, target.release.state == .preparing
        else {
            throw Failure.invalidRelease
        }
        // project と blob の存在確認は ProjectStorage の組み立て側が行います。
        let updated = records.map { record in
            let release = record.release
            if release.id == releaseID {
                return Record(
                    release: Release(id: release.id, project: project, state: .active),
                    manifest: record.manifest)
            }
            if release.project == project, release.state == .active {
                return Record(
                    release: Release(id: release.id, project: project, state: .retired),
                    manifest: record.manifest)
            }
            return record
        }
        // 両方の状態を一つの snapshot に入れ、一度の原子的置換で公開します。
        try saveRecords(updated)
    }

    public func removeRelease(_ releaseID: ReleaseID) throws {
        var records = try readRecords()
        guard records.contains(where: { $0.release.id == releaseID }) else { return }
        records.removeAll { $0.release.id == releaseID }
        try saveRecords(records)
    }

    private func readRecords() throws -> [Record] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return try JSONDecoder().decode([Record].self, from: data)
    }

    private func saveRecords(_ records: [Record]) throws {
        let data = try JSONEncoder().encode(records)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try writeData(data, fileURL)
    }
}
