import Foundation
import GraphQL

// A write can change what this request already read, so the request's cached reads are
// dropped afterward, whether or not it succeeded.
private func afterWrite<T: Sendable>(
  _ context: (any Sendable)?, _ write: () async throws -> T
) async throws -> T {
  let value: T
  do { value = try await write() } catch {
    await (context as? GraphQLContext)?.invalidate()
    throw error
  }
  await (context as? GraphQLContext)?.invalidate()
  return value
}

// An input object's fields, named by the coding keys its decoder reads, in schema order.
private func inputFields<Key: CodingKey>(
  _: Key.Type, _ fields: KeyValuePairs<Key, InputObjectField>
) -> InputObjectFieldMap {
  InputObjectFieldMap(uniqueKeysWithValues: fields.map { ($0.key.stringValue, $0.value) })
}
// A patch names what to remove in clearFields, so null is never a value.
private func rejectNulls(_ value: Map) throws {
  switch value {
  case .null: throw ServerError.invalidArgument("patch values cannot be null; use clearFields")
  case .array(let items): for item in items { try rejectNulls(item) }
  case .dictionary(let fields): for item in fields.values { try rejectNulls(item) }
  default: break
  }
}

func makeMutationType(
  contact: GraphQLObjectType, group: GraphQLObjectType, contactType: GraphQLEnumType,
  contactKey: GraphQLEnumType
) throws -> GraphQLObjectType {
  typealias Docs = FieldDocs.Contact
  typealias Input = FieldDocs.ContactInput
  func text(_ description: String) -> InputObjectField {
    InputObjectField(type: GraphQLString, description: description)
  }
  let ids = GraphQLList(GraphQLNonNull(GraphQLID))

  // Value inputs, shaped like the values a card returns.
  let phoneNumber = try GraphQLInputObjectType(
    name: "PhoneNumberInput",
    fields: inputFields(
      PhoneNumberInput.CodingKeys.self,
      [
        .stringValue: InputObjectField(
          type: GraphQLNonNull(GraphQLString), description: FieldDocs.PhoneNumber.stringValue)
      ]))
  let postalAddress = try GraphQLInputObjectType(
    name: "PostalAddressInput",
    description: "A postal address. In an update, a part that is present replaces the stored one.",
    fields: inputFields(
      PostalAddressInput.CodingKeys.self,
      [
        .street: text(FieldDocs.PostalAddress.street),
        .subLocality: text(FieldDocs.PostalAddress.subLocality),
        .city: text(FieldDocs.PostalAddress.city),
        .subAdministrativeArea: text(FieldDocs.PostalAddress.subAdministrativeArea),
        .state: text(FieldDocs.PostalAddress.state),
        .postalCode: text(FieldDocs.PostalAddress.postalCode),
        .country: text(FieldDocs.PostalAddress.country),
        .isoCountryCode: text(FieldDocs.PostalAddress.isoCountryCode),
      ]))
  let socialProfile = try GraphQLInputObjectType(
    name: "SocialProfileInput",
    description: "A social profile; it needs a username or a urlString.",
    fields: inputFields(
      SocialProfileInput.CodingKeys.self,
      [
        .urlString: text(FieldDocs.SocialProfile.urlString),
        .username: text(FieldDocs.SocialProfile.username),
        .userIdentifier: text(FieldDocs.SocialProfile.userIdentifier),
        .service: text(FieldDocs.SocialProfile.service),
      ]))
  let instantMessageAddress = try GraphQLInputObjectType(
    name: "InstantMessageAddressInput",
    description: "An instant message address; it needs a username.",
    fields: inputFields(
      InstantMessageAddressInput.CodingKeys.self,
      [
        .username: text(FieldDocs.InstantMessageAddress.username),
        .service: text(FieldDocs.InstantMessageAddress.service),
      ]))
  let contactRelation = try GraphQLInputObjectType(
    name: "ContactRelationInput",
    fields: inputFields(
      ContactRelationInput.CodingKeys.self,
      [
        .name: InputObjectField(
          type: GraphQLNonNull(GraphQLString), description: FieldDocs.ContactRelation.name)
      ]))
  let dateComponents = try GraphQLInputObjectType(
    name: "DateComponentsInput", description: "A day that may have no year.",
    fields: inputFields(
      DateComponentsInput.CodingKeys.self,
      [
        .calendar: text(FieldDocs.DateComponents.calendar),
        .era: InputObjectField(type: GraphQLInt, description: FieldDocs.DateComponents.era),
        .year: InputObjectField(type: GraphQLInt, description: FieldDocs.DateComponents.year),
        .month: InputObjectField(
          type: GraphQLNonNull(GraphQLInt), description: FieldDocs.DateComponents.month),
        .day: InputObjectField(
          type: GraphQLNonNull(GraphQLInt), description: FieldDocs.DateComponents.day),
        .isLeapMonth: InputObjectField(
          type: GraphQLBoolean, description: FieldDocs.DateComponents.isLeapMonth),
      ]))

  // For each kind of value: a new entry, a change to one entry, and the changes to a list.
  func entries(_ name: String, _ value: any GraphQLInputType & GraphQLNullableType) throws
    -> (list: GraphQLInputType, changes: GraphQLInputType)
  {
    let add = try GraphQLInputObjectType(
      name: "Labeled\(name)Input",
      fields: inputFields(
        LabeledEntryKey.self,
        [
          .label: text(Input.label),
          .value: InputObjectField(
            type: GraphQLNonNull(value), description: FieldDocs.LabeledValue.value),
        ]))
    let update = try GraphQLInputObjectType(
      name: "Labeled\(name)Update",
      fields: inputFields(
        LabeledEntryKey.self,
        [
          .identifier: InputObjectField(
            type: GraphQLNonNull(GraphQLID), description: Input.entryIdentifier),
          .label: text(Input.label),
          .value: InputObjectField(type: value, description: FieldDocs.LabeledValue.value),
        ]))
    let added = GraphQLList(GraphQLNonNull(add))
    let changes = try GraphQLInputObjectType(
      name: "Labeled\(name)Changes", description: Input.changes,
      fields: inputFields(
        LabeledOperationKey.self,
        [
          .add: InputObjectField(type: added, description: Input.add),
          .update: InputObjectField(
            type: GraphQLList(GraphQLNonNull(update)), description: Input.updateEntries),
          .remove: InputObjectField(type: ids, description: Input.remove),
        ]))
    return (added, changes)
  }
  let strings = try entries("String", GraphQLString)
  let lists: [(ContactInputKey, (list: GraphQLInputType, changes: GraphQLInputType), String)] = [
    (.phoneNumbers, try entries("PhoneNumber", phoneNumber), Docs.phoneNumbers),
    (.emailAddresses, strings, Docs.emailAddresses),
    (.postalAddresses, try entries("PostalAddress", postalAddress), Docs.postalAddresses),
    (.urlAddresses, strings, Docs.urlAddresses),
    (.contactRelations, try entries("ContactRelation", contactRelation), Docs.contactRelations),
    (.socialProfiles, try entries("SocialProfile", socialProfile), Docs.socialProfiles),
    (
      .instantMessageAddresses, try entries("InstantMessageAddress", instantMessageAddress),
      Docs.instantMessageAddresses
    ),
    (.dates, try entries("DateComponents", dateComponents), Docs.dates),
  ]
  // Fields a create input and a patch share; lists differ in shape.
  func contactFields(creating: Bool) -> InputObjectFieldMap {
    var fields: [(ContactInputKey, InputObjectField)] = [
      (.contactType, InputObjectField(type: contactType, description: Docs.contactType)),
      (.namePrefix, text(Docs.namePrefix)), (.givenName, text(Docs.givenName)),
      (.middleName, text(Docs.middleName)), (.familyName, text(Docs.familyName)),
      (.previousFamilyName, text(Docs.previousFamilyName)),
      (.nameSuffix, text(Docs.nameSuffix)), (.nickname, text(Docs.nickname)),
      (.phoneticGivenName, text(Docs.phoneticGivenName)),
      (.phoneticMiddleName, text(Docs.phoneticMiddleName)),
      (.phoneticFamilyName, text(Docs.phoneticFamilyName)),
      (.phoneticOrganizationName, text(Docs.phoneticOrganizationName)),
      (.organizationName, text(Docs.organizationName)),
      (.departmentName, text(Docs.departmentName)), (.jobTitle, text(Docs.jobTitle)),
    ]
    for (key, types, description) in lists {
      fields.append(
        (
          key,
          InputObjectField(
            type: creating ? types.list : types.changes,
            description: "\(description) \(creating ? Input.list : Input.changes)")
        ))
    }
    fields += [
      (.birthday, InputObjectField(type: dateComponents, description: Input.birthday)),
      (
        .nonGregorianBirthday,
        InputObjectField(type: dateComponents, description: Input.nonGregorianBirthday)
      ),
      (.note, text(Input.note)), (.imageData, text(Input.imageData)),
    ]
    if creating {
      fields += [
        (
          .containerIdentifier,
          InputObjectField(type: GraphQLID, description: Input.containerIdentifier)
        ),
        (.groupIdentifiers, InputObjectField(type: ids, description: Input.groupIdentifiers)),
      ]
    } else {
      fields.append(
        (
          .clearFields,
          InputObjectField(
            type: GraphQLList(GraphQLNonNull(contactKey)), description: Input.clearFields)
        ))
    }
    return InputObjectFieldMap(uniqueKeysWithValues: fields.map { ($0.0.stringValue, $0.1) })
  }
  let createContactInput = try GraphQLInputObjectType(
    name: "CreateContactInput", fields: contactFields(creating: true))
  let contactPatch = try GraphQLInputObjectType(
    name: "ContactPatch", fields: contactFields(creating: false))
  let createGroupInput = try GraphQLInputObjectType(
    name: "CreateGroupInput",
    fields: inputFields(
      CreateGroupInput.CodingKeys.self,
      [
        .name: InputObjectField(
          type: GraphQLNonNull(GraphQLString), description: FieldDocs.GroupInput.name),
        .containerIdentifier: InputObjectField(
          type: GraphQLID, description: FieldDocs.GroupInput.containerIdentifier),
      ]))
  let groupPatch = try GraphQLInputObjectType(
    name: "GroupPatch",
    fields: inputFields(
      GroupPatch.CodingKeys.self,
      [
        .name: InputObjectField(
          type: GraphQLNonNull(GraphQLString), description: FieldDocs.GroupInput.name)
      ]))
  let deletedContact = try GraphQLObjectType(
    name: "DeleteContactResult",
    fields: [
      "deletedId": field(
        GraphQLNonNull(GraphQLID), \DeletedContact.deletedId,
        description: FieldDocs.Write.deletedId),
      "vCard": field(
        GraphQLNonNull(GraphQLString), \DeletedContact.vCard,
        description: FieldDocs.Write.deletedVCard),
    ])
  let deleted = try GraphQLObjectType(
    name: "DeleteResult",
    fields: [
      "deletedId": field(
        GraphQLNonNull(GraphQLID), \DeletedGroup.deletedId, description: FieldDocs.Write.deletedId)
    ])
  let idArg: GraphQLArgumentConfigMap = ["id": GraphQLArgument(type: GraphQLNonNull(GraphQLID))]
  func members(_ description: String, _ write: @escaping @Sendable (String, [String]) -> GroupWrite)
    -> GraphQLField
  {
    GraphQLField(
      type: group, description: description,
      args: [
        "id": GraphQLArgument(type: GraphQLNonNull(GraphQLID)),
        "contactIdentifiers": GraphQLArgument(
          type: GraphQLNonNull(GraphQLList(GraphQLNonNull(GraphQLID))),
          description: FieldDocs.GroupInput.contactIdentifiers),
      ],
      resolve: { _, args, context, _ in
        let arguments = try decodeInput(GraphQLMembersArguments.self, from: args)
        let cards = try memberIdentifiers(arguments.contactIdentifiers)
        return try await afterWrite(context) {
          try await writeGroup(write(arguments.id, cards))
        }
      })
  }
  return try GraphQLObjectType(
    name: "Mutation",
    fields: [
      "createContact": GraphQLField(
        type: contact, description: Input.create,
        args: ["input": GraphQLArgument(type: GraphQLNonNull(createContactInput))],
        resolve: { _, args, context, _ in
          let create = try decodeInput(
            GraphQLCreateArguments<CreateContactInput>.self, from: args)
          return try await afterWrite(context) {
            try await writeContact(.create(create.input.changes)).record
          }
        }),
      "updateContact": GraphQLField(
        type: contact, description: Input.update,
        args: [
          "id": GraphQLArgument(type: GraphQLNonNull(GraphQLID)),
          "patch": GraphQLArgument(type: GraphQLNonNull(contactPatch), description: Input.patch),
        ],
        resolve: { _, args, context, _ in
          try rejectNulls(args["patch"])
          let update = try decodeInput(GraphQLPatchArguments<ContactPatch>.self, from: args)
          return try await afterWrite(context) {
            try await writeContact(.update(id: update.id, update.patch.changes)).record
          }
        }),
      "deleteContact": GraphQLField(
        type: deletedContact, description: FieldDocs.Write.deleteContact, args: idArg,
        resolve: { _, args, context, _ in
          let id = try decodeInput(GraphQLIDArguments.self, from: args).id
          return try await afterWrite(context) {
            try await deleteContact(id: id, includeImage: true)
          }
        }),
      "createGroup": GraphQLField(
        type: group, description: FieldDocs.GroupInput.create,
        args: ["input": GraphQLArgument(type: GraphQLNonNull(createGroupInput))],
        resolve: { _, args, context, _ in
          let input = try decodeInput(GraphQLCreateArguments<CreateGroupInput>.self, from: args)
            .input
          return try await afterWrite(context) {
            try await writeGroup(
              .create(name: input.name, containerIdentifier: input.containerIdentifier))
          }
        }),
      "updateGroup": GraphQLField(
        type: group, description: FieldDocs.GroupInput.update,
        args: [
          "id": GraphQLArgument(type: GraphQLNonNull(GraphQLID)),
          "patch": GraphQLArgument(type: GraphQLNonNull(groupPatch)),
        ],
        resolve: { _, args, context, _ in
          let update = try decodeInput(GraphQLPatchArguments<GroupPatch>.self, from: args)
          return try await afterWrite(context) {
            try await writeGroup(.rename(id: update.id, name: update.patch.name))
          }
        }),
      "deleteGroup": GraphQLField(
        type: deleted, description: FieldDocs.GroupInput.delete, args: idArg,
        resolve: { _, args, context, _ in
          let id = try decodeInput(GraphQLIDArguments.self, from: args).id
          return try await afterWrite(context) { try await deleteGroup(id: id) }
        }),
      "addGroupMembers": members(FieldDocs.GroupInput.addMembers) {
        .addMembers(id: $0, contactIdentifiers: $1)
      },
      "removeGroupMembers": members(FieldDocs.GroupInput.removeMembers) {
        .removeMembers(id: $0, contactIdentifiers: $1)
      },
      "setMeContact": GraphQLField(
        type: contact, description: FieldDocs.Write.setMe, args: idArg,
        resolve: { _, args, context, _ in
          let id = try decodeInput(GraphQLIDArguments.self, from: args).id
          return try await afterWrite(context) { try await setMeContact(id: id) }
        }),
      "showContact": GraphQLField(
        type: contact, description: FieldDocs.Write.show, args: idArg,
        resolve: { _, args, _, _ in
          let id = try decodeInput(GraphQLIDArguments.self, from: args).id
          return try await showContact(id: id)
        }),
    ])
}
