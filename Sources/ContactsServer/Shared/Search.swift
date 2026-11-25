import Contacts
import Foundation

// One filter for GraphQL and MCP searches.
enum SortDirection: String, CaseIterable, Decodable, Sendable {
  case ascending = "ASC"
  case descending = "DESC"
}
// The parts of a card a filter or a patch can name, spelled after the CNContact keys.
enum ContactKey: String, CaseIterable, Codable, Sendable {
  case namePrefix = "NAME_PREFIX"
  case givenName = "GIVEN_NAME"
  case middleName = "MIDDLE_NAME"
  case familyName = "FAMILY_NAME"
  case previousFamilyName = "PREVIOUS_FAMILY_NAME"
  case nameSuffix = "NAME_SUFFIX"
  case nickname = "NICKNAME"
  case phoneticGivenName = "PHONETIC_GIVEN_NAME"
  case phoneticMiddleName = "PHONETIC_MIDDLE_NAME"
  case phoneticFamilyName = "PHONETIC_FAMILY_NAME"
  case phoneticOrganizationName = "PHONETIC_ORGANIZATION_NAME"
  case organizationName = "ORGANIZATION_NAME"
  case departmentName = "DEPARTMENT_NAME"
  case jobTitle = "JOB_TITLE"
  case phoneNumbers = "PHONE_NUMBERS"
  case emailAddresses = "EMAIL_ADDRESSES"
  case postalAddresses = "POSTAL_ADDRESSES"
  case urlAddresses = "URL_ADDRESSES"
  case contactRelations = "CONTACT_RELATIONS"
  case socialProfiles = "SOCIAL_PROFILES"
  case instantMessageAddresses = "INSTANT_MESSAGE_ADDRESSES"
  case dates = "DATES"
  case birthday = "BIRTHDAY"
  case nonGregorianBirthday = "NON_GREGORIAN_BIRTHDAY"
  case imageData = "IMAGE_DATA"
  case note = "NOTE"
}
extension ContactRecord {
  // Whether the card has a value for the key.
  func has(_ key: ContactKey) -> Bool {
    switch key {
    case .namePrefix: return namePrefix != nil
    case .givenName: return givenName != nil
    case .middleName: return middleName != nil
    case .familyName: return familyName != nil
    case .previousFamilyName: return previousFamilyName != nil
    case .nameSuffix: return nameSuffix != nil
    case .nickname: return nickname != nil
    case .phoneticGivenName: return phoneticGivenName != nil
    case .phoneticMiddleName: return phoneticMiddleName != nil
    case .phoneticFamilyName: return phoneticFamilyName != nil
    case .phoneticOrganizationName: return phoneticOrganizationName != nil
    case .organizationName: return organizationName != nil
    case .departmentName: return departmentName != nil
    case .jobTitle: return jobTitle != nil
    case .phoneNumbers: return !phoneNumbers.isEmpty
    case .emailAddresses: return !emailAddresses.isEmpty
    case .postalAddresses: return !postalAddresses.isEmpty
    case .urlAddresses: return !urlAddresses.isEmpty
    case .contactRelations: return !contactRelations.isEmpty
    case .socialProfiles: return !socialProfiles.isEmpty
    case .instantMessageAddresses: return !instantMessageAddresses.isEmpty
    case .dates: return !dates.isEmpty
    case .birthday: return birthday != nil
    case .nonGregorianBirthday: return nonGregorianBirthday != nil
    case .imageData: return imageDataAvailable
    // The note is not on the record; a search that names it reads notes from Contacts.
    case .note: return false
    }
  }
  // The stored label of every labelled value on the card; nil for a value without one.
  var labels: [String?] {
    chosenLabels + socialProfiles.map(\.label) + instantMessageAddresses.map(\.label)
  }
  // Labels of the properties Contacts offers built-in labels for. A social profile's or
  // an instant message address's label names its service, so it is never built in.
  var chosenLabels: [String?] {
    phoneNumbers.map(\.label) + emailAddresses.map(\.label) + postalAddresses.map(\.label)
      + urlAddresses.map(\.label) + contactRelations.map(\.label) + dates.map(\.label)
  }
  // Everything a text query can match, folded.
  fileprivate var searchText: [String] {
    let addresses = postalAddresses.map(\.value).flatMap {
      [$0.street, $0.subLocality, $0.city, $0.state, $0.postalCode, $0.country]
    }
    let profiles = socialProfiles.map(\.value).flatMap { [$0.username, $0.urlString] }
    let text: [String?] =
      [
        fullName, namePrefix, givenName, middleName, familyName, previousFamilyName, nameSuffix,
        nickname, phoneticGivenName, phoneticMiddleName, phoneticFamilyName,
        phoneticOrganizationName, organizationName, departmentName, jobTitle,
      ] + emailAddresses.map(\.value) + urlAddresses.map(\.value) + addresses + profiles
      + instantMessageAddresses.map(\.value.username) + contactRelations.map(\.value.name)
    return text.compactMap { $0 }.map(folded)
  }
}
private func digits(_ text: String) -> String { text.filter(\.isNumber) }

