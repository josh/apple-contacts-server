# Server

Requires macOS 14+. Serves `POST /graphql`, `POST /mcp`, and `GET /metrics`.
`swift build -c release` produces `.build/release/apple-contacts-server`.

## Setup

launchd owns the sockets and starts the server on connection, including after
exit. Direct launch is refused. Use absolute executable/socket paths (`~` is not
expanded); Unix socket paths have a 104-byte limit. Adjust this LaunchAgent to
the installed binary and user, and create its socket directory:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.github.josh.apple-contacts-server</string>
  <key>ProgramArguments</key>
  <array><string>/usr/local/bin/apple-contacts-server</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>CONTACTS_REQUEST_ACCESS</key><string>1</string>
  </dict>
  <key>Sockets</key><dict>
    <key>Listeners</key><dict>
      <key>SockPathName</key><string>/Users/you/Library/Application Support/apple-contacts-server/server.sock</string>
      <key>SockPathMode</key><integer>384</integer>
    </dict>
  </dict>
</dict></plist>
```

Save as `~/Library/LaunchAgents/com.github.josh.apple-contacts-server.plist`, then load:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.github.josh.apple-contacts-server.plist
```

The executable embeds `NSContactsUsageDescription` and
`NSAppleEventsUsageDescription` in its `__TEXT,__info_plist` section. Both the
framework and scripting stay in this process so each grant belongs to the executable
launchd runs. A rebuilt ad-hoc signed binary is a new executable to macOS and is asked
for access again; sign with a stable identity to keep the grants.

The server needs two separate grants:

| Grant                  | Used for                                                                        | Asked                                         |
| ---------------------- | ------------------------------------------------------------------------------- | --------------------------------------------- |
| Contacts               | Every read and write of cards and groups, through the Contacts framework.       | At startup, with `CONTACTS_REQUEST_ACCESS=1`. |
| Automation of Contacts | Notes, creation and modification dates, group members, My Card, showing a card. | The first time a request needs scripting.     |

The server asks for Contacts access only when `CONTACTS_REQUEST_ACCESS=1` is set and
access is not already granted. Until the user answers, and after a refusal, `/graphql`
and `/mcp` answer `NOT_AUTHORIZED` with a message that says how to allow it,
`contacts_access_granted` reports 0, and metrics stay available. A refusal does not
exit the process, because launchd would only start it again into the same refusal.

Framework reads never launch Contacts. Requests that need scripting do, and the
server leaves Contacts open afterward: it never quits it. Without the Automation
grant those requests answer `NOT_AUTHORIZED`; see [AppleScript](APPLESCRIPT.md).

## Sockets

At least one `Sockets` label is required; each may hold multiple sockets. Use
`SockPathName`/`SockPathMode` for Unix or `SockNodeName`/`SockServiceName` for TCP.
Only `TailscaleServe` checks grants; other labels grant fixed access. Excluded
endpoints or missing grants return 403.

| Label            | Access                                                             |
| ---------------- | ------------------------------------------------------------------ |
| `Listeners`      | All endpoints, including writes. Restrict who can connect.         |
| `Metrics`        | `/metrics` only.                                                   |
| `GraphQL`        | `/graphql`, including writes.                                      |
| `MCP`            | `/mcp`, including writes.                                          |
| `TailscaleServe` | Checks `Tailscale-App-Capabilities` for the configured capability. |

For `TailscaleServe`, a Unix socket with `SockPathName` and `SockPathMode` 384 is
recommended:

```sh
tailscale serve --bg --https=443 --accept-app-caps=example.com/cap/contacts unix:/path/to/tailscale-serve.sock
```

`tailscaled` must run as root or as the socket's owner to open it. The sandboxed
Mac App Store build cannot use Unix sockets; use `SockNodeName=127.0.0.1`,
`SockServiceName=8175`, and an `http://127.0.0.1:8175` target instead. Any local
process can reach a loopback port and forge the capability header.

Capability grants are a list of objects mapping `graphql`/`mcp` to `r` or `rw`,
and `metrics` to `r`, under the configured capability key:

```json
{
  "example.com/cap/contacts": [{ "graphql": "r", "mcp": "rw", "metrics": "r" }]
}
```

