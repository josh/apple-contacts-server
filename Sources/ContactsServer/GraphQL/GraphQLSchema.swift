import Foundation
import GraphQL

// Resolvers receive the Swift record their parent field returned.
func record<Source>(_ source: any Sendable, as _: Source.Type) throws -> Source {
  guard let value = source as? Source else {
    throw ServerError.internalError("Unexpected GraphQL source; expected \(Source.self)")
  }
  return value
}
func field<Source, Value: Sendable>(
  _ type: GraphQLOutputType, _ value: @escaping @Sendable (Source) throws -> Value,
  description: String? = nil
) -> GraphQLField {
  GraphQLField(
    type: type, description: description,
    resolve: { source, _, _, _ in try value(record(source, as: Source.self)) })
}
func requestContext(_ context: (any Sendable)?) throws -> GraphQLContext {
  guard let context = context as? GraphQLContext else {
    throw ServerError.internalError("Missing GraphQL request context")
  }
  return context
}
private func contacts(_ context: (any Sendable)?) async throws -> ContactsData {
  try await requestContext(context).contacts()
}
struct PageInfo: Sendable {
  let offset, limit: Int
  let hasNextPage, hasPreviousPage: Bool
}
struct GraphQLPage<Item: Sendable>: Sendable {
  let items: [Item]
  let totalCount: Int
  let pageInfo: PageInfo
}
func page<Item: Sendable>(_ values: [Item], limit: Int, offset: Int) throws -> GraphQLPage<Item> {
  guard (1...100).contains(limit), offset >= 0 else {
    throw ServerError.invalidArgument("limit must be 1...100 and offset must be nonnegative")
  }
  let start = min(offset, values.count)
  let end = min(start + limit, values.count)
  return GraphQLPage(
    items: Array(values[start..<end]), totalCount: values.count,
    pageInfo: PageInfo(
      offset: offset, limit: limit, hasNextPage: end < values.count,
      hasPreviousPage: offset > 0 && !values.isEmpty))
}
private func contactPage(args: Map, context: (any Sendable)?, groupID: String? = nil)
  async throws -> GraphQLPage<ContactRecord>
{
  let arguments = try decodeInput(GraphQLContactSearch.self, from: args)
  let search = arguments.search
  let request = try requestContext(context)
  // Scripting-only fields are read only for a search that filters or sorts by them.
  let extras = try await request.extras(search.requiredExtras)
  return try page(
    search.contacts(try await request.contacts(), extras: extras, groupID: groupID),
    limit: arguments.limit, offset: arguments.offset)
}

// One cache per HTTP execution, shared by item fields and root aliases. A Task
// caches failures as well as successes and coalesces concurrent resolver calls.
actor GraphQLContext {
  func invalidate() {
    data = nil
    notes = nil
    creationDates = nil
    modificationDates = nil
  }
  private var data: Task<ContactsData, Error>?
  func contacts() async throws -> ContactsData {
    if data == nil { data = Task { try await readContactsData() } }
    return try await data!.value
  }
  // Scripting-only fields are read for every card at once, the first time a query
  // selects them.
  private var notes: Task<[String: String?], Error>?
  private var creationDates, modificationDates: Task<[String: Date?], Error>?
  func extras(_ fields: Set<ExtraField>) async throws -> ContactExtras {
    var extras = ContactExtras()
    if fields.contains(.note) {
      if notes == nil { notes = Task { try await readProperty(.notes) } }
      extras.notes = try await notes!.value
    }
    if fields.contains(.creationDate) {
      if creationDates == nil { creationDates = Task { try await readProperty(.creationDates) } }
      extras.creationDates = try await creationDates!.value
    }
    if fields.contains(.modificationDate) {
      if modificationDates == nil {
        modificationDates = Task { try await readProperty(.modificationDates) }
      }
      extras.modificationDates = try await modificationDates!.value
    }
    return extras
  }
}

