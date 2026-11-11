import AppKit
import Darwin
import Foundation

private let temporaryPrefix = ".wechat-download-sync-"

func realHomeDirectory() throws -> URL {
    guard let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir else {
        throw SyncError.message("无法确定当前用户的主目录")
    }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}

func expectedWeChatRoot() throws -> URL {
    return try realHomeDirectory().appendingPathComponent(
        "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files", isDirectory: true)
}

func expectedDownloads() throws -> URL {
    return try realHomeDirectory().appendingPathComponent("Downloads", isDirectory: true)
}

func isWeChatFileDirectory(_ selected: URL) throws -> Bool {
    let root = try expectedWeChatRoot().standardizedFileURL.path
    let path = selected.standardizedFileURL.path
    guard path.hasPrefix(root + "/") else { return false }
    let components = String(path.dropFirst(root.count + 1)).split(separator: "/")
    return components.count == 3 && components[1] == "msg" && components[2] == "file"
}

struct Identity: Codable, Equatable, Hashable {
    let device: UInt64
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
}

struct FileInfo: Equatable {
    let identity: Identity
    let mode: mode_t
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    var regular: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
    var symbolicLink: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFLNK) }
    var directory: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
}

struct Transfer: Codable {
    var destination: String
    var temporary: String
    var identity: Identity
    var phase: String
}

struct SyncState: Codable {
    let version: Int
    let source: String
    let downloads: String
    let sourceIdentity: Identity
    let downloadsIdentity: Identity
    var baseline: [String: Identity]
    var transfers: [String: Transfer]
}

struct Observation {
    let info: FileInfo
    let firstSeen: Date
}

enum SyncError: Error, CustomStringConvertible {
    case message(String)
    case system(String, Int32)

    var description: String {
        switch self {
        case .message(let text): return text
        case .system(let operation, let number):
            return "\(operation)：\(String(cString: strerror(number)))"
        }
    }
}

func fileInfo(_ path: String) -> FileInfo? {
    var value = stat()
    guard lstat(path, &value) == 0 else { return nil }
    return FileInfo(
        identity: Identity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino),
                           birthSeconds: Int64(value.st_birthtimespec.tv_sec),
                           birthNanoseconds: Int64(value.st_birthtimespec.tv_nsec)),
        mode: value.st_mode, size: Int64(value.st_size),
        modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
        modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec))
}

func linkTarget(_ path: String) -> String? {
    guard fileInfo(path)?.symbolicLink == true else { return nil }
    return try? FileManager.default.destinationOfSymbolicLink(atPath: path)
}

func allFiles(_ source: URL) throws -> [String: FileInfo] {
    var walkError: Error?
    guard let resolved = realpath(source.path, nil) else {
        throw SyncError.system("解析微信文件目录", errno)
    }
    let canonicalPath = String(cString: resolved)
    free(resolved)
    let canonicalSource = URL(fileURLWithPath: canonicalPath, isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(at: canonicalSource, includingPropertiesForKeys: nil,
        options: [], errorHandler: { _, error in walkError = error; return false }) else {
        throw SyncError.message("无法读取微信文件目录")
    }
    var files: [String: FileInfo] = [:]
    let prefix = canonicalSource.path + "/"
    for case let nativeURL as NSURL in enumerator {
        let url = nativeURL as URL
        guard url.path.hasPrefix(prefix) else { continue }
        let name = url.lastPathComponent
        if name == ".DS_Store" || name.hasPrefix(temporaryPrefix) {
            if fileInfo(url.path)?.directory == true { enumerator.skipDescendants() }
            continue
        }
        guard let info = fileInfo(url.path), info.regular else { continue }
        files[String(url.path.dropFirst(prefix.count))] = info
    }
    if let error = walkError { throw error }
    return files
}

func writeState(_ state: SyncState, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(state)
    try data.write(to: url, options: .atomic)
}

func loadState(_ url: URL) throws -> SyncState {
    return try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: url))
}

