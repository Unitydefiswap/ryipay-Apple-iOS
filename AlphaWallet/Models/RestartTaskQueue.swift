// Copyright © 2021 Stormbird PTE. LTD.

import Foundation

class RestartTaskQueue {
    private (set) var queue: [Task]

    enum Task: Equatable {
        case addServer(CustomRPC)
        case enableServer(RPCServer)
        case switchDappServer(server: RPCServer)
        case loadUrlInDappBrowser(URL)
    }

    init() {
        queue = .init()
    }

    func add(_ task: Task) {
        queue.append(task)
    }

    func remove(_ task: Task) {
        guard let index = queue.firstIndex(where: { $0 == task }) else { return }
        queue.remove(at: index)
    }
}