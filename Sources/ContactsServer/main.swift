import Darwin
import Foundation
import Logging

import struct os.OSAllocatedUnfairLock

let usage = """
  Usage: apple-contacts-server

  Serves /graphql, /mcp, and /metrics on the sockets launchd hands it. Start it from a
  LaunchAgent plist; run directly, it exits.

  Socket labels: \(SocketLabel.allCases.map(\.rawValue).joined(separator: ", "))
  Environment variables:
  \(ConfigVariable.allCases.map { "  \($0.rawValue)" }.joined(separator: "\n"))

  See https://github.com/josh/apple-contacts-server/blob/main/docs/SERVER.md
  """

// Reports a fatal error on stderr and exits.
func fail(_ error: Error) -> Never {
  FileHandle.standardError.write(Data("error: \(error)\n".utf8))
  exit(1)
}

// launchd starts the server and owns its sockets; CONTACTS_* environment variables in
// the plist configure it. The only arguments are --help and the developer dumps of the
// API docs.
Task.detached {
  do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["-h"] {
      print(usage)
    } else if arguments == ["--dump-mcp-tools"] {
      print(try mcpToolsJSON())
    } else if arguments == ["--dump-graphql-schema"] {
      print(try graphQLSchemaSDL())
    } else if !arguments.isEmpty {
      throw ServerError.internalError(
        "Use --help; the server is configured by CONTACTS_* variables in its launchd plist")
    } else {
      let config = try ServerConfig(environment: ProcessInfo.processInfo.environment)
      let sockets = try activateLaunchdSockets()
      if sockets.contains(where: { $0.label == .tailscaleServe }),
        config.tailscaleAppCapability == nil
      {
        throw ServerError.internalError(
          "The TailscaleServe socket requires \(ConfigVariable.tailscaleAppCapability.rawValue)")
      }
      serverLogger.logLevel = config.logLevel
      startMainActorWatchdog()
      // With access already granted there is nothing to request. Until the user answers,
      // the APIs answer NOT_AUTHORIZED rather than wait.
      let requestAccess = config.requestAccess && !hasAccess
      let authorizing = OSAllocatedUnfairLock(initialState: requestAccess)
      if requestAccess {
        Task {
          // A refusal leaves the server running: exiting would only drop connections and
          // have launchd start it again into the same refusal.
          do { try await authorizeContacts() } catch {
            serverLogger.error(
              "Contacts access was not granted",
              metadata: ["status": "\(statusName())", "reason": "\(error)"])
          }
          authorizing.withLock { $0 = false }
        }
      }
      observeContactChanges()
      try await serve(
        sockets: sockets, config: config, authorizing: { authorizing.withLock { $0 } })
    }

    exit(0)
  } catch {
    fail(error)
  }

}
// The main thread runs its run loop, which drains the main queue for the main actor. A
// run loop rather than dispatchMain: AppleScript waits for each Apple-event reply on the
// main run loop, and with the main thread parked in dispatchMain some replies are never
// seen.
CFRunLoopRun()
