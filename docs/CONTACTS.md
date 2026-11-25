# Contacts framework

The server reads and writes cards, groups, and containers with the public Contacts
framework (`CNContactStore`), in its own process, without launching Contacts. It uses
no private API and does not read the address book database. What the framework cannot
do goes through [Contacts scripting](APPLESCRIPT.md) or is left out.

Behavior here was observed on macOS 27.2 with an iCloud (CardDAV) container.

## Stored cards

Cards are fetched with `unifyResults = false`: one record per stored card. A person
with cards in two accounts is two records, and each names the others in
`linkedContactIdentifiers`. Stored cards are what notes, dates, group membership, and
Contacts scripting all attach to, and a stored card's `identifier` is the same string
Contacts scripting reports as the person's `id`, such as
`7D9E633C-B71E-494D-9977-7F7A96F16DBF:ABPerson`.

Linked cards are found by comparing a unified fetch with the stored one. This was
not exercised live: the address book it was built against has no linked cards.

`containerIdentifier` and `groupIdentifiers` come from one identifier-only fetch per
container and per group, since a card does not say where it is stored.

## Keys

Every record is built from one fixed set of keys. Reading a property the fetch left
out raises an Objective-C exception that Swift cannot catch and that ends the
process, so `Shared/FrameworkRecords.swift` is the only place that reads `CNContact`
properties, after checking the keys are present. Writes fetch only the keys they
change, plus the picture, and read only those.

## Labels

`label` is the stored string. A built-in label is a token such as `_$!<Home>!$_` or
`_$!<Mobile>!$_`; any other string is a custom label. `localizedLabel` is
`CNLabeledValue.localizedString(forLabel:)`, such as `home`. Input accepts either
form and stores a built-in label's token when given its word or localized name.

The store gives a new social profile a label when none is supplied. Social profiles
and instant message addresses are left out of the `customLabels` filter because their
labels are not chosen from a built-in set.

## Dates

`birthday`, `nonGregorianBirthday`, and `dates` are date components. A birthday
without a year has no `year`; the framework's vCard writes it as year 1604 with
`X-APPLE-OMIT-YEAR`.

## Notes

The framework gives this executable no access to notes. Reading or writing a note
needs the `com.apple.developer.contacts.notes` entitlement, which Apple grants per
app and a bare executable cannot carry. Without it:

- A fetch that asks for `CNContactNoteKey` succeeds but returns cards without the
  key. The server never asks for it; notes come from Contacts scripting.
- **A card that has a note cannot be saved.** Any update to it, even of one text
  field, fails with Core Data error 134092. The server answers
  `UNSUPPORTED_OPERATION` and saves nothing. Clearing the note through scripting
  with a missing value makes the card savable again; setting the note to `""` does
  not, because an empty note still counts as a note.
- Deleting a card that has a note works.

The legacy AddressBook framework saved a text field on a card with a note in a test,
but it cannot read or write notes either and is deprecated; the server does not use
it.

## Pictures

`imageDataAvailable` is on every card; picture data is fetched per card on request.
The store re-encodes a picture within seconds of a save, so the bytes read back can
differ from the bytes written, and a thumbnail appears a few seconds later. A tiny
picture (64×64, 177 bytes) was lost on a later save; a 512×512 JPEG survived every
kind of write, with Contacts open or closed.

## Groups

Creating, renaming, and deleting a group use the framework. Changing members does
not: `CNSaveRequest.removeMember(_:from:)` succeeds and leaves the member in the
group, and `addMember(_:to:)` fails for a card that has a note. Both go through
Contacts scripting. Adding a new card to groups as part of creating it uses the
framework.

## vCard

`CNContactVCardSerialization` writes vCard 3.0 without `NOTE` or `PHOTO`, even when
the picture key is fetched, so the server adds both lines when asked. Custom labels
are written as `X-ABLabel` items. The output was checked by counting cards and
lines; it was not parsed back or imported elsewhere.

## Freshness

Reading every card takes about half a second for 300 cards, most of it the labelled
lists and `imageDataAvailable`. One snapshot serves requests for up to five minutes
and is dropped when `CNContactStoreDidChange` arrives or this server writes. The
notification arrives for changes made by Contacts and by other processes.

## Not provided

Change history (`CNChangeHistoryFetchRequest` has no Swift enumerator), linking or
unlinking cards, creating containers, smart groups, and moving a group under another.
