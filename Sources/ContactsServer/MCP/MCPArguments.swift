import Foundation

// Typed tool arguments. Each rejects keys its tool does not declare. MCP rejects
// explicit nulls before decoding, so optional fields are plain optionals.

struct IDArguments: Decodable {
  let id: String
  enum CodingKeys: String, CodingKey, CaseIterable { case id }
  init(from decoder: Decoder) throws {
    id = try decoder.inputContainer(keyedBy: CodingKeys.self).decode(String.self, forKey: .id)
    guard !id.isEmpty else { throw ServerError.invalidArgument("id required") }
  }
}

struct PatchArguments<Patch: Decodable>: Decodable {
  let id: String
  let patch: Patch
  enum CodingKeys: String, CodingKey, CaseIterable { case id, patch }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    guard !id.isEmpty else { throw ServerError.invalidArgument("id required") }
    patch = try c.decode(Patch.self, forKey: .patch)
  }
}

struct ContactGetArguments: Decodable {
  let id: String
  let include: [ExtraField]?
  enum CodingKeys: String, CodingKey, CaseIterable { case id, include }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    guard !id.isEmpty else { throw ServerError.invalidArgument("id required") }
    include = try c.decodeIfPresent([ExtraField].self, forKey: .include)
  }
}

struct MembersArguments: Decodable {
  let id: String
  let contactIdentifiers: [String]
  enum CodingKeys: String, CodingKey, CaseIterable { case id, contactIdentifiers }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    guard !id.isEmpty else { throw ServerError.invalidArgument("id required") }
    contactIdentifiers = try c.decode([String].self, forKey: .contactIdentifiers)
  }
}

struct ContactSearchArguments: Decodable {
  let filter: Filter?
  let orderBy: Order?
  let limit: Int?
  let cursor: String?
  let include: [ExtraField]?

  struct Filter: Decodable {
    let query: String?
    let identifiers: [String]?
    let contactTypes: [ContactType]?
    let containerIdentifiers, groupIdentifiers: [String]?
    let has, missing: [ContactKey]?
    let labels: [String]?
    let customLabels, linked: Bool?
    let createdFrom, createdBefore, modifiedFrom, modifiedBefore: String?
    enum CodingKeys: String, CodingKey, CaseIterable {
      case query, identifiers, contactTypes, containerIdentifiers, groupIdentifiers, has, missing
      case labels, customLabels, linked, createdFrom, createdBefore, modifiedFrom, modifiedBefore
    }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      query = try c.decodeIfPresent(String.self, forKey: .query)
      identifiers = try c.decodeIfPresent([String].self, forKey: .identifiers)
      contactTypes = try c.decodeIfPresent([ContactType].self, forKey: .contactTypes)
      containerIdentifiers = try c.decodeIfPresent([String].self, forKey: .containerIdentifiers)
      groupIdentifiers = try c.decodeIfPresent([String].self, forKey: .groupIdentifiers)
      has = try c.decodeIfPresent([ContactKey].self, forKey: .has)
      missing = try c.decodeIfPresent([ContactKey].self, forKey: .missing)
      labels = try c.decodeIfPresent([String].self, forKey: .labels)
      customLabels = try c.decodeIfPresent(Bool.self, forKey: .customLabels)
      linked = try c.decodeIfPresent(Bool.self, forKey: .linked)
      createdFrom = try c.decodeIfPresent(String.self, forKey: .createdFrom)
      createdBefore = try c.decodeIfPresent(String.self, forKey: .createdBefore)
      modifiedFrom = try c.decodeIfPresent(String.self, forKey: .modifiedFrom)
      modifiedBefore = try c.decodeIfPresent(String.self, forKey: .modifiedBefore)
    }
  }
  struct Order: Decodable {
    let field: ContactSortField
    let direction: SortDirection?
    enum CodingKeys: String, CodingKey, CaseIterable { case field, direction }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      field = try c.decode(ContactSortField.self, forKey: .field)
      direction = try c.decodeIfPresent(SortDirection.self, forKey: .direction)
    }
  }
  enum CodingKeys: String, CodingKey, CaseIterable { case filter, orderBy, limit, cursor, include }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    filter = try c.decodeIfPresent(Filter.self, forKey: .filter)
    orderBy = try c.decodeIfPresent(Order.self, forKey: .orderBy)
    limit = try c.decodeIfPresent(Int.self, forKey: .limit)
    cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
    include = try c.decodeIfPresent([ExtraField].self, forKey: .include)
  }

  var search: ContactSearch {
    var search = ContactSearch()
    if let filter {
      search.query = filter.query
      search.identifiers = filter.identifiers
      search.contactTypes = filter.contactTypes
      search.containerIdentifiers = filter.containerIdentifiers
      search.groupIdentifiers = filter.groupIdentifiers
      search.has = filter.has
      search.missing = filter.missing
      search.labels = filter.labels
      search.customLabels = filter.customLabels
      search.linked = filter.linked
      search.createdFrom = filter.createdFrom
      search.createdBefore = filter.createdBefore
      search.modifiedFrom = filter.modifiedFrom
      search.modifiedBefore = filter.modifiedBefore
    }
    if let orderBy {
      search.order = orderBy.field
      search.direction = orderBy.direction ?? .ascending
    }
    return search
  }
}

struct GroupSearchArguments: Decodable {
  let filter: Filter?
  let limit: Int?
  let cursor: String?

  struct Filter: Decodable {
    let query: String?
    let containerIdentifiers: [String]?
    enum CodingKeys: String, CodingKey, CaseIterable { case query, containerIdentifiers }
    init(from decoder: Decoder) throws {
      let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
      query = try c.decodeIfPresent(String.self, forKey: .query)
      containerIdentifiers = try c.decodeIfPresent([String].self, forKey: .containerIdentifiers)
    }
  }
  enum CodingKeys: String, CodingKey, CaseIterable { case filter, limit, cursor }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    filter = try c.decodeIfPresent(Filter.self, forKey: .filter)
    limit = try c.decodeIfPresent(Int.self, forKey: .limit)
    cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
  }

  var search: GroupSearch {
    GroupSearch(query: filter?.query, containerIdentifiers: filter?.containerIdentifiers)
  }
}