func makeSchema() throws -> GraphQLSchema {
  func enumeration(_ name: String, _ values: [String], descriptions: [String: String] = [:])
    throws -> GraphQLEnumType
  {
    try GraphQLEnumType(
      name: name,
      values: GraphQLEnumValueMap(
        uniqueKeysWithValues: values.map {
          ($0, GraphQLEnumValue(value: .string($0), description: descriptions[$0]))
        }))
  }
  let identifier = GraphQLNonNull(GraphQLID)
  let identifiers = GraphQLNonNull(GraphQLList(GraphQLNonNull(GraphQLID)))
  let dateTime = try GraphQLScalarType(
    name: "DateTime", description: "RFC 3339 timestamp with an explicit offset, serialized in UTC.",
    // Every output date comes from timestamp() and is already canonical UTC.
    serialize: { value in
      guard let text = value as? String else {
        throw ServerError.internalError("DateTime output is not a string")
      }
      return .string(text)
    },
    parseValue: { value in
      _ = try parseTimestamp(value.stringValue())
      return value
    },
    parseLiteral: { node in
      let value = try valueFromASTUntyped(valueAST: node)
      _ = try parseTimestamp(value.stringValue())
      return value
    })
  let contactType = try enumeration(
    "ContactType", ContactType.allCases.map(\.rawValue),
    descriptions: [
      "PERSON": "A person.", "ORGANIZATION": "A card shown by its company name.",
    ])
  let containerType = try enumeration(
    "ContainerType", ContainerType.allCases.map(\.rawValue),
    descriptions: [
      "UNASSIGNED": "The store does not say.", "LOCAL": "On My Mac.",
      "EXCHANGE": "An Exchange folder.",
      "CARD_DAV": "A CardDAV address book, which is how iCloud appears.",
    ])
  let direction = try enumeration(
    "SortDirection", SortDirection.allCases.map(\.rawValue),
    descriptions: ["ASC": "Smallest or earliest first.", "DESC": "Largest or latest first."])
  let contactSortField = try enumeration(
    "ContactSortField", ContactSortField.allCases.map(\.rawValue),
    descriptions: [
      "USER_DEFAULT": "The name order chosen in Contacts settings.",
      "GIVEN_NAME": "First name, then last name; a card without a name sorts by organization.",
      "FAMILY_NAME": "Last name, then first name; a card without a name sorts by organization.",
      "ORGANIZATION_NAME": "The organization, ignoring case and accents.",
      "BIRTHDAY": "Month and day of the birthday, then year.",
      "CREATION_DATE": "When the card was created; read from Contacts through scripting.",
      "MODIFICATION_DATE": "When the card last changed; read from Contacts through scripting.",
    ])
  let contactKey = try enumeration(
    "ContactKey", ContactKey.allCases.map(\.rawValue),
    descriptions: [
      "IMAGE_DATA": "The card's picture.",
      "NOTE": "The note, which only Contacts scripting provides.",
    ])

  // Value types of the multi-value properties.
  func text<Source>(_ value: KeyPath<Source, String?> & Sendable, _ description: String)
    -> GraphQLField
  {
    field(GraphQLString, { (source: Source) in source[keyPath: value] }, description: description)
  }
  let phoneNumber = try GraphQLObjectType(
    name: "PhoneNumber", description: "A phone number, as CNPhoneNumber.",
    fields: [
      "stringValue": field(
        GraphQLNonNull(GraphQLString), \PhoneNumberValue.stringValue,
        description: FieldDocs.PhoneNumber.stringValue)
    ])
  let postalAddress = try GraphQLObjectType(
    name: "PostalAddress", description: "A postal address, as CNPostalAddress.",
    fields: [
      "street": text(\PostalAddressValue.street, FieldDocs.PostalAddress.street),
      "subLocality": text(\PostalAddressValue.subLocality, FieldDocs.PostalAddress.subLocality),
      "city": text(\PostalAddressValue.city, FieldDocs.PostalAddress.city),
      "subAdministrativeArea": text(
        \PostalAddressValue.subAdministrativeArea, FieldDocs.PostalAddress.subAdministrativeArea),
      "state": text(\PostalAddressValue.state, FieldDocs.PostalAddress.state),
      "postalCode": text(\PostalAddressValue.postalCode, FieldDocs.PostalAddress.postalCode),
      "country": text(\PostalAddressValue.country, FieldDocs.PostalAddress.country),
      "isoCountryCode": text(
        \PostalAddressValue.isoCountryCode, FieldDocs.PostalAddress.isoCountryCode),
    ])
  let socialProfile = try GraphQLObjectType(
    name: "SocialProfile", description: "A social profile, as CNSocialProfile.",
    fields: [
      "urlString": text(\SocialProfileValue.urlString, FieldDocs.SocialProfile.urlString),
      "username": text(\SocialProfileValue.username, FieldDocs.SocialProfile.username),
      "userIdentifier": text(
        \SocialProfileValue.userIdentifier, FieldDocs.SocialProfile.userIdentifier),
      "service": text(\SocialProfileValue.service, FieldDocs.SocialProfile.service),
    ])
  let instantMessageAddress = try GraphQLObjectType(
    name: "InstantMessageAddress",
    description: "An instant message address, as CNInstantMessageAddress.",
    fields: [
      "username": text(
        \InstantMessageAddressValue.username, FieldDocs.InstantMessageAddress.username),
      "service": text(\InstantMessageAddressValue.service, FieldDocs.InstantMessageAddress.service),
    ])
  let contactRelation = try GraphQLObjectType(
    name: "ContactRelation", description: "A related person, as CNContactRelation.",
    fields: [
      "name": field(
        GraphQLNonNull(GraphQLString), \ContactRelationValue.name,
        description: FieldDocs.ContactRelation.name)
    ])
  func part(_ value: KeyPath<DateComponentsValue, Int?> & Sendable, _ description: String)
    -> GraphQLField
  {
    field(
      GraphQLInt, { (date: DateComponentsValue) in date[keyPath: value] },
      description: description)
  }
  let dateComponents = try GraphQLObjectType(
    name: "DateComponents",
    description: "A day as Contacts stores it, which may have no year; as NSDateComponents.",
    fields: [
      "calendar": text(\DateComponentsValue.calendar, FieldDocs.DateComponents.calendar),
      "era": part(\.era, FieldDocs.DateComponents.era),
      "year": part(\.year, FieldDocs.DateComponents.year),
      "month": part(\.month, FieldDocs.DateComponents.month),
      "day": part(\.day, FieldDocs.DateComponents.day),
      "isLeapMonth": field(
        GraphQLBoolean, \DateComponentsValue.isLeapMonth,
        description: FieldDocs.DateComponents.isLeapMonth),
    ])
  // One CNLabeledValue type per kind of value.
  func labeled<Value: Encodable & Sendable>(
    _ name: String, of _: Value.Type, _ value: GraphQLOutputType
  ) throws -> GraphQLOutputType {
    typealias Entry = LabeledValueRecord<Value>
    let type = try GraphQLObjectType(
      name: name, description: "One labelled entry of a card, as CNLabeledValue.",
      fields: [
        "identifier": field(
          identifier, { (entry: Entry) in entry.identifier },
          description: FieldDocs.LabeledValue.identifier),
        "label": field(
          GraphQLString, { (entry: Entry) in entry.label },
          description: FieldDocs.LabeledValue.label),
        "localizedLabel": field(
          GraphQLString, { (entry: Entry) in entry.localizedLabel },
          description: FieldDocs.LabeledValue.localizedLabel),
        "value": field(
          GraphQLNonNull(value), { (entry: Entry) in entry.value },
          description: FieldDocs.LabeledValue.value),
      ])
    return GraphQLNonNull(GraphQLList(GraphQLNonNull(type)))
  }
  let labeledStrings = try labeled("LabeledString", of: String.self, GraphQLString)

  typealias Docs = FieldDocs.Contact
  let contact = try GraphQLObjectType(
    name: "Contact",
    description:
      "One stored card, with the property names of CNContact. Cards are read as stored, not unified.",
    fields: [
      "identifier": field(identifier, \ContactRecord.identifier, description: Docs.identifier),
      "contactType": field(
        GraphQLNonNull(contactType), { (card: ContactRecord) in card.contactType.rawValue },
        description: Docs.contactType),
      "namePrefix": text(\ContactRecord.namePrefix, Docs.namePrefix),
      "givenName": text(\ContactRecord.givenName, Docs.givenName),
      "middleName": text(\ContactRecord.middleName, Docs.middleName),
      "familyName": text(\ContactRecord.familyName, Docs.familyName),
      "previousFamilyName": text(\ContactRecord.previousFamilyName, Docs.previousFamilyName),
      "nameSuffix": text(\ContactRecord.nameSuffix, Docs.nameSuffix),
      "nickname": text(\ContactRecord.nickname, Docs.nickname),
      "phoneticGivenName": text(\ContactRecord.phoneticGivenName, Docs.phoneticGivenName),
      "phoneticMiddleName": text(\ContactRecord.phoneticMiddleName, Docs.phoneticMiddleName),
      "phoneticFamilyName": text(\ContactRecord.phoneticFamilyName, Docs.phoneticFamilyName),
      "phoneticOrganizationName": text(
        \ContactRecord.phoneticOrganizationName, Docs.phoneticOrganizationName),
      "organizationName": text(\ContactRecord.organizationName, Docs.organizationName),
      "departmentName": text(\ContactRecord.departmentName, Docs.departmentName),
      "jobTitle": text(\ContactRecord.jobTitle, Docs.jobTitle),
      "phoneNumbers": field(
        try labeled("LabeledPhoneNumber", of: PhoneNumberValue.self, phoneNumber),
        \ContactRecord.phoneNumbers, description: Docs.phoneNumbers),
      "emailAddresses": field(
        labeledStrings, \ContactRecord.emailAddresses, description: Docs.emailAddresses),
      "postalAddresses": field(
        try labeled("LabeledPostalAddress", of: PostalAddressValue.self, postalAddress),
        \ContactRecord.postalAddresses, description: Docs.postalAddresses),
      "urlAddresses": field(
        labeledStrings, \ContactRecord.urlAddresses, description: Docs.urlAddresses),
      "contactRelations": field(
        try labeled("LabeledContactRelation", of: ContactRelationValue.self, contactRelation),
        \ContactRecord.contactRelations, description: Docs.contactRelations),
      "socialProfiles": field(
        try labeled("LabeledSocialProfile", of: SocialProfileValue.self, socialProfile),
        \ContactRecord.socialProfiles, description: Docs.socialProfiles),
      "instantMessageAddresses": field(
        try labeled(
          "LabeledInstantMessageAddress", of: InstantMessageAddressValue.self,
          instantMessageAddress),
        \ContactRecord.instantMessageAddresses, description: Docs.instantMessageAddresses),
      "dates": field(
        try labeled("LabeledDateComponents", of: DateComponentsValue.self, dateComponents),
        \ContactRecord.dates, description: Docs.dates),
      "birthday": field(dateComponents, \ContactRecord.birthday, description: Docs.birthday),
      "nonGregorianBirthday": field(
        dateComponents, \ContactRecord.nonGregorianBirthday,
        description: Docs.nonGregorianBirthday),
      "imageDataAvailable": field(
        GraphQLNonNull(GraphQLBoolean), \ContactRecord.imageDataAvailable,
        description: Docs.imageDataAvailable),
      "fullName": text(\ContactRecord.fullName, Docs.fullName),
      "containerIdentifier": field(
        GraphQLID, \ContactRecord.containerIdentifier, description: Docs.containerIdentifier),
      "groupIdentifiers": field(
        identifiers, \ContactRecord.groupIdentifiers, description: Docs.groupIdentifiers),
      "linkedContactIdentifiers": field(
        identifiers, \ContactRecord.linkedContactIdentifiers,
        description: Docs.linkedContactIdentifiers),
      "isMe": field(GraphQLNonNull(GraphQLBoolean), \ContactRecord.isMe, description: Docs.isMe),
      "note": GraphQLField(
        type: GraphQLString, description: Docs.note,
        resolve: { source, _, context, _ in
          let id = try record(source, as: ContactRecord.self).identifier
          return try await requestContext(context).extras([.note]).note(id)
        }),
      "creationDate": GraphQLField(
        type: dateTime, description: Docs.creationDate,
        resolve: { source, _, context, _ in
          let id = try record(source, as: ContactRecord.self).identifier
          return try await requestContext(context).extras([.creationDate]).creationDate(id)
            .map(timestamp)
        }),
      "modificationDate": GraphQLField(
        type: dateTime, description: Docs.modificationDate,
        resolve: { source, _, context, _ in
          let id = try record(source, as: ContactRecord.self).identifier
          return try await requestContext(context).extras([.modificationDate])
            .modificationDate(id).map(timestamp)
        }),
      "thumbnailImageData": GraphQLField(
        type: GraphQLString, description: Docs.thumbnailImageData,
        resolve: { source, _, _, _ in
          let card = try record(source, as: ContactRecord.self)
          guard card.imageDataAvailable else { return nil }
          return try await readImage(id: card.identifier, .thumbnail)?.base64EncodedString()
        }),
      "imageData": GraphQLField(
        type: GraphQLString, description: Docs.imageData,
        resolve: { source, _, _, _ in
          let card = try record(source, as: ContactRecord.self)
          guard card.imageDataAvailable else { return nil }
          return try await readImage(id: card.identifier, .full)?.base64EncodedString()
        }),
      "vCard": GraphQLField(
        type: GraphQLNonNull(GraphQLString), description: Docs.vCard,
        args: [
          "includeNote": GraphQLArgument(type: GraphQLNonNull(GraphQLBoolean), defaultValue: false),
          "includeImage": GraphQLArgument(
            type: GraphQLNonNull(GraphQLBoolean), defaultValue: false),
        ],
        resolve: { source, args, context, _ in
          let id = try record(source, as: ContactRecord.self).identifier
          let arguments = try decodeInput(GraphQLVCardArguments.self, from: args)
          let notes =
            arguments.includeNote
            ? try await requestContext(context).extras([.note]).notes : nil
          return try await exportVCard(
            VCardRequest(identifiers: [id], notes: notes, includeImages: arguments.includeImage)
          ).vCard
        }),
    ])

  let pageInfo = try GraphQLObjectType(
    name: "PageInfo",
    fields: [
      "offset": field(
        GraphQLNonNull(GraphQLInt), \PageInfo.offset, description: "Requested zero-based offset."),
      "limit": field(
        GraphQLNonNull(GraphQLInt), \PageInfo.limit, description: "Requested maximum page size."),
      "hasNextPage": field(
        GraphQLNonNull(GraphQLBoolean), \PageInfo.hasNextPage,
        description: "Whether results exist after this page."),
      "hasPreviousPage": field(
        GraphQLNonNull(GraphQLBoolean), \PageInfo.hasPreviousPage,
        description: "Whether matching results exist before the requested offset."),
    ])
  func pageType<Item: Sendable>(
    _ name: String, _ item: GraphQLObjectType, of _: Item.Type, items: String, totalCount: String
  ) throws -> GraphQLObjectType {
    try GraphQLObjectType(
      name: name,
      fields: [
        "items": field(
          GraphQLNonNull(GraphQLList(GraphQLNonNull(item))), \GraphQLPage<Item>.items,
          description: items),
        "totalCount": field(
          GraphQLNonNull(GraphQLInt), \GraphQLPage<Item>.totalCount, description: totalCount),
        "pageInfo": field(
          GraphQLNonNull(pageInfo), \GraphQLPage<Item>.pageInfo,
          description: "Position and availability of neighboring pages."),
      ])
  }
  let contactPageType = try pageType(
    "ContactPage", contact, of: ContactRecord.self, items: FieldDocs.ContactPage.items,
    totalCount: FieldDocs.ContactPage.totalCount)

  let ids = GraphQLList(GraphQLNonNull(GraphQLID))
  let keys = GraphQLList(GraphQLNonNull(contactKey))
  typealias Filter = FieldDocs.ContactFilter
  let contactFilter = try GraphQLInputObjectType(
    name: "ContactFilter",
    fields: [
      "query": InputObjectField(type: GraphQLString, description: Filter.query),
      "identifiers": InputObjectField(type: ids, description: Filter.identifiers),
      "contactTypes": InputObjectField(
        type: GraphQLList(GraphQLNonNull(contactType)), description: Filter.contactTypes),
      "containerIdentifiers": InputObjectField(
        type: ids, description: Filter.containerIdentifiers),
      "groupIdentifiers": InputObjectField(type: ids, description: Filter.groupIdentifiers),
      "has": InputObjectField(type: keys, description: Filter.has),
      "missing": InputObjectField(type: keys, description: Filter.missing),
      "labels": InputObjectField(
        type: GraphQLList(GraphQLNonNull(GraphQLString)), description: Filter.labels),
      "customLabels": InputObjectField(type: GraphQLBoolean, description: Filter.customLabels),
      "linked": InputObjectField(type: GraphQLBoolean, description: Filter.linked),
      "createdFrom": InputObjectField(type: GraphQLString, description: Filter.createdFrom),
      "createdBefore": InputObjectField(type: GraphQLString, description: Filter.createdBefore),
      "modifiedFrom": InputObjectField(type: GraphQLString, description: Filter.modifiedFrom),
      "modifiedBefore": InputObjectField(type: GraphQLString, description: Filter.modifiedBefore),
    ])
  let contactOrder = try GraphQLInputObjectType(
    name: "ContactOrder",
    fields: [
      "field": InputObjectField(
        type: GraphQLNonNull(contactSortField), description: FieldDocs.Order.field),
      "direction": InputObjectField(
        type: direction, defaultValue: "ASC", description: FieldDocs.Order.direction),
    ])
  let groupFilter = try GraphQLInputObjectType(
    name: "GroupFilter",
    fields: [
      "query": InputObjectField(type: GraphQLString, description: FieldDocs.GroupFilter.query),
      "containerIdentifiers": InputObjectField(
        type: ids, description: FieldDocs.GroupFilter.containerIdentifiers),
    ])
  let pageArgs: GraphQLArgumentConfigMap = [
    "limit": GraphQLArgument(type: GraphQLNonNull(GraphQLInt), defaultValue: 50),
    "offset": GraphQLArgument(type: GraphQLNonNull(GraphQLInt), defaultValue: 0),
  ]
  var contactArgs = pageArgs
  contactArgs["filter"] = GraphQLArgument(type: contactFilter)
  contactArgs["orderBy"] = GraphQLArgument(type: contactOrder)
  var groupArgs = pageArgs
  groupArgs["filter"] = GraphQLArgument(type: groupFilter)
  let idArg: GraphQLArgumentConfigMap = ["id": GraphQLArgument(type: GraphQLNonNull(GraphQLID))]

  let group = try GraphQLObjectType(
    name: "Group", description: "A group of cards, as CNGroup.",
    fields: [
      "identifier": field(
        identifier, \GroupRecord.identifier, description: FieldDocs.Group.identifier),
      "name": field(
        GraphQLNonNull(GraphQLString), \GroupRecord.name, description: FieldDocs.Group.name),
      "containerIdentifier": field(
        identifier, \GroupRecord.containerIdentifier,
        description: FieldDocs.Group.containerIdentifier),
      "parentGroupIdentifier": field(
        GraphQLID, \GroupRecord.parentGroupIdentifier,
        description: FieldDocs.Group.parentGroupIdentifier),
      "subgroupIdentifiers": field(
        identifiers, \GroupRecord.subgroupIdentifiers,
        description: FieldDocs.Group.subgroupIdentifiers),
      "memberCount": field(
        GraphQLNonNull(GraphQLInt), \GroupRecord.memberCount,
        description: FieldDocs.Group.memberCount),
      "members": GraphQLField(
        type: contactPageType, description: "Cards in this group; filters apply within it.",
        args: contactArgs,
        resolve: { source, args, context, _ in
          let id = try record(source, as: GroupRecord.self).identifier
          return try await contactPage(args: args, context: context, groupID: id)
        }),
    ])
  let groupPageType = try pageType(
    "GroupPage", group, of: GroupRecord.self, items: FieldDocs.GroupPage.items,
    totalCount: FieldDocs.GroupPage.totalCount)
  let container = try GraphQLObjectType(
    name: "Container",
    description: "One address book of an account, as CNContainer.",
    fields: [
      "identifier": field(
        identifier, \ContainerRecord.identifier, description: FieldDocs.Container.identifier),
      "name": field(
        GraphQLNonNull(GraphQLString), \ContainerRecord.name,
        description: FieldDocs.Container.name),
      "type": field(
        GraphQLNonNull(containerType), { (container: ContainerRecord) in container.type.rawValue },
        description: FieldDocs.Container.type),
      "isDefault": field(
        GraphQLNonNull(GraphQLBoolean), \ContainerRecord.isDefault,
        description: FieldDocs.Container.isDefault),
      "contactCount": field(
        GraphQLNonNull(GraphQLInt), \ContainerRecord.contactCount,
        description: FieldDocs.Container.contactCount),
      "groupCount": field(
        GraphQLNonNull(GraphQLInt), \ContainerRecord.groupCount,
        description: FieldDocs.Container.groupCount),
      "groups": GraphQLField(
        type: GraphQLNonNull(GraphQLList(GraphQLNonNull(group))),
        description: "Groups stored in this container, by name.",
        resolve: { source, _, context, _ in
          let id = try record(source, as: ContainerRecord.self).identifier
          return GroupSearch(containerIdentifiers: [id]).groups(try await contacts(context))
        }),
    ])
  // Links between the types, added once each exists.
  var contactLinks = try contact.fields()
  contactLinks["container"] = GraphQLField(
    type: container, description: "The container that stores the card.",
    resolve: { source, _, context, _ in
      guard let id = try record(source, as: ContactRecord.self).containerIdentifier else {
        return nil
      }
      return try await contacts(context).container(id: id)
    })
  contactLinks["groups"] = GraphQLField(
    type: GraphQLNonNull(GraphQLList(GraphQLNonNull(group))),
    description: "The groups the card belongs to.",
    resolve: { source, _, context, _ in
      let ids = try record(source, as: ContactRecord.self).groupIdentifiers
      let data = try await contacts(context)
      return ids.compactMap(data.group(id:))
    })
  contactLinks["linkedContacts"] = GraphQLField(
    type: GraphQLNonNull(GraphQLList(GraphQLNonNull(contact))),
    description: "The other stored cards Contacts shows together with this one.",
    resolve: { source, _, context, _ in
      let ids = try record(source, as: ContactRecord.self).linkedContactIdentifiers
      let data = try await contacts(context)
      return ids.compactMap(data.contact(id:))
    })
  contact.fields = { contactLinks }
  var groupLinks = try group.fields()
  groupLinks["container"] = GraphQLField(
    type: container, description: "The container that stores the group.",
    resolve: { source, _, context, _ in
      let id = try record(source, as: GroupRecord.self).containerIdentifier
      return try await contacts(context).container(id: id)
    })
  group.fields = { groupLinks }

  func count(_ value: KeyPath<ContactsSummary, Int> & Sendable, _ description: String)
    -> GraphQLField
  {
    field(
      GraphQLNonNull(GraphQLInt), { (summary: ContactsSummary) in summary[keyPath: value] },
      description: description)
  }
  let summary = try GraphQLObjectType(
    name: "Summary", description: "Counts across the whole store.",
    fields: [
      "contactCount": count(\.contactCount, FieldDocs.Summary.contactCount),
      "personCount": count(\.personCount, FieldDocs.Summary.personCount),
      "organizationCount": count(\.organizationCount, FieldDocs.Summary.organizationCount),
      "linkedContactCount": count(\.linkedContactCount, FieldDocs.Summary.linkedContactCount),
      "groupCount": count(\.groupCount, FieldDocs.Summary.groupCount),
      "containerCount": count(\.containerCount, FieldDocs.Summary.containerCount),
    ])
  let defaults = try GraphQLObjectType(
    name: "Defaults", description: "The container new cards go to and the user's own card.",
    fields: [
      "defaultContainerIdentifier": field(
        identifier, \Defaults.defaultContainerIdentifier,
        description: FieldDocs.Defaults.defaultContainerIdentifier),
      "meContactIdentifier": field(
        GraphQLID, \Defaults.meContactIdentifier,
        description: FieldDocs.Defaults.meContactIdentifier),
    ])
  let vCardExport = try GraphQLObjectType(
    name: "VCardExport", description: "Cards as one vCard 3.0 file.",
    fields: [
      "vCard": field(
        GraphQLNonNull(GraphQLString), \VCardExport.vCard, description: FieldDocs.VCard.vCard),
      "contactCount": field(
        GraphQLNonNull(GraphQLInt), \VCardExport.contactCount,
        description: FieldDocs.VCard.contactCount),
      "byteCount": field(
        GraphQLNonNull(GraphQLInt), \VCardExport.byteCount,
        description: FieldDocs.VCard.byteCount),
    ])
  let mutation = try makeMutationType(
    contact: contact, group: group, contactType: contactType, contactKey: contactKey)
  return try GraphQLSchema(
    query: GraphQLObjectType(
      name: "Query",
      fields: [
        "contacts": GraphQLField(
          type: contactPageType,
          description:
            "Stored cards, in the name order chosen in Contacts settings unless ordered otherwise.",
          args: contactArgs,
          resolve: { _, args, context, _ in try await contactPage(args: args, context: context) }),
        "contact": GraphQLField(
          type: contact, description: "Find a stored card by its identifier; null when missing.",
          args: idArg,
          resolve: { _, args, context, _ in
            let id = try decodeInput(GraphQLIDArguments.self, from: args).id
            return try await contacts(context).contact(id: id)
          }),
        "groups": GraphQLField(
          type: groupPageType, description: "Groups in every container, by name.",
          args: groupArgs,
          resolve: { _, args, context, _ in
            let arguments = try decodeInput(GraphQLGroupSearch.self, from: args)
            return try await page(
              arguments.search.groups(contacts(context)), limit: arguments.limit,
              offset: arguments.offset)
          }),
        "group": GraphQLField(
          type: group, description: "Find a group by its identifier; null when missing.",
          args: idArg,
          resolve: { _, args, context, _ in
            let id = try decodeInput(GraphQLIDArguments.self, from: args).id
            return try await contacts(context).group(id: id)
          }),
        "containers": GraphQLField(
          type: GraphQLNonNull(GraphQLList(GraphQLNonNull(container))),
          description: "Every container, by identifier.",
          resolve: { _, _, context, _ in try await contacts(context).containers }),
        "container": GraphQLField(
          type: container, description: "Find a container by its identifier; null when missing.",
          args: idArg,
          resolve: { _, args, context, _ in
            let id = try decodeInput(GraphQLIDArguments.self, from: args).id
            return try await contacts(context).container(id: id)
          }),
        "defaults": GraphQLField(
          type: defaults, description: "The container new cards go to and the user's own card.",
          resolve: { _, _, context, _ in Defaults(try await contacts(context)) }),
        "summary": GraphQLField(
          type: summary, description: "Counts across the whole store.",
          resolve: { _, _, context, _ in ContactsSummary(try await contacts(context)) }),
        "exportVCard": GraphQLField(
          type: vCardExport, description: FieldDocs.VCard.export,
          args: [
            "filter": GraphQLArgument(type: contactFilter, description: FieldDocs.VCard.filter),
            "unify": GraphQLArgument(
              type: GraphQLNonNull(GraphQLBoolean), description: FieldDocs.VCard.unify,
              defaultValue: true),
            "includeNotes": GraphQLArgument(
              type: GraphQLNonNull(GraphQLBoolean), description: FieldDocs.VCard.includeNotes,
              defaultValue: false),
            "includeImages": GraphQLArgument(
              type: GraphQLNonNull(GraphQLBoolean), description: FieldDocs.VCard.includeImages,
              defaultValue: false),
          ],
          resolve: { _, args, context, _ in
            let arguments = try decodeInput(GraphQLExportArguments.self, from: args)
            let request = try requestContext(context)
            let data = try await request.contacts()
            var export = VCardRequest(
              unify: arguments.unify, includeImages: arguments.includeImages)
            if let search = arguments.filter?.search {
              let extras = try await request.extras(search.requiredExtras)
              export.identifiers = try search.contacts(data, extras: extras).map(\.identifier)
            }
            if arguments.includeNotes { export.notes = try await request.extras([.note]).notes }
            export.linked = Dictionary(
              data.contacts.map { ($0.identifier, $0.linkedContactIdentifiers) },
              uniquingKeysWith: { first, _ in first })
            return try await exportVCard(export)
          }),
      ]), mutation: mutation)
}
