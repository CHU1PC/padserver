import Foundation
import PadDomain
import Testing

@testable import PadInterface

private func servingEntry(at seconds: TimeInterval, path: String = "/", status: Int = 200) -> LogEntry {
    LogEntry(
        timestamp: Date(timeIntervalSince1970: seconds), source: "serving", level: .info,
        message: "host=example.com path=\(path) status=\(status) duration_ms=12.5")
}

@Test func receiveParsesServingEntryIntoRow() {
    var presenter = RequestFeedPresenter()
    presenter.receive(servingEntry(at: 10, path: "/docs/page", status: 404))

    #expect(presenter.rows.count == 1)
    #expect(presenter.rows.first?.host == "example.com")
    #expect(presenter.rows.first?.path == "/docs/page")
    #expect(presenter.rows.first?.status == 404)
    #expect(presenter.rows.first?.durationMilliseconds == 12.5)
    #expect(presenter.rows.first?.timestamp == Date(timeIntervalSince1970: 10))
}

@Test func rowIsFailureOnlyForClientAndServerErrors() {
    var presenter = RequestFeedPresenter()
    presenter.receive(servingEntry(at: 1, status: 399))
    presenter.receive(servingEntry(at: 2, status: 400))
    presenter.receive(servingEntry(at: 3, status: 503))

    #expect(presenter.rows.map(\.isFailure) == [true, true, false])
}

@Test func rowsAreNewestFirst() {
    var presenter = RequestFeedPresenter()
    presenter.receive(servingEntry(at: 10, path: "/a"))
    presenter.receive(servingEntry(at: 30, path: "/c"))
    presenter.receive(servingEntry(at: 20, path: "/b"))

    #expect(presenter.rows.map(\.path) == ["/c", "/b", "/a"])
}

@Test func receiveKeepsDuplicateRequestsAsSeparateRows() {
    var presenter = RequestFeedPresenter()
    presenter.receive(servingEntry(at: 10))
    presenter.receive(servingEntry(at: 10))

    #expect(presenter.rows.count == 2)
    #expect(Set(presenter.rows.map(\.id)).count == 2)
}

@Test func receiveIgnoresEntriesFromOtherSources() {
    var presenter = RequestFeedPresenter()
    presenter.receive(LogEntry(timestamp: Date(), source: "guest", level: .info, message: "booted"))

    #expect(presenter.rows.isEmpty)
}

@Test func receiveIgnoresUnparsableServingMessages() {
    var presenter = RequestFeedPresenter()
    let messages = [
        "",
        "host=example.com path=/ status=abc duration_ms=1.0",
        "host=example.com path=/ status=200 duration_ms=fast",
        "host=example.com path=/ status=200",
        "path=/ host=example.com status=200 duration_ms=1.0",
    ]
    for message in messages {
        presenter.receive(LogEntry(timestamp: Date(), source: "serving", level: .info, message: message))
    }

    #expect(presenter.rows.isEmpty)
}

@Test func rowsAreLimitedToMostRecent() {
    var presenter = RequestFeedPresenter()
    for index in 0..<150 {
        presenter.receive(servingEntry(at: TimeInterval(index), path: "/\(index)"))
    }

    #expect(presenter.rows.count == 100)
    #expect(presenter.rows.first?.path == "/149")
    #expect(presenter.rows.last?.path == "/50")
}
