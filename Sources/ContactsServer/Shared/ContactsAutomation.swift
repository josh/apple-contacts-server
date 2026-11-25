import AppKit
import Carbon
import Foundation

// Contacts scripting supplies what the Contacts framework cannot give this executable:
// notes, creation and modification dates, the selected card, and setting My Card.
// Sending Contacts an Apple event launches it, so only API requests that need these
// reach this file; metrics collection and plain reads never do.
//
// A scripting `person` is one stored card, and its `id` is the card's CNContact
// identifier, so the two paths join on it.
let contactsBundleID = "com.apple.AddressBook"
private let automationSettingsPath = "System Settings > Privacy & Security > Automation"

// -1743: the user has not allowed this server to control Contacts.
private let notPermittedCode = -1743
// -1728: no such object, which is also what Contacts answers for a card the framework
// saved a moment ago and it has not loaded yet; -10006: it refused a set.
private let notReadyCodes: Set<Int> = [-1728, -10006]
// -1712: Contacts did not answer an event in time. Whatever the event was sent to do
// may still have happened.
private let timedOutCode = -1712
// The note handler raises this when Contacts and the store disagree on whether a card
// has a picture. Contacts catches up with a picture the framework just stored within
// seconds, so the step is retried like a card it has not loaded yet.
let stalePictureCode = 9001
let stalePictureMessage =
  "Contacts and the contact store disagree on whether this card has a picture, and Contacts would save its own version, so the note was not set. Retry in a moment"
struct AutomationTimedOut: Error {}
// Callers retry the automation step only; a framework save never repeats.
struct AutomationNotReady: Error, Sendable {
  let code: Int
  let message: String
}
let automationTimedOutMessage = "Contacts did not answer in time"

// The running Contacts, when there is one. A new process means a fresh copy of every card.
func contactsProcessID() -> pid_t? {
  NSRunningApplication.runningApplications(withBundleIdentifier: contactsBundleID).first?
    .processIdentifier
}

// A failed Apple event, as the error clients act on.
private func automationError(_ error: NSDictionary, what: String) -> Error {
  let code = error[NSAppleScript.errorNumber] as? Int ?? 0
  let message = error[NSAppleScript.errorMessage] as? String ?? "unknown"
  if code == timedOutCode { return AutomationTimedOut() }
  if code == notPermittedCode {
    return ServerError.notAuthorized(
      "This server is not allowed to control Contacts; allow it in \(automationSettingsPath)")
  }
  if notReadyCodes.contains(code) || code == stalePictureCode {
    return AutomationNotReady(code: code, message: message)
  }
  return ServerError.internalError("\(what) failed (code \(code)): \(message)")
}

// Fixed handlers compiled once per process. No client text becomes source.
@MainActor private var compiledScripts: [String: NSAppleScript] = [:]
@MainActor
private func compiledScript(_ source: String, what: String) throws -> NSAppleScript {
  if let script = compiledScripts[source] { return script }
  guard let script = NSAppleScript(source: source) else {
    throw ServerError.internalError("Cannot create \(what)")
  }
  var error: NSDictionary?
  guard script.compileAndReturnError(&error) else {
    throw ServerError.internalError(
      "Cannot compile \(what) (code \(error?[NSAppleScript.errorNumber] as? Int ?? 0))")
  }
  compiledScripts[source] = script
  return script
}
// A fixed AppleScript handler, written once: its name is both the `on` line of its
// source and the subroutine the server calls.
struct AutomationHandler: Sendable {
  let name: String
  let parameters: [String]
  let body: String
  var source: String {
    "on \(name)(\(parameters.joined(separator: ", ")))\n\(body)\nend \(name)\n"
  }
}
// Calls a handler with typed Apple-event arguments, one per parameter.
@MainActor
private func call(_ handler: AutomationHandler, _ arguments: [NSAppleEventDescriptor]) throws
  -> NSAppleEventDescriptor
{
  guard arguments.count == handler.parameters.count else {
    throw ServerError.internalError("Wrong argument count for \(handler.name)")
  }
  let script = try compiledScript(handler.source, what: "Contacts handler \(handler.name)")
  let list = NSAppleEventDescriptor.list()
  for (index, value) in arguments.enumerated() { list.insert(value, at: index + 1) }
  let event = NSAppleEventDescriptor(
    eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
    targetDescriptor: nil, returnID: -1, transactionID: 0)
  event.setParam(.init(string: handler.name), forKeyword: AEKeyword(keyASSubroutineName))
  event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
  var error: NSDictionary?
  let result = script.executeAppleEvent(event, error: &error)
  if let error { throw automationError(error, what: "Contacts handler \(handler.name)") }
  return result
}