Combine grants using the greatest access per endpoint; omitted endpoints get none.
Unknown API names/levels, `metrics: "rw"`, malformed headers, or headers over
16 KiB deny access. Accept plain JSON or RFC 2047 UTF-8 Q-encoded header values.
Only a trusted Tailscale Serve proxy may reach this socket: the header is its
assertion of identity and access, not a credential the server verifies independently.

No built-in authentication or TLS beyond socket access: keep direct sockets private
and use Tailscale Serve remotely.

## Configuration

Configuration comes only from the plist's `EnvironmentVariables`. Invalid values
prevent startup; other environment variables are ignored.

| Variable                            | Default      | Value                                                                        |
| ----------------------------------- | ------------ | ---------------------------------------------------------------------------- |
| `CONTACTS_TAILSCALE_APP_CAPABILITY` | None         | `domain/path`; required for `TailscaleServe`.                                |
| `CONTACTS_ALLOWED_ORIGINS`          | None         | Space-separated `http(s)://host[:port]` origins.                             |
| `CONTACTS_EXIT_WHEN_IDLE_SECONDS`   | Stay running | 1–86400 seconds without open connections.                                    |
| `CONTACTS_LOG_LEVEL`                | `info`       | Minimum: `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical`. |
| `CONTACTS_METRICS_INTERVAL_SECONDS` | `3600`       | Delay after collection, 1–604800 seconds.                                    |
| `CONTACTS_REQUEST_ACCESS`           | Off          | `1` to ask macOS for Contacts access at startup when it is not granted.      |

## HTTP

HTTP/1.1 supports concurrent requests, keep-alive, and chunked bodies. JSON POSTs
require `Content-Type: application/json` (415 otherwise). Bodies over 1 MiB,
including chunked uploads, receive 413.

Host is not validated. An unlisted `Origin` receives 403; allowed origins receive
CORS headers and OPTIONS preflight support. Configured origins cannot contain
paths, queries, fragments, or credentials; default ports are removed.
Repeated `Origin`, `Content-Type`, or `Tailscale-App-Capabilities` headers return
400 rather than choosing a value.

## Deadlines and recovery

GraphQL/MCP handlers have a 60-second deadline after the body is collected.
Expiry cancels their task and returns 504 without waiting for it to finish.
Cancellation cannot interrupt a synchronous native call or undo a save, so work
may finish after the timeout. Refetch before retrying writes.

An independent watchdog checks the main actor every 10 seconds and exits with
status 1 after more than 120 seconds without a heartbeat. This lets launchd recover
from an Apple event that blocks the actor; an HTTP deadline alone cannot free it.
Contacts framework calls run on their own queue and do not hold the actor.
Idle exit counts open connections, including keep-alive connections, rather than
time since the last request.

## Errors

| Code                    | Meaning                                                                               |
| ----------------------- | ------------------------------------------------------------------------------------- |
| `INVALID_ARGUMENT`      | Invalid input, including an unknown entry identifier; nothing saved.                  |
| `NOT_AUTHORIZED`        | A grant is missing or still pending; the message says which and how to allow it.      |
| `NOT_FOUND`             | No such card, group, or container, or Contacts scripting cannot see it.               |
| `READ_ONLY`             | The card or its container does not accept changes.                                    |
| `UNSUPPORTED_OPERATION` | Contacts cannot do this, such as changing a card that has a note or deleting My Card. |
| `WRITE_FAILED`          | The store refused the save; nothing saved.                                            |
| `WRITE_APPLIED`         | Part of the write was stored and a later step failed or did not answer.               |
| `SHOW_FAILED`           | Contacts did not select the card.                                                     |
| `INTERNAL`              | Unexpected failure, including Apple-event errors; message includes the code.          |

On `WRITE_APPLIED`, refetch the card or group and apply only the missing changes. A
write that sets a note is a framework save followed by an Apple event, with no
rollback between them.

## Limits

The store is read as a whole, which takes about half a second for 300 cards, and
kept as a snapshot for up to five minutes. It is reloaded sooner when the store
reports a change or this server writes to it. Cards are read as stored rather than
unified, and a card that has a note cannot be changed through the framework; see
[Contacts](CONTACTS.md).
