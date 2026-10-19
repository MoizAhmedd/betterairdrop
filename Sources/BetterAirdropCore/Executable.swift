import Foundation

public enum Executable {
    /// This process's executable, absolute and with symlinks resolved (the brew link in
    /// /opt/homebrew/bin points into BetterAirdrop.app/Contents/Helpers). Not `CommandLine.arguments[0]`:
    /// run through PATH, that's just "betterairdrop", which resolves against the current directory.
    public static var url: URL {
        let raw = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return raw.resolvingSymlinksInPath()
    }
}