private func isMissing(_ value: NSAppleEventDescriptor) -> Bool {
  value.descriptorType == DescType(typeType) && value.typeCodeValue == OSType(cMissingValue)
}
@Sendable private func scriptText(_ value: NSAppleEventDescriptor) -> String? {
  guard !isMissing(value), let text = value.stringValue, !text.isEmpty else { return nil }
  return text
}
// Contacts is a Cocoa scripting app: it packs a date with the same conversion
// NSAppleEventDescriptor uses to unpack one, so the descriptor's own value is the instant.
@Sendable private func scriptDate(_ value: NSAppleEventDescriptor) -> Date? {
  isMissing(value) ? nil : value.dateValue
}

// One property of every person, keyed by identifier.
struct ScriptProperty<Value: Sendable>: Sendable {
  let expression: String
  let decode: @Sendable (NSAppleEventDescriptor) -> Value
}
extension ScriptProperty where Value == String? {
  static let notes = Self(expression: "note", decode: scriptText)
}
extension ScriptProperty where Value == Date? {
  static let creationDates = Self(expression: "creation date", decode: scriptDate)
  static let modificationDates = Self(expression: "modification date", decode: scriptDate)
}
// Reads the identifiers before and after the property so an address book that changed
// in between is reported instead of pairing values with the wrong cards.
func readProperty<Value: Sendable>(_ property: ScriptProperty<Value>) async throws
  -> [String: Value]
{
  try await onMainActor {
    let source = """
      with timeout of 30 seconds
          tell application id "\(contactsBundleID)"
              set idsBefore to id of every person
              set rows to \(property.expression) of every person
              set idsAfter to id of every person
              return {idsBefore, rows, idsAfter}
          end tell
      end timeout
      """
    let script = try compiledScript(source, what: "Contacts property read")
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error {
      switch automationError(error, what: "Contacts property read") {
      case is AutomationTimedOut: throw ServerError.internalError(automationTimedOutMessage)
      case let notReady as AutomationNotReady:
        throw ServerError.internalError(
          "Contacts property read failed (code \(notReady.code)): \(notReady.message)")
      case let failure: throw failure
      }
    }
    guard result.numberOfItems == 3, let before = result.atIndex(1), let rows = result.atIndex(2),
      let after = result.atIndex(3),
      [before, rows, after].allSatisfy({ $0.descriptorType == DescType(typeAEList) }),
      before.numberOfItems == rows.numberOfItems, after.numberOfItems == rows.numberOfItems
    else { throw ServerError.internalError("Inconsistent Contacts property read") }
    var output: [String: Value] = [:]
    for index in 0..<rows.numberOfItems {
      guard let value = rows.atIndex(index + 1),
        let id = before.atIndex(index + 1)?.stringValue,
        id == after.atIndex(index + 1)?.stringValue
      else { throw ServerError.internalError("Contacts changed during the read; retry") }
      // updateValue preserves an explicit nil payload when Value is Optional.
      guard output.updateValue(property.decode(value), forKey: id) == nil else {
        throw ServerError.internalError("Contacts reported one identifier twice")
      }
    }
    return output
  }
}

