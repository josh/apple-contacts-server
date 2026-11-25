import Contacts
import Foundation

// Framework writes, run on the contacts queue. A card's note is not here: Contacts sets
// it afterward through scripting.

enum ContactWrite: Sendable {
  case create(ContactChanges)
  case update(id: String, ContactChanges)

  var changes: ContactChanges {
    switch self {
    case .create(let changes), .update(_, let changes): return changes
    }
  }
  // The card an update changes; nil for a create.
  var existingID: String? {
    if case .update(let id, _) = self { return id }
    return nil
  }
}
private func frameworkKey(_ key: ContactKey) -> String? {
  switch key {
  case .namePrefix: return CNContactNamePrefixKey
  case .givenName: return CNContactGivenNameKey
  case .middleName: return CNContactMiddleNameKey
  case .familyName: return CNContactFamilyNameKey
  case .previousFamilyName: return CNContactPreviousFamilyNameKey
  case .nameSuffix: return CNContactNameSuffixKey
  case .nickname: return CNContactNicknameKey
  case .phoneticGivenName: return CNContactPhoneticGivenNameKey
  case .phoneticMiddleName: return CNContactPhoneticMiddleNameKey
  case .phoneticFamilyName: return CNContactPhoneticFamilyNameKey
  case .phoneticOrganizationName: return CNContactPhoneticOrganizationNameKey
  case .organizationName: return CNContactOrganizationNameKey
  case .departmentName: return CNContactDepartmentNameKey
  case .jobTitle: return CNContactJobTitleKey
  case .phoneNumbers: return CNContactPhoneNumbersKey
  case .emailAddresses: return CNContactEmailAddressesKey
  case .postalAddresses: return CNContactPostalAddressesKey
  case .urlAddresses: return CNContactUrlAddressesKey
  case .contactRelations: return CNContactRelationsKey
  case .socialProfiles: return CNContactSocialProfilesKey
  case .instantMessageAddresses: return CNContactInstantMessageAddressesKey
  case .dates: return CNContactDatesKey
  case .birthday: return CNContactBirthdayKey
  case .nonGregorianBirthday: return CNContactNonGregorianBirthdayKey
  case .imageData: return CNContactImageDataKey
  case .note: return nil
  }
}
extension ContactChanges {
  // The framework keys an update reads or sets. Only these are fetched, and the save
  // leaves every other property of the card as it is.
  var touchedKeys: [CNKeyDescriptor] {
    var keys: Set<ContactKey> = Set(strings.keys).union(clear)
    if !phoneNumbers.isEmpty { keys.insert(.phoneNumbers) }
    if !emailAddresses.isEmpty { keys.insert(.emailAddresses) }
    if !postalAddresses.isEmpty { keys.insert(.postalAddresses) }
    if !urlAddresses.isEmpty { keys.insert(.urlAddresses) }
    if !contactRelations.isEmpty { keys.insert(.contactRelations) }
    if !socialProfiles.isEmpty { keys.insert(.socialProfiles) }
    if !instantMessageAddresses.isEmpty { keys.insert(.instantMessageAddresses) }
    if !dates.isEmpty { keys.insert(.dates) }
    if birthday != nil { keys.insert(.birthday) }
    if nonGregorianBirthday != nil { keys.insert(.nonGregorianBirthday) }
    if imageData != nil { keys.insert(.imageData) }
    var names = keys.compactMap(frameworkKey)
    if contactType != nil { names.append(CNContactTypeKey) }
    // The picture is always fetched and saved back. A small test picture was lost by a
    // save that left it out, so no save is trusted to keep a picture it did not fetch.
    names.append(CNContactImageDataKey)
    return ([CNContactIdentifierKey] + Set(names).sorted()).map { $0 as CNKeyDescriptor }
  }
  // Whether nothing but the note changes, which needs no framework save.
  var isFrameworkEmpty: Bool {
    var rest = self
    rest.strings[.note] = nil
    rest.clear.remove(.note)
    return rest.isEmpty
  }
}

