import Contacts
import Foundation

// Create and patch input for a card, shared by the GraphQL mutations and the MCP tools.
// Input is shaped like output: CNContact's property names, and CNLabeledValue-shaped
// entries. Decoding yields Sendable values; `ContactWrites.swift` turns them into
// framework objects on the contacts queue.

private func nonblank(_ text: String, _ name: String) throws -> String {
  guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    throw ServerError.invalidArgument("\(name) must not be blank")
  }
  return text
}

// The value of one labelled entry. `stored` makes the framework value for a new entry;
// `merged` applies the parts an update names to an existing one.
protocol LabeledValueInput: Decodable, Sendable {
  associatedtype Stored: NSCopying & NSSecureCoding
  func stored() throws -> Stored
  func merged(into old: Stored) throws -> Stored
}
extension LabeledValueInput {
  func merged(into old: Stored) throws -> Stored { try stored() }
}
extension String: LabeledValueInput {
  func stored() throws -> NSString { try nonblank(self, "value") as NSString }
}
struct PhoneNumberInput: LabeledValueInput {
  let stringValue: String
  enum CodingKeys: String, CodingKey, CaseIterable { case stringValue }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    stringValue = try c.decode(String.self, forKey: .stringValue)
  }
  func stored() throws -> CNPhoneNumber {
    CNPhoneNumber(stringValue: try nonblank(stringValue, "stringValue"))
  }
}
struct ContactRelationInput: LabeledValueInput {
  let name: String
  enum CodingKeys: String, CodingKey, CaseIterable { case name }
  init(from decoder: Decoder) throws {
    name = try decoder.inputContainer(keyedBy: CodingKeys.self).decode(String.self, forKey: .name)
  }
  func stored() throws -> CNContactRelation { CNContactRelation(name: try nonblank(name, "name")) }
}
// In an update, a part that is present replaces the stored one and "" empties it.
struct PostalAddressInput: LabeledValueInput {
  let street, subLocality, city, subAdministrativeArea, state, postalCode, country: String?
  let isoCountryCode: String?
  enum CodingKeys: String, CodingKey, CaseIterable {
    case street, subLocality, city, subAdministrativeArea, state, postalCode, country
    case isoCountryCode
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    street = try c.decodeIfPresent(String.self, forKey: .street)
    subLocality = try c.decodeIfPresent(String.self, forKey: .subLocality)
    city = try c.decodeIfPresent(String.self, forKey: .city)
    subAdministrativeArea = try c.decodeIfPresent(String.self, forKey: .subAdministrativeArea)
    state = try c.decodeIfPresent(String.self, forKey: .state)
    postalCode = try c.decodeIfPresent(String.self, forKey: .postalCode)
    country = try c.decodeIfPresent(String.self, forKey: .country)
    isoCountryCode = try c.decodeIfPresent(String.self, forKey: .isoCountryCode)
  }
  func stored() throws -> CNPostalAddress { try merged(into: CNPostalAddress()) }
  func merged(into old: CNPostalAddress) throws -> CNPostalAddress {
    guard let address = old.mutableCopy() as? CNMutablePostalAddress else {
      throw ServerError.internalError("Cannot copy a postal address")
    }
    if let street { address.street = street }
    if let subLocality { address.subLocality = subLocality }
    if let city { address.city = city }
    if let subAdministrativeArea { address.subAdministrativeArea = subAdministrativeArea }
    if let state { address.state = state }
    if let postalCode { address.postalCode = postalCode }
    if let country { address.country = country }
    if let isoCountryCode { address.isoCountryCode = isoCountryCode.lowercased() }
    let parts = [
      address.street, address.subLocality, address.city, address.subAdministrativeArea,
      address.state, address.postalCode, address.country, address.isoCountryCode,
    ]
    guard parts.contains(where: { !$0.isEmpty }) else {
      throw ServerError.invalidArgument("a postal address needs at least one part")
    }
    return address
  }
}
struct SocialProfileInput: LabeledValueInput {
  let urlString, username, userIdentifier, service: String?
  enum CodingKeys: String, CodingKey, CaseIterable {
    case urlString, username, userIdentifier, service
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    urlString = try c.decodeIfPresent(String.self, forKey: .urlString)
    username = try c.decodeIfPresent(String.self, forKey: .username)
    userIdentifier = try c.decodeIfPresent(String.self, forKey: .userIdentifier)
    service = try c.decodeIfPresent(String.self, forKey: .service)
  }
  func stored() throws -> CNSocialProfile {
    try merged(
      into: CNSocialProfile(urlString: nil, username: nil, userIdentifier: nil, service: nil))
  }
  func merged(into old: CNSocialProfile) throws -> CNSocialProfile {
    func part(_ new: String?, _ old: String) -> String? {
      let value = new ?? old
      return value.isEmpty ? nil : value
    }
    let profile = CNSocialProfile(
      urlString: part(urlString, old.urlString), username: part(username, old.username),
      userIdentifier: part(userIdentifier, old.userIdentifier),
      service: part(service, old.service))
    guard !profile.urlString.isEmpty || !profile.username.isEmpty else {
      throw ServerError.invalidArgument("a social profile needs a username or a urlString")
    }
    return profile
  }
}
struct InstantMessageAddressInput: LabeledValueInput {
  let username, service: String?
  enum CodingKeys: String, CodingKey, CaseIterable { case username, service }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    username = try c.decodeIfPresent(String.self, forKey: .username)
    service = try c.decodeIfPresent(String.self, forKey: .service)
  }
  func stored() throws -> CNInstantMessageAddress {
    try merged(into: CNInstantMessageAddress(username: "", service: ""))
  }
  func merged(into old: CNInstantMessageAddress) throws -> CNInstantMessageAddress {
    let address = CNInstantMessageAddress(
      username: username ?? old.username, service: service ?? old.service)
    guard !address.username.isEmpty else {
      throw ServerError.invalidArgument("an instant message address needs a username")
    }
    return address
  }
}
// A day that may have no year. An update replaces the whole date.
struct DateComponentsInput: LabeledValueInput {
  let calendar: String?
  let era, year: Int?
  let month, day: Int
  let isLeapMonth: Bool?
  enum CodingKeys: String, CodingKey, CaseIterable {
    case calendar, era, year, month, day, isLeapMonth
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    calendar = try c.decodeIfPresent(String.self, forKey: .calendar)
    era = try c.decodeIfPresent(Int.self, forKey: .era)
    year = try c.decodeIfPresent(Int.self, forKey: .year)
    month = try c.decode(Int.self, forKey: .month)
    day = try c.decode(Int.self, forKey: .day)
    isLeapMonth = try c.decodeIfPresent(Bool.self, forKey: .isLeapMonth)
  }
  func stored() throws -> NSDateComponents { try components() as NSDateComponents }
  // The date in its calendar. Without a year, the day is checked against a leap year so
  // that 29 February is accepted.
  func components(gregorian: Bool? = nil) throws -> DateComponents {
    let identifier = NSCalendar.Identifier(rawValue: calendar ?? "gregorian")
    guard let named = NSCalendar(calendarIdentifier: identifier) else {
      throw ServerError.invalidArgument("calendar must be a calendar identifier such as chinese")
    }
    let isGregorian = identifier == .gregorian
    if let gregorian, gregorian != isGregorian {
      throw ServerError.invalidArgument(
        gregorian
          ? "birthday is Gregorian; use nonGregorianBirthday for another calendar"
          : "nonGregorianBirthday needs a calendar other than gregorian")
    }
    if let year, isGregorian, !(1...9999).contains(year) {
      throw ServerError.invalidArgument("year must be 1...9999")
    }
    var result = DateComponents()
    result.calendar = named as Calendar
    result.era = era
    result.year = year
    result.month = month
    result.day = day
    if isLeapMonth == true { result.isLeapMonth = true }
    var check = result
    if year == nil, isGregorian { check.year = 2000 }
    guard (1...13).contains(month), (1...31).contains(day),
      year == nil && !isGregorian || check.isValidDate(in: named as Calendar)
    else { throw ServerError.invalidArgument("month and day must name a real day") }
    return result
  }
}