extension AutomationHandler {
  // Variable names avoid Contacts' own terms: inside the tell block a word such as
  // `note` or `selection` names an application property.
  //
  // `save` commits every unsaved change in Contacts, which is the only way scripting
  // stores an edit. Contacts saves the card as it holds it, so the note is set only when
  // Contacts agrees with the store on whether the card has a picture. A missing value,
  // not "", clears the note: an empty note still counts as a note to the framework,
  // which then refuses to save the card.
  static let setNote = AutomationHandler(
    name: "setnote", parameters: ["personID", "clearNote", "noteValue", "expectImage"],
    body: """
          with timeout of 15 seconds
              tell application id "\(contactsBundleID)"
                  set target to person id personID
                  set hasImage to (image of target is not missing value)
                  if hasImage is not expectImage then error "picture differs from the store" number \(stalePictureCode)
                  if clearNote then
                      set note of target to missing value
                  else
                      set note of target to noteValue
                  end if
                  save
                  return {id of target, note of target}
              end tell
          end timeout
      """)
  static let changeMembers = AutomationHandler(
    name: "changemembers", parameters: ["groupID", "personIDs", "adding"],
    body: """
          with timeout of 30 seconds
              tell application id "\(contactsBundleID)"
                  set theGroup to group id groupID
                  repeat with personID in personIDs
                      if adding then
                          add (person id (personID as text)) to theGroup
                      else
                          remove (person id (personID as text)) from theGroup
                      end if
                  end repeat
                  save
                  return id of every person of theGroup
              end tell
          end timeout
      """)
  static let setMyCard = AutomationHandler(
    name: "setmycard", parameters: ["personID"],
    body: """
          with timeout of 15 seconds
              tell application id "\(contactsBundleID)"
                  set target to person id personID
                  set my card to target
                  save
                  return id of my card
              end tell
          end timeout
      """)
  static let showPerson = AutomationHandler(
    name: "showperson", parameters: ["personID"],
    body: """
          with timeout of 15 seconds
              tell application id "\(contactsBundleID)"
                  set target to person id personID
                  set selection to {target}
                  activate
                  set shown to selection
                  if (count of shown) is not 1 then error "Contacts did not select the card"
                  return id of item 1 of shown
              end tell
          end timeout
      """)
}

// Sets or clears one card's note and confirms Contacts kept it. `hasImage` is whether the
// store has a picture for the card.
@MainActor
func setNote(id: String, note: String?, hasImage: Bool) throws {
  let result = try call(
    .setNote,
    [
      .init(string: id), .init(boolean: note == nil), .init(string: note ?? ""),
      .init(boolean: hasImage),
    ])
  guard result.numberOfItems == 2, result.atIndex(1)?.stringValue == id,
    let kept = result.atIndex(2)
  else { throw ServerError.internalError("Contacts returned an inconsistent note") }
  guard scriptText(kept) == note else {
    throw ServerError.writeApplied(
      "Contacts accepted the note for \(id) but did not keep it as written; refetch the card before retrying"
    )
  }
}
// Adds cards to a group or removes them from it, and confirms Contacts lists the group
// that way afterward.
@MainActor
func changeMembers(groupID: String, personIDs: [String], adding: Bool) throws {
  let people = NSAppleEventDescriptor.list()
  for (index, id) in personIDs.enumerated() { people.insert(.init(string: id), at: index + 1) }
  let result = try call(
    .changeMembers, [.init(string: groupID), people, .init(boolean: adding)])
  let count = result.numberOfItems
  let members = Set(count > 0 ? (1...count).compactMap { result.atIndex($0)?.stringValue } : [])
  guard adding ? members.isSuperset(of: personIDs) : members.isDisjoint(with: personIDs) else {
    throw ServerError.writeFailed(
      "Contacts did not \(adding ? "add the cards to" : "remove the cards from") the group")
  }
}
@MainActor
func setMyCard(id: String) throws {
  let result = try call(.setMyCard, [.init(string: id)])
  guard result.stringValue == id else {
    throw ServerError.writeApplied(
      "Contacts accepted the change but reports another card as My Card; refetch defaults before retrying"
    )
  }
}
// Selects the card in Contacts and brings Contacts forward.
@MainActor
func showPerson(id: String) throws {
  let result = try call(.showPerson, [.init(string: id)])
  guard result.stringValue == id else {
    throw ServerError.showFailed("Contacts selected another card")
  }
}