func checkSource(_ source: URL, relative: String) throws -> URL {
    guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
        throw SyncError.message("微信文件路径无效")
    }
    let file = source.appendingPathComponent(relative)
    let root = source.resolvingSymlinksInPath().path
    let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().path
    guard parent == root || parent.hasPrefix(root + "/") else {
        throw SyncError.message("微信文件路径已改变")
    }
    return file
}

func unusedDestination(_ downloads: URL, name: String) -> URL {
    let original = downloads.appendingPathComponent(name)
    if fileInfo(original.path) == nil { return original }
    let stem = original.deletingPathExtension().lastPathComponent
    let suffix = original.pathExtension
    var number = 2
    while true {
        let fileName = suffix.isEmpty ? "\(stem) (微信 \(number))" : "\(stem) (微信 \(number)).\(suffix)"
        let candidate = downloads.appendingPathComponent(fileName)
        if fileInfo(candidate.path) == nil { return candidate }
        number += 1
    }
}

func systemCall(_ result: Int32, _ operation: String) throws {
    if result != 0 { throw SyncError.system(operation, errno) }
}

final class SyncWorker {
    let source: URL
    let downloads: URL
    let stateURL: URL
    var state: SyncState
    var observations: [String: Observation] = [:]
    let settleSeconds: TimeInterval

    init(source: URL, downloads: URL, stateURL: URL, state: SyncState, settleSeconds: TimeInterval = 15) {
        self.source = source
        self.downloads = downloads
        self.stateURL = stateURL
        self.state = state
        self.settleSeconds = settleSeconds
    }

    func save() throws { try writeState(state, to: stateURL) }

    func conflict(_ relative: String, _ message: String) throws {
        state.transfers[relative]?.phase = "conflict"
        try save()
        NSLog("同步暂停，保留文件供检查：%@（%@）", relative, message)
    }

    func updateLink(_ file: URL, oldTarget: URL, newTarget: URL) throws {
        if linkTarget(file.path) == newTarget.path { return }
        guard linkTarget(file.path) == oldTarget.path else {
            throw SyncError.message("微信文件链接已被修改")
        }
        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(temporaryPrefix + UUID().uuidString)
        try systemCall(symlink(newTarget.path, temporary.path), "创建更新后的微信链接")
        guard linkTarget(file.path) == oldTarget.path else {
            _ = unlink(temporary.path)
            throw SyncError.message("微信文件链接在更新期间发生变化")
        }
        try systemCall(renamex_np(file.path, temporary.path, UInt32(RENAME_SWAP)), "更新微信文件链接")
        guard linkTarget(temporary.path) == oldTarget.path else {
            if linkTarget(file.path) == newTarget.path {
                _ = renamex_np(file.path, temporary.path, UInt32(RENAME_SWAP))
            }
            throw SyncError.message("微信文件链接在切换期间发生变化")
        }
        try systemCall(unlink(temporary.path), "清理旧微信链接")
    }

