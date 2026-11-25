# AppleScript

Contacts scripting supplies what the Contacts framework cannot give this executable.
The [scripting dictionary](Contacts.sdef) is the reference. Events go to
`com.apple.AddressBook` from the server process, through `NSAppleScript`, so the
Automation grant belongs to the executable launchd runs.

| Through scripting                    | Why                                                             |
| ------------------------------------ | --------------------------------------------------------------- |
| `note`, read and write               | The framework needs an entitlement the executable cannot carry. |
| `creation date`, `modification date` | The framework does not expose them.                             |
| Group members, add and remove        | The framework ignores a removal and refuses a card with a note. |
| `my card`, write                     | The framework can only read it.                                 |
| `selection`                          | Showing a card in Contacts.                                     |

## Launching Contacts

Sending Contacts an Apple event launches it when it is not running. The server may
start Contacts this way and never quits it. Metrics and framework reads send no
events, so they never start it.

## Fixed scripts

Scripts are compiled once per process. Client values travel as typed Apple-event
arguments to a handler, never as source text.

## Main run loop

The main thread runs `CFRunLoopRun()`, not `dispatchMain()`: AppleScript waits for
each Apple-event reply on the main run loop.

## Reads

A property is read for every person in one event, with the identifiers read before
and after; counts must match and each identifier must be unchanged, or the read
fails. For 300 cards a property takes about 60 to 130 ms. The first event after
Contacts launches takes about two seconds.

Dates arrive as `ldt ` descriptors and are read with the descriptor's own date
conversion. Values for cards changed under the current UTC offset match the legacy
AddressBook framework's to the second. The alternative reading, which the TV server
needs for TV, differs by an hour for dates under the other daylight-saving offset;
that case was not checked against a second source.

## Writes

`save` is how scripting stores an edit, and it commits every unsaved change in
Contacts. Each handler changes one thing, saves, and returns what Contacts then
reports, which the server checks.

- **Note.** `set note` then `save`. Clearing sets a missing value, not `""`. The
  handler first compares whether Contacts has a picture for the card with what the
  store says, and raises an error when they differ; the server retries for up to 15
  seconds, since Contacts catches up with a picture the framework just stored. After
  the save the server checks the store again and answers `WRITE_APPLIED` if the card
  gained or lost a picture.
- **Group members.** `add` or `remove` each person, `save`, then return the group's
  members, which must include or exclude the cards.
- **My Card.** `set my card`, `save`, and return its identifier. Not exercised live.
- **Show.** Set the selection, activate Contacts, and return the selected identifier.

A card the framework just created is retried for up to 15 seconds until scripting
can address it. An event Contacts does not answer in time is `WRITE_APPLIED`: it may
have been applied.

## Errors

| Code     | Meaning                                                          | Answer                                                                                  |
| -------- | ---------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `-1743`  | The server is not allowed to control Contacts.                   | `NOT_AUTHORIZED`                                                                        |
| `-1728`  | No such object, or a card Contacts has not loaded yet.           | Retried, then `NOT_FOUND`                                                               |
| `-10006` | Contacts refused a set.                                          | Retried                                                                                 |
| `-1712`  | Contacts did not answer in time.                                 | `WRITE_APPLIED` for a write                                                             |
| `9001`   | Contacts and the store disagree on whether a card has a picture. | Retried, then `UNSUPPORTED_OPERATION`, or `WRITE_APPLIED` when other changes were saved |

## Working with Contacts open

With Contacts open, framework writes of text fields, labelled lists, and pictures
were followed by note writes through Contacts without losing either side's change.
Contacts keeps its own copy of each card, so the note handler's picture check stays
as a guard against it saving an older one.
