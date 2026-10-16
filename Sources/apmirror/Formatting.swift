import Foundation
import MirrorCore

typealias Format = DisplayFormat

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
