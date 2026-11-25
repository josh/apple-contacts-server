import Foundation

// Codes are the client contract. GraphQL reports them in extensions.code and
// MCP in the error payload; the message is a sentence for people.
enum ErrorCode: String, Encodable, Sendable {
  case invalidArgument = "INVALID_ARGUMENT"
  case notFound = "NOT_FOUND"
  case forbidden = "FORBIDDEN"
  case notAuthorized = "NOT_AUTHORIZED"
  case readOnly = "READ_ONLY"
  case unsupportedOperation = "UNSUPPORTED_OPERATION"
  case writeFailed = "WRITE_FAILED"
  case writeApplied = "WRITE_APPLIED"
  case showFailed = "SHOW_FAILED"
  case internalError = "INTERNAL"
}
struct ServerError: Error, CustomStringConvertible, Sendable {
  let code: ErrorCode
  let message: String
  var description: String { message }
  static func invalidArgument(_ message: String) -> Self {
    .init(code: .invalidArgument, message: message)
  }
  static func notFound(_ message: String) -> Self { .init(code: .notFound, message: message) }
  static func forbidden(_ message: String) -> Self { .init(code: .forbidden, message: message) }
  static func notAuthorized(_ message: String) -> Self {
    .init(code: .notAuthorized, message: message)
  }
  static func readOnly(_ message: String) -> Self { .init(code: .readOnly, message: message) }
  static func unsupportedOperation(_ message: String) -> Self {
    .init(code: .unsupportedOperation, message: message)
  }
  static func writeFailed(_ message: String) -> Self { .init(code: .writeFailed, message: message) }
  static func writeApplied(_ message: String) -> Self {
    .init(code: .writeApplied, message: message)
  }
  static func showFailed(_ message: String) -> Self { .init(code: .showFailed, message: message) }
  static func internalError(_ message: String) -> Self {
    .init(code: .internalError, message: message)
  }
}

// The records mirror the Contacts framework: property names are CNContact's, and a
// multi-value property is a list shaped like CNLabeledValue. Raw values are the API
// spelling.
enum ContactType: String, CaseIterable, Codable, Sendable {
  case person = "PERSON"
  case organization = "ORGANIZATION"
}
enum ContainerType: String, CaseIterable, Codable, Sendable {
  case unassigned = "UNASSIGNED"
  case local = "LOCAL"
  case exchange = "EXCHANGE"
  case cardDAV = "CARD_DAV"
}

// One CNLabeledValue. `label` is the stored string, which for a built-in label is a
// token such as _$!<Home>!$_; `localizedLabel` is how Contacts shows it.
struct LabeledValueRecord<Value: Encodable & Sendable>: Encodable, Sendable {
  let identifier: String
  let label: String?
  let localizedLabel: String?
  let value: Value
  enum CodingKeys: String, CodingKey { case identifier, label, localizedLabel, value }
}
// CNPhoneNumber.
struct PhoneNumberValue: Encodable, Sendable {
  let stringValue: String
  enum CodingKeys: String, CodingKey { case stringValue }
}
// CNPostalAddress; a part the card leaves empty is absent.
struct PostalAddressValue: Encodable, Sendable {
  let street, subLocality, city, subAdministrativeArea, state, postalCode, country: String?
  let isoCountryCode: String?
  enum CodingKeys: String, CodingKey {
    case street, subLocality, city, subAdministrativeArea, state, postalCode, country
    case isoCountryCode
  }
}
// CNSocialProfile.
struct SocialProfileValue: Encodable, Sendable {
  let urlString, username, userIdentifier, service: String?
  enum CodingKeys: String, CodingKey { case urlString, username, userIdentifier, service }
}
// CNInstantMessageAddress.
struct InstantMessageAddressValue: Encodable, Sendable {
  let username, service: String?
  enum CodingKeys: String, CodingKey { case username, service }
}
// CNContactRelation.
struct ContactRelationValue: Encodable, Sendable {
  let name: String
  enum CodingKeys: String, CodingKey { case name }
}
// NSDateComponents as Contacts stores a birthday or other date: a day that may have no
// year. `calendar` is absent for the Gregorian calendar.
struct DateComponentsValue: Encodable, Sendable, Equatable {
  let calendar: String?
  let era, year, month, day: Int?
  let isLeapMonth: Bool?
  enum CodingKeys: String, CodingKey { case calendar, era, year, month, day, isLeapMonth }
  // Orders by month and day, which every date has, then by year.
  var sortKey: [Int] { [month ?? 0, day ?? 0, year ?? 0] }
}

