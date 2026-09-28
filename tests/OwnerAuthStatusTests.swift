import Foundation

@main struct OwnerAuthStatusTests {
    static func main() throws {
        let rows = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String]
        let expected: Bool? = CommandLine.arguments[1] == "unknown" ? nil : CommandLine.arguments[1] == "yes"
        precondition(Snapshot.parse(rows[1]).signedIn["Work"]?["codex"] == expected)
        precondition(Snapshot.setupAuthentication(status: 0, output: rows[0])?["codex"] == expected)
        precondition(Snapshot.setupAuthentication(status: 1, output: rows[0]) == nil)
        precondition(Snapshot.setupAuthentication(status: 0, output: "codex\tunrecognized")?["codex"] == nil)
    }
}