// What the framework answers for any change to a card that has a note. The note belongs
// to an entitlement only Apple grants, and without it the framework can neither read the
// note nor save the card that holds it.
private let notedCardSaveCode = 134092
let notedCardMessage =
  "The Contacts framework cannot save a change to a card that has a note, so this card can be changed only after its note is removed. Clear the note (clearFields: [NOTE]), make the change, and set the note again, or edit the card in Contacts"

// A save the store refused, with nothing stored.
private func execute(_ save: CNSaveRequest, _ store: CNContactStore) throws {
  do { try store.execute(save) } catch {
    let native = error as NSError
    if native.domain == NSCocoaErrorDomain, native.code == notedCardSaveCode {
      throw ServerError.unsupportedOperation("\(notedCardMessage) (Core Data error \(native.code))")
    }
    let mapped = contactsError(error)
    if let server = mapped as? ServerError, server.code != .internalError { throw server }
    throw ServerError.writeFailed("Contacts refused the save: \(mapped)")
  }
}

// One stored card, mutable, with the keys the write reads or sets. Keys left out of the
// fetch are left as they are by the save.
func storedContact(_ store: CNContactStore, id: String, keys: [CNKeyDescriptor]) throws
  -> CNMutableContact
{
  let request = CNContactFetchRequest(keysToFetch: keys)
  request.unifyResults = false
  request.mutableObjects = true
  request.predicate = CNContact.predicateForContacts(withIdentifiers: [id])
  var found: CNMutableContact?
  try store.enumerateContacts(with: request) { contact, stop in
    guard contact.identifier == id else { return }
    found = contact as? CNMutableContact
    stop.pointee = true
  }
  guard let found else { throw ServerError.notFound("no card has this id") }
  return found
}
private func storedGroups(_ store: CNContactStore, ids: [String]) throws -> [CNGroup] {
  let found = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: ids))
  guard Set(found.map(\.identifier)) == Set(ids) else {
    throw ServerError.notFound("no group has this identifier")
  }
  return found
}
func containerIdentifier(_ store: CNContactStore, ofGroup id: String) throws -> String? {
  try store.containers(matching: CNContainer.predicateForContainerOfGroup(withIdentifier: id))
    .first?.identifier
}

