import CoreImage
import CoreVideo
import Foundation
import JitsiCore

#if canImport(Darwin)
import Darwin
#endif

/// Screen sharing on iOS happens in a broadcast upload extension, so the frames cross a
/// process boundary before libwebrtc ever sees them. Both sides agree on an App Group and a
/// Unix-domain socket inside it; the host app listens, the extension connects and writes
/// length-prefixed BGRA frames.
public enum ScreenShareConfiguration {
    /// Must match the App Group capability on both the host app and the broadcast
    /// extension. Set this before the conference starts sharing; the extension template
    /// hardcodes the same value.
    public static var appGroupIdentifier = "group.com.jitsi.meetsdk"
    public static var socketFileName = "jitsi-broadcast.sock"
    /// Bundle id of the broadcast upload extension, used by `ScreenShareBroadcastPicker`.
    public static var extensionBundleIdentifier: String?

    static func socketURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(socketFileName)
    }
}

/// One decoded screen frame. The receiver builds the pixel buffer, so the media backend never
/// touches the wire format.
public struct ScreenShareFrame {
    public let pixelBuffer: CVPixelBuffer
    public let timestampUs: Int64
    public let rotation: VideoRotation

    public init(pixelBuffer: CVPixelBuffer, timestampUs: Int64, rotation: VideoRotation) {
        self.pixelBuffer = pixelBuffer
        self.timestampUs = timestampUs
        self.rotation = rotation
    }
}

// MARK: - Wire format
//
// 36-byte header, all big-endian:
//   magic "JSSF" | version u32 | width u32 | height u32 | bytesPerRow u32 |
//   timestampUs u64 | rotation u32 (0/90/180/270) | payloadLength u32
// followed by `payloadLength` bytes of BGRA pixels.

private enum ScreenShareWire {
    static let magic: UInt32 = 0x4A53_5346 // "JSSF"
    static let version: UInt32 = 1
    static let headerSize = 36
    static let maxPayload = 64 * 1024 * 1024

    struct Header {
        var width: Int
        var height: Int
        var bytesPerRow: Int
        var timestampUs: Int64
        var rotation: Int
        var payloadLength: Int
    }

    static func encode(_ header: Header) -> Data {
        var data = Data(capacity: headerSize)
        data.appendUInt32BE(magic)
        data.appendUInt32BE(version)
        data.appendUInt32BE(UInt32(header.width))
        data.appendUInt32BE(UInt32(header.height))
        data.appendUInt32BE(UInt32(header.bytesPerRow))
        data.appendUInt64BE(UInt64(bitPattern: header.timestampUs))
        data.appendUInt32BE(UInt32(header.rotation))
        data.appendUInt32BE(UInt32(header.payloadLength))
        return data
    }

    static func decode(_ data: Data) -> Header? {
        guard data.count == headerSize else { return nil }
        let bytes = [UInt8](data)
        func u32(_ offset: Int) -> UInt32 {
            (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
        }
        func u64(_ offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in offset..<(offset + 8) {
                value = (value << 8) | UInt64(bytes[index])
            }
            return value
        }
        guard u32(0) == magic, u32(4) == version else { return nil }
        let width = Int(u32(8))
        let height = Int(u32(12))
        let bytesPerRow = Int(u32(16))
        let timestamp = Int64(bitPattern: u64(20))
        let rotation = Int(u32(28))
        let length = Int(u32(32))
        guard width > 0, height > 0, bytesPerRow >= width * 4,
              length >= bytesPerRow * height, length <= maxPayload,
              bytesPerRow * height <= maxPayload
        else { return nil }
        return Header(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            timestampUs: timestamp,
            rotation: rotation,
            payloadLength: length
        )
    }
}

// MARK: - Host side

/// Listens on the App Group socket for frames written by the broadcast extension.
/// Reconnects are expected: the user can stop and restart the system broadcast without
/// restarting the conference, and iOS launches a fresh extension process each time.
final class ScreenShareReceiver {
    private let queue = DispatchQueue(label: "com.jitsi.screenshare.receive")
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clientFDs: Set<Int32> = []
    private var running = false
    private var onFrame: ((ScreenShareFrame) -> Void)?

