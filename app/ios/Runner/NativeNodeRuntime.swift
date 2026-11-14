import Darwin
import Flutter
import Foundation

private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

/// Node is process-wide. All channel state is owned by the main queue.
@objc(DshNativeNodeRuntime) final class NativeNodeRuntime: NSObject, FlutterStreamHandler {
  private typealias NodeStart = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
  private static let shared = NativeNodeRuntime()

  private let files = FileManager.default
  private var phase = "installed"
  private var nodeStarted = false
  private var nodeExited = false
  private var generation = UUID().uuidString
  private var details: [String: Any] = [:]
  private var logs: [[String: Any]] = []
  private var logSequence = 0
  private var eventSink: FlutterEventSink?
  private var timer: Timer?
  private var verifying = false
  private var deadline: Date?

  private var root: URL {
    files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NativeNode", isDirectory: true)
  }

  private var script: URL {
    Bundle.main.bundleURL.appendingPathComponent("NativeNode/supervisor.mjs")
  }

  private var binary: URL? {
    Bundle.main.privateFrameworksURL?.appendingPathComponent("NodeMobile.framework/NodeMobile")
  }

  private var installed: Bool {
    files.fileExists(atPath: script.path) && binary.map { files.fileExists(atPath: $0.path) } == true
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "dsh/native_node", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      shared.handle(call, result: result)
    }
    FlutterEventChannel(name: "dsh/native_node/events", binaryMessenger: registrar.messenger())
      .setStreamHandler(shared)
  }

  private func error(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    publishStatus()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private var status: [String: Any] {
    var value = details
    value["phase"] = installed ? phase : "unimplemented"
    if installed {
      value["abi"] = "arm64"
      value["installedVersion"] = "0.2.2-rc.1"
      value["bundledVersion"] = "0.2.2-rc.1"
      value["dshVersion"] = "0.2.2-rc.1"
    }
    return value
  }

  private func publishStatus() {
    var value = status
    if let reason = value["error"] as? [String: String] {
      value["error"] = [reason["code"], reason["message"]].compactMap { $0 }.joined(separator: ": ")
    }
    eventSink?(["type": "status", "status": value])
  }

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    let method = call.method
    let arguments = call.arguments as? [String: Any]
    switch method {
    case "getLogs", "logs", "getLogSnapshot":
      let count = max(0, arguments?["lines"] as? Int ?? 100)
      let entries = Array(logs.suffix(count))
      if method == "getLogSnapshot" {
        result(["entries": entries, "throughSeq": logSequence])
      } else {
        result(entries.compactMap { $0["line"] as? String })
      }
      return
    case "status":
      result(status)
      return
    // The engine sees real sandbox paths on iOS: there is no guest and no /root.
    // Dart asks for them before the first frame, which must not start Node.
    case "paths":
      do {
        result(try pathsSnapshot())
      } catch {
        result(self.error("native_node_paths_failed", "Could not prepare the native runtime directories."))
      }
      return
    case "install" where installed && arguments?["dropKept"] as? Bool != true:
      result(nil) // Bundled, verified by the build preparation step.
      return
    default:
      break
    }
    guard ["start", "restart", "stop"].contains(method) else { result(FlutterMethodNotImplemented); return }
    guard installed else { result(error("native_node_unavailable", "Prepare the bundled native runtime first.")); return }
    guard !nodeExited else { result(error("native_node_exited", "Reopen the app to initialize Node again.")); return }
    if let arguments,
       arguments["phoneStorage"] as? Bool == true ||
       arguments["mode"] as? String == "safe" ||
       (arguments["env"] as? [String: String])?.isEmpty == false {
      result(error("native_node_unsupported_options", "Native Node does not support these launch options."))
      return
    }
    if method == "stop" && !nodeStarted { result(nil); return }
    if method == "start" && ["starting", "running"].contains(phase) { result(nil); return }
    do {
      try prepareStorage()
      if !nodeStarted { try startNode() }
      try command(method == "stop" ? "stop" : "start")
      result(nil)
    } catch {
      fail("native_node_launch_failed", "Could not initialize the native runtime.")
      result(self.error("native_node_launch_failed", "Could not initialize the native runtime."))
    }
  }

  private func prepareStorage() throws {
    for directory in ["", "home", "home/workspace", "tmp", "logs"] {
      try files.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    }
  }

  /// One spelling for cwd and home: Node's getcwd resolves the container's
  /// /var symlink, so Home and the workspace must be spelled the same way.
  private func canonical(_ url: URL) -> URL {
    guard let resolved = realpath(url.path, nil) else { return url }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
  }

  /// The paths the in-process DSH engine uses. Created up front so session
  /// creation only ever has to reuse them.
  private func pathsSnapshot() throws -> [String: String] {
    try prepareStorage()
    let home = canonical(root.appendingPathComponent("home", isDirectory: true))
    return [
      "root": canonical(root).path,
      "home": home.path,
      "workspace": canonical(home.appendingPathComponent("workspace", isDirectory: true)).path,
    ]
  }

  private func startNode() throws {
    guard let binary, let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL),
          let symbol = dlsym(handle, "node_start") else {
      throw CocoaError(.executableLoad)
    }
    // NativeNode inherits the process environment. Resolve system CONNECT
    // proxies here rather than passing an untrusted Dart env map.
    SystemProxyEnvironment.apply()
    // Keep the image loaded for the process lifetime, including after exit.
    let start = unsafeBitCast(symbol, to: NodeStart.self)
    for name in ["command.json", "status.json"] {
      let url = root.appendingPathComponent(name)
      if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
    }
    nodeStarted = true
    let arguments = ["node", "--expose-internals", script.path, canonical(root).path]
    let thread = Thread { [weak self] in
      let bytes = arguments.flatMap { Array($0.utf8CString) }
      let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
      defer { buffer.deallocate() }
      bytes.withUnsafeBufferPointer { buffer.initialize(from: $0.baseAddress!, count: bytes.count) }
      var offset = 0
      var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { argument in
        defer { offset += argument.utf8.count + 1 }
        return buffer.advanced(by: offset)
      }
      argv.append(nil)
      let exitCode = argv.withUnsafeMutableBufferPointer { start(Int32(arguments.count), $0.baseAddress) }
      DispatchQueue.main.async { [weak self] in
        self?.nodeExited = true
        self?.fail("native_node_exited", "Node exited with code \(exitCode).")
      }
    }
    thread.name = "DSH NodeMobile"
    thread.stackSize = 16 * 1024 * 1024
    thread.start()
  }

  private func command(_ action: String) throws {
    let next = UUID().uuidString
    let data = try JSONSerialization.data(withJSONObject: ["action": action, "generation": next])
    try data.write(to: root.appendingPathComponent("command.json"), options: .atomic)
    generation = next
    phase = action == "stop" ? "stopping" : "starting"
    deadline = Date().addingTimeInterval(90)
    details = [:]
    verifying = false
    publishStatus()
    if timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
    }
  }

  private func fail(_ code: String, _ message: String) {
    phase = "error"
    details = ["error": ["code": code, "message": message]]
    deadline = nil
    log(code)
    publishStatus()
  }

  private func log(_ line: String) {
    logSequence += 1
    let entry: [String: Any] = ["seq": logSequence, "line": line, "stream": "system"]
    logs.append(entry)
    eventSink?(["type": "logs", "entries": [entry]])
    if logs.count > 100 { logs.removeFirst() }
    NSLog("native-node: %@", line)
  }

  private func describe(_ error: Error) -> String {
    if let error = error as? URLError { return "URLError \(error.code.rawValue)" }
    let error = error as NSError
    return "\(error.domain) \(error.code)"
  }

  private func poll() {
    if nodeExited { timer?.invalidate(); timer = nil; return }
    if let deadline, Date() > deadline {
      if phase == "starting" { try? command("stop") }
      fail("native_node_timeout", "Native runtime did not acknowledge the request before the deadline.")
      return
    }
    guard let data = try? Data(contentsOf: root.appendingPathComponent("status.json")),
          let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          record["generation"] as? String == generation,
          let state = record["phase"] as? String else { return }
    switch state {
    case "error":
      if phase != "error", let reason = record["error"] as? [String: String] {
        fail(reason["code"] ?? "native_node_worker_failed", reason["message"] ?? "DSH Worker failed.")
      }
    case "stopped":
      if phase == "stopping" { phase = "stopped"; deadline = nil; publishStatus() }
    case "candidate":
      guard phase == "starting", !verifying else { return }
      verify(record)
    default: break
    }
  }

  private func verify(_ record: [String: Any]) {
    guard let base = record["baseUrl"] as? String, let token = record["token"] as? String,
          !token.isEmpty, var url = URLComponents(string: base), url.scheme == "http",
          url.host == "127.0.0.1", url.user == nil, url.password == nil,
          url.query == nil, url.fragment == nil, url.path.isEmpty,
          let port = url.port, (1...65535).contains(port) else { return }
    url.path = "/"
    guard let anonymous = url.url else { return }
    url.queryItems = [URLQueryItem(name: "token", value: token)]
    guard let endpoint = url.url else { return }
    verifying = true
    let expected = generation
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForResource = 3
    let session = URLSession(configuration: config, delegate: NoRedirectSessionDelegate(), delegateQueue: nil)
    Task { @MainActor [weak self] in
      defer { session.finishTasksAndInvalidate() }
      do {
        let before = try await session.data(from: anonymous)
        let denied = (before.1 as? HTTPURLResponse)?.statusCode
        guard denied == 401 || denied == 403 else {
          guard let self, self.generation == expected, self.phase == "starting" else { return }
          self.verifying = false
          self.log("anonymous DSH probe failed: HTTP \(denied ?? 0)")
          return
        }
        do {
          let exchange = try await session.data(from: endpoint)
          let exchangeStatus = (exchange.1 as? HTTPURLResponse)?.statusCode ?? 0
          guard let self, self.generation == expected, self.phase == "starting" else { return }
          guard exchangeStatus == 303,
                let response = exchange.1 as? HTTPURLResponse,
                let cookie = self.authenticationCookie(from: response, url: anonymous) else {
            self.verifying = false
            self.log("local DSH token exchange failed: HTTP \(exchangeStatus)")
            return
          }
          var signedIn = URLRequest(url: anonymous)
          signedIn.setValue(cookie, forHTTPHeaderField: "Cookie")
          let after = try await session.data(for: signedIn)
          let status = (after.1 as? HTTPURLResponse)?.statusCode ?? 0
          guard self.generation == expected, self.phase == "starting" else { return }
          self.verifying = false
          guard (200..<300).contains(status) else {
            self.log("authenticated DSH readiness failed: HTTP \(status)")
            return
          }
          self.phase = "running"
          self.deadline = nil
          self.details = ["baseUrl": base, "token": token, "runtimeInstanceId": expected,
                          "nodeVersion": record["nodeVersion"] ?? "",
                          "workingDirectory": self.root.appendingPathComponent("home/workspace").path]
          self.publishStatus()
          self.log("authenticated DSH readiness (Node " + (record["nodeVersion"] as? String ?? "unknown") + ")")
        } catch {
          guard let self, self.generation == expected, self.phase == "starting" else { return }
          self.verifying = false
          self.log("authenticated DSH readiness failed: \(self.describe(error))")
        }
      } catch {
        guard let self, self.generation == expected, self.phase == "starting" else { return }
        self.verifying = false
        self.log("anonymous DSH probe failed: \(self.describe(error))")
      }
    }
  }

  private func authenticationCookie(from response: HTTPURLResponse, url: URL) -> String? {
    guard let header = response.value(forHTTPHeaderField: "Set-Cookie") else { return nil }
    let cookie = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: url)
      .map { "\($0.name)=\($0.value)" }
      .joined(separator: "; ")
    return cookie.isEmpty ? nil : cookie
  }
}
