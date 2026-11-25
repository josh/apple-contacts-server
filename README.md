# apple-contacts-server

A Swift HTTP server for reading and changing the cards and groups of macOS Contacts
through GraphQL and MCP, with Prometheus metrics for address book counts. The Contacts
framework reads and writes cards in the server process; Contacts scripting supplies
notes, creation and modification dates, and group membership changes.

| Endpoint        | Documentation                                               |
| --------------- | ----------------------------------------------------------- |
| `POST /graphql` | [GraphQL](docs/GRAPHQL.md), [schema](docs/contacts.graphql) |
| `POST /mcp`     | [MCP](docs/MCP.md), [tool catalog](docs/mcp-tools.json)     |
| `GET /metrics`  | [Metrics](docs/METRICS.md), [example](docs/metrics.prom)    |

Cards use the names of the Contacts framework: a card is shaped like `CNContact`, and
each phone number, email address, or postal address is a `CNLabeledValue` with its
`identifier`, `label`, and `value`.

## Running

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.github.josh.apple-contacts-server</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/apple-contacts-server</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CONTACTS_REQUEST_ACCESS</key>
    <string>1</string>
  </dict>
  <key>Sockets</key>
  <dict>
    <key>Listeners</key>
    <dict>
      <key>SockPathName</key>
      <string>/Users/you/Library/Application Support/apple-contacts-server/server.sock</string>
      <key>SockPathMode</key>
      <integer>384</integer>
    </dict>
  </dict>
</dict>
</plist>
```

See [Server](docs/SERVER.md) for setup, the two macOS grants it needs, sockets, and
configuration, and [Contacts](docs/CONTACTS.md) for what the framework cannot do.
