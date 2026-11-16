#!/usr/bin/env python3
"""Run production EngineLifecycle against a synthetic loopback HTTP peer on macOS.

Exercises actual host messages/acknowledgements, not a second boolean model.
Does not start PiP, a phone task, or a real user engine.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

if sys.platform != 'darwin':
    raise SystemExit('Requires the macOS Foundation/Swift toolchain')
root = Path(__file__).resolve().parents[3]
source = (root / 'app/ios/Runner/EngineChannel.swift').read_text()
production = source[source.index('private final class EngineLifecycle:'):source.index('/// dsh/runtime:')]
posts = {}


class Peer(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(303)
        self.send_header('Set-Cookie', 'dsh-auth-test=synthetic')
        self.end_headers()

    def do_POST(self):
        value = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert self.headers['Cookie'] == 'dsh-auth-test=synthetic'
        assert self.path == '/dsh-go/v1/lifecycle'
        posts[value['revision']] = value
        response = json.dumps({'v': 1, 'host': value, 'closed': False, 'blocked': False}).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response)


fixture = r'''
@main struct BackgroundFixture {
  static func main() throws {
    let queue = DispatchQueue(label: "engine-background-fixture")
    var nativeObservation: (Int, Bool, Bool)?
    let lifecycle = EngineLifecycle(
      queue: queue, publishNative: { nativeObservation = ($0, $1, $2) },
      changed: {}, lostServer: {})
    func phase(_ name: String, _ change: () -> Void) throws {
      queue.sync(execute: change)
      let deadline = Date().addingTimeInterval(5)
      while Date() < deadline {
        let (state, native) = queue.sync { (lifecycle.status(), nativeObservation) }
        if let revision = state["revision"] as? Int,
           state["acknowledgedRevision"] as? Int == revision {
          guard let native, native.0 == revision, native.1 == state["foreground"] as? Bool,
            native.2 == state["continued"] as? Bool else {
            throw NSError(domain: "native-observation", code: 1)
          }
          let data = try JSONSerialization.data(withJSONObject: ["name": name, "revision": revision])
          print(String(decoding: data, as: UTF8.self))
          return
        }
        Thread.sleep(forTimeInterval: 0.01)
      }
      throw NSError(domain: "background-fixture", code: 1)
    }
    try phase("background-idle") {
      lifecycle.publishCurrentObservation()
      lifecycle.runtime(baseUrl: CommandLine.arguments[1], token: "synthetic")
    }
    try phase("pip") { lifecycle.observe(pictureInPicture: true) }
    try phase("both") { lifecycle.observe(continued: true) }
    try phase("continued-survives-pip-stop") { lifecycle.observe(pictureInPicture: false) }
    try phase("both-again") { lifecycle.observe(pictureInPicture: true) }
    try phase("pip-survives-continued-stop") { lifecycle.observe(continued: false) }
    try phase("neither") { lifecycle.observe(pictureInPicture: false) }
    try phase("foreground") { lifecycle.observe(foreground: true) }
    try phase("background-again") { lifecycle.observe(foreground: false) }
  }
}
'''

server = ThreadingHTTPServer(('127.0.0.1', 0), Peer)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory(prefix='dsh-engine-background-') as temporary:
        temporary = Path(temporary)
        swift = temporary / 'check.swift'
        executable = temporary / 'check'
        swift.write_text('import Foundation\n' + production + fixture)
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(swift), '-o', str(executable)], check=True)
        run = subprocess.run([str(executable), f'http://127.0.0.1:{server.server_port}'], check=True, text=True, capture_output=True, timeout=60)
    seen = [json.loads(line) for line in run.stdout.splitlines()]
    assert len(seen) == 9, 'all source transitions must be acknowledged'
    granted = {'pip', 'both', 'continued-survives-pip-stop', 'both-again', 'pip-survives-continued-stop'}
    for step in seen:
        post = posts[step['revision']]
        allowed = step['name'] in granted
        assert post['computePermission'] == ('granted' if allowed else 'denied'), step['name']
        assert post['foreground'] == (allowed or step['name'] == 'foreground'), step['name']
        assert post['operation'] == 'host'
    print('PASS: 9 production lifecycle messages preserve independent PiP/continued grants and withdraw them on stop')
finally:
    server.shutdown()
    server.server_close()
