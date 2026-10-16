import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Turns names from the cloud into safe single path components, and keeps every write inside the
/// target folder. A cloud name is data from outside, so it never reaches the file system unchanged.
public enum FileNameSanitizer {
    public static let maxNameBytes = 255
    /// Suffix of the temporary file a download is written to before it is renamed.
    public static let partSuffix = ".rainbarrel-part"

    /// Characters that cannot be part of a name on common drive formats (`/` and `:` on macOS and
    /// Linux, the rest on NTFS and exFAT, the formats the drive may be reformatted to).
    private static let replaced: Set<Unicode.Scalar> = ["/", ":", "\\", "*", "?", "\"", "<", ">", "|"]

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    /// A safe file or folder name: `/`, `:` and the characters that NTFS or exFAT reject become `_`,
    /// control characters are removed, `.`, `..` and an empty result become `_`, a trailing dot or
    /// space is dropped, and the result fits `maxBytes` UTF-8 bytes with its extension intact.
    public static func sanitize(_ raw: String, maxBytes: Int = maxNameBytes) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if isControl(scalar) { continue }
            scalars.append(replaced.contains(scalar) ? "_" : scalar)
        }
        var name = String(scalars)
        while let first = name.first, first == " " { name.removeFirst() }
        while let last = name.last, last == " " || last == "." { name.removeLast() }
        if name.isEmpty || name == "." || name == ".." { return "_" }
        // A file called ".x.rainbarrel-part" would be taken for a leftover of our own and cleaned up.
        if name.hasPrefix("."), name.hasSuffix(partSuffix) { name = "_" + name }
        return truncated(name, maxBytes: maxBytes)
    }

    /// Cut `name` to at most `maxBytes` UTF-8 bytes, shortening the part before the extension
    /// (the text from the last dot, when it is short) and never splitting a character.
    public static func truncated(_ name: String, maxBytes: Int) -> String {
        guard name.utf8.count > maxBytes else { return name }
        let (stem, ext) = split(name)
        let budget = max(maxBytes - ext.utf8.count, 1)
        var result = ""
        var used = 0
        for character in stem {
            let size = String(character).utf8.count
            if used + size > budget { break }
            result.append(character)
            used += size
        }
        if result.isEmpty { result = "_" }
        return result + ext
    }

    /// Split into the part before the extension and the extension with its dot ("" when there is none).
    /// An extension is the text after the last dot when the dot is not the first character and the
    /// text is at most 16 bytes.
    public static func split(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = String(name[dot...])
        guard ext.utf8.count <= 16, ext.count > 1 else { return (name, "") }
        return (String(name[..<dot]), ext)
    }

    /// `name (2).ext` style variant for a name that is already taken.
    public static func numbered(_ name: String, _ number: Int) -> String {
        guard number > 1 else { return name }
        let (stem, ext) = split(name)
        let suffix = " (\(number))"
        let room = maxNameBytes - ext.utf8.count - suffix.utf8.count
        return truncated(stem, maxBytes: max(room, 1)) + suffix + ext
    }

    /// Name of the temporary file for `finalName`: `.<name>.rainbarrel-part`. Long names are cut
    /// (and tagged with `tag`) so that the temporary name stays within 255 bytes too.
    public static func partName(for finalName: String, tag: String) -> String {
        let plain = "." + finalName + partSuffix
        if plain.utf8.count <= maxNameBytes { return plain }
        let shortened = truncated(finalName, maxBytes: 180)
        return "." + shortened + "." + tag.prefix(12) + partSuffix
    }

    /// True for names that look like our temporary files.
    public static func isPartFile(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(partSuffix) && name.utf8.count > partSuffix.utf8.count + 1
    }
}

public enum PathGuard {
    /// Join `relative` below `root` and make sure the result lies inside `root`, both lexically
    /// (no `..` tricks) and after resolving symbolic links of the part that already exists.
    /// Returns the absolute path.
    public static func resolve(root: String, relative: String) throws -> String {
        let rootPath = standardize(root)
        let full = standardize(rootPath + "/" + relative)
        guard full.hasPrefix(rootPath + "/") else { throw DownloadError.pathEscapesRoot(relative) }

        // The deepest ancestor that exists must resolve to a place inside the resolved root.
        var ancestor = parent(of: full)
        while ancestor.count > rootPath.count, !FileManager.default.fileExists(atPath: ancestor) {
            ancestor = parent(of: ancestor)
        }
        let resolvedRoot = realPath(rootPath) ?? rootPath
        let resolvedAncestor = realPath(ancestor) ?? ancestor
        guard resolvedAncestor == resolvedRoot || resolvedAncestor.hasPrefix(resolvedRoot + "/") else {
            throw DownloadError.pathEscapesRoot(relative)
        }
        return full
    }

    /// Parent folder of an absolute path.
    public static func parent(of path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    private static func standardize(_ path: String) -> String {
        var result = URL(fileURLWithPath: path).standardized.path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
