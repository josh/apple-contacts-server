import Contacts
import Foundation

import struct os.OSAllocatedUnfairLock

// The Contacts framework reads and writes the address book without launching Contacts.
// Only Sendable records leave this file's queue.
//
// The store has its own serial queue instead of the main actor: its calls block for as
// long as they take, and that wait must not stall AppleScript or trip the main-actor
// watchdog. One queue also keeps a write's fetch, change, and save from interleaving
// with another request's.
private let settingsPath = "System Settings > Privacy & Security > Contacts"
private let contactsQueue = DispatchQueue(label: "apple-contacts-server.contacts")

func statusName() -> String {
  switch CNContactStore.authorizationStatus(for: .contacts) {
  case .notDetermined: return "notDetermined"
  case .restricted: return "restricted"
  case .denied: return "denied"
  case .authorized: return "authorized"
  default: return "unknown"
  }
}
var hasAccess: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }
// Checked before every store call: a fetch made while macOS is still asking would wait
// on the queue behind the prompt. The message says how to fix the state macOS reports.
func requireAccess() throws {
  let problem: String
  switch CNContactStore.authorizationStatus(for: .contacts) {
  case .authorized: return
  case .denied: problem = "Contacts access is denied; allow it in \(settingsPath)"
  case .restricted:
    problem = "Contacts access is restricted on this Mac, for example by a profile or Screen Time"
  case .notDetermined:
    problem =
      "Contacts access has not been granted; answer the server's prompt, or set \(ConfigVariable.requestAccess.rawValue)=1 in the launchd plist so the server can ask"
  default:
    problem = "Contacts access is in a state this server does not recognize; check \(settingsPath)"
  }
  throw ServerError.notAuthorized(problem)
}
// Asks macOS for access. A refusal is reported, not fatal: the server keeps answering,
// and requireAccess explains the state to each caller.
func authorizeContacts() async throws {
  let granted: Bool
  do { granted = try await CNContactStore().requestAccess(for: .contacts) } catch {
    let native = error as NSError
    // The framework reports a refusal as an error; requireAccess words it better.
    try requireAccess()
    throw ServerError.notAuthorized(
      "Contacts authorization failed (\(native.domain) code \(native.code))")
  }
  try requireAccess()
  guard granted else { throw ServerError.notAuthorized("the access request was refused") }
}

// Runs one framework write and drops the snapshot, whether or not the write succeeded.
// The server never quits Contacts: it may start it for a scripting request, and it
// leaves it open.
func writingContacts<T: Sendable>(_ body: @escaping @Sendable (CNContactStore) throws -> T)
  async throws -> T
{
  defer { invalidateContacts() }
  return try await onContactsQueue(body)
}

// Runs one read or write on the contacts queue with a fresh store, so nothing a
// previous request fetched is reused.
func onContactsQueue<T: Sendable>(_ body: @escaping @Sendable (CNContactStore) throws -> T)
  async throws -> T
{
  try requireAccess()
  return try await withCheckedThrowingContinuation { continuation in
    contactsQueue.async {
      continuation.resume(
        with: Result {
          do { return try autoreleasepool { try body(CNContactStore()) } } catch {
            throw contactsError(error)
          }
        })
    }
  }
}

// A framework failure as the error clients act on.
func contactsError(_ error: Error) -> Error {
  if error is ServerError { return error }
  let native = error as NSError
  guard native.domain == CNErrorDomain, let code = CNError.Code(rawValue: native.code) else {
    return error
  }
  let detail = "\(native.localizedDescription) (CNError \(native.code))"
  switch code {
  case .authorizationDenied:
    return ServerError.notAuthorized("Contacts access is denied; allow it in \(settingsPath)")
  case .recordDoesNotExist: return ServerError.notFound(detail)
  case .insertedRecordAlreadyExists, .containmentCycle, .containmentScope,
    .parentRecordDoesNotExist, .recordIdentifierInvalid, .validationMultipleErrors,
    .validationTypeMismatch, .validationConfigurationError:
    return ServerError.invalidArgument(detail)
  case .recordNotWritable, .parentContainerNotWritable:
    return ServerError.readOnly(detail)
  case .policyViolation, .featureDisabledByUser, .featureNotAvailable:
    return ServerError.unsupportedOperation(detail)
  default: return ServerError.internalError(detail)
  }
}