// Applies the named operations to one multi-value property. Every identifier is checked
// before anything changes, and an entry the patch does not name keeps its identifier,
// label, and value.
private func applied<Value: LabeledValueInput>(
  _ operations: LabeledOperations<Value>, to current: [CNLabeledValue<Value.Stored>],
  _ property: LabeledProperty
) throws -> [CNLabeledValue<Value.Stored>] {
  guard !operations.isEmpty else { return current }
  let known = Set(current.map(\.identifier))
  let named = operations.update.map(\.identifier) + operations.remove
  if let unknown = named.first(where: { !known.contains($0) }) {
    throw ServerError.invalidArgument(
      "\(property.rawValue) has no entry with identifier \(unknown)")
  }
  func label(_ input: String?) -> String? {
    input.flatMap { $0.isEmpty ? nil : storedLabel($0, for: property) }
  }
  let removed = Set(operations.remove)
  let updates = Dictionary(
    operations.update.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
  var result: [CNLabeledValue<Value.Stored>] = []
  for entry in current where !removed.contains(entry.identifier) {
    guard let update = updates[entry.identifier] else {
      result.append(entry)
      continue
    }
    let value = try update.value.map { try $0.merged(into: entry.value) } ?? entry.value
    result.append(
      entry.settingLabel(update.label == nil ? entry.label : label(update.label), value: value))
  }
  for entry in operations.add {
    result.append(CNLabeledValue(label: label(entry.label), value: try entry.value.stored()))
  }
  return result
}

private func setText(_ contact: CNMutableContact, _ key: ContactKey, _ value: String) {
  switch key {
  case .namePrefix: contact.namePrefix = value
  case .givenName: contact.givenName = value
  case .middleName: contact.middleName = value
  case .familyName: contact.familyName = value
  case .previousFamilyName: contact.previousFamilyName = value
  case .nameSuffix: contact.nameSuffix = value
  case .nickname: contact.nickname = value
  case .phoneticGivenName: contact.phoneticGivenName = value
  case .phoneticMiddleName: contact.phoneticMiddleName = value
  case .phoneticFamilyName: contact.phoneticFamilyName = value
  case .phoneticOrganizationName: contact.phoneticOrganizationName = value
  case .organizationName: contact.organizationName = value
  case .departmentName: contact.departmentName = value
  case .jobTitle: contact.jobTitle = value
  // Lists, dates, the picture, and the note are not text properties of the card.
  default: break
  }
}
private func apply(_ changes: ContactChanges, to contact: CNMutableContact) throws {
  if let type = changes.contactType {
    contact.contactType = type == .organization ? .organization : .person
  }
  for (key, value) in changes.strings { setText(contact, key, value) }
  for key in changes.clear {
    switch key {
    case .phoneNumbers: contact.phoneNumbers = []
    case .emailAddresses: contact.emailAddresses = []
    case .postalAddresses: contact.postalAddresses = []
    case .urlAddresses: contact.urlAddresses = []
    case .contactRelations: contact.contactRelations = []
    case .socialProfiles: contact.socialProfiles = []
    case .instantMessageAddresses: contact.instantMessageAddresses = []
    case .dates: contact.dates = []
    case .birthday: contact.birthday = nil
    case .nonGregorianBirthday: contact.nonGregorianBirthday = nil
    case .imageData: contact.imageData = nil
    case .note: break
    default: setText(contact, key, "")
    }
  }
  // A list is read only when the patch changes it: reading a property the fetch left out
  // raises an exception that ends the process.
  if !changes.phoneNumbers.isEmpty {
    contact.phoneNumbers = try applied(
      changes.phoneNumbers, to: contact.phoneNumbers, .phoneNumbers)
  }
  if !changes.emailAddresses.isEmpty {
    contact.emailAddresses = try applied(
      changes.emailAddresses, to: contact.emailAddresses, .emailAddresses)
  }
  if !changes.postalAddresses.isEmpty {
    contact.postalAddresses = try applied(
      changes.postalAddresses, to: contact.postalAddresses, .postalAddresses)
  }
  if !changes.urlAddresses.isEmpty {
    contact.urlAddresses = try applied(
      changes.urlAddresses, to: contact.urlAddresses, .urlAddresses)
  }
  if !changes.contactRelations.isEmpty {
    contact.contactRelations = try applied(
      changes.contactRelations, to: contact.contactRelations, .contactRelations)
  }
  if !changes.socialProfiles.isEmpty {
    contact.socialProfiles = try applied(
      changes.socialProfiles, to: contact.socialProfiles, .socialProfiles)
  }
  if !changes.instantMessageAddresses.isEmpty {
    contact.instantMessageAddresses = try applied(
      changes.instantMessageAddresses, to: contact.instantMessageAddresses,
      .instantMessageAddresses)
  }
  if !changes.dates.isEmpty {
    contact.dates = try applied(changes.dates, to: contact.dates, .dates)
  }
  if let birthday = changes.birthday { contact.birthday = birthday }
  if let birthday = changes.nonGregorianBirthday { contact.nonGregorianBirthday = birthday }
  if let image = changes.imageData { contact.imageData = image }
}

// Creates or updates one card and returns its identifier. Nothing is stored unless the
// whole change applies.
func saveContact(_ write: ContactWrite, store: CNContactStore) throws -> String {
  let save = CNSaveRequest()
  switch write {
  case .create(let changes):
    let contact = CNMutableContact()
    try apply(changes, to: contact)
    let container = changes.containerIdentifier ?? store.defaultContainerIdentifier()
    guard
      try store.containers(
        matching: CNContainer.predicateForContainers(withIdentifiers: [container])
      )
      .count == 1
    else { throw ServerError.notFound("no container has this identifier") }
    let groups = try storedGroups(store, ids: changes.groupIdentifiers)
    for group in groups {
      guard try containerIdentifier(store, ofGroup: group.identifier) == container else {
        throw ServerError.invalidArgument(
          "group \(group.identifier) is in another container than the new card")
      }
    }
    save.add(contact, toContainerWithIdentifier: container)
    for group in groups { save.addMember(contact, to: group) }
    try execute(save, store)
    return contact.identifier
  case .update(let id, let changes):
    let contact = try storedContact(store, id: id, keys: changes.touchedKeys)
    try apply(changes, to: contact)
    save.update(contact)
    try execute(save, store)
    return id
  }
}

// Deletes one stored card. The user's own card is refused: Contacts and other apps
// depend on it.
func removeContact(id: String, store: CNContactStore) throws {
  let contact = try storedContact(store, id: id, keys: [CNContactIdentifierKey as CNKeyDescriptor])
  if let me = try? store.unifiedMeContactWithKeys(toFetch: [
    CNContactIdentifierKey as CNKeyDescriptor
  ]), me.identifier == id || me.isUnifiedWithContact(withIdentifier: id) {
    throw ServerError.unsupportedOperation(
      "this is the user's own card; choose another My Card before deleting it")
  }
  let save = CNSaveRequest()
  save.delete(contact)
  try execute(save, store)
}

// The group and every card exist, and the cards are stored in the group's container.
func checkMembers(_ members: [String], ofGroup id: String, store: CNContactStore) throws {
  _ = try storedGroups(store, ids: [id])
  var inContainer: Set<String> = []
  if let container = try containerIdentifier(store, ofGroup: id) {
    let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
    request.unifyResults = false
    request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: container)
    try store.enumerateContacts(with: request) { contact, _ in
      inContainer.insert(contact.identifier)
    }
  }
  for member in members {
    _ = try storedContact(store, id: member, keys: [CNContactIdentifierKey as CNKeyDescriptor])
    guard inContainer.contains(member) else {
      throw ServerError.invalidArgument("card \(member) is in another container than the group")
    }
  }
}

