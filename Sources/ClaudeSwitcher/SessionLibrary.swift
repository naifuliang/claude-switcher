import AppKit
import Foundation
import SwiftUI

struct LocalCodeSession: Identifiable {
    let id: String
    let title: String
    let workingDirectory: String
    let mode: String
    let file: URL
    let archived: Bool
}

struct SessionScan {
    var sessions: [LocalCodeSession] = []
    var unreadableFiles = 0
}

enum SessionLibrary {
    static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    // Read only. Never migrate credentials, Electron databases or account permissions.
    static func scan(support: URL = applicationSupport) -> SessionScan {
        var result = SessionScan()
        for mode in ["Claude", "Claude-3p"] {
            let root = support.appendingPathComponent(mode).appendingPathComponent("claude-code-sessions")
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in files where file.pathExtension == "json" {
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                do {
                    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
                    guard let session = object as? [String: Any], let id = session["sessionId"] as? String else { continue }
                    result.sessions.append(LocalCodeSession(
                        id: mode + ":" + file.path + ":" + id,
                        title: session["title"] as? String ?? L("Untitled session", "未命名会话"),
                        workingDirectory: session["originCwd"] as? String ?? session["cwd"] as? String ?? "",
                        mode: mode, file: file, archived: session["isArchived"] as? Bool ?? false))
                } catch { result.unreadableFiles += 1 }
            }
        }
        result.sessions.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return result
    }
}

struct SessionLibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var scan = SessionScan()
    @State private var loading = false
    @State private var query = ""
    @State private var groupByFolder = true
    @State private var expanded: Set<String> = []

    private var filtered: [LocalCodeSession] {
        scan.sessions.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.workingDirectory.localizedCaseInsensitiveContains(query) }
    }
    private var groups: [(String, [LocalCodeSession])] {
        Dictionary(grouping: filtered) { session in
            let mode = session.mode == "Claude" ? L("Official mode", "官方模式") : L("Third-party mode", "第三方模式")
            if groupByFolder {
                let folder = session.workingDirectory.isEmpty ? L("Unknown folder", "未知目录") : session.workingDirectory
                return mode + " · " + folder
            }
            return mode
        }.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    var body: some View {
        WorkspacePage(title: L("Sessions", "会话"), subtitle: L("Find your local Code history, even when it is hidden after switching.", "检查本机 Code 历史，找回切换后看不到的会话。")) {
            HStack(spacing: 16) {
                countCard(L("Official mode", "官方模式"), count: scan.sessions.filter { $0.mode == "Claude" }.count)
                countCard(L("Third-party mode", "第三方模式"), count: scan.sessions.filter { $0.mode == "Claude-3p" }.count)
            }
            SurfaceCard {
                Label(L("Different modes, different history folders", "不同模式使用不同的历史目录"), systemImage: "folder.badge.questionmark").font(.headline)
                Text(L("The switcher changes inference settings, not your signed-in identity. Official and third-party modes can show different local histories. A missing sidebar entry does not mean the session was deleted.", "切换器更改的是推理配置，不是 Claude 登录身份。官方模式和第三方模式可能显示不同的本地历史；侧边栏看不到，不代表文件被删除。"))
                    .foregroundStyle(.secondary)
                Text(L("The list below is read-only and grouped by folder. Use Claude's own import/export wizard to preview and transfer supported sessions and projects. Custom sidebar-group fidelity depends on Claude's importer and is not guaranteed.", "下方列表为只读目录索引。通过 Claude 自带的导入与导出向导，可预览并迁移受支持的会话与项目；自定义侧边栏分组能否完整保留，取决于 Claude 的导入器，暂不保证。"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L("Set up history import", "准备导入历史会话")) { model.prepareHistoryImport() }
                        .buttonStyle(.borderedProminent).disabled(model.busy)
                    Button(L("Show original history folder", "显示原历史目录")) {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: SessionLibrary.applicationSupport.appendingPathComponent("Claude").path)
                    }
                }
                Text(L("In Claude: Settings → Import & export. Nothing is imported automatically.", "Claude 内的入口：设置 → Import & export。不会自动导入任何内容。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            SurfaceCard {
                HStack {
                    TextField(L("Search sessions or folders", "搜索会话或目录"), text: $query).textFieldStyle(.roundedBorder)
                    Toggle(L("Group by folder", "按目录分组"), isOn: $groupByFolder).toggleStyle(.checkbox)
                    Button { refresh() } label: { Label(L("Scan", "扫描"), systemImage: "arrow.clockwise") }.disabled(loading)
                    if loading { ProgressView().controlSize(.small) }
                }
                if scan.unreadableFiles > 0 {
                    Text(L("\(scan.unreadableFiles) files could not be read; results may be incomplete.", "有 \(scan.unreadableFiles) 个文件无法读取，结果可能不完整。"))
                        .font(.caption).foregroundStyle(.orange)
                }
                if filtered.isEmpty && !loading {
                    Text(L("No matching local sessions found.", "未找到匹配的本地会话。"))
                        .foregroundStyle(.secondary).padding(.vertical, 20)
                }
                ForEach(groups, id: \.0) { name, sessions in
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(name) }, set: { on in
                        if on { expanded.insert(name) } else { expanded.remove(name) }
                    })) {
                        VStack(spacing: 0) {
                            ForEach(sessions) { session in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "bubble.left").foregroundStyle(.secondary).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(session.title).font(.subheadline).textSelection(.enabled)
                                        if session.archived { Text(L("Archived", "已归档")).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Button(L("Show file", "显示文件")) { NSWorkspace.shared.activateFileViewerSelecting([session.file]) }
                                }.padding(.vertical, 10)
                                Divider()
                            }
                        }.padding(.leading, 8)
                    } label: {
                        HStack {
                            Text(groupTitle(name)).font(.subheadline).lineLimit(2).help(name)
                            Spacer()
                            Text("\(sessions.count)").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
            }
        }.task { refresh() }
    }

    private func groupTitle(_ key: String) -> String {
        guard groupByFolder, let separator = key.range(of: " · ") else { return key }
        let mode = String(key[..<separator.lowerBound])
        let path = String(key[separator.upperBound...])
        return mode + " · " + URL(fileURLWithPath: path).lastPathComponent
    }

    private func countCard(_ title: String, count: Int) -> some View {
        SurfaceCard {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(loading ? "—" : "\(count)").font(.system(size: 32, weight: .semibold, design: .rounded))
            Text(L("Local Code sessions", "本地 Code 会话")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            scan = await Task.detached(priority: .userInitiated) { SessionLibrary.scan() }.value
            loading = false
        }
    }
}