// Every key a record is built from, fetched together so no record reads a property the
// fetch left out: that raises an exception Swift cannot catch. The note is absent
// because the framework refuses the whole fetch without an entitlement this executable
// cannot carry; notes come from Contacts scripting instead.
let contactKeys: [CNKeyDescriptor] =
  [
    CNContactIdentifierKey, CNContactTypeKey,
    CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey,
    CNContactFamilyNameKey, CNContactPreviousFamilyNameKey, CNContactNameSuffixKey,
    CNContactNicknameKey,
    CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey,
    CNContactPhoneticFamilyNameKey, CNContactPhoneticOrganizationNameKey,
    CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey,
    CNContactBirthdayKey, CNContactNonGregorianBirthdayKey, CNContactDatesKey,
    CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey,
    CNContactUrlAddressesKey, CNContactRelationsKey, CNContactSocialProfilesKey,
    CNContactInstantMessageAddressesKey,
    CNContactImageDataAvailableKey,
  ].map { $0 as CNKeyDescriptor } + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
private let identifierOnly = [CNContactIdentifierKey as CNKeyDescriptor]

// Stored cards matching the predicate, or all of them. Unification is off so each
// record is one card, with the identifier Contacts scripting knows it by.
private func storedContacts(
  _ store: CNContactStore, keys: [CNKeyDescriptor], predicate: NSPredicate? = nil
) throws -> [CNContact] {
  let request = CNContactFetchRequest(keysToFetch: keys)
  request.unifyResults = false
  request.sortOrder = .none
  request.predicate = predicate
  var contacts: [CNContact] = []
  try store.enumerateContacts(with: request) { contact, _ in contacts.append(contact) }
  return contacts
}
private func identifiers(_ store: CNContactStore, matching predicate: NSPredicate) throws
  -> [String]
{
  try storedContacts(store, keys: identifierOnly, predicate: predicate).map(\.identifier)
}

// Which cards Contacts shows as one person. A unified fetch returns one contact per
// person; a card missing from it was folded into another, and the unified contact says
// which. Without linked cards the two fetches agree and nothing more is asked.
private func linkedGroups(_ store: CNContactStore, stored: Set<String>) throws -> [[String]] {
  let request = CNContactFetchRequest(keysToFetch: identifierOnly)
  request.unifyResults = true
  request.sortOrder = .none
  var unified: [CNContact] = []
  try store.enumerateContacts(with: request) { contact, _ in unified.append(contact) }
  let shown = Set(unified.map(\.identifier))
  let folded = stored.subtracting(shown)
  guard !folded.isEmpty else { return [] }
  var groups: [String: [String]] = [:]
  for card in folded.sorted() {
    guard let owner = unified.first(where: { $0.isUnifiedWithContact(withIdentifier: card) })
    else { continue }
    groups[owner.identifier, default: stored.contains(owner.identifier) ? [owner.identifier] : []]
      .append(card)
  }
  return groups.values.filter { $0.count > 1 }.map { $0.sorted() }
}

