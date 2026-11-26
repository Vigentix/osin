import Darwin
import Foundation

/// Which file a path refers to (device + inode), read without following symlinks.
///
/// Recorded when an item is scanned and when it is trashed, so a later clean or restore can tell
/// "the same item" from "something else that now has the same path".
public struct FileIdentity: Sendable, Codable, Hashable {
    public let device: Int64
    public let inode: UInt64

    public init(device: Int64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    /// `nil` when nothing exists at `path`.
    public init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
    }
}
