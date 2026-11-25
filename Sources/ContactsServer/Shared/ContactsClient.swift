import Foundation

// AppleScript runs as one main-actor job; the pool releases its temporaries. Only
// Sendable records come back.
func onMainActor<T: Sendable>(_ body: @MainActor () throws -> T) async throws -> T {
  try await MainActor.run { try autoreleasepool(invoking: body) }
}

// Contacts loads a card the framework just saved a moment later. Awaiting the sleep
// releases the main actor, so other requests run between attempts.
private func untilSynchronized<T: Sendable>(_ attempt: @MainActor () throws -> T) async throws
  -> T
{
  let clock = ContinuousClock()
  let end = clock.now + .seconds(15)
  while true {
    do {
      return try await onMainActor(attempt)
    } catch is AutomationNotReady where clock.now < end {
      try await clock.sleep(for: .milliseconds(500))
    }
  }
}

// The fields only Contacts scripting provides; raw values are the API spelling.
enum ExtraField: String, CaseIterable, Codable, Sendable {
  case note = "NOTE"
  case creationDate = "CREATION_DATE"
  case modificationDate = "MODIFICATION_DATE"
}
// Scripting-only fields for every card, for the fields a request asked for. A card
// scripting does not list has none.
struct ContactExtras: Sendable {
  var notes: [String: String?]?
  var creationDates, modificationDates: [String: Date?]?

  func note(_ id: String) -> String? { notes?[id] ?? nil }
  func creationDate(_ id: String) -> Date? { creationDates?[id] ?? nil }
  func modificationDate(_ id: String) -> Date? { modificationDates?[id] ?? nil }
}
// One Apple event per field; reading any of them launches Contacts when it is not running.
func readExtras(_ fields: Set<ExtraField>) async throws -> ContactExtras {
  var extras = ContactExtras()
  if fields.contains(.note) { extras.notes = try await readProperty(.notes) }
  if fields.contains(.creationDate) {
    extras.creationDates = try await readProperty(.creationDates)
  }
  if fields.contains(.modificationDate) {
    extras.modificationDates = try await readProperty(.modificationDates)
  }
  return extras
}

// Sets the note through Contacts. Contacts saves the card as it holds it, so the note is
// set only once Contacts agrees with the store on whether the card has a picture, and
// the picture is checked again afterward.
private func writeNote(id: String, note: String?) async throws {
  let before = try await hasPicture(id: id)
  defer { invalidateContacts() }
  try await untilSynchronized { try setNote(id: id, note: note, hasImage: before) }
  guard try await hasPicture(id: id) == before else {
    throw ServerError.writeApplied(
      "The note of \(id) was saved, but the card \(before ? "lost" : "gained") a picture when Contacts saved it. Refetch the card and check its picture"
    )
  }
}

// A card after a write, with its note when the write changed it.
struct WrittenContact: Sendable {
  let record: ContactRecord
  // Set when the write touched the note: the note as it now is, nil when cleared.
  let note: String??
}

// Saves through the framework and sets the note through Contacts. A note change is
// checked first: without Automation access, or for a card scripting cannot see, the
// write fails before anything is saved.
//
// The framework cannot save a card that has a note. So a patch that clears the note
// clears it before the save, a patch that sets one sets it after, and a patch that
// changes other fields of a card whose note stays is refused.
func writeContact(_ write: ContactWrite) async throws -> WrittenContact {
  let changes = write.changes
  let noteChange: String??
  if let text = changes.strings[.note] {
    noteChange = .some(text)
  } else {
    noteChange = changes.clear.contains(.note) ? .some(nil) : nil
  }
  var clearsFirst = false
  if let noteChange, let existing = write.existingID {
    guard let current = try await readProperty(.notes)[existing] else {
      guard try await readContactsData().contact(id: existing) != nil else {
        throw ServerError.notFound("no card has this id")
      }
      throw ServerError.unsupportedOperation(
        "Contacts scripting does not list this card, so its note cannot be changed")
    }
    if current != nil, !changes.isFrameworkEmpty {
      guard noteChange == nil else { throw ServerError.unsupportedOperation(notedCardMessage) }
      clearsFirst = true
    }
  } else if noteChange != nil {
    // A new card: confirm Contacts answers before the card is stored.
    _ = try await readProperty(.notes)
  }
  if clearsFirst, let existing = write.existingID {
    do { try await writeNote(id: existing, note: nil) } catch {
      throw noteFailure(error, id: existing, saved: false)
    }
  }
  let id: String
  let saved: Bool
  if let existing = write.existingID, changes.isFrameworkEmpty {
    id = existing
    saved = false
  } else {
    defer { invalidateContacts() }
    do { id = try await writingContacts { store in try saveContact(write, store: store) } } catch
      where clearsFirst
    {
      throw ServerError.writeApplied(
        "The note of \(write.existingID ?? "the card") was removed, but the card's other changes were not saved: \(error). Refetch the card before retrying"
      )
    }
    saved = true
  }
  if let noteChange, !clearsFirst {
    do { try await writeNote(id: id, note: noteChange) } catch {
      throw noteFailure(error, id: id, saved: saved)
    }
  }
  guard let record = try await readContactsData().contact(id: id) else {
    throw ServerError.writeApplied(
      "The card \(id) was saved but could not be refetched. Refetch this id before retrying")
  }
  return WrittenContact(record: record, note: noteChange)
}
// The note step failed. When the framework already saved the card's other changes, the
// client must learn that part of the write was stored.
private func noteFailure(_ error: Error, id: String, saved: Bool) -> Error {
  let also = saved ? "; the card's other changes were saved" : ""
  switch error {
  case let server as ServerError where server.code == .writeApplied: return server
  case is AutomationTimedOut:
    return ServerError.writeApplied(
      "\(automationTimedOutMessage), so the note of \(id) may or may not have been stored\(also). Refetch the card before retrying"
    )
  case let notReady as AutomationNotReady where notReady.code == stalePictureCode:
    let message = "\(stalePictureMessage)\(also)"
    return saved ? ServerError.writeApplied(message) : ServerError.unsupportedOperation(message)
  case let notReady as AutomationNotReady where !saved:
    return ServerError.notFound(
      "Contacts scripting cannot find this card (code \(notReady.code)): \(notReady.message)")
  case let notReady as AutomationNotReady:
    return ServerError.writeApplied(
      "The card \(id) was saved, but Contacts did not expose it to scripting in time to set its note (code \(notReady.code): \(notReady.message)). Refetch this id before retrying"
    )
  default:
    guard saved else { return error }
    let reason = error is CancellationError ? "the request was cancelled" : "\(error)"
    return ServerError.writeApplied(
      "The card \(id) was saved, but its note was not set: \(reason). Refetch this id before retrying"
    )
  }
}