// A new labelled entry. A label may be a stored token, a custom label, or a built-in
// label's word such as home or mobile; omitted, the entry has no label.
struct LabeledAdd<Value: LabeledValueInput>: Decodable, Sendable {
  let label: String?
  let value: Value
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: LabeledEntryKey.self)
    guard !c.contains(.identifier) else {
      throw ServerError.invalidArgument("a new entry has no identifier; the store assigns one")
    }
    label = try c.decodeIfPresent(String.self, forKey: .label)
    value = try c.decode(Value.self, forKey: .value)
  }
}
// A change to the entry with this identifier. Only what is present changes; a label of
// "" removes the label.
struct LabeledUpdate<Value: LabeledValueInput>: Decodable, Sendable {
  let identifier: String
  let label: String?
  let value: Value?
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: LabeledEntryKey.self)
    identifier = try c.decode(String.self, forKey: .identifier)
    label = try c.decodeIfPresent(String.self, forKey: .label)
    value = try c.decodeIfPresent(Value.self, forKey: .value)
    guard label != nil || value != nil else {
      throw ServerError.invalidArgument("an update needs a label or a value")
    }
  }
}
enum LabeledEntryKey: String, CodingKey, CaseIterable { case identifier, label, value }
// Changes to one multi-value property. Entries the patch does not name are untouched;
// nothing replaces the whole list.
struct LabeledOperations<Value: LabeledValueInput>: Decodable, Sendable {
  var add: [LabeledAdd<Value>] = []
  var update: [LabeledUpdate<Value>] = []
  var remove: [String] = []
  var isEmpty: Bool { add.isEmpty && update.isEmpty && remove.isEmpty }
  init() {}
  init(add: [LabeledAdd<Value>]) { self.add = add }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: LabeledOperationKey.self)
    add = try c.decodeIfPresent([LabeledAdd<Value>].self, forKey: .add) ?? []
    update = try c.decodeIfPresent([LabeledUpdate<Value>].self, forKey: .update) ?? []
    remove = try c.decodeIfPresent([String].self, forKey: .remove) ?? []
    guard !isEmpty else {
      throw ServerError.invalidArgument("a list change needs add, update, or remove")
    }
    let named = update.map(\.identifier) + remove
    guard Set(named).count == named.count else {
      throw ServerError.invalidArgument("an entry may be updated or removed once per patch")
    }
  }
}
enum LabeledOperationKey: String, CodingKey, CaseIterable { case add, update, remove }

