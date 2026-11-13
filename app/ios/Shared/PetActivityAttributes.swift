import ActivityKit
import Foundation

@available(iOS 16.2, *)
struct PetActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var packId: String?
    var phase: String
    var label: String
    var staleLabel: String
  }

  // Opaque host reference, never a host's credentials or address.
  var host: String
  var sessionId: String

  var url: URL? {
    guard host != "local-pet" else { return nil }
    var parts = URLComponents()
    parts.scheme = "dshgo"
    parts.host = "pet-session"
    parts.queryItems = [URLQueryItem(name: "host", value: host),
                        URLQueryItem(name: "sessionId", value: sessionId)]
    return parts.url
  }
}
