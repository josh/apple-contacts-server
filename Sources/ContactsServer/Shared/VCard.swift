import Contacts
import Foundation

// vCard 3.0 export. The framework writes every property it can read, which leaves out
// the note and the picture, so those are added to each card as NOTE and PHOTO lines.

struct VCardExport: Sendable {
  let vCard: String
  let contactCount: Int
  let byteCount: Int
  init(cards: [String]) {
    vCard = cards.joined()
    contactCount = cards.count
    byteCount = vCard.utf8.count
  }
}

// RFC 2426 text escaping.
private func escaped(_ text: String) -> String {
  var result = ""
  for character in text {
    switch character {
    case "\\": result += "\\\\"
    case ",": result += "\\,"
    case ";": result += "\\;"
    case "\r\n", "\n", "\r": result += "\\n"
    default: result.append(character)
    }
  }
  return result
}
// Folds a content line at 75 octets, never inside a character.
private func foldedLine(_ line: String) -> String {
  var result = ""
  var width = 0
  for character in line {
    let size = character.utf8.count
    if width + size > 75 {
      result += "\r\n "
      width = 1
    }
    result.append(character)
    width += size
  }
  return result + "\r\n"
}
private func card(_ contact: CNContact, note: String?, includeImage: Bool) throws -> String {
  var text = String(
    decoding: try CNContactVCardSerialization.data(with: [contact]), as: UTF8.self)
  var extra = ""
  if let note, !note.isEmpty { extra += foldedLine("NOTE:" + escaped(note)) }
  if includeImage, contact.isKeyAvailable(CNContactImageDataKey), let image = contact.imageData {
    extra += foldedLine(
      "PHOTO;ENCODING=b;TYPE=\(imageType(image)):" + image.base64EncodedString())
  }
  guard let end = text.range(of: "END:VCARD", options: .backwards) else {
    throw ServerError.internalError("The framework wrote a vCard without an end")
  }
  text.insert(contentsOf: extra, at: end.lowerBound)
  return text
}

// Which cards to export and what to add to them. `notes` maps a stored card's
// identifier to its note; `linked` names the other cards unified with each.
struct VCardRequest: Sendable {
  var identifiers: [String]?
  var unify = false
  var notes: [String: String?]?
  var linked: [String: [String]] = [:]
  var includeImages = false
}
func exportVCard(_ request: VCardRequest) async throws -> VCardExport {
  try await onContactsQueue { store in
    var keys = [CNContactVCardSerialization.descriptorForRequiredKeys()]
    if request.includeImages { keys.append(CNContactImageDataKey as CNKeyDescriptor) }
    let fetch = CNContactFetchRequest(keysToFetch: keys)
    fetch.unifyResults = request.unify
    fetch.sortOrder = .userDefault
    if let identifiers = request.identifiers {
      fetch.predicate = CNContact.predicateForContacts(withIdentifiers: identifiers)
    }
    var contacts: [CNContact] = []
    try store.enumerateContacts(with: fetch) { contact, _ in contacts.append(contact) }
    // A unified contact carries the notes of every card it shows together.
    func note(_ id: String) -> String? {
      guard let notes = request.notes else { return nil }
      let cards = [id] + (request.unify ? request.linked[id] ?? [] : [])
      var seen: [String] = []
      for text in cards.compactMap({ notes[$0] ?? nil }) where !seen.contains(text) {
        seen.append(text)
      }
      return seen.isEmpty ? nil : seen.joined(separator: "\n\n")
    }
    return VCardExport(
      cards: try contacts.map {
        try card($0, note: note($0.identifier), includeImage: request.includeImages)
      })
  }
}
