import Foundation
import Testing
@testable import RainbarrelCore

@Suite("Terminal output sanitising")
struct TerminalSanitizeTests {
    @Test func plainTextPassesThroughUnchanged() {
        for text in ["", "IMG_0001.jpg", "Urlaub am Meer/Bäder 2019/ÄÖÜ ß.jpg", "日本語/写真.png",
                     "photo 🌅.heic", "with space and \u{A0}no-break space"] {
            #expect(text.sanitizedForTerminal == text)
        }
    }

    @Test func escapeSequencesBecomeVisibleText() {
        let name = "a\u{1B}[31mred\u{1B}[0m\u{1B}]0;title\u{07}.jpg"
        #expect(name.sanitizedForTerminal == "a\\u{1B}[31mred\\u{1B}[0m\\u{1B}]0;title\\u{07}.jpg")
    }

    @Test func c0ControlsNewlineAndTabAreEscaped() {
        #expect("x\u{00}y".sanitizedForTerminal == "x\\u{00}y")
        #expect("x\ty".sanitizedForTerminal == "x\\u{09}y")
        #expect("x\ny".sanitizedForTerminal == "x\\u{0A}y")
        #expect("x\ry".sanitizedForTerminal == "x\\u{0D}y")
        #expect("x\r\ny".sanitizedForTerminal == "x\\u{0D}\\u{0A}y")
        #expect("x\u{1F}y".sanitizedForTerminal == "x\\u{1F}y")
    }

    @Test func delAndC1ControlsAreEscaped() {
        #expect("x\u{7F}y".sanitizedForTerminal == "x\\u{7F}y")
        #expect("x\u{80}y".sanitizedForTerminal == "x\\u{80}y")
        // U+009B is the single-character form of ESC [ (CSI).
        #expect("x\u{9B}31my".sanitizedForTerminal == "x\\u{9B}31my")
        #expect("x\u{9F}y".sanitizedForTerminal == "x\\u{9F}y")
    }

    @Test func boundariesAroundTheControlRangesAreKept() {
        // U+0020 is the first printable ASCII character, U+007E the last, U+00A0 follows C1.
        #expect(" ~\u{A0}".sanitizedForTerminal == " ~\u{A0}")
    }

    @Test func noControlCharacterSurvivesAndTheResultIsStable() {
        let every = String(String.UnicodeScalarView((0...0xA0).compactMap(Unicode.Scalar.init)))
        let clean = every.sanitizedForTerminal
        #expect(!clean.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) })
        #expect(clean.sanitizedForTerminal == clean)
    }
}