    func finish(_ relative: String) throws {
        guard var record = state.transfers[relative] else { return }
        let file = try checkSource(source, relative: relative)
        guard record.destination == URL(fileURLWithPath: record.destination).lastPathComponent,
              record.temporary.hasPrefix(temporaryPrefix), !record.temporary.contains("/") else {
            try conflict(relative, "文件名无效")
            return
        }
        let destination = downloads.appendingPathComponent(record.destination)
        let temporary = file.deletingLastPathComponent().appendingPathComponent(record.temporary)

        if linkTarget(file.path) == destination.path {
            if let tempInfo = fileInfo(temporary.path) {
                guard tempInfo.symbolicLink, linkTarget(temporary.path) == destination.path else {
                    try conflict(relative, "中断后的临时文件需要检查")
                    return
                }
                try systemCall(unlink(temporary.path), "清理临时链接")
            }
            record.phase = "linked"
            state.transfers[relative] = record
            try save()
            return
        }
        if let original = fileInfo(file.path) {
            guard original.regular, original.identity == record.identity else {
                try conflict(relative, "微信文件在同步期间发生变化")
                return
            }
            if fileInfo(destination.path) != nil {
                if linkTarget(temporary.path) == destination.path {
                    try systemCall(unlink(temporary.path), "清理临时链接")
                }
                record.destination = unusedDestination(downloads, name: file.lastPathComponent).lastPathComponent
                record.temporary = temporaryPrefix + UUID().uuidString
                state.transfers[relative] = record
                try save()
                return
            }
            if fileInfo(temporary.path) != nil {
                guard linkTarget(temporary.path) == destination.path else {
                    try conflict(relative, "临时路径已被占用")
                    return
                }
            } else {
                try systemCall(symlink(destination.path, temporary.path), "建立微信文件链接")
            }
            guard fileInfo(file.path)?.identity == record.identity else {
                try conflict(relative, "微信文件在同步期间发生变化")
                return
            }
            if renamex_np(file.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
                if errno == EEXIST {
                    try systemCall(unlink(temporary.path), "清理临时链接")
                    record.destination = unusedDestination(downloads, name: file.lastPathComponent).lastPathComponent
                    record.temporary = temporaryPrefix + UUID().uuidString
                    state.transfers[relative] = record
                    try save()
                    return
                }
                throw SyncError.system("移动下载文件", errno)
            }
            guard fileInfo(destination.path)?.identity == record.identity else {
                if fileInfo(file.path) == nil {
                    _ = renamex_np(destination.path, file.path, UInt32(RENAME_EXCL))
                }
                try conflict(relative, "文件在移动时发生变化")
                return
            }
        } else {
            guard let moved = fileInfo(destination.path) else {
                if linkTarget(temporary.path) == destination.path {
                    try systemCall(unlink(temporary.path), "清理临时链接")
                }
                state.transfers.removeValue(forKey: relative)
                try save()
                return
            }
            guard moved.regular, moved.identity == record.identity else {
                try conflict(relative, "移动后的下载文件已改变")
                return
            }
        }
        if fileInfo(temporary.path) != nil {
            guard linkTarget(temporary.path) == destination.path else {
                try conflict(relative, "临时路径已被占用")
                return
            }
        } else {
            try systemCall(symlink(destination.path, temporary.path), "建立微信文件链接")
        }
        guard fileInfo(file.path) == nil else {
            try conflict(relative, "微信文件路径已被占用")
            return
        }
        try systemCall(renamex_np(temporary.path, file.path, UInt32(RENAME_EXCL)), "启用微信文件链接")
        record.phase = "linked"
        state.transfers[relative] = record
        try save()
        NSLog("已放入下载文件夹：%@", destination.lastPathComponent)
    }

