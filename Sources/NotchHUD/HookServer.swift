import Foundation
import Network

/// Thread-safe snapshot of HUD state for the GET /state debug endpoint.
final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "{}"
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
}

/// Tiny localhost HTTP listener. Claude Code hooks POST their stdin JSON here.
final class HookServer {
    private let listener: NWListener
    private let onEvent: ([String: Any]) -> Void
    let stateBox = StateBox()

    /// Called when the port cannot be bound (typically a second instance).
    init?(port: UInt16, onEvent: @escaping ([String: Any]) -> Void, onFailure: @escaping (String) -> Void = { _ in }) {
        self.onEvent = onEvent
        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        // Exclusive: two HUDs sharing a port would each get half the events.
        params.allowLocalEndpointReuse = false
        guard let l = try? NWListener(using: params) else { return nil }
        listener = l
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                onFailure("could not listen on 127.0.0.1:\(port): \(error). Is another NotchHUD running?")
            }
        }
        listener.start(queue: .global(qos: .utility))
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        // Hooks send one small request; anything that dawdles is not a hook.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { conn.cancel() }
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }

            if buf.starts(with: Data("GET /state".utf8)) {
                let json = self.stateBox.get()
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(json.utf8.count)\r\n\r\n\(json)"
                conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })
                return
            }

            if let (header, body) = Self.completeRequest(from: buf) {
                // Only `POST /event` with a JSON body is an event; anything else is ignored.
                let accepted = header.hasPrefix("POST /event") && header.lowercased().contains("content-type: application/json")
                if accepted, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    self.onEvent(obj)
                }
                let response = accepted
                    ? "HTTP/1.1 204 No Content\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
                    : "HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
                conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })
                return
            }
            if isComplete || error != nil || buf.count > 512 * 1024 {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    /// Returns header and body once the full request (per Content-Length) has arrived.
    private static func completeRequest(from buf: Data) -> (header: String, body: Data)? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(decoding: buf[..<sep.lowerBound], as: UTF8.self)
        var contentLength = 0
        for line in header.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = buf[sep.upperBound...]
        guard body.count >= contentLength else { return nil }
        return (header, body.prefix(contentLength))
    }
}
