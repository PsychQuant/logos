import ArgumentParser
import Foundation

extension SwiftTermReplay {
    struct Record: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a command in a PTY and record stdout to a ttyrec file."
        )

        mutating func run() throws {
            throw ValidationError("record not yet implemented (Task 4)")
        }
    }
}
