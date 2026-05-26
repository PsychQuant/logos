import ArgumentParser
import Foundation

extension SwiftTermReplay {
    struct Replay: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Replay a ttyrec file through a SwiftTerm view."
        )

        mutating func run() throws {
            throw ValidationError("replay not yet implemented (Task 5)")
        }
    }
}
