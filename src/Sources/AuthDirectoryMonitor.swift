import Foundation

final class AuthDirectoryMonitor {
    private let debounceInterval: TimeInterval
    private let logPrefix: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pendingRefresh: DispatchWorkItem?

    init(debounceInterval: TimeInterval, logPrefix: String, onChange: @escaping () -> Void) {
        self.debounceInterval = debounceInterval
        self.logPrefix = logPrefix
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        stop()

        let authDir = AuthPaths.authDirectory
        try? FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)

        let fileDescriptor = open(authDir.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            pendingRefresh?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                NSLog("%@ Auth directory changed", logPrefix)
                onChange()
            }
            pendingRefresh = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        self.source = source
    }

    func stop() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        source?.cancel()
        source = nil
    }
}
