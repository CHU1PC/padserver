import ArgumentParser

@main
struct Padctl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "padctl",
        abstract: "Manage a PadServer instance from the command line.",
        version: "0.1.0",
        subcommands: [
            Login.self, Reinstall.self, Start.self, Stop.self, StatusCommand.self, Logs.self, Share.self,
        ],
    )
}
