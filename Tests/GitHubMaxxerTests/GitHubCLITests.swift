import Foundation
import Testing

@testable import GitHubMaxxer

struct GitHubCLITests {
  @Test func findsGitHubCLIOnTheLoginShellPath() async throws {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let gh = directory.appending(path: "gh")
    let shell = directory.appending(path: "shell")
    try "#!/bin/sh\n".write(to: gh, atomically: true, encoding: .utf8)
    try "#!/bin/sh\necho 'Welcome back'\necho '\(gh.path)'\n"
      .write(to: shell, atomically: true, encoding: .utf8)
    for file in [gh, shell] {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    #expect(await GitHubCLI.executable(shell: shell.path) == gh)
  }

  @Test func signsInThroughGitHubCLIAndShowsTheOneTimeCode() async throws {
    let gh = try script(
      """
      case "$1 $2" in
        "auth status") echo octocat ;;
        "auth refresh")
          printf '! One-time code (0D78-B0CF) copied to clipboard\\n' >&2
          sleep 0.2
          printf 'Authentication complete.\\n' >&2
          sleep 0.2 ;;
        *) echo fresh-credential ;;
      esac
      """)
    defer { try? FileManager.default.removeItem(at: gh.deletingLastPathComponent()) }
    let codes = LockedValues<String>()
    let token = try await GitHubCLI.signIn(as: "octocat", with: gh) { codes.append($0) }
    #expect(token == "fresh-credential")
    #expect(codes.values == ["0D78-B0CF"])
  }

  @Test func signsInAsTheConnectionsAccountThenSwitchesBack() async throws {
    let gh = try script(
      """
      echo "$*" >> "$(dirname "$0")/calls"
      case "$1 $2" in
        "auth status") echo hubot ;;
        "auth token") echo octocat-credential ;;
      esac
      """)
    let directory = gh.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let token = try await GitHubCLI.signIn(as: "octocat", with: gh) { _ in }
    let calls = try String(contentsOf: directory.appending(path: "calls"), encoding: .utf8)
      .split(separator: "\n").filter { !$0.hasPrefix("auth status") }
    #expect(token == "octocat-credential")
    #expect(
      calls == [
        "auth switch --hostname github.com --user octocat",
        "auth refresh --hostname github.com --scopes gist",
        "auth token --hostname github.com",
        "auth switch --hostname github.com --user hubot",
      ])
  }

  @Test func asksToSignInToGitHubCLIWhenTheAccountIsMissing() async throws {
    let gh = try script(
      """
      case "$1 $2" in
        "auth status") echo hubot ;;
        "auth switch") exit 1 ;;
      esac
      """)
    defer { try? FileManager.default.removeItem(at: gh.deletingLastPathComponent()) }
    await #expect {
      try await GitHubCLI.signIn(as: "octocat", with: gh) { _ in }
    } throws: { error in
      error.localizedDescription.contains("isn't signed in as @octocat")
    }
  }

  @Test func cancellingBeforeGitHubCLIStartsNeverStartsTheSignIn() async throws {
    let gh = try script(
      """
      echo "$*" >> "$(dirname "$0")/calls"
      [ "$1 $2" = "auth status" ] && sleep 0.3 && echo octocat
      """)
    let directory = gh.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let signIn = Task { try await GitHubCLI.signIn(as: "octocat", with: gh) { _ in } }
    signIn.cancel()
    await #expect(throws: CancellationError.self) { try await signIn.value }
    let calls = try String(contentsOf: directory.appending(path: "calls"), encoding: .utf8)
    #expect(!calls.contains("auth refresh"))
  }

  @Test func reportsWhyGitHubCLICouldNotSignIn() async throws {
    let gh = try script(
      """
      [ "$1 $2" = "auth status" ] && echo octocat && exit 0
      printf "failed to authenticate via web browser: This 'device_code' has expired.\\n" >&2
      exit 1
      """)
    defer { try? FileManager.default.removeItem(at: gh.deletingLastPathComponent()) }
    await #expect {
      try await GitHubCLI.signIn(as: "octocat", with: gh) { _ in }
    } throws: { error in
      error.localizedDescription.contains("device_code' has expired")
    }
  }

  private func script(_ body: String) throws -> URL {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let gh = directory.appending(path: "gh")
    try "#!/bin/sh\n\(body)\n".write(to: gh, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
    return gh
  }
}