// Every field of a create input or a patch; each mode accepts its own subset.
enum ContactInputKey: String, CodingKey, CaseIterable {
  case contactType, namePrefix, givenName, middleName, familyName, previousFamilyName
  case nameSuffix, nickname, phoneticGivenName, phoneticMiddleName, phoneticFamilyName
  case phoneticOrganizationName, organizationName, departmentName, jobTitle
  case phoneNumbers, emailAddresses, postalAddresses, urlAddresses, contactRelations
  case socialProfiles, instantMessageAddresses, dates, birthday, nonGregorianBirthday, note
  case imageData
  // Create only.
  case containerIdentifier, groupIdentifiers
  // Patch only.
  case clearFields

  // The text fields, with the key each sets.
  static let strings: [(ContactInputKey, ContactKey)] = [
    (.namePrefix, .namePrefix), (.givenName, .givenName), (.middleName, .middleName),
    (.familyName, .familyName), (.previousFamilyName, .previousFamilyName),
    (.nameSuffix, .nameSuffix), (.nickname, .nickname),
    (.phoneticGivenName, .phoneticGivenName), (.phoneticMiddleName, .phoneticMiddleName),
    (.phoneticFamilyName, .phoneticFamilyName),
    (.phoneticOrganizationName, .phoneticOrganizationName),
    (.organizationName, .organizationName), (.departmentName, .departmentName),
    (.jobTitle, .jobTitle), (.note, .note),
  ]
}

// What a create or a patch asks for, checked and ready to apply.
struct ContactChanges: Sendable {
  var contactType: ContactType?
  var strings: [ContactKey: String] = [:]
  var phoneNumbers = LabeledOperations<PhoneNumberInput>()
  var emailAddresses = LabeledOperations<String>()
  var postalAddresses = LabeledOperations<PostalAddressInput>()
  var urlAddresses = LabeledOperations<String>()
  var contactRelations = LabeledOperations<ContactRelationInput>()
  var socialProfiles = LabeledOperations<SocialProfileInput>()
  var instantMessageAddresses = LabeledOperations<InstantMessageAddressInput>()
  var dates = LabeledOperations<DateComponentsInput>()
  var birthday, nonGregorianBirthday: DateComponents?
  var imageData: Data?
  var clear: Set<ContactKey> = []
  var containerIdentifier: String?
  var groupIdentifiers: [String] = []

  var touchesImage: Bool { imageData != nil || clear.contains(.imageData) }
  var isEmpty: Bool {
    contactType == nil && strings.isEmpty && phoneNumbers.isEmpty && emailAddresses.isEmpty
      && postalAddresses.isEmpty && urlAddresses.isEmpty && contactRelations.isEmpty
      && socialProfiles.isEmpty && instantMessageAddresses.isEmpty && dates.isEmpty
      && birthday == nil && nonGregorianBirthday == nil && imageData == nil && clear.isEmpty
  }
}

// A create input decodes each list as the entries to add; a patch decodes add, update,
// and remove. Patches reject null before decoding, so an optional here is absent or set.
struct ContactInput: Sendable {
  let changes: ContactChanges

