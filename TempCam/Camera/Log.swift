import os

/// Unified logging categories. View in Console.app (filter subsystem `com.tempcam.app`)
/// or with `log stream --predicate 'subsystem == "com.tempcam.app"'`.
enum Log {
    static let subsystem = "com.tempcam.app"

    /// Session configuration, devices, zoom, focus, torch.
    static let camera = Logger(subsystem: subsystem, category: "camera")
    /// Start/stop recording and the file the movie output produces.
    static let recording = Logger(subsystem: subsystem, category: "recording")
    /// Copying the finished clip and handing it to Photos.
    static let photos = Logger(subsystem: subsystem, category: "photos")
}
