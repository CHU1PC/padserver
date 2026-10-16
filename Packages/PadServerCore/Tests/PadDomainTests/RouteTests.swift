import Foundation
import Testing

@testable import PadDomain

@Test func routeNormalizesHostAndPathPrefix() throws {
    let project = try ProjectName("my-site")
    let first = Route(
        project: project,
        host: try RouteHost("EXAMPLE.COM"),
        pathPrefix: try RoutePathPrefix("/blog/"),
        target: .staticSite
    )
    let second = Route(
        project: project,
        host: try RouteHost("example.com"),
        pathPrefix: try RoutePathPrefix("/blog"),
        target: .staticSite
    )

    #expect(first == second)
    #expect(first.host.value == "example.com")
    #expect(first.pathPrefix.value == "/blog")
}

@Test func rootPathRemainsRoot() throws {
    #expect(try RoutePathPrefix("/").value == "/")
}

@Test(arguments: ["", "example.com/path", "https://example.com", "bad host", "-example.com", "example-.com"])
func routeHostRejectsInvalidValues(value: String) {
    #expect(throws: RouteHost.ValidationError.self) {
        try RouteHost(value)
    }
}

@Test(arguments: ["", "blog", "/blog?x=1", "/blog#part"])
func routePathPrefixRejectsInvalidValues(value: String) {
    #expect(throws: RoutePathPrefix.ValidationError.self) {
        try RoutePathPrefix(value)
    }
}

@Test func routeTargetCarriesContainerServiceAndPort() throws {
    let container = try ContainerRouteTarget(service: "web", port: 8080)
    let target = RouteTarget.container(container)
    let route = Route(
        project: try ProjectName("my-app"),
        host: try RouteHost("app.example.com"),
        pathPrefix: try RoutePathPrefix("/"),
        target: target
    )

    #expect(route.target == .container(container))
}

@Test(arguments: ["", "bad service", "web/path"])
func containerRouteTargetRejectsInvalidService(service: String) {
    #expect(throws: ContainerRouteTarget.ValidationError.self) {
        try ContainerRouteTarget(service: service, port: 8080)
    }
}

@Test func containerRouteTargetRejectsPortZero() {
    #expect(throws: ContainerRouteTarget.ValidationError.self) {
        try ContainerRouteTarget(service: "web", port: 0)
    }
}

@Test func containerRouteTargetRejectsInvalidDecodedValues() {
    for json in ["{\"service\":\"\",\"port\":8080}", "{\"service\":\"web\",\"port\":0}"] {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ContainerRouteTarget.self, from: Data(json.utf8))
        }
    }
}

@Test func routeHostRespectsDNSLengthBoundary() throws {
    let longestHost = [String(repeating: "a", count: 63), String(repeating: "b", count: 63),
                       String(repeating: "c", count: 63), String(repeating: "d", count: 61)].joined(separator: ".")
    #expect(longestHost.utf8.count == 253)
    #expect(try RouteHost(longestHost).value == longestHost)

    let tooLongHost = longestHost + "dd"
    #expect(throws: RouteHost.ValidationError.self) {
        try RouteHost(tooLongHost)
    }
}

@Test func routeRejectsInvalidDecodedHost() {
    let data = Data("\"bad host\"".utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(RouteHost.self, from: data)
    }
}
