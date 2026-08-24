import Foundation
import Network

/// TCP listener on the phone; PC connects via usbmuxd/iproxy tunnel over USB.
final class StreamServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "usbcam.server", qos: .userInteractive)
    private var connections: [NWConnection] = []
    private let port: UInt16
    var onClientChange: ((Int) -> Void)?

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.listener?.cancel() }
            }
            listener.start(queue: queue)
        } catch {}
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connections.append(connection)
        notify()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.connections.removeAll { $0 === connection }
                self.notify()
            default:
                break
            }
        }
        receiveLoop(connection)
    }

    /// Drain inbound bytes (peer acks) so TCP buffers don't fill.
    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, _, _ in
            guard let self, connection.state == .ready else { return }
            self.receiveLoop(connection)
        }
    }

    func broadcast(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            for conn in self.connections where conn.state == .ready {
                conn.send(content: data, completion: .contentProcessed { _ in })
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
            DispatchQueue.main.async { self.onClientChange?(0) }
        }
    }

    private func notify() {
        let count = connections.count
        DispatchQueue.main.async { [weak self] in
            self?.onClientChange?(count)
        }
    }
}