enum ContactSortField: String, CaseIterable, Decodable, Sendable {
  case userDefault = "USER_DEFAULT"
  case givenName = "GIVEN_NAME"
  case familyName = "FAMILY_NAME"
  case organizationName = "ORGANIZATION_NAME"
  case birthday = "BIRTHDAY"
  case creationDate = "CREATION_DATE"
  case modificationDate = "MODIFICATION_DATE"
}

struct ContactSearch: Sendable {
  var direction = SortDirection.ascending
  var order: ContactSortField?
  var query: String?
  var identifiers: [String]?
  var contactTypes: [ContactType]?
  var containerIdentifiers: [String]?
  var groupIdentifiers: [String]?
  var has: [ContactKey]?
  var missing: [ContactKey]?
  // Words or stored tokens; a card matches when any labelled value carries one.
  var labels: [String]?
  var customLabels: Bool?
  var linked: Bool?
  // Each date bound is a timestamp or YYYY-MM-DD.
  var createdFrom, createdBefore, modifiedFrom, modifiedBefore: String?

  // The scripting-only fields this search filters or sorts by. Reading them launches
  // Contacts, so a search that names none of them never does.
  var requiredExtras: Set<ExtraField> {
    var fields: Set<ExtraField> = []
    if (has ?? []).contains(.note) || (missing ?? []).contains(.note) { fields.insert(.note) }
    if createdFrom != nil || createdBefore != nil || order == .creationDate {
      fields.insert(.creationDate)
    }
    if modifiedFrom != nil || modifiedBefore != nil || order == .modificationDate {
      fields.insert(.modificationDate)
    }
    return fields
  }

  private func matcher(_ extras: ContactExtras) throws -> (ContactRecord) -> Bool {
    let created = try DateRange(from: createdFrom, before: createdBefore, name: "created")
    let modified = try DateRange(from: modifiedFrom, before: modifiedBefore, name: "modified")
    func holds(_ key: ContactKey, _ card: ContactRecord) -> Bool {
      key == .note ? extras.note(card.identifier) != nil : card.has(key)
    }
    let text = query.map { folded($0.trimmingCharacters(in: .whitespaces)) }
    // A query with digits also matches phone numbers, however they are punctuated.
    let number = query.map(digits).flatMap { $0.count >= 3 ? $0 : nil }
    let identifiers = identifiers.map(Set.init)
    let containers = containerIdentifiers.map(Set.init)
    let groups = groupIdentifiers.map(Set.init)
    let labels = labels.map { Set($0.flatMap(storedLabels(matching:))) }
    return { card in
      (identifiers == nil || identifiers!.contains(card.identifier))
        && (contactTypes == nil || contactTypes!.contains(card.contactType))
        && (containers == nil || card.containerIdentifier.map(containers!.contains) == true)
        && (groups == nil || !groups!.isDisjoint(with: card.groupIdentifiers))
        && (has == nil || has!.allSatisfy { holds($0, card) })
        && (missing == nil || !missing!.contains { holds($0, card) })
        && created.contains(extras.creationDate(card.identifier))
        && modified.contains(extras.modificationDate(card.identifier))
        && (labels == nil || card.labels.contains { $0.map(labels!.contains) == true })
        && (customLabels == nil
          || customLabels == card.chosenLabels.contains { $0.map { !isBuiltInLabel($0) } == true })
        && (linked == nil || linked == !card.linkedContactIdentifiers.isEmpty)
        && (text == nil || text!.isEmpty || card.searchText.contains { $0.contains(text!) }
          || (number != nil
            && card.phoneNumbers.contains { digits($0.value.stringValue).contains(number!) }))
    }
  }

