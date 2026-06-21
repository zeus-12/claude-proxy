import Foundation
import Network

/// One loopback HTTP server for a single ProxyInstance. Hand-rolls a minimal
/// HTTP/1.1 request reader and writer — we only need request/response with
/// `Connection: close` semantics (no keep-alive, no pipelining), which keeps
/// the surface small and predictable. SSE streaming works fine over a
/// close-delimited connection.
final class ProxyServer {

    let instance: ProxyInstance
    private var listener: NWListener?
    private let queue: DispatchQueue
    /// Called on the main queue with every real listener state change. The UI
    /// derives status from this only — never from "we asked it to start".
    private let onStatus: (InstanceStatus) -> Void

    init(instance: ProxyInstance, onStatus: @escaping (InstanceStatus) -> Void) {
        self.instance = instance
        self.onStatus = onStatus
        self.queue = DispatchQueue(label: "proxy.server.\(instance.port)")
    }

    func start() {
        guard let port = NWEndpoint.Port(rawValue: UInt16(instance.port)) else {
            report(.failed("Invalid port \(instance.port)"))
            return
        }

        // Bind the socket to the 127.0.0.1 endpoint explicitly so the kernel
        // itself rejects any non-loopback connection. External access is meant
        // to go through a tunnel (ngrok/cloudflared) which runs locally and
        // reaches 127.0.0.1 — not by exposing the port on the LAN.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        do {
            let listener = try NWListener(using: params)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.report(.running)
                case .failed(let error):
                    self?.report(.failed(Self.describe(error)))
                case .cancelled:
                    self?.report(.stopped)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            report(.starting)
            listener.start(queue: queue)
        } catch {
            report(.failed(Self.describe(error)))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func report(_ status: InstanceStatus) {
        DispatchQueue.main.async { self.onStatus(status) }
    }

    private static func describe(_ error: Error) -> String {
        if let nwError = error as? NWError, case .posix(let code) = nwError, code == .EADDRINUSE {
            return "Port already in use"
        }
        return error.localizedDescription
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        let handler = HTTPConnection(conn: conn, instance: instance, queue: queue)
        handler.start()
    }
}
