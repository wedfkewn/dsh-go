import CFNetwork
import Foundation

/// Resolves the user's system proxy without exposing proxy credentials to logs.
/// NativeNode runs in-process, so the environment is applied immediately before
/// NodeMobile starts and remains process-scoped for that runtime.
enum SystemProxyEnvironment {
  private static func endpoint(_ destination: URL, settings: CFDictionary) -> String? {
    // `CFNetworkCopyProxiesForURL` is not annotated nullable, so it imports as a
    // non-optional Unmanaged value even though the CFArray may be empty.
    let copied = CFNetworkCopyProxiesForURL(destination as CFURL, settings).takeRetainedValue()
    guard let proxies = copied as? [[AnyHashable: Any]] else { return nil }
    for proxy in proxies {
      guard let type = proxy[kCFProxyTypeKey as String] as? String,
            type == kCFProxyTypeHTTP as String || type == kCFProxyTypeHTTPS as String,
            let host = proxy[kCFProxyHostNameKey as String] as? String,
            !host.isEmpty,
            let port = proxy[kCFProxyPortNumberKey as String] as? NSNumber,
            (1...65535).contains(port.intValue) else { continue }
      var components = URLComponents()
      // HTTPS proxy entries describe an HTTP CONNECT endpoint. Do not use
      // https:// here: that would incorrectly require TLS to the proxy itself.
      components.scheme = "http"
      components.host = host
      components.port = port.intValue
      if let user = proxy[kCFProxyUsernameKey as String] as? String, !user.isEmpty { components.user = user }
      if let password = proxy[kCFProxyPasswordKey as String] as? String, !password.isEmpty { components.password = password }
      if let value = components.string, !value.isEmpty { return value }
    }
    return nil
  }

  static func values() -> [String: String] {
    guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else { return [:] }
    let http = endpoint(URL(string: "http://api.deepseek.com/models")!, settings: settings)
    let https = endpoint(URL(string: "https://api.deepseek.com/models")!, settings: settings)
    if http == nil && https == nil { return [:] }
    return [
      "HTTP_PROXY": http ?? https!,
      "HTTPS_PROXY": https ?? http!,
      "NO_PROXY": "localhost,127.0.0.1,::1",
    ]
  }

  static func apply() {
    for (key, value) in values() { setenv(key, value, 1) }
  }
}
