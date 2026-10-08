import Foundation

func scratchDirectory(_ label: String) throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "np-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// Marks `root` as an unpacked MnC Wine tree the way RunnerInstaller.hasClone looks for one.
func markClone(_ root: URL, loader: String = "loader") throws {
    let file = root.appending(path: "loader/wine")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(loader.utf8).write(to: file)
}