// Makes the card My Card through Contacts and returns it as the store then reports it.
func setMeContact(id: String) async throws -> ContactRecord {
  guard try await readContactsData().contact(id: id) != nil else {
    throw ServerError.notFound("no card has this id")
  }
  defer { invalidateContacts() }
  do { try await untilSynchronized { try setMyCard(id: id) } } catch is AutomationTimedOut {
    throw ServerError.writeApplied(
      "\(automationTimedOutMessage), so My Card may or may not have changed; refetch defaults before retrying"
    )
  } catch let notReady as AutomationNotReady {
    throw ServerError.notFound(
      "Contacts scripting cannot find this card (code \(notReady.code)): \(notReady.message)")
  }
  invalidateContacts()
  guard let record = try await readContactsData().contact(id: id) else {
    throw ServerError.writeApplied("My Card was set, but the card could not be refetched")
  }
  return record
}

// Selects the card in Contacts. Navigation only: nothing is stored.
func showContact(id: String) async throws -> ContactRecord {
  guard let record = try await readContactsData().contact(id: id) else {
    throw ServerError.notFound("no card has this id")
  }
  do { try await untilSynchronized { try showPerson(id: id) } } catch is AutomationTimedOut {
    throw ServerError.showFailed(automationTimedOutMessage)
  } catch let notReady as AutomationNotReady {
    throw ServerError.showFailed(
      "Contacts scripting cannot find this card (code \(notReady.code)): \(notReady.message)")
  }
  return record
}

// A deleted card, with a vCard of it taken just before the delete so it can be restored.
struct DeletedContact: Encodable, Sendable {
  let deletedId: String
  let vCard: String
  enum CodingKeys: String, CodingKey { case deletedId, vCard }
}
// Deletes one stored card. The recovery copy carries the note when Contacts scripting
// answers; a delete does not fail because the note could not be read.
func deleteContact(id: String, includeImage: Bool) async throws -> DeletedContact {
  guard try await readContactsData().contact(id: id) != nil else {
    throw ServerError.notFound("no card has this id")
  }
  let notes = try? await readProperty(.notes)
  let copy = try await exportVCard(
    VCardRequest(identifiers: [id], notes: notes, includeImages: includeImage))
  guard copy.contactCount == 1 else { throw ServerError.notFound("no card has this id") }
  defer { invalidateContacts() }
  try await writingContacts { store in try removeContact(id: id, store: store) }
  return DeletedContact(deletedId: id, vCard: copy.vCard)
}

struct DeletedGroup: Encodable, Sendable {
  let deletedId: String
  enum CodingKeys: String, CodingKey { case deletedId }
}
// Applies a group write and returns the group as the store then reports it. Membership
// changes go through Contacts scripting: the framework accepts a removal and leaves the
// member in the group, and it refuses to add a card that has a note.
func writeGroup(_ write: GroupWrite) async throws -> GroupRecord {
  let id: String
  switch write {
  case .addMembers(let group, let members), .removeMembers(let group, let members):
    try await onContactsQueue { store in try checkMembers(members, ofGroup: group, store: store) }
    var adding = false
    if case .addMembers = write { adding = true }
    defer { invalidateContacts() }
    do {
      try await untilSynchronized { [adding] in
        try changeMembers(groupID: group, personIDs: members, adding: adding)
      }
    } catch is AutomationTimedOut {
      throw ServerError.writeApplied(
        "\(automationTimedOutMessage), so the group's members may or may not have changed; refetch the group before retrying"
      )
    } catch let notReady as AutomationNotReady {
      throw ServerError.notFound(
        "Contacts scripting cannot find the group or a card (code \(notReady.code)): \(notReady.message)"
      )
    }
    id = group
  default:
    id = try await writingContacts { store in try saveGroup(write, store: store) }
  }
  invalidateContacts()
  guard let record = try await readContactsData().group(id: id) else {
    throw ServerError.writeApplied(
      "The group \(id) was saved but could not be refetched. Refetch this id before retrying")
  }
  return record
}
func deleteGroup(id: String) async throws -> DeletedGroup {
  defer { invalidateContacts() }
  _ = try await writingContacts { store in try saveGroup(.delete(id: id), store: store) }
  return DeletedGroup(deletedId: id)
}