    func scan() throws {
        guard fileInfo(source.path)?.identity == state.sourceIdentity,
              fileInfo(downloads.path)?.identity == state.downloadsIdentity else {
            throw SyncError.message("微信目录或下载目录不可用，同步已暂停")
        }
        for (relative, record) in state.transfers {
            let file = try checkSource(source, relative: relative)
            let destination = downloads.appendingPathComponent(record.destination)
            if record.phase == "planned" {
                do { try finish(relative) } catch { NSLog("同步失败：%@", String(describing: error)) }
            } else if record.phase == "linked" {
                if fileInfo(destination.path) == nil {
                    let moved = try allFiles(downloads).first { $0.value.identity == record.identity }
                    if let moved = moved {
                        let updated = downloads.appendingPathComponent(moved.key)
                        try updateLink(file, oldTarget: destination, newTarget: updated)
                        state.transfers[relative]?.destination = moved.key
                        try save()
                        NSLog("下载文件已改名或移到子文件夹，微信链接已更新：%@", moved.key)
                        continue
                    }
                    if linkTarget(file.path) == destination.path {
                        try systemCall(unlink(file.path), "移除已删除文件的微信链接")
                    }
                    state.transfers.removeValue(forKey: relative)
                    try save()
                    NSLog("下载文件已删除，微信链接已移除：%@", relative)
                } else if fileInfo(file.path) == nil {
                    state.transfers.removeValue(forKey: relative)
                    try save()
                } else if let actual = fileInfo(destination.path), actual.regular,
                          actual.identity != record.identity {
                    state.transfers[relative]?.identity = actual.identity
                    try save()
                }
            }
        }
        let current = try allFiles(source)
        let originalIdentities = Set(state.baseline.values)
        var baselineChanged = false
        for (relative, info) in current {
            if state.baseline[relative] != nil || originalIdentities.contains(info.identity) {
                if state.baseline[relative] != info.identity {
                    state.baseline[relative] = info.identity
                    baselineChanged = true
                }
            }
        }
        for relative in Array(state.baseline.keys) {
            if current[relative] == nil && fileInfo(source.appendingPathComponent(relative).path) == nil {
                state.baseline.removeValue(forKey: relative)
                baselineChanged = true
            }
        }
        if baselineChanged { try save() }

        let now = Date()
        for (relative, info) in current {
            if state.baseline[relative] != nil || state.transfers[relative] != nil {
                observations.removeValue(forKey: relative)
                continue
            }
            guard let observation = observations[relative], observation.info == info else {
                observations[relative] = Observation(info: info, firstSeen: now)
                continue
            }
            guard now.timeIntervalSince(observation.firstSeen) >= settleSeconds else { continue }
            let original = try checkSource(source, relative: relative)
            let target = unusedDestination(downloads, name: original.lastPathComponent)
            state.transfers[relative] = Transfer(destination: target.lastPathComponent,
                temporary: temporaryPrefix + UUID().uuidString, identity: info.identity, phase: "planned")
            try save()
            do { try finish(relative) } catch { NSLog("同步失败：%@", String(describing: error)) }
            observations.removeValue(forKey: relative)
        }
        for relative in Array(observations.keys) where current[relative] == nil {
            observations.removeValue(forKey: relative)
        }
    }
}

func initialize(source: URL, downloads: URL, stateURL: URL) throws {
    guard !FileManager.default.fileExists(atPath: stateURL.path) else {
        throw SyncError.message("同步配置已存在")
    }
    guard let sourceInfo = fileInfo(source.path), sourceInfo.directory,
          let downloadsInfo = fileInfo(downloads.path), downloadsInfo.directory,
          sourceInfo.identity.device == downloadsInfo.identity.device else {
        throw SyncError.message("微信目录和下载目录必须存在于同一文件系统")
    }
    let baseline = try allFiles(source).mapValues { $0.identity }
    let state = SyncState(version: 1, source: source.path, downloads: downloads.path,
        sourceIdentity: sourceInfo.identity, downloadsIdentity: downloadsInfo.identity,
        baseline: baseline, transfers: [:])
    try writeState(state, to: stateURL)
    NSLog("已保留 %d 个现有文件", baseline.count)
}

func showMessage(_ text: String) {
    let alert = NSAlert()
    alert.messageText = "微信下载同步"
    alert.informativeText = text
    alert.addButton(withTitle: "好")
    alert.runModal()
}

func chooseDirectory(_ suggested: URL, title: String, message: String, requireMatch: Bool) throws -> URL {
    let panel = NSOpenPanel()
    panel.title = title
    panel.message = message
    panel.prompt = "授权此文件夹"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = suggested
    guard panel.runModal() == .OK, let selection = panel.url else {
        throw SyncError.message("未选择文件夹")
    }
    guard !requireMatch || selection.resolvingSymlinksInPath().path == suggested.resolvingSymlinksInPath().path else {
        throw SyncError.message("所选目录与要求的文件夹不一致")
    }
    return selection
}