    /// Binds the socket and starts accepting. Throws when the App Group is not configured,
    /// because a missing container is a setup error the integrator has to see.
    func start(onFrame: @escaping (ScreenShareFrame) -> Void) throws {
        guard let url = ScreenShareConfiguration.socketURL() else {
            throw JitsiError.unsupported(
                "screen sharing needs an App Group (\(ScreenShareConfiguration.appGroupIdentifier)) shared with the broadcast extension")
        }
        let path = url.path
        guard path.utf8.count < 104 else {
            throw JitsiError.unsupported("App Group socket path is too long for sockaddr_un")
        }

        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw JitsiError.unsupported("socket(AF_UNIX) failed: \(String(cString: strerror(errno)))")
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
            pathBytes.withUnsafeBufferPointer { source in
                UnsafeMutableRawPointer(destination).copyMemory(from: source.baseAddress!, byteCount: pathBytes.count)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            unlink(path)
            throw JitsiError.unsupported("screen-share socket bind failed: \(message)")
        }

        listenFD = fd
        running = true
        self.onFrame = onFrame
        NSLog("[jitsi-media] screen-share socket listening at %@", path)

        let acceptQueue = queue
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let listener = listenFD
        listenFD = -1
        let clients = clientFDs
        clientFDs.removeAll()
        onFrame = nil
        lock.unlock()

        if listener >= 0 {
            shutdown(listener, SHUT_RDWR)
            close(listener)
        }
        for client in clients {
            shutdown(client, SHUT_RDWR)
            close(client)
        }
        if let url = ScreenShareConfiguration.socketURL() {
            unlink(url.path)
        }
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let listener = listenFD
            let active = running
            lock.unlock()
            guard active, listener >= 0 else { return }

            var address = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listener, &address, &length)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            lock.lock()
            clientFDs.insert(client)
            lock.unlock()
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                self?.readFrames(from: client)
            }
        }
    }

    private func readFrames(from client: Int32) {
        defer {
            lock.lock()
            clientFDs.remove(client)
            lock.unlock()
            close(client)
        }
        var headerBuffer = [UInt8](repeating: 0, count: ScreenShareWire.headerSize)
        while true {
            guard readExactly(client, into: &headerBuffer) else { return }
            guard let header = ScreenShareWire.decode(Data(headerBuffer)) else {
                NSLog("[jitsi-media] screen-share: malformed frame header, closing connection")
                return
            }
            var payload = [UInt8](repeating: 0, count: header.payloadLength)
            guard readExactly(client, into: &payload) else { return }
            guard let pixelBuffer = Self.pixelBuffer(from: payload, header: header) else { continue }

            lock.lock()
            let deliver = onFrame
            let active = running
            lock.unlock()
            guard active, let deliver else { return }
            deliver(ScreenShareFrame(
                pixelBuffer: pixelBuffer,
                timestampUs: header.timestampUs,
                rotation: VideoRotation(rawValue: header.rotation) ?? .none
            ))
        }
    }

    private func readExactly(_ fd: Int32, into buffer: inout [UInt8]) -> Bool {
        var offset = 0
        let total = buffer.count
        while offset < total {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base.advanced(by: offset), total - offset)
            }
            if count <= 0 { return false }
            offset += count
        }
        return true
    }

    private static func pixelBuffer(from payload: [UInt8], header: ScreenShareWire.Header) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true
        ]
        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, header.width, header.height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created
        ) == kCVReturnSuccess, let pixelBuffer = created else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let copyBytes = min(header.width * 4, min(header.bytesPerRow, destinationStride))
        payload.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            for row in 0..<header.height {
                let sourceRow = sourceBase.advanced(by: row * header.bytesPerRow)
                let destinationRow = base.advanced(by: row * destinationStride)
                destinationRow.copyMemory(from: sourceRow, byteCount: copyBytes)
            }
        }
        return pixelBuffer
    }
}

// MARK: - Extension side

/// Writes ReplayKit frames to the App Group socket. Link this into the broadcast upload
/// extension; `Templates/JitsiBroadcastExtension/SampleHandler.swift` is the complete
/// extension-side implementation.
public final class ScreenShareBroadcastSender {
    private let path: String
    private let queue = DispatchQueue(label: "com.jitsi.screenshare.send")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var fd: Int32 = -1
    private var lastConnectAttempt: TimeInterval = 0

    /// Fails when the App Group is not configured on the extension target.
    public init?(
        appGroupIdentifier: String = ScreenShareConfiguration.appGroupIdentifier,
        socketFileName: String = ScreenShareConfiguration.socketFileName
    ) {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        else { return nil }
        path = container.appendingPathComponent(socketFileName).path
    }

    public func send(pixelBuffer: CVPixelBuffer, timestampUs: Int64, rotation: VideoRotation = .none) {
        queue.async { [self] in
            guard isConnected || connect() else { return }
            guard let frame = bgraBuffer(from: pixelBuffer) else { return }
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(frame) else { return }

            let width = CVPixelBufferGetWidth(frame)
            let height = CVPixelBufferGetHeight(frame)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(frame)
            let header = ScreenShareWire.encode(ScreenShareWire.Header(
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                timestampUs: timestampUs,
                rotation: rotation.rawValue,
                payloadLength: bytesPerRow * height
            ))
            let wroteHeader = writeAll(header)
            let wroteFrame = base.withMemoryRebound(to: UInt8.self, capacity: bytesPerRow * height) {
                writeAll($0, count: bytesPerRow * height)
            }
            if !wroteHeader || !wroteFrame {
                closeConnection()
            }
        }
    }

    public func close() {
        queue.sync {
            closeConnection()
        }
    }

    private var isConnected: Bool { fd >= 0 }

    private func connect() -> Bool {
        let now = Date().timeIntervalSince1970
        // The extension can start writing before the app has finished binding the socket;
        // retrying a few times a second keeps the first seconds of a broadcast alive without
        // spinning on a missing listener.
        guard now - lastConnectAttempt > 0.25 else { return false }
        lastConnectAttempt = now

        let candidate = socket(AF_UNIX, SOCK_STREAM, 0)
        guard candidate >= 0 else { return false }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
            pathBytes.withUnsafeBufferPointer { source in
                UnsafeMutableRawPointer(destination).copyMemory(from: source.baseAddress!, byteCount: pathBytes.count)
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(candidate, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(candidate)
            return false
        }
        fd = candidate
        return true
    }

    private func closeConnection() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            return writeAll(base.assumingMemoryBound(to: UInt8.self), count: raw.count)
        }
    }

    private func writeAll(_ base: UnsafePointer<UInt8>, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let written = write(fd, base.advanced(by: offset), count - offset)
            if written <= 0 {
                if written < 0 && errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    /// ReplayKit hands over 420f/420v buffers on most devices and BGRA on some; the wire
    /// format is BGRA so the receiver does not need a colour-space branch.
    private func bgraBuffer(from source: CVPixelBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA {
            return source
        }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var destination: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &destination
        ) == kCVReturnSuccess, let destination else { return nil }
        ciContext.render(
            CIImage(cvPixelBuffer: source),
            to: destination,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return destination
    }
}

// MARK: - Byte helpers

private extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}