  init(from decoder: Decoder, creating: Bool) throws {
    let c = try decoder.inputContainer(keyedBy: ContactInputKey.self)
    let foreign: [ContactInputKey] =
      creating ? [.clearFields] : [.containerIdentifier, .groupIdentifiers]
    guard !foreign.contains(where: c.contains) else {
      throw ServerError.invalidArgument("Unknown input field")
    }
    var result = ContactChanges()
    result.contactType = try c.decodeIfPresent(ContactType.self, forKey: .contactType)
    for (key, target) in ContactInputKey.strings {
      guard let value = try c.decodeIfPresent(String.self, forKey: key) else { continue }
      // The note keeps its line breaks; every other text field is one trimmed line.
      result.strings[target] =
        target == .note
        ? try nonblank(value, key.stringValue)
        : try nonblank(value, key.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func list<Value: LabeledValueInput>(_ key: ContactInputKey) throws -> LabeledOperations<Value> {
      guard c.contains(key), try !c.decodeNil(forKey: key) else { return .init() }
      return creating
        ? .init(add: try c.decode([LabeledAdd<Value>].self, forKey: key))
        : try c.decode(LabeledOperations<Value>.self, forKey: key)
    }
    result.phoneNumbers = try list(.phoneNumbers)
    result.emailAddresses = try list(.emailAddresses)
    result.postalAddresses = try list(.postalAddresses)
    result.urlAddresses = try list(.urlAddresses)
    result.contactRelations = try list(.contactRelations)
    result.socialProfiles = try list(.socialProfiles)
    result.instantMessageAddresses = try list(.instantMessageAddresses)
    result.dates = try list(.dates)
    result.birthday = try c.decodeIfPresent(DateComponentsInput.self, forKey: .birthday)?
      .components(gregorian: true)
    result.nonGregorianBirthday =
      try c.decodeIfPresent(DateComponentsInput.self, forKey: .nonGregorianBirthday)?
      .components(gregorian: false)
    if let encoded = try c.decodeIfPresent(String.self, forKey: .imageData) {
      result.imageData = try decodedImage(encoded)
    }
    if let fields = try c.decodeIfPresent([ContactKey].self, forKey: .clearFields) {
      guard Set(fields).count == fields.count else {
        throw ServerError.invalidArgument("duplicate clearFields")
      }
      result.clear = Set(fields)
    }
    let set = Set(result.strings.keys)
    let lists: [(ContactKey, Bool)] = [
      (.phoneNumbers, result.phoneNumbers.isEmpty),
      (.emailAddresses, result.emailAddresses.isEmpty),
      (.postalAddresses, result.postalAddresses.isEmpty),
      (.urlAddresses, result.urlAddresses.isEmpty),
      (.contactRelations, result.contactRelations.isEmpty),
      (.socialProfiles, result.socialProfiles.isEmpty),
      (.instantMessageAddresses, result.instantMessageAddresses.isEmpty),
      (.dates, result.dates.isEmpty), (.birthday, result.birthday == nil),
      (.nonGregorianBirthday, result.nonGregorianBirthday == nil),
      (.imageData, result.imageData == nil),
    ]
    let changed = set.union(lists.filter { !$0.1 }.map(\.0))
    guard result.clear.isDisjoint(with: changed) else {
      throw ServerError.invalidArgument("a field cannot be both set and cleared")
    }
    if creating {
      result.containerIdentifier = try c.decodeIfPresent(String.self, forKey: .containerIdentifier)
      result.groupIdentifiers =
        try c.decodeIfPresent([String].self, forKey: .groupIdentifiers) ?? []
      // Contacts shows a card with none of these as "No Name".
      let named: [ContactKey] = [
        .givenName, .familyName, .organizationName, .nickname, .middleName,
      ]
      guard
        named.contains(where: set.contains) || !result.phoneNumbers.isEmpty
          || !result.emailAddresses.isEmpty
      else {
        throw ServerError.invalidArgument(
          "a new card needs a name, an organization, a phone number, or an email address")
      }
    } else if result.isEmpty {
      throw ServerError.invalidArgument("patch must contain at least one change")
    }
    changes = result
  }
}
struct CreateContactInput: Decodable, Sendable {
  let changes: ContactChanges
  init(from decoder: Decoder) throws {
    changes = try ContactInput(from: decoder, creating: true).changes
  }
}
struct ContactPatch: Decodable, Sendable {
  let changes: ContactChanges
  init(from decoder: Decoder) throws {
    changes = try ContactInput(from: decoder, creating: false).changes
  }
}
