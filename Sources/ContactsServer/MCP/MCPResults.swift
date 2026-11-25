import Foundation

// A stored card as MCP returns it: the framework's fields, read without launching
// Contacts, and the scripting-only fields a call asked for. Absent values and empty
// lists are omitted to keep results short.
struct MCPContact: Encodable {
  let record: ContactRecord
  let note: String?
  let creationDate, modificationDate: Date?

  init(record: ContactRecord, extras: ContactExtras = .init(), include: Set<ExtraField> = []) {
    self.record = record
    note = include.contains(.note) ? extras.note(record.identifier) : nil
    creationDate = include.contains(.creationDate) ? extras.creationDate(record.identifier) : nil
    modificationDate =
      include.contains(.modificationDate) ? extras.modificationDate(record.identifier) : nil
  }
  // A card after a write, with its note when the write changed it.
  init(written: WrittenContact) {
    record = written.record
    note = written.note ?? nil
    creationDate = nil
    modificationDate = nil
  }

  enum CodingKeys: String, CodingKey {
    case identifier, contactType, fullName, namePrefix, givenName, middleName, familyName
    case previousFamilyName, nameSuffix, nickname, phoneticGivenName, phoneticMiddleName
    case phoneticFamilyName, phoneticOrganizationName, organizationName, departmentName, jobTitle
    case phoneNumbers, emailAddresses, postalAddresses, urlAddresses, contactRelations
    case socialProfiles, instantMessageAddresses, dates, birthday, nonGregorianBirthday
    case imageDataAvailable, containerIdentifier, groupIdentifiers, linkedContactIdentifiers, isMe
    case note, creationDate, modificationDate
  }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    func list<Item: Encodable>(_ items: [Item], _ key: CodingKeys) throws {
      if !items.isEmpty { try c.encode(items, forKey: key) }
    }
    try c.encode(record.identifier, forKey: .identifier)
    try c.encode(record.contactType, forKey: .contactType)
    try c.encodeIfPresent(record.fullName, forKey: .fullName)
    try c.encodeIfPresent(record.namePrefix, forKey: .namePrefix)
    try c.encodeIfPresent(record.givenName, forKey: .givenName)
    try c.encodeIfPresent(record.middleName, forKey: .middleName)
    try c.encodeIfPresent(record.familyName, forKey: .familyName)
    try c.encodeIfPresent(record.previousFamilyName, forKey: .previousFamilyName)
    try c.encodeIfPresent(record.nameSuffix, forKey: .nameSuffix)
    try c.encodeIfPresent(record.nickname, forKey: .nickname)
    try c.encodeIfPresent(record.phoneticGivenName, forKey: .phoneticGivenName)
    try c.encodeIfPresent(record.phoneticMiddleName, forKey: .phoneticMiddleName)
    try c.encodeIfPresent(record.phoneticFamilyName, forKey: .phoneticFamilyName)
    try c.encodeIfPresent(record.phoneticOrganizationName, forKey: .phoneticOrganizationName)
    try c.encodeIfPresent(record.organizationName, forKey: .organizationName)
    try c.encodeIfPresent(record.departmentName, forKey: .departmentName)
    try c.encodeIfPresent(record.jobTitle, forKey: .jobTitle)
    try list(record.phoneNumbers, .phoneNumbers)
    try list(record.emailAddresses, .emailAddresses)
    try list(record.postalAddresses, .postalAddresses)
    try list(record.urlAddresses, .urlAddresses)
    try list(record.contactRelations, .contactRelations)
    try list(record.socialProfiles, .socialProfiles)
    try list(record.instantMessageAddresses, .instantMessageAddresses)
    try list(record.dates, .dates)
    try c.encodeIfPresent(record.birthday, forKey: .birthday)
    try c.encodeIfPresent(record.nonGregorianBirthday, forKey: .nonGregorianBirthday)
    try c.encode(record.imageDataAvailable, forKey: .imageDataAvailable)
    try c.encodeIfPresent(record.containerIdentifier, forKey: .containerIdentifier)
    try list(record.groupIdentifiers, .groupIdentifiers)
    try list(record.linkedContactIdentifiers, .linkedContactIdentifiers)
    if record.isMe { try c.encode(true, forKey: .isMe) }
    try c.encodeIfPresent(note, forKey: .note)
    try c.encodeIfPresent(creationDate.map(timestamp), forKey: .creationDate)
    try c.encodeIfPresent(modificationDate.map(timestamp), forKey: .modificationDate)
  }
}
