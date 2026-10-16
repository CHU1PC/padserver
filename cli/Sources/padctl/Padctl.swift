import ArgumentParser

@main
struct Padctl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "padctl",
        abstract: "Manage a PadServer instance from the command line.",
        version: "0.1.0",
        subcommands: [Login.self],
    )
}
