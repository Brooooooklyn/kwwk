import Foundation
import KWWKAgent

func cliShellPath(environment: [String: String]) -> String {
    guard let shell = environment["SHELL"],
          shell.hasPrefix("/"),
          FileManager.default.isExecutableFile(atPath: shell) else {
        return kwwkDefaultShellPath
    }
    return shell
}

/// The user's home directory. iOS Foundation has no
/// `homeDirectoryForCurrentUser`; `NSHomeDirectory()` is how the rest of the
/// package reaches the same path there (`SessionStore.defaultDirectory`).
func cliHomeDirectory() -> String {
    #if targetEnvironment(macCatalyst) || os(iOS)
    return NSHomeDirectory()
    #else
    return FileManager.default.homeDirectoryForCurrentUser.path
    #endif
}
