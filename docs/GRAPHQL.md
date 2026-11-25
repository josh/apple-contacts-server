# GraphQL

`POST /graphql`. The [schema](contacts.graphql) documents types, fields, inputs, and
validation. No subscriptions.

```sh
curl --unix-socket /path/to/server.sock http://localhost/graphql \
  -H 'Content-Type: application/json' \
  --data '{"query":"{ contacts(limit: 10, filter: {contactTypes: [ORGANIZATION], missing: [IMAGE_DATA]}) { totalCount items { identifier organizationName emailAddresses { identifier label localizedLabel value } } } }"}'
```

The endpoint follows [GraphQL over HTTP](https://http-spec.graphql.org/September2026/).
Responses use `application/graphql-response+json` when Accept allows it or is absent,
else `application/json` on 2xx; Accept without either returns 406.

Null `variables`/`operationName` mean absent. Request errors carry no `data`: a body
that is not JSON or a document that does not parse returns 400; a malformed envelope,
failed validation, an ambiguous operation, or variables that do not coerce return 422.
Other methods return 405 with `Allow: POST`. A read-only grant permits only the
selected query operation; mutations require write access (403). Execution errors use
HTTP 200 with `data` and `errors`; clients must inspect the body. Each error carries
its [code](SERVER.md#errors) in `extensions.code`.

## Shape

Types and fields follow the Contacts framework. `Contact` has the properties of
`CNContact`; `phoneNumbers`, `emailAddresses`, `postalAddresses`, `urlAddresses`,
`contactRelations`, `socialProfiles`, `instantMessageAddresses`, and `dates` are
lists of `CNLabeledValue`: `identifier`, `label`, `localizedLabel`, and a `value`
shaped like the framework's value class. `Group` is `CNGroup` and `Container` is
`CNContainer`. Objects carry `identifier`; arguments that name one are `id`.

Cards are returned as stored, not unified; see [Contacts](CONTACTS.md#stored-cards).

## Reads

`contacts`, `contact`, `groups`, `group`, `containers`, `container`, `defaults`, and
`summary` come from the Contacts framework alone and never launch Contacts. Within a
request the store is read once. Pages take `limit` (1–100, default 50) and `offset`
and return `items`, `totalCount`, and `pageInfo`.

These come from Contacts scripting instead, and launch Contacts when it is not
running:

- `note`, `creationDate`, and `modificationDate` on `Contact`. Each is read for every
  card in one Apple event, the first time a query selects it.
- The filter fields `createdFrom`, `createdBefore`, `modifiedFrom`, and
  `modifiedBefore`, the keys `NOTE` in `has` and `missing`, and the sort fields
  `CREATION_DATE` and `MODIFICATION_DATE`.
- `vCard(includeNote: true)` and `exportVCard(includeNotes: true)`.

A query that names none of them needs no Automation grant.

`thumbnailImageData` and `imageData` are base64 and are fetched per card when
selected. A thumbnail appears a few seconds after a picture is set.

## Export

`exportVCard` returns cards as one vCard 3.0 text with `contactCount` and
`byteCount`. `unify` defaults to true, so a person with cards in two accounts is
exported once; `filter` selects stored cards. The framework writes neither notes nor
pictures, so `includeNotes` and `includeImages` add `NOTE` and `PHOTO` lines.
`Contact.vCard` exports one stored card.

## Writes

`createContact(input)` and `updateContact(id, patch)` take the shapes a card returns.

- A text field in a patch replaces the stored value. Null and blank values are
  rejected; `clearFields` removes a value, and a field cannot be both set and cleared.
- A list in a patch is `{add, update, remove}`. `update` and `remove` name entries by
  `identifier`; every identifier is checked before anything changes. An entry the
  patch does not name keeps its identifier, label, and value. Nothing replaces a whole
  list; `clearFields` empties one.
- An `update` changes only what is present. For a postal address, a social profile,
  or an instant message address, a part that is present replaces the stored one and
  `""` empties it. A `label` of `""` removes the label.
- A `label` is a stored token such as `_$!<Home>!$_`, a custom label, or the word for
  a built-in label such as `home`, `work`, `mobile`, or `other`.
- `birthday` is Gregorian and may omit `year`; `nonGregorianBirthday` needs a
  `calendar`.
- `imageData` is base64 of an image. The 1 MiB body limit allows about 700 KB.

A card that has a note cannot be changed through the framework, so:

- A patch of other fields on a card with a note fails with `UNSUPPORTED_OPERATION`
  and saves nothing.
- A patch of only `note`, or only `clearFields: [NOTE]`, always works.
- A patch that clears the note and changes other fields clears the note first, then
  saves.
- A patch that sets a note on a card without one saves the other fields first, then
  sets the note. If the note step fails, the answer is `WRITE_APPLIED`.

`deleteContact` returns a vCard of the card taken just before the delete, with its
picture, and with its note when Contacts scripting answered. It refuses My Card.

`createGroup`, `updateGroup`, and `deleteGroup` use the framework.
`addGroupMembers` and `removeGroupMembers` use Contacts scripting. `setMeContact` and
`showContact` use Contacts scripting; `showContact` selects the card and brings
Contacts forward without storing anything.