// Group writes.
enum GroupWrite: Sendable {
  case create(name: String, containerIdentifier: String?)
  case rename(id: String, name: String)
  case delete(id: String)
  case addMembers(id: String, contactIdentifiers: [String])
  case removeMembers(id: String, contactIdentifiers: [String])
}
// Applies the write and returns the group's identifier.
func saveGroup(_ write: GroupWrite, store: CNContactStore) throws -> String {
  func group(_ id: String) throws -> CNGroup {
    guard let group = try storedGroups(store, ids: [id]).first else {
      throw ServerError.notFound("no group has this id")
    }
    return group
  }
  func mutable(_ group: CNGroup) throws -> CNMutableGroup {
    guard let copy = group.mutableCopy() as? CNMutableGroup else {
      throw ServerError.internalError("Cannot copy a group")
    }
    return copy
  }
  let save = CNSaveRequest()
  let id: String
  switch write {
  case .create(let name, let container):
    let container = container ?? store.defaultContainerIdentifier()
    guard
      try store.containers(
        matching: CNContainer.predicateForContainers(withIdentifiers: [container])
      )
      .count == 1
    else { throw ServerError.notFound("no container has this identifier") }
    let group = CNMutableGroup()
    group.name = name
    save.add(group, toContainerWithIdentifier: container)
    id = group.identifier
  case .rename(let existing, let name):
    let group = try mutable(group(existing))
    group.name = name
    save.update(group)
    id = existing
  case .delete(let existing):
    save.delete(try mutable(group(existing)))
    id = existing
  case .addMembers, .removeMembers:
    // The framework accepts a removal and leaves the member in the group, and refuses
    // to add a card that has a note, so membership changes go through Contacts scripting.
    throw ServerError.internalError("Group members change through Contacts scripting")
  }
  try execute(save, store)
  return id
}