func configure(appSupport: URL) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
    let downloads = try expectedDownloads()
    let sourceSelection = try chooseDirectory(expectedWeChatRoot(), title: "选择微信文件夹",
        message: "请选择微信账号目录下的 msg/file 文件夹。已有文件将留在原处。", requireMatch: false)
    guard try isWeChatFileDirectory(sourceSelection) else {
        throw SyncError.message("请选择微信账号目录下的 msg/file 文件夹")
    }
    let source = sourceSelection.standardizedFileURL
    guard sourceSelection.startAccessingSecurityScopedResource() else {
        throw SyncError.message("无法获得微信文件夹访问权限")
    }
    defer { sourceSelection.stopAccessingSecurityScopedResource() }
    let downloadSelection = try chooseDirectory(downloads, title: "选择下载文件夹",
        message: "请选择系统“下载”文件夹，供同步程序保存今后的微信新文件。", requireMatch: true)
    guard downloadSelection.startAccessingSecurityScopedResource() else {
        throw SyncError.message("无法获得下载文件夹访问权限")
    }
    defer { downloadSelection.stopAccessingSecurityScopedResource() }
    let sourceBookmark = try sourceSelection.bookmarkData(options: [.withSecurityScope],
                                                           includingResourceValuesForKeys: nil, relativeTo: nil)
    let downloadsBookmark = try downloadSelection.bookmarkData(options: [.withSecurityScope],
                                                                includingResourceValuesForKeys: nil, relativeTo: nil)
    try sourceBookmark.write(to: appSupport.appendingPathComponent("source.bookmark"), options: .atomic)
    try downloadsBookmark.write(to: appSupport.appendingPathComponent("downloads.bookmark"), options: .atomic)
    let stateURL = appSupport.appendingPathComponent("state.json")
    if FileManager.default.fileExists(atPath: stateURL.path) {
        let existing = try loadState(stateURL)
        guard existing.source == source.path, existing.downloads == downloads.path else {
            throw SyncError.message("现有同步配置与授权路径不一致")
        }
    } else {
        try initialize(source: source, downloads: downloads, stateURL: stateURL)
    }
}

