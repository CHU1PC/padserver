import Foundation
import Testing

@testable import PadDomain

@Test func projectManifestStoresStaticSiteRootAndRoutes() throws {
    let projectName = try ProjectName("blog")
    let route = Route(
        project: projectName,
        host: try RouteHost("example.com"),
        pathPrefix: try RoutePathPrefix("/"),
        target: .staticSite
    )

    let manifest = try ProjectManifest(name: projectName, root: "dist", routes: [route])

    #expect(manifest.name == projectName)
    #expect(manifest.root == "dist")
    #expect(manifest.routes == [route])
}

@Test(arguments: ["", "../site", "site/../public", "/var/www"])
func projectManifestRejectsInvalidRoot(root: String) throws {
    let projectName = try ProjectName("blog")
    let route = Route(
        project: projectName,
        host: try RouteHost("example.com"),
        pathPrefix: try RoutePathPrefix("/"),
        target: .staticSite
    )

    #expect(throws: ProjectManifest.ValidationError.self) {
        try ProjectManifest(name: projectName, root: root, routes: [route])
    }
}

@Test func projectManifestAcceptsCurrentDirectoryAsRoot() throws {
    let projectName = try ProjectName("blog")
    let route = Route(
        project: projectName,
        host: try RouteHost("example.com"),
        pathPrefix: try RoutePathPrefix("/"),
        target: .staticSite
    )

    #expect(try ProjectManifest(name: projectName, root: ".", routes: [route]).root == ".")
}

@Test func projectManifestRejectsEmptyRoutes() throws {
    #expect(throws: ProjectManifest.ValidationError.self) {
        try ProjectManifest(name: ProjectName("blog"), root: "dist", routes: [])
    }
}

@Test func projectManifestRejectsRouteForAnotherProject() throws {
    let route = Route(
        project: try ProjectName("other"),
        host: try RouteHost("example.com"),
        pathPrefix: try RoutePathPrefix("/"),
        target: .staticSite
    )

    #expect(throws: ProjectManifest.ValidationError.self) {
        try ProjectManifest(name: ProjectName("blog"), root: "dist", routes: [route])
    }
}

@Test func projectManifestRejectsContainerRoute() throws {
    let route = Route(
        project: try ProjectName("blog"),
        host: try RouteHost("example.com"),
        pathPrefix: try RoutePathPrefix("/"),
        target: .container(try ContainerRouteTarget(service: "web", port: 8080))
    )

    #expect(throws: ProjectManifest.ValidationError.self) {
        try ProjectManifest(name: ProjectName("blog"), root: "dist", routes: [route])
    }
}

@Test func projectManifestCodableRoundTripsValidManifest() throws {
    let projectName = try ProjectName("blog")
    let manifest = try ProjectManifest(
        name: projectName,
        root: "dist",
        routes: [
            Route(
                project: projectName,
                host: try RouteHost("example.com"),
                pathPrefix: try RoutePathPrefix("/"),
                target: .staticSite
            )
        ]
    )
    let data = try JSONEncoder().encode(manifest)

    #expect(try JSONDecoder().decode(ProjectManifest.self, from: data) == manifest)
}

@Test func projectManifestCodableUsesExternalRouteFormat() throws {
    let manifestJSON = Data(
        "{\"name\":\"blog\",\"root\":\"dist\",\"routes\":[{\"host\":\"example.com\",\"path_prefix\":\"/docs\"}]}".utf8
    )
    let expectedManifest = try ProjectManifest(
        name: ProjectName("blog"),
        root: "dist",
        routes: [
            Route(
                project: ProjectName("blog"),
                host: try RouteHost("example.com"),
                pathPrefix: try RoutePathPrefix("/docs"),
                target: .staticSite
            )
        ]
    )

    let decodedManifest = try JSONDecoder().decode(ProjectManifest.self, from: manifestJSON)
    let encodedManifest = try JSONEncoder().encode(decodedManifest)
    let expectedExternalManifest = try JSONDecoder().decode(
        ProjectManifestExternalFormat.self, from: manifestJSON)
    let encodedExternalManifest = try JSONDecoder().decode(
        ProjectManifestExternalFormat.self, from: encodedManifest)

    #expect(decodedManifest == expectedManifest)
    #expect(encodedExternalManifest == expectedExternalManifest)
}

@Test func projectManifestRejectsInvalidDecodedManifest() {
    let emptyRoutes = Data("{\"name\":\"blog\",\"root\":\"dist\",\"routes\":[]}".utf8)
    let invalidRoot = Data("{\"name\":\"blog\",\"root\":\"../site\",\"routes\":[]}".utf8)

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ProjectManifest.self, from: emptyRoutes)
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ProjectManifest.self, from: invalidRoot)
    }
}

private struct ProjectManifestExternalFormat: Codable, Equatable {
    let name: String
    let root: String
    let routes: [ProjectManifestExternalRouteFormat]
}

private struct ProjectManifestExternalRouteFormat: Codable, Equatable {
    let host: String
    let pathPrefix: String

    private enum CodingKeys: String, CodingKey {
        case host
        case pathPrefix = "path_prefix"
    }
}
