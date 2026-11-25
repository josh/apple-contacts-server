import Contacts
import Foundation
import ImageIO

// A card's picture. Pictures are read one card at a time, never with the snapshot: the
// data is large and most requests do not want it.

// The picture a client sent as base64, checked to be an image ImageIO can decode.
func decodedImage(_ encoded: String) throws -> Data {
  guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !data.isEmpty
  else { throw ServerError.invalidArgument("imageData must be base64") }
  guard let source = CGImageSourceCreateWithData(data as CFData, nil),
    CGImageSourceGetCount(source) > 0,
    CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
  else { throw ServerError.invalidArgument("imageData must be an image, such as PNG or JPEG") }
  return data
}
// The vCard TYPE of picture data, such as JPEG or PNG.
func imageType(_ data: Data) -> String {
  guard let source = CGImageSourceCreateWithData(data as CFData, nil),
    let type = CGImageSourceGetType(source) as String?
  else { return "JPEG" }
  switch type {
  case "public.png": return "PNG"
  case "public.tiff": return "TIFF"
  case "com.compuserve.gif": return "GIF"
  case "public.heic": return "HEIC"
  default: return "JPEG"
  }
}

enum ImageKey: Sendable {
  case thumbnail, full
  var key: String { self == .thumbnail ? CNContactThumbnailImageDataKey : CNContactImageDataKey }
}
// The picture of one stored card; nil when the card has none.
func readImage(id: String, _ which: ImageKey) async throws -> Data? {
  try await onContactsQueue { store in
    let contact = try storedContact(store, id: id, keys: [which.key as CNKeyDescriptor])
    guard contact.isKeyAvailable(which.key) else { return nil }
    return which == .thumbnail ? contact.thumbnailImageData : contact.imageData
  }
}

// Whether the store has a picture for one card.
func hasPicture(id: String) async throws -> Bool {
  try await onContactsQueue { store in
    let key = CNContactImageDataAvailableKey
    let contact = try storedContact(store, id: id, keys: [key as CNKeyDescriptor])
    return contact.isKeyAvailable(key) && contact.imageDataAvailable
  }
}
