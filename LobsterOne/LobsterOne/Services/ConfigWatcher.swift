import Foundation

final class ConfigWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let directoryPath: String
    private let onChange: (String?) -> Void
    private let homeDirectory: URL

    init(homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()), onChange: @escaping (String?) -> Void) {
        self.homeDirectory = homeDirectory
        self.directoryPath = homeDirectory.appendingPathComponent(".claude").path
        self.onChange = onChange
    }

    func start() {
        let fd = open(directoryPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let config = ConfigService(homeDirectory: self.homeDirectory)
            self.onChange(config.readAPIKey())
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }
}
