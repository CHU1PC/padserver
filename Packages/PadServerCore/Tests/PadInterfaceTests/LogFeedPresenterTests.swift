import Foundation
import Testing

@testable import PadDomain
@testable import PadInterface

private let fixedEpochSeconds = 1_700_000_000.0
private let fixedTimestamp = Date(timeIntervalSince1970: fixedEpochSeconds)

private func entry(_ message: String, level: LogLevel = .info) -> LogEntry {
    LogEntry(timestamp: fixedTimestamp, source: "web", level: level, message: message)
}

@Test func logFeedStartsEmpty() {
    #expect(LogFeedPresenter().rows.isEmpty)
}

@Test func logFeedAppendsEntriesInArrivalOrder() {
    var presenter = LogFeedPresenter()
    presenter.append(entry("first"))
    presenter.append(entry("second", level: .error))

    #expect(presenter.rows.map(\.message) == ["first", "second"])
    #expect(presenter.rows.map(\.level) == [.info, .error])
    #expect(presenter.rows[0].source == "web")
    #expect(presenter.rows[0].timestamp == fixedTimestamp)
}

@Test func logFeedGivesEveryRowAUniqueID() {
    var presenter = LogFeedPresenter()
    presenter.append(entry("same"))
    presenter.append(entry("same"))

    #expect(Set(presenter.rows.map(\.id)).count == 2)
}

@Test func logFeedKeepsOnlyTheNewestRows() {
    var presenter = LogFeedPresenter()
    let total = LogFeedPresenter.rowLimit + 5
    for index in 0..<total {
        presenter.append(entry("message \(index)"))
    }

    #expect(presenter.rows.count == LogFeedPresenter.rowLimit)
    #expect(presenter.rows.first?.message == "message 5")
    #expect(presenter.rows.last?.message == "message \(total - 1)")
}

private func projectEntry(_ message: String, project: String?) -> LogEntry {
    LogEntry(timestamp: fixedTimestamp, source: "serving", level: .info, message: message, project: project)
}

@Test func logFeedFilteredByProjectKeepsOnlyThatProjectsEntries() {
    var presenter = LogFeedPresenter(project: "blog")
    presenter.append(projectEntry("blog 1", project: "blog"))
    presenter.append(projectEntry("shop 1", project: "shop"))
    presenter.append(projectEntry("unnamed", project: nil))
    presenter.append(projectEntry("blog 2", project: "blog"))

    #expect(presenter.rows.map(\.message) == ["blog 1", "blog 2"])
}

@Test func logFeedWithoutFilterKeepsEveryEntryAndExposesProjectName() {
    var presenter = LogFeedPresenter()
    presenter.append(projectEntry("blog 1", project: "blog"))
    presenter.append(projectEntry("unnamed", project: nil))

    #expect(presenter.rows.map(\.project) == ["blog", nil])
}
