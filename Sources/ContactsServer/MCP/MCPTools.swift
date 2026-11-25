import Foundation
import MCP
import NIOHTTP1

private struct PageOutput<Item: Encodable>: Encodable {
  let items: [Item]
  let totalCount: Int
  let nextCursor: String?
  enum CodingKeys: String, CodingKey { case items, totalCount, nextCursor }
}
private struct ContainersOutput: Encodable {
  let containers: [ContainerRecord]
  enum CodingKeys: CodingKey { case containers }
}
private struct GroupOutput: Encodable {
  let group: GroupRecord?
  enum CodingKeys: CodingKey { case group }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(group, forKey: .group)
  }
}
private struct ContactOutput: Encodable {
  let contact: MCPContact?
  enum CodingKeys: CodingKey { case contact }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(contact, forKey: .contact)
  }
}
private func describe(_ value: Value, _ text: String) -> Value {
  guard case .object(var object) = value else { return value }
  object["description"] = .string(text)
  return .object(object)
}
private func object(_ properties: [String: Value], required: [String] = []) -> Value {
  .object([
    "type": .string(JSONType.object.rawValue), "properties": .object(properties),
    "required": .array(required.map(Value.string)), "additionalProperties": false,
  ])
}
// An object schema whose property names are the coding keys of the type it describes,
// so the schema cannot name a field the encoder or decoder does not use.
private func schema<Key: CodingKey>(
  _: Key.Type, _ properties: KeyValuePairs<Key, Value>, required: [Key] = []
) -> Value {
  object(
    Dictionary(uniqueKeysWithValues: properties.map { ($0.key.stringValue, $0.value) }),
    required: required.map(\.stringValue))
}
// JSON Schema type names.
private enum JSONType: String { case object, array, string, integer, number, boolean, null }
// A value of one JSON type, with optional keywords such as minimum or default.
private func primitive(_ type: JSONType, _ keywords: [String: Value] = [:]) -> Value {
  .object(keywords.merging(["type": .string(type.rawValue)]) { _, type in type })
}
private func array(_ item: Value) -> Value {
  .object(["type": .string(JSONType.array.rawValue), "items": item])
}
private func enumeration(_ values: [String]) -> Value {
  primitive(.string, ["enum": .array(values.map(Value.string))])
}
private func nullable(_ value: Value) -> Value {
  .object(["anyOf": .array([value, primitive(.null)])])
}
private func toolsCatalog() -> [Tool] {
  let integer = primitive(.integer)
  let string = primitive(.string)
  let boolean = primitive(.boolean)
  let limit = describe(
    primitive(.integer, ["minimum": 1, "maximum": 100, "default": 50]),
    "Maximum items in the page, from 1 through 100; defaults to 50.")
  let cursor = describe(
    string, "nextCursor from the previous page; omit for the first page.")
  let direction = describe(
    enumeration(SortDirection.allCases.map(\.rawValue)), FieldDocs.Order.direction)
  func page<Item: Encodable>(_: Item.Type, _ item: Value, _ items: String, _ totalCount: String)
    -> Value
  {
    schema(
      PageOutput<Item>.CodingKeys.self,
      [
        .items: describe(array(item), items),
        .totalCount: describe(integer, totalCount),
        .nextCursor: describe(string, "Cursor for the next page; omitted on the last page."),
      ], required: [.items, .totalCount])
  }
  func byID(_ noun: String) -> Value {
    schema(
      IDArguments.CodingKeys.self,
      [.id: describe(string, "Identifier of the \(noun).")], required: [.id])
  }
  // One CNLabeledValue list; the value schema differs per property.
  func labeled<Item: Encodable & Sendable>(_: Item.Type, _ value: Value, _ description: String)
    -> Value
  {
    describe(
      array(
        schema(
          LabeledValueRecord<Item>.CodingKeys.self,
          [
            .identifier: describe(string, FieldDocs.LabeledValue.identifier),
            .label: describe(string, FieldDocs.LabeledValue.label),
            .localizedLabel: describe(string, FieldDocs.LabeledValue.localizedLabel),
            .value: describe(value, FieldDocs.LabeledValue.value),
          ], required: [.identifier, .value])), "\(description) Omitted when empty.")
  }
  let dateComponents = schema(
    DateComponentsValue.CodingKeys.self,
    [
      .calendar: describe(string, FieldDocs.DateComponents.calendar),
      .era: describe(integer, FieldDocs.DateComponents.era),
      .year: describe(integer, FieldDocs.DateComponents.year),
      .month: describe(integer, FieldDocs.DateComponents.month),
      .day: describe(integer, FieldDocs.DateComponents.day),
      .isLeapMonth: describe(boolean, FieldDocs.DateComponents.isLeapMonth),
    ])
  let postalAddress = schema(
    PostalAddressValue.CodingKeys.self,
    [
      .street: describe(string, FieldDocs.PostalAddress.street),
      .subLocality: describe(string, FieldDocs.PostalAddress.subLocality),
      .city: describe(string, FieldDocs.PostalAddress.city),
      .subAdministrativeArea: describe(string, FieldDocs.PostalAddress.subAdministrativeArea),
      .state: describe(string, FieldDocs.PostalAddress.state),
      .postalCode: describe(string, FieldDocs.PostalAddress.postalCode),
      .country: describe(string, FieldDocs.PostalAddress.country),
      .isoCountryCode: describe(string, FieldDocs.PostalAddress.isoCountryCode),
    ])
  typealias Docs = FieldDocs.Contact
  let identifierList = array(string)
  let contact = schema(
    MCPContact.CodingKeys.self,
    [
      .identifier: describe(string, Docs.identifier),
      .contactType: describe(
        enumeration(ContactType.allCases.map(\.rawValue)), Docs.contactType),
      .fullName: describe(string, Docs.fullName),
      .namePrefix: describe(string, Docs.namePrefix),
      .givenName: describe(string, Docs.givenName),
      .middleName: describe(string, Docs.middleName),
      .familyName: describe(string, Docs.familyName),
      .previousFamilyName: describe(string, Docs.previousFamilyName),
      .nameSuffix: describe(string, Docs.nameSuffix),
      .nickname: describe(string, Docs.nickname),
      .phoneticGivenName: describe(string, Docs.phoneticGivenName),
      .phoneticMiddleName: describe(string, Docs.phoneticMiddleName),
      .phoneticFamilyName: describe(string, Docs.phoneticFamilyName),
      .phoneticOrganizationName: describe(string, Docs.phoneticOrganizationName),
      .organizationName: describe(string, Docs.organizationName),
      .departmentName: describe(string, Docs.departmentName),
      .jobTitle: describe(string, Docs.jobTitle),
      .phoneNumbers: labeled(
        PhoneNumberValue.self,
        schema(
          PhoneNumberValue.CodingKeys.self,
          [.stringValue: describe(string, FieldDocs.PhoneNumber.stringValue)],
          required: [.stringValue]), Docs.phoneNumbers),
      .emailAddresses: labeled(String.self, string, Docs.emailAddresses),
      .postalAddresses: labeled(PostalAddressValue.self, postalAddress, Docs.postalAddresses),
      .urlAddresses: labeled(String.self, string, Docs.urlAddresses),
      .contactRelations: labeled(
        ContactRelationValue.self,
        schema(
          ContactRelationValue.CodingKeys.self,
          [.name: describe(string, FieldDocs.ContactRelation.name)], required: [.name]),
        Docs.contactRelations),
      .socialProfiles: labeled(
        SocialProfileValue.self,
        schema(
          SocialProfileValue.CodingKeys.self,
          [
            .urlString: describe(string, FieldDocs.SocialProfile.urlString),
            .username: describe(string, FieldDocs.SocialProfile.username),
            .userIdentifier: describe(string, FieldDocs.SocialProfile.userIdentifier),
            .service: describe(string, FieldDocs.SocialProfile.service),
          ]), Docs.socialProfiles),
      .instantMessageAddresses: labeled(
        InstantMessageAddressValue.self,
        schema(
          InstantMessageAddressValue.CodingKeys.self,
          [
            .username: describe(string, FieldDocs.InstantMessageAddress.username),
            .service: describe(string, FieldDocs.InstantMessageAddress.service),
          ]), Docs.instantMessageAddresses),
      .dates: labeled(DateComponentsValue.self, dateComponents, Docs.dates),
      .birthday: describe(dateComponents, Docs.birthday),
      .nonGregorianBirthday: describe(dateComponents, Docs.nonGregorianBirthday),
      .imageDataAvailable: describe(boolean, Docs.imageDataAvailable),
      .containerIdentifier: describe(string, Docs.containerIdentifier),
      .groupIdentifiers: describe(
        identifierList, "\(Docs.groupIdentifiers) Omitted when empty."),
      .linkedContactIdentifiers: describe(
        identifierList,
        "Identifiers of the other stored cards Contacts shows together with this one as one person. Omitted for a card that stands alone."
      ),
      .isMe: describe(boolean, "True on the user's own card; omitted otherwise."),
      .note: describe(
        string, "The note; present only when include names NOTE and the card has one."),
      .creationDate: describe(
        string,
        "When the card was created, as an RFC 3339 timestamp; present only when include names CREATION_DATE."
      ),
      .modificationDate: describe(
        string,
        "When the card last changed, as an RFC 3339 timestamp; present only when include names MODIFICATION_DATE."
      ),
    ], required: [.identifier, .contactType, .imageDataAvailable])
  let group = schema(
    GroupRecord.CodingKeys.self,
    [
      .identifier: describe(string, FieldDocs.Group.identifier),
      .name: describe(string, FieldDocs.Group.name),
      .containerIdentifier: describe(string, FieldDocs.Group.containerIdentifier),
      .parentGroupIdentifier: describe(string, FieldDocs.Group.parentGroupIdentifier),
      .subgroupIdentifiers: describe(identifierList, FieldDocs.Group.subgroupIdentifiers),
      .memberCount: describe(integer, FieldDocs.Group.memberCount),
    ], required: [.identifier, .name, .containerIdentifier, .subgroupIdentifiers, .memberCount])
  let container = schema(
    ContainerRecord.CodingKeys.self,
    [
      .identifier: describe(string, FieldDocs.Container.identifier),
      .name: describe(string, FieldDocs.Container.name),
      .type: describe(
        enumeration(ContainerType.allCases.map(\.rawValue)), FieldDocs.Container.type),
      .isDefault: describe(boolean, FieldDocs.Container.isDefault),
      .contactCount: describe(integer, FieldDocs.Container.contactCount),
      .groupCount: describe(integer, FieldDocs.Container.groupCount),
    ], required: [.identifier, .name, .type, .isDefault, .contactCount, .groupCount])
  typealias Filter = FieldDocs.ContactFilter
  let contactKeys = array(enumeration(ContactKey.allCases.map(\.rawValue)))
  let include = describe(
    array(enumeration(ExtraField.allCases.map(\.rawValue))), FieldDocs.Include.include)
  let contactSearch = schema(
    ContactSearchArguments.CodingKeys.self,
    [
      .filter: describe(
        schema(
          ContactSearchArguments.Filter.CodingKeys.self,
          [
            .query: describe(string, Filter.query),
            .identifiers: describe(identifierList, Filter.identifiers),
            .contactTypes: describe(
              array(enumeration(ContactType.allCases.map(\.rawValue))), Filter.contactTypes),
            .containerIdentifiers: describe(identifierList, Filter.containerIdentifiers),
            .groupIdentifiers: describe(identifierList, Filter.groupIdentifiers),
            .has: describe(contactKeys, Filter.has),
            .missing: describe(contactKeys, Filter.missing),
            .labels: describe(array(string), Filter.labels),
            .customLabels: describe(boolean, Filter.customLabels),
            .linked: describe(boolean, Filter.linked),
            .createdFrom: describe(string, Filter.createdFrom),
            .createdBefore: describe(string, Filter.createdBefore),
            .modifiedFrom: describe(string, Filter.modifiedFrom),
            .modifiedBefore: describe(string, Filter.modifiedBefore),
          ]), "Criteria to match; they intersect."),
      .orderBy: schema(
        ContactSearchArguments.Order.CodingKeys.self,
        [
          .field: describe(
            enumeration(ContactSortField.allCases.map(\.rawValue)), FieldDocs.Order.field),
          .direction: direction,
        ], required: [.field]),
      .limit: limit, .cursor: cursor, .include: include,
    ])

  // Write input, shaped like the card: value schemas, then for each list the entries of
  // a new card and the add, update, and remove of a patch.
  typealias Input = FieldDocs.ContactInput
  let label = describe(string, Input.label)
  let phoneNumberInput = schema(
    PhoneNumberInput.CodingKeys.self,
    [.stringValue: describe(string, FieldDocs.PhoneNumber.stringValue)],
    required: [.stringValue])
  let postalAddressInput = describe(
    schema(
      PostalAddressInput.CodingKeys.self,
      [
        .street: describe(string, FieldDocs.PostalAddress.street),
        .subLocality: describe(string, FieldDocs.PostalAddress.subLocality),
        .city: describe(string, FieldDocs.PostalAddress.city),
        .subAdministrativeArea: describe(string, FieldDocs.PostalAddress.subAdministrativeArea),
        .state: describe(string, FieldDocs.PostalAddress.state),
        .postalCode: describe(string, FieldDocs.PostalAddress.postalCode),
        .country: describe(string, FieldDocs.PostalAddress.country),
        .isoCountryCode: describe(string, FieldDocs.PostalAddress.isoCountryCode),
      ]), "In an update, a part that is present replaces the stored one and \"\" empties it.")
  let socialProfileInput = describe(
    schema(
      SocialProfileInput.CodingKeys.self,
      [
        .urlString: describe(string, FieldDocs.SocialProfile.urlString),
        .username: describe(string, FieldDocs.SocialProfile.username),
        .userIdentifier: describe(string, FieldDocs.SocialProfile.userIdentifier),
        .service: describe(string, FieldDocs.SocialProfile.service),
      ]), "Needs a username or a urlString.")
  let instantMessageInput = describe(
    schema(
      InstantMessageAddressInput.CodingKeys.self,
      [
        .username: describe(string, FieldDocs.InstantMessageAddress.username),
        .service: describe(string, FieldDocs.InstantMessageAddress.service),
      ]), "Needs a username.")
  let relationInput = schema(
    ContactRelationInput.CodingKeys.self,
    [.name: describe(string, FieldDocs.ContactRelation.name)], required: [.name])
  let dateInput = schema(
    DateComponentsInput.CodingKeys.self,
    [
      .calendar: describe(string, FieldDocs.DateComponents.calendar),
      .era: describe(integer, FieldDocs.DateComponents.era),
      .year: describe(integer, FieldDocs.DateComponents.year),
      .month: describe(
        primitive(.integer, ["minimum": 1, "maximum": 13]), FieldDocs.DateComponents.month),
      .day: describe(
        primitive(.integer, ["minimum": 1, "maximum": 31]), FieldDocs.DateComponents.day),
      .isLeapMonth: describe(boolean, FieldDocs.DateComponents.isLeapMonth),
    ], required: [.month, .day])
  func entries(_ value: Value, creating: Bool, _ description: String) -> Value {
    let added = array(
      schema(
        LabeledEntryKey.self,
        [.label: label, .value: describe(value, FieldDocs.LabeledValue.value)], required: [.value]))
    guard !creating else { return describe(added, "\(description) \(Input.list)") }
    let updated = array(
      schema(
        LabeledEntryKey.self,
        [
          .identifier: describe(string, Input.entryIdentifier), .label: label,
          .value: describe(value, FieldDocs.LabeledValue.value),
        ], required: [.identifier]))
    return describe(
      schema(
        LabeledOperationKey.self,
        [
          .add: describe(added, Input.add), .update: describe(updated, Input.updateEntries),
          .remove: describe(identifierList, Input.remove),
        ]), "\(description) \(Input.changes)")
  }
  // The picture is absent: it travels as base64, which a tool call cannot carry cheaply,
  // so it is set through GraphQL.
  func contactInput(creating: Bool) -> [(ContactInputKey, Value)] {
    var fields: [(ContactInputKey, Value)] = [
      (.contactType, describe(enumeration(ContactType.allCases.map(\.rawValue)), Docs.contactType)),
      (.namePrefix, describe(string, Docs.namePrefix)),
      (.givenName, describe(string, Docs.givenName)),
      (.middleName, describe(string, Docs.middleName)),
      (.familyName, describe(string, Docs.familyName)),
      (.previousFamilyName, describe(string, Docs.previousFamilyName)),
      (.nameSuffix, describe(string, Docs.nameSuffix)),
      (.nickname, describe(string, Docs.nickname)),
      (.phoneticGivenName, describe(string, Docs.phoneticGivenName)),
      (.phoneticMiddleName, describe(string, Docs.phoneticMiddleName)),
      (.phoneticFamilyName, describe(string, Docs.phoneticFamilyName)),
      (.phoneticOrganizationName, describe(string, Docs.phoneticOrganizationName)),
      (.organizationName, describe(string, Docs.organizationName)),
      (.departmentName, describe(string, Docs.departmentName)),
      (.jobTitle, describe(string, Docs.jobTitle)),
      (.phoneNumbers, entries(phoneNumberInput, creating: creating, Docs.phoneNumbers)),
      (.emailAddresses, entries(string, creating: creating, Docs.emailAddresses)),
      (.postalAddresses, entries(postalAddressInput, creating: creating, Docs.postalAddresses)),
      (.urlAddresses, entries(string, creating: creating, Docs.urlAddresses)),
      (.contactRelations, entries(relationInput, creating: creating, Docs.contactRelations)),
      (.socialProfiles, entries(socialProfileInput, creating: creating, Docs.socialProfiles)),
      (
        .instantMessageAddresses,
        entries(instantMessageInput, creating: creating, Docs.instantMessageAddresses)
      ),
      (.dates, entries(dateInput, creating: creating, Docs.dates)),
      (.birthday, describe(dateInput, Input.birthday)),
      (.nonGregorianBirthday, describe(dateInput, Input.nonGregorianBirthday)),
      (.note, describe(string, Input.note)),
    ]
    if creating {
      fields += [
        (.containerIdentifier, describe(string, Input.containerIdentifier)),
        (.groupIdentifiers, describe(identifierList, Input.groupIdentifiers)),
      ]
    } else {
      fields.append((.clearFields, describe(contactKeys, Input.clearFields)))
    }
    return fields
  }
  func properties(_ fields: [(ContactInputKey, Value)]) -> [String: Value] {
    Dictionary(uniqueKeysWithValues: fields.map { ($0.0.stringValue, $0.1) })
  }
  let contactResult = schema(
    ContactOutput.CodingKeys.self, [.contact: describe(contact, "The card as it now is.")],
    required: [.contact])
  let groupResult = schema(
    GroupOutput.CodingKeys.self, [.group: describe(group, "The group as it now is.")],
    required: [.group])
  let members = schema(
    MembersArguments.CodingKeys.self,
    [
      .id: describe(string, "Identifier of the group."),
      .contactIdentifiers: describe(identifierList, FieldDocs.GroupInput.contactIdentifiers),
    ], required: [.id, .contactIdentifiers])
  let annotations = Tool.Annotations(
    readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
  let created = Tool.Annotations(
    readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
  let changed = Tool.Annotations(
    readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
  let replaced = Tool.Annotations(
    readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
  let added = Tool.Annotations(
    readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
  let noArguments = object([:])
  let pictureNote = "The picture cannot be set here; use GraphQL."
  let cursorNotes =
    "Cursor is the next page offset; keep the criteria and limit unchanged across pages."
  return [
    Tool(
      name: ToolName.contactsSearch.rawValue,
      description:
        "Read stored cards from Contacts, in the name order chosen in Contacts settings unless orderBy says otherwise. Cards are returned as stored, not unified: a person with cards in two accounts is two results that name each other in linkedContactIdentifiers. Fields follow CNContact. Results come from the Contacts framework without launching Contacts, unless include, a date filter, a date order, or the NOTE key asks for what only Contacts scripting provides. Filters intersect; empty arrays match nothing. \(cursorNotes)",
      inputSchema: contactSearch, annotations: annotations,
      outputSchema: page(
        MCPContact.self, contact, FieldDocs.ContactPage.items, FieldDocs.ContactPage.totalCount)),
    Tool(
      name: ToolName.contactsGet.rawValue,
      description: "Read one stored card by identifier; returns null when absent.",
      inputSchema: schema(
        ContactGetArguments.CodingKeys.self,
        [.id: describe(string, "Identifier of the card."), .include: include], required: [.id]),
      annotations: annotations,
      outputSchema: schema(
        ContactOutput.CodingKeys.self,
        [.contact: describe(nullable(contact), "The card, or null when absent.")],
        required: [.contact])),
    Tool(
      name: ToolName.contactsCreate.rawValue,
      description:
        "\(Input.create) The card is stored through the Contacts framework; a note is then set through Contacts scripting. \(pictureNote)",
      inputSchema: object(properties(contactInput(creating: true))), annotations: created,
      outputSchema: contactResult),
    Tool(
      name: ToolName.contactsUpdate.rawValue, description: "\(Input.update) \(pictureNote)",
      inputSchema: schema(
        PatchArguments<ContactPatch>.CodingKeys.self,
        [
          .id: describe(string, "Identifier of the card."),
          .patch: describe(object(properties(contactInput(creating: false))), Input.patch),
        ], required: [.id, .patch]),
      annotations: changed, outputSchema: contactResult),
    Tool(
      name: ToolName.contactsDelete.rawValue,
      description:
        "\(FieldDocs.Write.deleteContact) The vCard here omits the picture; GraphQL returns it with one.",
      inputSchema: byID("card"), annotations: changed,
      outputSchema: schema(
        DeletedContact.CodingKeys.self,
        [
          .deletedId: describe(string, FieldDocs.Write.deletedId),
          .vCard: describe(string, FieldDocs.Write.deletedVCard),
        ], required: [.deletedId, .vCard])),
    Tool(
      name: ToolName.contactsSetMe.rawValue, description: FieldDocs.Write.setMe,
      inputSchema: byID("card"), annotations: replaced, outputSchema: contactResult),
    Tool(
      name: ToolName.contactsShow.rawValue, description: FieldDocs.Write.show,
      inputSchema: byID("card"), annotations: added, outputSchema: contactResult),
    Tool(
      name: ToolName.contactsSummary.rawValue,
      description: "Count the cards, groups, and containers in Contacts.",
      inputSchema: noArguments, annotations: annotations,
      outputSchema: schema(
        ContactsSummary.CodingKeys.self,
        [
          .contactCount: describe(integer, FieldDocs.Summary.contactCount),
          .personCount: describe(integer, FieldDocs.Summary.personCount),
          .organizationCount: describe(integer, FieldDocs.Summary.organizationCount),
          .linkedContactCount: describe(integer, FieldDocs.Summary.linkedContactCount),
          .groupCount: describe(integer, FieldDocs.Summary.groupCount),
          .containerCount: describe(integer, FieldDocs.Summary.containerCount),
        ],
        required: [
          .contactCount, .personCount, .organizationCount, .linkedContactCount, .groupCount,
          .containerCount,
        ])),
    Tool(
      name: ToolName.groupsList.rawValue,
      description: "Read the groups in Contacts, by name. Filters intersect. \(cursorNotes)",
      inputSchema: schema(
        GroupSearchArguments.CodingKeys.self,
        [
          .filter: describe(
            schema(
              GroupSearchArguments.Filter.CodingKeys.self,
              [
                .query: describe(string, FieldDocs.GroupFilter.query),
                .containerIdentifiers: describe(
                  identifierList, FieldDocs.GroupFilter.containerIdentifiers),
              ]), "Criteria to match; they intersect."),
          .limit: limit, .cursor: cursor,
        ]),
      annotations: annotations,
      outputSchema: page(
        GroupRecord.self, group, FieldDocs.GroupPage.items, FieldDocs.GroupPage.totalCount)),
    Tool(
      name: ToolName.groupsGet.rawValue,
      description:
        "Read one group by identifier; returns null when absent. List its members with contacts_search and filter.groupIdentifiers.",
      inputSchema: byID("group"), annotations: annotations,
      outputSchema: schema(
        GroupOutput.CodingKeys.self,
        [.group: describe(nullable(group), "The group, or null when absent.")],
        required: [.group])),
    Tool(
      name: ToolName.groupsCreate.rawValue, description: FieldDocs.GroupInput.create,
      inputSchema: schema(
        CreateGroupInput.CodingKeys.self,
        [
          .name: describe(string, FieldDocs.GroupInput.name),
          .containerIdentifier: describe(string, FieldDocs.GroupInput.containerIdentifier),
        ], required: [.name]),
      annotations: created, outputSchema: groupResult),
    Tool(
      name: ToolName.groupsUpdate.rawValue, description: FieldDocs.GroupInput.update,
      inputSchema: schema(
        PatchArguments<GroupPatch>.CodingKeys.self,
        [
          .id: describe(string, "Identifier of the group."),
          .patch: schema(
            GroupPatch.CodingKeys.self, [.name: describe(string, FieldDocs.GroupInput.name)],
            required: [.name]),
        ], required: [.id, .patch]),
      annotations: replaced, outputSchema: groupResult),
    Tool(
      name: ToolName.groupsDelete.rawValue, description: FieldDocs.GroupInput.delete,
      inputSchema: byID("group"), annotations: changed,
      outputSchema: schema(
        DeletedGroup.CodingKeys.self,
        [.deletedId: describe(string, FieldDocs.Write.deletedId)], required: [.deletedId])),
    Tool(
      name: ToolName.groupsAddMembers.rawValue, description: FieldDocs.GroupInput.addMembers,
      inputSchema: members, annotations: added, outputSchema: groupResult),
    Tool(
      name: ToolName.groupsRemoveMembers.rawValue,
      description: FieldDocs.GroupInput.removeMembers,
      inputSchema: members, annotations: replaced, outputSchema: groupResult),
    Tool(
      name: ToolName.containersList.rawValue,
      description:
        "Read the containers Contacts stores cards in: one or more per account, such as iCloud or an Exchange folder.",
      inputSchema: noArguments, annotations: annotations,
      outputSchema: schema(
        ContainersOutput.CodingKeys.self,
        [.containers: describe(array(container), "Every container, by identifier.")],
        required: [.containers])),
    Tool(
      name: ToolName.defaultsGet.rawValue,
      description: "Read the container new cards go to and the identifier of the user's own card.",
      inputSchema: noArguments, annotations: annotations,
      outputSchema: schema(
        Defaults.CodingKeys.self,
        [
          .defaultContainerIdentifier: describe(
            string, FieldDocs.Defaults.defaultContainerIdentifier),
          .meContactIdentifier: describe(string, FieldDocs.Defaults.meContactIdentifier),
        ], required: [.defaultContainerIdentifier])),
  ]
}
// MCP inputs omit optional values; an explicit null anywhere is invalid.
private func rejectNulls(_ value: Value) throws {
  switch value {
  case .null: throw ServerError.invalidArgument("Omit optional MCP inputs instead of sending null")
  case .object(let object): for value in object.values { try rejectNulls(value) }
  case .array(let array): for value in array { try rejectNulls(value) }
  default: break
  }
}
private func result<T: Encodable>(_ value: T) throws -> CallTool.Result {
  let bytes = try JSONEncoder().encode(value)
  return try .init(
    content: [.text(text: String(decoding: bytes, as: UTF8.self), annotations: nil, _meta: nil)],
    structuredContent: try JSONDecoder().decode(Value.self, from: bytes), isError: false)
}
// Tool names are the MCP contract; the catalog and dispatch both use these cases.
enum ToolName: String {
  case contactsCreate = "contacts_create"
  case contactsDelete = "contacts_delete"
  case contactsGet = "contacts_get"
  case contactsSearch = "contacts_search"
  case contactsSetMe = "contacts_set_me"
  case contactsShow = "contacts_show"
  case contactsSummary = "contacts_summary"
  case contactsUpdate = "contacts_update"
  case containersList = "containers_list"
  case defaultsGet = "defaults_get"
  case groupsAddMembers = "groups_add_members"
  case groupsCreate = "groups_create"
  case groupsDelete = "groups_delete"
  case groupsGet = "groups_get"
  case groupsList = "groups_list"
  case groupsRemoveMembers = "groups_remove_members"
  case groupsUpdate = "groups_update"
}
private func callTool(_ tool: ToolName, _ params: CallTool.Parameters) async throws
  -> CallTool.Result
{
  let args = params.arguments ?? [:]
  try rejectNulls(.object(args))
  func arguments<T: Decodable>(_ type: T.Type) throws -> T { try decodeInput(type, from: args) }
  func noArguments() throws {
    guard args.isEmpty else { throw ServerError.invalidArgument("Unknown input field") }
  }
  // The page at the cursor offset; nextCursor is the following page's offset, and the
  // client keeps the criteria unchanged.
  func page<Item: Encodable>(
    _ items: [Item], limit: Int?, cursor: String?
  ) throws -> PageOutput<Item> {
    let limit = limit ?? 50
    guard (1...100).contains(limit) else {
      throw ServerError.invalidArgument("limit must be 1...100")
    }
    let offset =
      try cursor.map { token in
        guard let value = Int(token), value >= 0 else {
          throw ServerError.invalidArgument(
            "cursor must be a nextCursor string from the previous response. Omit cursor for the first page."
          )
        }
        return value
      } ?? 0
    let pageItems = Array(items.dropFirst(offset).prefix(limit))
    let end = offset + pageItems.count
    return PageOutput(
      items: pageItems, totalCount: items.count, nextCursor: end < items.count ? String(end) : nil)
  }
  // The picture is set through GraphQL; the tools' schemas do not declare it.
  func rejectPicture(_ fields: [String: Value]) throws {
    guard fields[ContactInputKey.imageData.stringValue] == nil else {
      throw ServerError.invalidArgument("Unknown input field")
    }
  }
  func written(_ write: ContactWrite) async throws -> CallTool.Result {
    try result(ContactOutput(contact: MCPContact(written: try await writeContact(write))))
  }
  func members(_ write: (String, [String]) -> GroupWrite) async throws -> CallTool.Result {
    let request = try arguments(MembersArguments.self)
    let cards = try memberIdentifiers(request.contactIdentifiers)
    return try result(GroupOutput(group: try await writeGroup(write(request.id, cards))))
  }
  switch tool {
  case .contactsSearch:
    let request = try arguments(ContactSearchArguments.self)
    // Check paging before the read, so a bad limit or cursor does not cost one.
    _ = try page([Int](), limit: request.limit, cursor: request.cursor)
    let search = request.search
    let included = Set(request.include ?? [])
    let extras = try await readExtras(search.requiredExtras.union(included))
    let items = try search.contacts(try await readContactsData(), extras: extras)
    return try result(
      page(
        items.map { MCPContact(record: $0, extras: extras, include: included) },
        limit: request.limit, cursor: request.cursor))
  case .contactsGet:
    let request = try arguments(ContactGetArguments.self)
    let included = Set(request.include ?? [])
    guard let card = try await readContactsData().contact(id: request.id) else {
      return try result(ContactOutput(contact: nil))
    }
    let extras = try await readExtras(included)
    return try result(
      ContactOutput(contact: MCPContact(record: card, extras: extras, include: included)))
  case .contactsCreate:
    try rejectPicture(args)
    return try await written(.create(try arguments(CreateContactInput.self).changes))
  case .contactsUpdate:
    if case .object(let patch)? = args[PatchArguments<ContactPatch>.CodingKeys.patch.stringValue] {
      try rejectPicture(patch)
    }
    let update = try arguments(PatchArguments<ContactPatch>.self)
    return try await written(.update(id: update.id, update.patch.changes))
  case .contactsDelete:
    let id = try arguments(IDArguments.self).id
    return try result(try await deleteContact(id: id, includeImage: false))
  case .contactsSetMe:
    let id = try arguments(IDArguments.self).id
    return try result(ContactOutput(contact: MCPContact(record: try await setMeContact(id: id))))
  case .contactsShow:
    let id = try arguments(IDArguments.self).id
    return try result(ContactOutput(contact: MCPContact(record: try await showContact(id: id))))
  case .contactsSummary:
    try noArguments()
    return try result(ContactsSummary(await readContactsData()))
  case .groupsList:
    let request = try arguments(GroupSearchArguments.self)
    _ = try page([Int](), limit: request.limit, cursor: request.cursor)
    return try result(
      page(
        request.search.groups(await readContactsData()), limit: request.limit,
        cursor: request.cursor))
  case .groupsGet:
    let id = try arguments(IDArguments.self).id
    return try result(GroupOutput(group: await readContactsData().group(id: id)))
  case .groupsCreate:
    let input = try arguments(CreateGroupInput.self)
    return try result(
      GroupOutput(
        group: try await writeGroup(
          .create(name: input.name, containerIdentifier: input.containerIdentifier))))
  case .groupsUpdate:
    let update = try arguments(PatchArguments<GroupPatch>.self)
    return try result(
      GroupOutput(group: try await writeGroup(.rename(id: update.id, name: update.patch.name))))
  case .groupsDelete:
    let id = try arguments(IDArguments.self).id
    return try result(try await deleteGroup(id: id))
  case .groupsAddMembers:
    return try await members { .addMembers(id: $0, contactIdentifiers: $1) }
  case .groupsRemoveMembers:
    return try await members { .removeMembers(id: $0, contactIdentifiers: $1) }
  case .containersList:
    try noArguments()
    return try result(ContainersOutput(containers: await readContactsData().containers))
  case .defaultsGet:
    try noArguments()
    return try result(Defaults(await readContactsData()))
  }
}
private let tools = toolsCatalog()
// A tool without readOnlyHint requires write access.
private let readOnlyTools = Set(tools.filter { $0.annotations.readOnlyHint == true }.map(\.name))

func mcpToolsJSON() throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return String(decoding: try encoder.encode(ListTools.Result(tools: tools)), as: UTF8.self)
}

// Tool errors are JSON like successful results, with the code clients act on.
private struct ToolError: Encodable {
  struct Body: Encodable {
    let code: ErrorCode
    let message: String
  }
  let error: Body
}
private func errorText(_ error: Error) -> String {
  let server = error as? ServerError
  let payload = ToolError(
    error: .init(
      code: server?.code ?? .internalError, message: server?.message ?? String(describing: error)))
  // Sorted keys put code before message; JSONEncoder does not keep declaration order.
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  // A code and a message are plain strings, which always encode.
  return String(decoding: try! encoder.encode(payload), as: UTF8.self)
}

// The JSON-RPC method of a request body, for logging.
private func jsonRPCMethod(_ body: Data) -> String {
  switch try? JSONDecoder().decode(RPCEnvelope.self, from: body) {
  case .message(let method?, _): method
  case .batch: "batch"
  default: "unknown"
  }
}
// The JSON-RPC envelope fields the server logs; params and results stay undecoded.
private enum RPCEnvelope: Decodable {
  case message(method: String?, hasError: Bool)
  case batch
  enum CodingKeys: String, CodingKey { case method, error }
  init(from decoder: Decoder) throws {
    guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
      _ = try decoder.unkeyedContainer()
      self = .batch
      return
    }
    self = .message(
      method: try? c.decode(String.self, forKey: .method), hasError: c.contains(.error))
  }
}

// Records the tool outcome so the logger need not reparse large result bodies.
private final class ToolOutcome: @unchecked Sendable {
  var ran = false
  var failed = false
}
@Sendable func handleMCP(
  method: HTTPMethod, headers: [String: String], body: Data,
  access: Capabilities.Access
) async throws -> ServiceResponse {
  let outcome = ToolOutcome()
  // Each HTTP request has isolated SDK protocol state, permitting independent clients.
  // The HTTP listener enforces Origin policy for all endpoints.
  let transport = StatelessHTTPServerTransport(
    validationPipeline: StandardValidationPipeline(validators: [
      AcceptHeaderValidator(mode: .jsonOnly),
      ContentTypeValidator(),
      ProtocolVersionValidator(),
    ]))
  let server = Server(
    name: "apple-contacts-server", version: "0.0.0",
    capabilities: .init(tools: .init(listChanged: false)))
  await server.withMethodHandler(ListTools.self) { params in
    guard params.cursor == nil else { throw MCPError.invalidParams("Tool catalog has no cursor") }
    outcome.ran = true
    return .init(tools: tools)
  }
  await server.withMethodHandler(CallTool.self) { params in
    guard let tool = ToolName(rawValue: params.name) else {
      throw MCPError.invalidParams("Unknown tool")
    }
    outcome.ran = true
    guard access == .write || (access == .read && readOnlyTools.contains(params.name)) else {
      outcome.failed = true
      return .init(
        content: [
          .text(text: "Forbidden: MCP write access required", annotations: nil, _meta: nil)
        ], isError: true)
    }
    do { return try await callTool(tool, params) } catch {
      outcome.failed = true
      return .init(
        content: [.text(text: errorText(error), annotations: nil, _meta: nil)], isError: true)
    }
  }
  do { try await server.start(transport: transport) } catch {
    await server.stop()
    throw error
  }
  let response = await transport.handleRequest(
    .init(method: method.rawValue, headers: headers, body: body, path: Route.mcp.rawValue))
  await server.stop()
  let responseBody = response.bodyData ?? Data()
  var failure: Failure? = outcome.failed ? .mcpTool : nil
  // Protocol replies (no tool or catalog handler ran) report errors in the JSON-RPC body.
  if !outcome.ran,
    case .message(_, hasError: true)? = try? JSONDecoder().decode(
      RPCEnvelope.self, from: responseBody)
  {
    failure = .mcpProtocol
  }
  var headers = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
  if !headers.contains(name: "Content-Type") {
    headers.add(name: "Content-Type", value: "application/json")
  }
  return ServiceResponse(
    status: .init(statusCode: response.statusCode), headers: headers, body: responseBody,
    failure: failure,
    logMetadata: method == .POST ? ["rpc": jsonRPCMethod(body)] : [:])
}
