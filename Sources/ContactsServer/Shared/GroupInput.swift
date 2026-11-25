import Foundation

// Group create and patch input, shared by the GraphQL mutations and the MCP tools.
private func groupName(_ name: String) throws -> String {
  let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { throw ServerError.invalidArgument("name must not be blank") }
  return trimmed
}
struct CreateGroupInput: Decodable, Sendable {
  let name: String
  let containerIdentifier: String?
  enum CodingKeys: String, CodingKey, CaseIterable { case name, containerIdentifier }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    name = try groupName(c.decode(String.self, forKey: .name))
    containerIdentifier = try c.decodeIfPresent(String.self, forKey: .containerIdentifier)
  }
}
struct GroupPatch: Decodable, Sendable {
  let name: String
  enum CodingKeys: String, CodingKey, CaseIterable { case name }
  init(from decoder: Decoder) throws {
    let c = try decoder.inputContainer(keyedBy: CodingKeys.self)
    name = try groupName(c.decode(String.self, forKey: .name))
  }
}
// The cards a membership change names.
func memberIdentifiers(_ identifiers: [String]) throws -> [String] {
  guard !identifiers.isEmpty, !identifiers.contains(""),
    Set(identifiers).count == identifiers.count
  else {
    throw ServerError.invalidArgument(
      "contactIdentifiers must be distinct, nonempty identifiers, at least one")
  }
  return identifiers
}
