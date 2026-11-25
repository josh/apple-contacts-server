// Field descriptions shared by the GraphQL schema and the MCP catalog. Names follow the
// Contacts framework, so each description says what CNContact means by the property.
enum FieldDocs {
  enum Contact {
    static let identifier =
      "The stored card's identifier, as CNContact.identifier reports it. It does not change over time."
    static let contactType = "PERSON, or ORGANIZATION for a card shown by its company name."
    static let namePrefix = "A title before the name, such as Dr."
    static let givenName = "The first name."
    static let middleName = "The middle name."
    static let familyName = "The last name."
    static let previousFamilyName = "A former last name, such as a maiden name."
    static let nameSuffix = "A suffix after the name, such as Jr."
    static let nickname = "The nickname."
    static let phoneticGivenName = "How the first name is pronounced."
    static let phoneticMiddleName = "How the middle name is pronounced."
    static let phoneticFamilyName = "How the last name is pronounced."
    static let phoneticOrganizationName = "How the organization name is pronounced."
    static let organizationName = "The company or organization."
    static let departmentName = "The department within the organization."
    static let jobTitle = "The job title."
    static let phoneNumbers = "Phone numbers, in the card's order."
    static let emailAddresses = "Email addresses, in the card's order."
    static let postalAddresses = "Postal addresses, in the card's order."
    static let urlAddresses = "URLs, in the card's order."
    static let contactRelations = "Related people by name, such as a spouse or an assistant."
    static let socialProfiles = "Social profiles."
    static let instantMessageAddresses = "Instant message addresses."
    static let dates = "Dates other than the birthday, such as an anniversary."
    static let birthday = "The birthday in the Gregorian calendar; the year may be absent."
    static let nonGregorianBirthday = "The birthday in another calendar, when the card has one."
    static let imageDataAvailable = "Whether the card has a picture."
    static let fullName =
      "The name as Contacts formats it; absent for a card with no name or organization."
    static let containerIdentifier = "Identifier of the container that stores the card."
    static let groupIdentifiers = "Identifiers of the groups the card belongs to."
    static let linkedContactIdentifiers =
      "Identifiers of the other stored cards Contacts shows together with this one as one person; empty for a card that stands alone."
    static let isMe = "Whether this is the user's own card."
    static let note =
      "The note. Read from Contacts through scripting, which launches Contacts when it is not running."
    static let creationDate =
      "When the card was created. Read from Contacts through scripting, which launches Contacts when it is not running."
    static let modificationDate =
      "When the card last changed. Read from Contacts through scripting, which launches Contacts when it is not running."
    static let thumbnailImageData = "A small version of the card's picture, as base64."
    static let imageData = "The card's picture as stored, as base64."
    static let vCard =
      "The card as a vCard 3.0. The note and the picture are added only when asked for; the note is read from Contacts through scripting."
  }
  // Input for a new card or a patch. Fields take the same shapes the card returns.
  enum ContactInput {
    static let note =
      "The note, set through Contacts scripting after the card's other changes are saved; this launches Contacts when it is not running."
    static let imageData =
      "The card's picture as base64 of an image such as PNG or JPEG. The request body is limited to 1 MiB, which allows a picture of about 700 KB."
    static let birthday =
      "The birthday in the Gregorian calendar; omit year for a birthday without one."
    static let nonGregorianBirthday =
      "The birthday in another calendar; calendar is required, such as chinese or hebrew."
    static let containerIdentifier =
      "Container to store the card in; defaults to the container new cards go to."
    static let groupIdentifiers =
      "Groups to add the card to; each must be in the card's container."
    static let clearFields =
      "Values to remove. A list key empties the whole list; IMAGE_DATA removes the picture. A key cannot be both set and cleared."
    static let create =
      "Create a card. It needs a name, an organization, a phone number, or an email address."
    static let update =
      "Change one stored card. Only what the patch names changes: a text field is replaced, and a list changes by add, update, and remove, leaving its other entries as they are. Values cannot be null or blank; remove one with clearFields."
    static let patch = "The changes; at least one."
    static let list = "Entries for this list."
    static let changes =
      "Changes to this list; entries the patch does not name keep their identifier, label, and value."
    static let add = "Entries to append."
    static let updateEntries =
      "Entries to change, by identifier. Only the label or the value parts that are present change; a label of \"\" removes the label."
    static let remove = "Identifiers of entries to remove."
    static let label =
      "A stored token, a custom label, or the word for a built-in label such as home, work, mobile, or other. Omitted, the entry has no label."
    static let entryIdentifier = "Identifier of the entry to change, from the card."
  }
  enum GroupInput {
    static let name = "The group's name; not blank."
    static let containerIdentifier =
      "Container to store the group in; defaults to the container new cards go to."
    static let create = "Create a group."
    static let update = "Rename a group."
    static let delete = "Delete a group. Its cards are not deleted."
    static let contactIdentifiers =
      "Identifiers of stored cards; each must be in the group's container."
    static let addMembers =
      "Add cards to a group, through Contacts scripting, which launches Contacts when it is not running. A card already in the group stays in it."
    static let removeMembers =
      "Remove cards from a group, through Contacts scripting, which launches Contacts when it is not running. The cards themselves are not deleted."
  }
  enum Write {
    static let deleteContact =
      "Delete one stored card. The result carries a vCard of the card taken just before, so it can be restored. The user's own card is refused."
    static let deletedId = "Identifier of what was deleted."
    static let deletedVCard =
      "The deleted card as a vCard 3.0. It carries the note when Contacts scripting answered."
    static let setMe =
      "Make a card the user's own card (My Card), through Contacts scripting; this launches Contacts when it is not running."
    static let show =
      "Select a card in Contacts and bring Contacts forward. Navigation only: nothing is stored."
  }
  enum VCard {
    static let export =
      "Export cards as one vCard 3.0 file. By default cards are unified, so a person with cards in two accounts is exported once."
    static let filter = "Cards to export; all cards when omitted."
    static let unify =
      "Export people as Contacts shows them rather than each stored card; defaults to true."
    static let includeNotes =
      "Add each card's note, read from Contacts through scripting, which launches Contacts when it is not running; defaults to false."
    static let includeImages = "Add each card's picture as a PHOTO line; defaults to false."
    static let vCard = "The vCard text."
    static let contactCount = "Number of cards in the text."
    static let byteCount = "Size of the text in bytes."
  }
  enum LabeledValue {
    static let identifier =
      "Identifier of this entry within the card, as CNLabeledValue.identifier reports it."
    static let label =
      "The label as stored. A built-in label is a token such as _$!<Home>!$_; any other string is a custom label. Absent when the entry has none."
    static let localizedLabel = "The label as Contacts shows it, such as home or mobile."
    static let value = "The entry's value."
  }
  enum PhoneNumber {
    static let stringValue = "The number as written on the card."
  }
  enum PostalAddress {
    static let street = "Street lines, separated by newlines."
    static let subLocality = "A neighborhood or district within the city."
    static let city = "The city."
    static let subAdministrativeArea = "A county or similar area within the state."
    static let state = "The state or province."
    static let postalCode = "The postal code."
    static let country = "The country as written on the card."
    static let isoCountryCode = "The ISO 3166-1 alpha-2 country code, in lowercase."
  }
  enum SocialProfile {
    static let urlString = "URL of the profile."
    static let username = "The user name on the service."
    static let userIdentifier = "The service's own identifier for the user."
    static let service = "The service, such as LinkedIn."
  }
  enum InstantMessageAddress {
    static let username = "The user name on the service."
    static let service = "The service, such as Skype."
  }
  enum ContactRelation {
    static let name = "The related person's name."
  }
  enum DateComponents {
    static let calendar =
      "Identifier of the calendar the parts are in, such as chinese or hebrew; absent for Gregorian."
    static let era = "The era, for a calendar other than Gregorian."
    static let year = "The year; absent for a date without one."
    static let month = "The month, from 1."
    static let day = "The day of the month, from 1."
    static let isLeapMonth = "True when the month is a leap month of a lunar calendar."
  }
  enum Group {
    static let identifier = "The group's identifier, as CNGroup.identifier reports it."
    static let name = "The group's name."
    static let containerIdentifier = "Identifier of the container that stores the group."
    static let parentGroupIdentifier =
      "Identifier of the group this one is nested in; absent at the top level."
    static let subgroupIdentifiers = "Identifiers of the groups nested in this one."
    static let memberCount = "Number of stored cards in the group."
  }
  enum Container {
    static let identifier = "The container's identifier, as CNContainer.identifier reports it."
    static let name = "The container's name; often empty for an account's only container."
    static let type =
      "LOCAL for On My Mac, EXCHANGE, CARD_DAV for iCloud and other CardDAV accounts, or UNASSIGNED."
    static let isDefault = "Whether new cards go to this container unless another is named."
    static let contactCount = "Number of stored cards in the container."
    static let groupCount = "Number of groups in the container."
  }
  enum Defaults {
    static let defaultContainerIdentifier =
      "Identifier of the container new cards go to unless another is named."
    static let meContactIdentifier = "Identifier of the user's own card; absent when none is set."
  }
  enum Summary {
    static let contactCount = "Stored cards in every container."
    static let personCount = "Cards whose contactType is PERSON."
    static let organizationCount = "Cards whose contactType is ORGANIZATION."
    static let linkedContactCount = "Cards Contacts shows together with another card."
    static let groupCount = "Groups in every container."
    static let containerCount = "Containers."
  }
  enum ContactFilter {
    static let query =
      "Case- and accent-insensitive substring of any name, the organization, department, job title, an email address, URL, postal address, profile, or related name. A query with three or more digits also matches phone numbers, whatever their punctuation."
    static let identifiers = "Match any of these cards; [] matches nothing."
    static let contactTypes = "Match any of these types; [] matches nothing."
    static let containerIdentifiers = "Match cards stored in any of these containers."
    static let groupIdentifiers = "Match cards that belong to any of these groups."
    static let has =
      "Match cards that have a value for every one of these keys. NOTE is read from Contacts through scripting, which launches Contacts when it is not running."
    static let missing = "Match cards that have no value for any of these keys."
    static let labels =
      "Match cards with an entry carrying any of these labels: a stored token, a custom label, or a built-in label's word such as home, work, mobile, or other."
    static let customLabels =
      "Match cards that do, or do not, have an entry with a custom label. Social profiles and instant message addresses are not counted: their labels name the service."
    static let linked = "Match cards Contacts does, or does not, show together with another card."
    static let createdFrom =
      "Created at or after this instant: an RFC 3339 timestamp, or YYYY-MM-DD for that day's midnight in the host zone. Creation dates are read from Contacts through scripting, which launches Contacts when it is not running."
    static let createdBefore = "Created before this instant; same forms and cost as createdFrom."
    static let modifiedFrom =
      "Last changed at or after this instant; same forms and cost as createdFrom."
    static let modifiedBefore =
      "Last changed before this instant; same forms and cost as createdFrom."
  }
  enum Include {
    static let include =
      "Fields to add that only Contacts scripting provides: NOTE, CREATION_DATE, MODIFICATION_DATE. Asking for any launches Contacts when it is not running and needs Automation access; omitted, the result comes from the Contacts framework alone."
  }
  enum GroupFilter {
    static let query = "Case- and accent-insensitive substring of the group's name."
    static let containerIdentifiers = "Match groups stored in any of these containers."
  }
  enum Order {
    static let field =
      "What to sort by. USER_DEFAULT is the name order chosen in Contacts settings; a card without the value sorts last. CREATION_DATE and MODIFICATION_DATE are read from Contacts through scripting, which launches Contacts when it is not running."
    static let direction = "ASC or DESC; defaults to ASC."
  }
  enum ContactPage {
    static let items = "Stored cards on this page."
    static let totalCount = "Number of matching cards across all pages."
  }
  enum GroupPage {
    static let items = "Groups on this page."
    static let totalCount = "Number of matching groups across all pages."
  }
}