// Reads the whole store. Membership comes from one identifier-only fetch per container
// and per group, since a card does not say where it is stored.
func loadContactsData(_ store: CNContactStore) throws -> ContactsData {
  let started = ContinuousClock.now
  let containers = try store.containers(matching: nil).sorted { $0.identifier < $1.identifier }
  let defaultContainer = store.defaultContainerIdentifier()
  var containerOf: [String: String] = [:]
  var groupsOf: [String: [String]] = [:]
  var groups: [GroupRecord] = []
  var containerRecords: [ContainerRecord] = []
  for container in containers {
    let members = try identifiers(
      store,
      matching: CNContact.predicateForContactsInContainer(withIdentifier: container.identifier))
    for member in members { containerOf[member] = container.identifier }
    let found = try store.groups(
      matching: CNGroup.predicateForGroupsInContainer(withIdentifier: container.identifier))
    for group in found.sorted(by: { $0.identifier < $1.identifier }) {
      let members = try identifiers(
        store, matching: CNContact.predicateForContactsInGroup(withIdentifier: group.identifier))
      for member in members { groupsOf[member, default: []].append(group.identifier) }
      let subgroups = try store.groups(
        matching: CNGroup.predicateForSubgroupsInGroup(withIdentifier: group.identifier))
      groups.append(
        GroupRecord(
          identifier: group.identifier, name: group.name,
          containerIdentifier: container.identifier,
          subgroupIdentifiers: subgroups.map(\.identifier).sorted(), memberCount: members.count))
    }
    containerRecords.append(
      ContainerRecord(
        identifier: container.identifier, name: container.name,
        type: ContainerType(container.type), isDefault: container.identifier == defaultContainer,
        contactCount: members.count, groupCount: found.count))
  }
  var parentOf: [String: String] = [:]
  for group in groups {
    for child in group.subgroupIdentifiers { parentOf[child] = group.identifier }
  }
  for index in groups.indices {
    groups[index].parentGroupIdentifier = parentOf[groups[index].identifier]
  }

  var contacts = try storedContacts(store, keys: contactKeys).map(ContactRecord.init)
  let stored = Set(contacts.map(\.identifier))
  var linkedTo: [String: [String]] = [:]
  for group in try linkedGroups(store, stored: stored) {
    for card in group { linkedTo[card] = group.filter { $0 != card } }
  }
  // The me card comes back unified, so its identifier may be any of that person's cards.
  let me = try? store.unifiedMeContactWithKeys(toFetch: identifierOnly)
  let meCards = me.map { me in
    stored.filter { $0 == me.identifier || me.isUnifiedWithContact(withIdentifier: $0) }
  }
  for index in contacts.indices {
    let id = contacts[index].identifier
    contacts[index].containerIdentifier = containerOf[id]
    contacts[index].groupIdentifiers = (groupsOf[id] ?? []).sorted()
    contacts[index].linkedContactIdentifiers = linkedTo[id] ?? []
    contacts[index].isMe = meCards?.contains(id) ?? false
  }
  serverLogger.debug(
    "Read contacts",
    metadata: [
      "contacts": "\(contacts.count)", "groups": "\(groups.count)",
      "containers": "\(containerRecords.count)",
      "duration_ms": "\(started.duration(to: .now) / .milliseconds(1))",
    ])
  return ContactsData(
    containers: containerRecords, groups: groups, contacts: contacts,
    defaultContainerIdentifier: defaultContainer,
    meContactIdentifier: meCards.flatMap { cards in
      me.flatMap { cards.contains($0.identifier) ? $0.identifier : cards.sorted().first }
    })
}
// Reading every card takes about half a second, so one snapshot serves requests until
// the store says it changed, this server writes to it, or the snapshot grows old.
private let snapshotMaxAge: Duration = .seconds(300)
// Touched only on contactsQueue.
private final class StoreState: @unchecked Sendable {
  var snapshot: (data: ContactsData, loaded: ContinuousClock.Instant)?
}
private let state = StoreState()
private let snapshotStale = OSAllocatedUnfairLock(initialState: true)
// The next read reloads the store.
func invalidateContacts() { snapshotStale.withLock { $0 = true } }

// The framework posts one coarse notification for any change, this server's own saves
// included, on a background thread. It is delivered only while the process holds a store.
private let observedStore = CNContactStore()
func observeContactChanges() {
  _ = observedStore
  _ = NotificationCenter.default.addObserver(
    forName: .CNContactStoreDidChange, object: nil, queue: nil
  ) { _ in
    serverLogger.debug("Contacts changed")
    invalidateContacts()
  }
}

// Every container, group, and stored card, from the snapshot when it is current.
func readContactsData() async throws -> ContactsData {
  try await onContactsQueue { store in
    // Cleared before loading, so a change that arrives during the load is not lost.
    let stale = snapshotStale.withLock { stale in
      defer { stale = false }
      return stale
    }
    if let snapshot = state.snapshot, !stale, snapshot.loaded.duration(to: .now) < snapshotMaxAge {
      return snapshot.data
    }
    do {
      let data = try loadContactsData(store)
      state.snapshot = (data, .now)
      return data
    } catch {
      invalidateContacts()
      throw error
    }
  }
}