// One stored card. The server reads cards as stored rather than unified, so a person
// with cards in two accounts is two records that name each other in
// `linkedContactIdentifiers`.
struct ContactRecord: Sendable {
  let identifier: String
  let contactType: ContactType
  let namePrefix, givenName, middleName, familyName, previousFamilyName, nameSuffix: String?
  let nickname: String?
  let phoneticGivenName, phoneticMiddleName, phoneticFamilyName: String?
  let phoneticOrganizationName: String?
  let organizationName, departmentName, jobTitle: String?
  let phoneNumbers: [LabeledValueRecord<PhoneNumberValue>]
  let emailAddresses: [LabeledValueRecord<String>]
  let postalAddresses: [LabeledValueRecord<PostalAddressValue>]
  let urlAddresses: [LabeledValueRecord<String>]
  let contactRelations: [LabeledValueRecord<ContactRelationValue>]
  let socialProfiles: [LabeledValueRecord<SocialProfileValue>]
  let instantMessageAddresses: [LabeledValueRecord<InstantMessageAddressValue>]
  let dates: [LabeledValueRecord<DateComponentsValue>]
  let birthday, nonGregorianBirthday: DateComponentsValue?
  let imageDataAvailable: Bool
  // Derived by the server rather than stored on the card.
  let fullName: String?
  var containerIdentifier: String?
  var groupIdentifiers: [String] = []
  var linkedContactIdentifiers: [String] = []
  var isMe = false

  // What the card sorts by when a name is wanted: the person's name in the order given,
  // or the organization for a card without one.
  func sortKey(familyNameFirst: Bool) -> String {
    let names = familyNameFirst ? [familyName, givenName] : [givenName, familyName]
    let parts = (names + [organizationName, fullName]).compactMap { $0 }
    return folded(parts.joined(separator: " "))
  }
}
// Case- and diacritic-insensitive form, for matching and ordering.
func folded(_ text: String) -> String {
  text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}

// CNGroup, with what the store says about where it sits.
struct GroupRecord: Encodable, Sendable {
  let identifier: String
  let name: String
  let containerIdentifier: String
  var parentGroupIdentifier: String?
  let subgroupIdentifiers: [String]
  let memberCount: Int
  enum CodingKeys: String, CodingKey {
    case identifier, name, containerIdentifier, parentGroupIdentifier, subgroupIdentifiers
    case memberCount
  }
}
// CNContainer: one address book of an account, such as iCloud or an Exchange folder.
struct ContainerRecord: Encodable, Sendable {
  let identifier: String
  let name: String
  let type: ContainerType
  let isDefault: Bool
  let contactCount, groupCount: Int
  enum CodingKeys: String, CodingKey {
    case identifier, name, type, isDefault, contactCount, groupCount
  }
}

// One read of the store: every container, group, and stored card.
struct ContactsData: Sendable {
  let containers: [ContainerRecord]
  let groups: [GroupRecord]
  let contacts: [ContactRecord]
  let defaultContainerIdentifier: String
  let meContactIdentifier: String?
  private let byID: [String: Int]

  init(
    containers: [ContainerRecord], groups: [GroupRecord], contacts: [ContactRecord],
    defaultContainerIdentifier: String, meContactIdentifier: String?
  ) {
    self.containers = containers
    self.groups = groups
    self.contacts = contacts
    self.defaultContainerIdentifier = defaultContainerIdentifier
    self.meContactIdentifier = meContactIdentifier
    byID = Dictionary(
      contacts.enumerated().map { ($1.identifier, $0) }, uniquingKeysWith: { first, _ in first })
  }
  func contact(id: String) -> ContactRecord? { byID[id].map { contacts[$0] } }
  func group(id: String) -> GroupRecord? { groups.first { $0.identifier == id } }
  func container(id: String) -> ContainerRecord? { containers.first { $0.identifier == id } }
}

// The container new cards go to and the user's own card.
struct Defaults: Encodable, Sendable {
  let defaultContainerIdentifier: String
  let meContactIdentifier: String?
  enum CodingKeys: String, CodingKey { case defaultContainerIdentifier, meContactIdentifier }
  init(_ data: ContactsData) {
    defaultContainerIdentifier = data.defaultContainerIdentifier
    meContactIdentifier = data.meContactIdentifier
  }
}
// Counts across the whole store.
struct ContactsSummary: Encodable, Sendable {
  let contactCount, personCount, organizationCount, linkedContactCount: Int
  let groupCount, containerCount: Int
  enum CodingKeys: String, CodingKey {
    case contactCount, personCount, organizationCount, linkedContactCount, groupCount
    case containerCount
  }
  init(_ data: ContactsData) {
    contactCount = data.contacts.count
    personCount = data.contacts.count { $0.contactType == .person }
    organizationCount = data.contacts.count { $0.contactType == .organization }
    linkedContactCount = data.contacts.count { !$0.linkedContactIdentifiers.isEmpty }
    groupCount = data.groups.count
    containerCount = data.containers.count
  }
}
