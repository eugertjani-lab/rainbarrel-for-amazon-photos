import Foundation
import RainbarrelCore

typealias Format = DisplayFormat

/// Messages can contain drive file names, so control characters are shown as escapes.
func printError(_ message: String) {
    FileHandle.standardError.write(Data((message.sanitizedForTerminal + "\n").utf8))
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description.sanitizedForTerminal }
}
