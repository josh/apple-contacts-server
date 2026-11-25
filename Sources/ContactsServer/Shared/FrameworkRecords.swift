import Contacts
import Foundation

// The only file that reads CNContact properties. Reading one the fetch did not ask for
// raises an Objective-C exception, which Swift cannot catch and which ends the process,
// so every record is built here from `contactKeys` after checking the keys are present.

private func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

private func labeled<Stored: NSCopying & NSSecureCoding, Value: Encodable & Sendable>(
  _ values: [CNLabeledValue<Stored>], _ convert: (Stored) -> Value
) -> [LabeledValueRecord<Value>] {
  values.map { item in
    LabeledValueRecord(
      identifier: item.identifier, label: item.label,
      localizedLabel: item.label.flatMap {
        nonEmpty(CNLabeledValue<NSString>.localizedString(forLabel: $0))
      },
      value: convert(item.value))
  }
}

extension DateComponentsValue {
  // Contacts leaves the year undefined for a day without one.
  init(_ components: DateComponents) {
    let identifier = (components.calendar as NSCalendar?)?.calendarIdentifier
    calendar = identifier == nil || identifier == .gregorian ? nil : identifier?.rawValue
    era = calendar == nil ? nil : components.era
    year = components.year
    month = components.month
    day = components.day
    isLeapMonth = components.isLeapMonth == true ? true : nil
  }
}
extension PostalAddressValue {
  init(_ address: CNPostalAddress) {
    street = nonEmpty(address.street)
    subLocality = nonEmpty(address.subLocality)
    city = nonEmpty(address.city)
    subAdministrativeArea = nonEmpty(address.subAdministrativeArea)
    state = nonEmpty(address.state)
    postalCode = nonEmpty(address.postalCode)
    country = nonEmpty(address.country)
    isoCountryCode = nonEmpty(address.isoCountryCode)
  }
}
extension SocialProfileValue {
  init(_ profile: CNSocialProfile) {
    urlString = nonEmpty(profile.urlString)
    username = nonEmpty(profile.username)
    userIdentifier = nonEmpty(profile.userIdentifier)
    service = nonEmpty(profile.service)
  }
}
extension ContainerType {
  init(_ type: CNContainerType) {
    switch type {
    case .local: self = .local
    case .exchange: self = .exchange
    case .cardDAV: self = .cardDAV
    default: self = .unassigned
    }
  }
}

extension ContactRecord {
  init(_ contact: CNContact) throws {
    guard contact.areKeysAvailable(contactKeys) else {
      throw ServerError.internalError("A contact was fetched without the keys its record needs")
    }
    identifier = contact.identifier
    contactType = contact.contactType == .organization ? .organization : .person
    namePrefix = nonEmpty(contact.namePrefix)
    givenName = nonEmpty(contact.givenName)
    middleName = nonEmpty(contact.middleName)
    familyName = nonEmpty(contact.familyName)
    previousFamilyName = nonEmpty(contact.previousFamilyName)
    nameSuffix = nonEmpty(contact.nameSuffix)
    nickname = nonEmpty(contact.nickname)
    phoneticGivenName = nonEmpty(contact.phoneticGivenName)
    phoneticMiddleName = nonEmpty(contact.phoneticMiddleName)
    phoneticFamilyName = nonEmpty(contact.phoneticFamilyName)
    phoneticOrganizationName = nonEmpty(contact.phoneticOrganizationName)
    organizationName = nonEmpty(contact.organizationName)
    departmentName = nonEmpty(contact.departmentName)
    jobTitle = nonEmpty(contact.jobTitle)
    phoneNumbers = labeled(contact.phoneNumbers) { PhoneNumberValue(stringValue: $0.stringValue) }
    emailAddresses = labeled(contact.emailAddresses) { $0 as String }
    postalAddresses = labeled(contact.postalAddresses) { PostalAddressValue($0) }
    urlAddresses = labeled(contact.urlAddresses) { $0 as String }
    contactRelations = labeled(contact.contactRelations) { ContactRelationValue(name: $0.name) }
    socialProfiles = labeled(contact.socialProfiles) { SocialProfileValue($0) }
    instantMessageAddresses = labeled(contact.instantMessageAddresses) {
      InstantMessageAddressValue(username: nonEmpty($0.username), service: nonEmpty($0.service))
    }
    dates = labeled(contact.dates) { DateComponentsValue($0 as DateComponents) }
    birthday = contact.birthday.map(DateComponentsValue.init)
    nonGregorianBirthday = contact.nonGregorianBirthday.map(DateComponentsValue.init)
    imageDataAvailable = contact.imageDataAvailable
    fullName = CNContactFormatter.string(from: contact, style: .fullName).flatMap(nonEmpty)
  }
}
