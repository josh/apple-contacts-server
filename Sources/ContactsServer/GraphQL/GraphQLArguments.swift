import Foundation

// Typed collection arguments. GraphQL has already checked their types and filled
// defaults; decoding gives resolvers named fields instead of map lookups.

struct GraphQLContactFilter: Decodable, Sendable {
  let query: String?
  let identifiers: [String]?
  let contactTypes: [ContactType]?
  let containerIdentifiers, groupIdentifiers: [String]?
  let has, missing: [ContactKey]?
  let labels: [String]?
  let customLabels, linked: Bool?
  let createdFrom, createdBefore, modifiedFrom, modifiedBefore: String?

  var search: ContactSearch {
    var search = ContactSearch()
    search.query = query
    search.identifiers = identifiers
    search.contactTypes = contactTypes
    search.containerIdentifiers = containerIdentifiers
    search.groupIdentifiers = groupIdentifiers
    search.has = has
    search.missing = missing
    search.labels = labels
    search.customLabels = customLabels
    search.linked = linked
    search.createdFrom = createdFrom
    search.createdBefore = createdBefore
    search.modifiedFrom = modifiedFrom
    search.modifiedBefore = modifiedBefore
    return search
  }
}
struct GraphQLContactSearch: Decodable {
  let filter: GraphQLContactFilter?
  let orderBy: Order?
  let limit, offset: Int

  struct Order: Decodable, Sendable {
    let field: ContactSortField
    let direction: SortDirection?
  }

  var search: ContactSearch {
    var search = filter?.search ?? ContactSearch()
    if let orderBy {
      search.order = orderBy.field
      search.direction = orderBy.direction ?? .ascending
    }
    return search
  }
}

struct GraphQLGroupSearch: Decodable {
  let filter: Filter?
  let limit, offset: Int

  struct Filter: Decodable, Sendable {
    let query: String?
    let containerIdentifiers: [String]?
  }

  var search: GroupSearch {
    GroupSearch(query: filter?.query, containerIdentifiers: filter?.containerIdentifiers)
  }
}

struct GraphQLIDArguments: Decodable {
  let id: String
}
struct GraphQLVCardArguments: Decodable {
  let includeNote, includeImage: Bool
}
struct GraphQLExportArguments: Decodable {
  let filter: GraphQLContactFilter?
  let unify, includeNotes, includeImages: Bool
}

// Mutation arguments.

struct GraphQLCreateArguments<Input: Decodable>: Decodable {
  let input: Input
}
struct GraphQLPatchArguments<Patch: Decodable>: Decodable {
  let id: String
  let patch: Patch
}
struct GraphQLMembersArguments: Decodable {
  let id: String
  let contactIdentifiers: [String]
}
