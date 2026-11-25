# MCP

`POST /mcp` accepts one JSON-RPC 2.0 message using protocol `2025-11-25`.
Supports `initialize`, `ping`, `tools/list`, `tools/call`, and accepted notifications
(HTTP 202). GET returns 405. Stateless: no session header, SSE stream, server
requests, or resumability.

Send `Content-Type: application/json`, `Accept: application/json, text/event-stream`,
and, after initialization, `MCP-Protocol-Version: 2025-11-25`.

```sh
curl --unix-socket /path/to/server.sock http://localhost/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"example","version":"1"}}}'
```

`tools/list` returns current descriptions and input/output schemas; the
[catalog](mcp-tools.json) is an export. Annotations do not grant permission.
The server requires `rw` for any tool without `readOnlyHint: true`.

## Tools

| Tool                                                  | Path      | Launches Contacts                                              |
| ----------------------------------------------------- | --------- | -------------------------------------------------------------- |
| `contacts_search`, `contacts_get`                     | Framework | Only with `include`, a date filter or order, or the `NOTE` key |
| `contacts_summary`, `defaults_get`, `containers_list` | Framework | No                                                             |
| `groups_list`, `groups_get`                           | Framework | No                                                             |
| `contacts_create`, `contacts_update`                  | Framework | Only when the note changes                                     |
| `contacts_delete`                                     | Both      | Yes, to copy the note                                          |
| `groups_create`, `groups_update`, `groups_delete`     | Framework | No                                                             |
| `groups_add_members`, `groups_remove_members`         | Scripting | Yes                                                            |
| `contacts_set_me`, `contacts_show`                    | Scripting | Yes                                                            |

Results are cards as the Contacts framework stores them, with absent values and
empty lists omitted. `include` on `contacts_search` and `contacts_get` adds `note`,
`creationDate`, or `modificationDate`, which only Contacts scripting provides; without
it a read needs no Automation grant.

Explicit null is rejected anywhere in the arguments, and so are fields a tool does
not declare. Lists page with `limit` and `cursor`; `nextCursor` is the next offset,
valid while the criteria and limit stay the same.

Writes follow the [GraphQL write rules](GRAPHQL.md#writes), including the refusal to
change a card that has a note. `contacts_create` takes the card's fields at the top
level; `contacts_update` takes `id` and `patch`.

## Not in MCP

A card's picture and vCard export are GraphQL only: both travel as large text that a
tool call cannot carry cheaply. Tools report `imageDataAvailable`, and
`clearFields: ["IMAGE_DATA"]` removes a picture. `contacts_delete` returns the deleted
card's vCard without its picture.
