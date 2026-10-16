import PadDomain
import Testing
@testable import padctl

@Test func decodesManifestAndNormalizesRouteValues() throws {
    let manifest = try ManifestLoader.load(
        from: """
            name = "blog"
            root = "dist"

            [[routes]]
            host = "Example.COM"
            path_prefix = "/docs/"
            """)

    #expect(manifest.name.value == "blog")
    #expect(manifest.root == "dist")
    #expect(manifest.routes.count == 1)
    #expect(manifest.routes[0].host.value == "example.com")
    #expect(manifest.routes[0].pathPrefix.value == "/docs")
}

@Test func reportsSyntaxErrorLine() {
    let toml = """
        name = "blog"
        root = "dist"

        [[routes]]
        host = "example.com"
        path_prefix = "/docs"
        broken =
        """

    #expect(loadErrorMessage(from: toml).contains("Line 7"))
}

@Test func reportsTopLevelEmptyRoutesAtItsSourceLine() {
    let toml = """
        # project manifest
        name = "blog"

        # no routes configured
        routes = []
        root = "dist"
        """

    #expect(loadErrorMessage(from: toml).contains("Line 5"))
}

@Test func reportsInvalidRootAtItsSourceLine() {
    let toml = """
        name = "blog"
        root = "../outside"

        [[routes]]
        host = "example.com"
        path_prefix = "/docs"
        """

    #expect(loadErrorMessage(from: toml).contains("Line 2"))
}

@Test func reportsInvalidRouteAtItsSourceLine() {
    let toml = """
        name = "blog"
        root = "dist"

        [[routes]]
        host = "invalid host"
        path_prefix = "/docs"
        """

    #expect(loadErrorMessage(from: toml).contains("Line 5"))
}

@Test func reportsInvalidPathPrefixAtItsSourceLine() {
    let toml = """
        name = "blog"
        root = "dist"

        [[routes]]
        host = "example.com"
        path_prefix = "docs"
        """

    #expect(loadErrorMessage(from: toml).contains("Line 6"))
}

private func loadErrorMessage(from toml: String) -> String {
    do {
        _ = try ManifestLoader.load(from: toml)
        return "Expected manifest loading to fail"
    } catch {
        return String(describing: error)
    }
}
