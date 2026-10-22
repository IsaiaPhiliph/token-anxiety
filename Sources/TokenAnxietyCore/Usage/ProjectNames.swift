import Foundation

/// Turns a working directory into the name of its project: the git repository it
/// belongs to, so every worktree and subfolder of one repository counts as one project.
///
/// Folders macOS protects (Documents, Desktop, iCloud Drive, other volumes…) are never
/// looked into: touching them makes macOS ask the user for access and blocks until they
/// answer. There the name comes from the path alone, with the known worktree layouts folded.
public final class ProjectNames: @unchecked Sendable {
    private let home: String
    private let cache = Locked<[String: String]>([:])
    private let fileExists: @Sendable (String) -> Bool
    private let readFile: @Sendable (String) -> String?
    private let isDirectory: @Sendable (String) -> Bool

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                isDirectory: @escaping @Sendable (String) -> Bool = { path in
                    var directory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
                },
                readFile: @escaping @Sendable (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) {
        self.home = (home as NSString).standardizingPath
        self.fileExists = fileExists
        self.isDirectory = isDirectory
        self.readFile = readFile
    }

    public func name(for directory: String?) -> String {
        guard let directory, !directory.isEmpty else { return Self.unknown }
        if let cached = cache.withLock({ $0[directory] }) { return cached }
        let name = resolve(directory)
        cache.withLock { $0[directory] = name }
        return name
    }

    public static let unknown = "–"

    private func resolve(_ directory: String) -> String {
        let path = (directory as NSString).standardizingPath
        if !isProtected(path), let root = repositoryRoot(containing: path) { return label(root) }
        // The folder is gone (a removed worktree): fold the known worktree layouts by hand.
        return label(Self.foldWorktree(path))
    }

    /// Walks up to the folder that holds `.git`. In a worktree `.git` is a file that
    /// points into the main repository ("gitdir: /repo/.git/worktrees/name").
    private func repositoryRoot(containing path: String) -> String? {
        var current = path
        while current != "/" && !current.isEmpty && current != home {
            let git = (current as NSString).appendingPathComponent(".git")
            if isDirectory(git) { return current }
            if fileExists(git) {
                if let text = readFile(git), let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") {
                    let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    if let range = target.range(of: "/.git/worktrees/") { return String(target[..<range.lowerBound]) }
                    if target.hasSuffix("/.git") { return String(target.dropLast(5)) }
                }
                return current
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Places where reading a file needs the user's permission (TCC).
    func isProtected(_ path: String) -> Bool {
        let protected = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music",
                         "Library/Mobile Documents", "Library/CloudStorage"].map { home + "/" + $0 }
        return path.hasPrefix("/Volumes/") || protected.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// `/repo/.claude/worktrees/x/sub` → `/repo`; `~/.codex/worktrees/abcd/repo/sub` → `…/repo`.
    static func foldWorktree(_ path: String) -> String {
        if let range = path.range(of: "/.claude/worktrees/") { return String(path[..<range.lowerBound]) }
        if let range = path.range(of: "/.codex/worktrees/") {
            let parts = path[range.upperBound...].split(separator: "/")
            if parts.count >= 2 { return String(path[..<range.upperBound]) + parts[0] + "/" + parts[1] }
        }
        return path
    }

    private func label(_ path: String) -> String {
        if path == home { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? Self.unknown : name
    }
}