func diagnoseAccess(source: URL, downloads: URL) throws {
    let name = temporaryPrefix + UUID().uuidString
    let sourceTest = source.appendingPathComponent(name)
    let destinationTest = downloads.appendingPathComponent(name)
    defer {
        _ = unlink(sourceTest.path)
        _ = unlink(destinationTest.path)
    }
    let sourceFD = open(sourceTest.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
    guard sourceFD >= 0 else { throw SyncError.system("创建微信目录测试文件", errno) }
    close(sourceFD)
    let downloadFD = open(destinationTest.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
    guard downloadFD >= 0 else { throw SyncError.system("创建下载目录测试文件", errno) }
    close(downloadFD)
    try systemCall(unlink(destinationTest.path), "清理下载目录测试文件")
    print("两个目录均可写入")
    if link(sourceTest.path, destinationTest.path) == 0 {
        print("跨目录建立文件链接成功")
        try systemCall(unlink(destinationTest.path), "清理测试链接")
    } else {
        print("跨目录建立文件链接失败：\(String(cString: strerror(errno)))")
    }
    if renamex_np(sourceTest.path, destinationTest.path, UInt32(RENAME_EXCL)) == 0 {
        print("跨目录移动文件成功")
        try systemCall(renamex_np(destinationTest.path, sourceTest.path, UInt32(RENAME_EXCL)), "恢复测试文件")
    } else {
        print("跨目录移动文件失败：\(String(cString: strerror(errno)))")
    }
}

func runBackground(appSupport: URL) throws {
    let data = try Data(contentsOf: appSupport.appendingPathComponent("source.bookmark"))
    var stale = false
    let selection = try URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                            relativeTo: nil, bookmarkDataIsStale: &stale)
    guard !stale, selection.startAccessingSecurityScopedResource() else {
        throw SyncError.message("微信文件夹授权已失效")
    }
    defer { selection.stopAccessingSecurityScopedResource() }
    let downloadsData = try Data(contentsOf: appSupport.appendingPathComponent("downloads.bookmark"))
    var downloadsStale = false
    let downloadSelection = try URL(resolvingBookmarkData: downloadsData, options: [.withSecurityScope],
                                    relativeTo: nil, bookmarkDataIsStale: &downloadsStale)
    guard !downloadsStale, downloadSelection.startAccessingSecurityScopedResource() else {
        throw SyncError.message("下载文件夹授权已失效")
    }
    defer { downloadSelection.stopAccessingSecurityScopedResource() }
    let stateURL = appSupport.appendingPathComponent("state.json")
    let state = try loadState(stateURL)
    let source = URL(fileURLWithPath: state.source, isDirectory: true)
    let downloads = URL(fileURLWithPath: state.downloads, isDirectory: true)
    guard state.version == 1, try isWeChatFileDirectory(source),
          selection.resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path,
          downloads.resolvingSymlinksInPath().path == (try expectedDownloads()).resolvingSymlinksInPath().path,
          downloadSelection.resolvingSymlinksInPath().path == downloads.resolvingSymlinksInPath().path else {
        throw SyncError.message("同步配置与授权路径不一致")
    }
    if CommandLine.arguments.contains("--check") {
        guard fileInfo(source.path)?.identity == state.sourceIdentity,
              fileInfo(downloads.path)?.identity == state.downloadsIdentity else {
            throw SyncError.message("同步目录已更改或不可用")
        }
        _ = try allFiles(source)
        print("文件夹授权和同步配置正常")
        return
    }
    if CommandLine.arguments.contains("--diagnose") {
        try diagnoseAccess(source: source, downloads: downloads)
        return
    }
    let lockURL = appSupport.appendingPathComponent("sync.lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
    guard descriptor >= 0 else { throw SyncError.system("打开同步锁", errno) }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        throw SyncError.message("同步程序已在运行")
    }
    let worker = SyncWorker(source: source, downloads: downloads,
                            stateURL: stateURL, state: state)
    while true {
        do { try worker.scan() } catch { NSLog("同步检查失败：%@", String(describing: error)) }
        Thread.sleep(forTimeInterval: 2)
    }
}

func selfTest() throws {
    let expectedRoot = try expectedWeChatRoot()
    let validAccount = expectedRoot.appendingPathComponent("example-account/msg/file", isDirectory: true)
    let invalidAccount = expectedRoot.appendingPathComponent("example-account/msg/video", isDirectory: true)
    guard try isWeChatFileDirectory(validAccount), try !isWeChatFileDirectory(invalidAccount) else {
        throw SyncError.message("微信账号目录识别测试失败")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-sync-" + UUID().uuidString)
    let source = root.appendingPathComponent("file", isDirectory: true)
    let month = source.appendingPathComponent("2026-11", isDirectory: true)
    let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = month.appendingPathComponent("old.txt")
    try Data("old".utf8).write(to: old)
    let stateURL = root.appendingPathComponent("state.json")
    try initialize(source: source, downloads: downloads, stateURL: stateURL)
    let worker = SyncWorker(source: source, downloads: downloads, stateURL: stateURL,
                            state: try loadState(stateURL), settleSeconds: 0)
    let incoming = month.appendingPathComponent("new.txt")
    try Data("new".utf8).write(to: incoming)
    try worker.scan()
    try worker.scan()
    let target = downloads.appendingPathComponent("new.txt")
    guard linkTarget(incoming.path) == target.path,
          try String(contentsOf: target, encoding: .utf8) == "new",
          fileInfo(old.path)?.regular == true else {
        throw SyncError.message("新文件或历史文件测试失败")
    }
    let restartedWorker = SyncWorker(source: source, downloads: downloads, stateURL: stateURL,
                                     state: try loadState(stateURL), settleSeconds: 0)
    try FileManager.default.removeItem(at: target)
    try restartedWorker.scan()
    guard fileInfo(incoming.path) == nil, fileInfo(old.path)?.regular == true else {
        throw SyncError.message("删除同步测试失败")
    }
    let existingTarget = downloads.appendingPathComponent("same.txt")
    let collision = month.appendingPathComponent("same.txt")
    try Data("unrelated".utf8).write(to: existingTarget)
    try Data("wechat".utf8).write(to: collision)
    try restartedWorker.scan()
    try restartedWorker.scan()
    let alternate = downloads.appendingPathComponent("same (微信 2).txt")
    guard try String(contentsOf: existingTarget, encoding: .utf8) == "unrelated",
          try String(contentsOf: alternate, encoding: .utf8) == "wechat",
          linkTarget(collision.path) == alternate.path else {
        throw SyncError.message("同名文件测试失败")
    }
    let subfolder = downloads.appendingPathComponent("分类", isDirectory: true)
    try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
    let renamed = subfolder.appendingPathComponent("renamed.txt")
    try FileManager.default.moveItem(at: alternate, to: renamed)
    try restartedWorker.scan()
    guard linkTarget(collision.path) == renamed.path,
          try String(contentsOf: collision, encoding: .utf8) == "wechat" else {
        throw SyncError.message("下载文件改名或移动测试失败")
    }
    try FileManager.default.removeItem(at: renamed)
    try restartedWorker.scan()
    guard fileInfo(collision.path) == nil else {
        throw SyncError.message("改名后的删除同步测试失败")
    }
    let oldMoved = month.appendingPathComponent("old-renamed.txt")
    try FileManager.default.moveItem(at: old, to: oldMoved)
    try restartedWorker.scan()
    try restartedWorker.scan()
    guard fileInfo(oldMoved.path)?.regular == true,
          fileInfo(downloads.appendingPathComponent("old-renamed.txt").path) == nil else {
        throw SyncError.message("已有文件移动测试失败")
    }
    let recovery = month.appendingPathComponent("recovery.txt")
    let recoveryTarget = downloads.appendingPathComponent("recovery.txt")
    let recoveryTemporary = month.appendingPathComponent(temporaryPrefix + "recovery")
    try Data("recovery".utf8).write(to: recovery)
    guard let recoveryInfo = fileInfo(recovery.path) else {
        throw SyncError.message("恢复测试文件不存在")
    }
    restartedWorker.state.transfers["2026-11/recovery.txt"] = Transfer(
        destination: recoveryTarget.lastPathComponent, temporary: recoveryTemporary.lastPathComponent,
        identity: recoveryInfo.identity, phase: "planned")
    try restartedWorker.save()
    try systemCall(symlink(recoveryTarget.path, recoveryTemporary.path), "创建恢复测试链接")
    try systemCall(renamex_np(recovery.path, recoveryTarget.path, UInt32(RENAME_EXCL)), "移动恢复测试文件")
    let recoveredWorker = SyncWorker(source: source, downloads: downloads, stateURL: stateURL,
                                    state: try loadState(stateURL), settleSeconds: 0)
    try recoveredWorker.scan()
    guard linkTarget(recovery.path) == recoveryTarget.path,
          try String(contentsOf: recovery, encoding: .utf8) == "recovery" else {
        throw SyncError.message("中断恢复测试失败")
    }
    try FileManager.default.removeItem(at: recoveryTarget)
    try recoveredWorker.scan()
    guard fileInfo(recovery.path) == nil else {
        throw SyncError.message("恢复后的删除同步测试失败")
    }
    print("模拟测试通过")
}

do {
    if CommandLine.arguments.contains("--self-test") {
        try selfTest()
    } else {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WeChatDownloadSync", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--configure") {
            do { try configure(appSupport: support) }
            catch { showMessage("无法完成授权：\(error)"); exit(1) }
        } else {
            try runBackground(appSupport: support)
        }
    }
} catch {
    NSLog("微信下载同步失败：%@", String(describing: error))
    exit(1)
}
