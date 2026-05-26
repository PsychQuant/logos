import ArgumentParser
import Foundation

@main
struct SwiftTermReplay: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swiftterm-replay",
        abstract: "Record + replay PTY streams through SwiftTerm for renderer testing.",
        subcommands: [Record.self, Replay.self]
    )
}
