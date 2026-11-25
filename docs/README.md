# Documentation

- [Server](SERVER.md): launchd, grants, sockets, configuration, and errors.
- [GraphQL](GRAPHQL.md) · [Schema](contacts.graphql)
- [MCP](MCP.md) · [Tool catalog](mcp-tools.json)
- [Metrics](METRICS.md) · [Example](metrics.prom)
- [Contacts](CONTACTS.md): what the Contacts framework provides, identity, labels, and its limits.
- [AppleScript](APPLESCRIPT.md) · [Scripting dictionary](Contacts.sdef): the fields and writes that go through Contacts.

The schema and catalog are exports; live introspection and MCP discovery describe
the running version. Refresh the scripting dictionary with
`/usr/bin/sdef /System/Applications/Contacts.app >docs/Contacts.sdef`.
