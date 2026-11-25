import Contacts
import Foundation

// The multi-value properties of a card; raw values are the CNContact property names.
enum LabeledProperty: String, CaseIterable, Sendable {
  case phoneNumbers, emailAddresses, postalAddresses, urlAddresses, contactRelations
  case socialProfiles, instantMessageAddresses, dates
}

// Contacts stores a built-in label as a token such as _$!<Home>!$_ and shows it
// localized; any other string is a custom label, stored and shown as written. Input may
// name a built-in label by a plain word instead of its token.
private let sharedLabels: [String: String] = [
  "home": CNLabelHome, "work": CNLabelWork, "school": CNLabelSchool, "other": CNLabelOther,
]
private let propertyLabels: [LabeledProperty: [String: String]] = [
  .phoneNumbers: [
    "mobile": CNLabelPhoneNumberMobile, "iphone": CNLabelPhoneNumberiPhone,
    "apple watch": CNLabelPhoneNumberAppleWatch, "main": CNLabelPhoneNumberMain,
    "home fax": CNLabelPhoneNumberHomeFax, "work fax": CNLabelPhoneNumberWorkFax,
    "other fax": CNLabelPhoneNumberOtherFax, "pager": CNLabelPhoneNumberPager,
  ],
  .emailAddresses: ["icloud": CNLabelEmailiCloud],
  .urlAddresses: ["homepage": CNLabelURLAddressHomePage],
  .dates: ["anniversary": CNLabelDateAnniversary],
  .contactRelations: [
    "assistant": CNLabelContactRelationAssistant, "manager": CNLabelContactRelationManager,
    "colleague": CNLabelContactRelationColleague, "teacher": CNLabelContactRelationTeacher,
    "sibling": CNLabelContactRelationSibling, "sister": CNLabelContactRelationSister,
    "brother": CNLabelContactRelationBrother, "friend": CNLabelContactRelationFriend,
    "spouse": CNLabelContactRelationSpouse, "wife": CNLabelContactRelationWife,
    "husband": CNLabelContactRelationHusband, "partner": CNLabelContactRelationPartner,
    "parent": CNLabelContactRelationParent, "mother": CNLabelContactRelationMother,
    "father": CNLabelContactRelationFather, "child": CNLabelContactRelationChild,
    "daughter": CNLabelContactRelationDaughter, "son": CNLabelContactRelationSon,
  ],
]
func isBuiltInLabel(_ label: String) -> Bool { label.hasPrefix("_$!<") && label.hasSuffix(">!$_") }

// The label to store for what a client wrote: a stored token as it is, a built-in
// label's word or localized name as that label's token, and anything else as a custom
// label.
func storedLabel(_ input: String, for property: LabeledProperty) -> String {
  if isBuiltInLabel(input) { return input }
  let word = folded(input.trimmingCharacters(in: .whitespaces))
  let known = sharedLabels.merging(propertyLabels[property] ?? [:]) { _, specific in specific }
  if let token = known[word] { return token }
  let localized = known.values.first {
    folded(CNLabeledValue<NSString>.localizedString(forLabel: $0)) == word
  }
  return localized ?? input
}
// Every stored label a filter word may mean, across the properties.
func storedLabels(matching input: String) -> Set<String> {
  Set(LabeledProperty.allCases.map { storedLabel(input, for: $0) })
}
