# Agents

- Live writes must stay within the user's authorized test scope. Use explicit identifiers, change only disposable test cards and groups in a container the user named, and delete them afterward with a verified re-read. Never change My Card in a test without the user's go-ahead.
- Test pictures must be realistic, such as a 512×512 JPEG. Contacts loses a tiny picture (a 64×64, 177-byte PNG) on a later save, which looks like a bug in the server.
- The server may start Contacts for a scripting request and must never quit it. Quit Contacts yourself, outside the server, when a test needs a fresh instance.
- Reads through the Contacts framework and metrics collection must not launch Contacts; only an API request that needs scripting may.
- Never fetch `CNContactNoteKey`, and never read a `CNContact` property outside `Shared/FrameworkRecords.swift` or a write that fetched its key: reading an unfetched key ends the process.
- A rebuilt binary is ad-hoc signed, and macOS asks again for Contacts and Automation access. Sign each dev build with a stable identity, such as `codesign --force --sign "Apple Development" --identifier com.github.josh.apple-contacts-server .build/debug/apple-contacts-server`, to keep the grants.
- Prefer existing dependencies. Do not add permanent unit/integration tests unless requested.

Regenerate the GraphQL schema and MCP tool catalog after changing either:

```sh
swift run apple-contacts-server --dump-graphql-schema >docs/contacts.graphql
swift run apple-contacts-server --dump-mcp-tools >docs/mcp-tools.json
prettier --write docs/contacts.graphql docs/mcp-tools.json
```