  // Matching cards, in the order Contacts lists names unless ordered otherwise.
  // `groupID` restricts to one group's members.
  // `extras` must hold the fields `requiredExtras` names.
  func contacts(_ data: ContactsData, extras: ContactExtras = .init(), groupID: String? = nil)
    throws -> [ContactRecord]
  {
    let matches = try matcher(extras)
    let items = data.contacts.filter {
      (groupID == nil || $0.groupIdentifiers.contains(groupID!)) && matches($0)
    }
    let descending = direction == .descending
    func compare<T: Comparable>(_ a: T?, _ b: T?) -> Bool? {
      if a == b { return nil }
      guard let a else { return false }
      guard let b else { return true }
      return descending ? a > b : a < b
    }
    let familyFirst: Bool
    switch order ?? .userDefault {
    case .userDefault: familyFirst = CNContactsUserDefaults.shared().sortOrder != .givenName
    case .familyName: familyFirst = true
    default: familyFirst = false
    }
    let keys = Dictionary(
      items.map { ($0.identifier, $0.sortKey(familyNameFirst: familyFirst)) },
      uniquingKeysWith: { first, _ in first })
    func key(_ card: ContactRecord) -> String { keys[card.identifier] ?? "" }
    return items.sorted { a, b in
      let result: Bool?
      switch order ?? .userDefault {
      case .userDefault, .givenName, .familyName: result = compare(key(a), key(b))
      case .organizationName:
        result = compare(a.organizationName.map(folded), b.organizationName.map(folded))
      case .birthday:
        result = compare(
          a.birthday.map { Lexicographic($0.sortKey) }, b.birthday.map { Lexicographic($0.sortKey) }
        )
      case .creationDate:
        result = compare(extras.creationDate(a.identifier), extras.creationDate(b.identifier))
      case .modificationDate:
        result = compare(
          extras.modificationDate(a.identifier), extras.modificationDate(b.identifier))
      }
      // Ties fall back to the name, then the identifier, so pages are stable.
      return result ?? (key(a) == key(b) ? a.identifier < b.identifier : key(a) < key(b))
    }
  }
}
private struct Lexicographic: Comparable {
  let parts: [Int]
  init(_ parts: [Int]) { self.parts = parts }
  static func < (a: Self, b: Self) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
}

// A half-open range of instants; a card without the date matches only an unbounded range.
private struct DateRange {
  let from, before: Date?
  init(from: String?, before: String?, name: String) throws {
    self.from = try from.map(parseBound)
    self.before = try before.map(parseBound)
    if let lower = self.from, let upper = self.before, lower >= upper {
      throw ServerError.invalidArgument("\(name)From must precede \(name)Before")
    }
  }
  func contains(_ date: Date?) -> Bool {
    if from == nil && before == nil { return true }
    guard let date else { return false }
    return (from == nil || date >= from!) && (before == nil || date < before!)
  }
}

struct GroupSearch: Sendable {
  var query: String?
  var containerIdentifiers: [String]?

  // Matching groups, by name.
  func groups(_ data: ContactsData) -> [GroupRecord] {
    let text = query.map { folded($0.trimmingCharacters(in: .whitespaces)) }
    let containers = containerIdentifiers.map(Set.init)
    return data.groups.filter {
      (containers == nil || containers!.contains($0.containerIdentifier))
        && (text == nil || text!.isEmpty || folded($0.name).contains(text!))
    }.sorted {
      let a = folded($0.name)
      let b = folded($1.name)
      return a == b ? $0.identifier < $1.identifier : a < b
    }
  }
}
