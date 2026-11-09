import Foundation
import Testing

struct ProjectFile {
    let missingEntries: [String]
    let orphanBuildFiles: [String]
    let unbuiltSwiftFiles: [String]

    init(root: URL) throws {
        let projectURL = root.appendingPathComponent("SignDrop.xcodeproj/project.pbxproj")
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: projectURL), format: nil)
        let project = try #require(plist as? [String: Any])
        let objects = try #require(project["objects"] as? [String: [String: Any]])
        let rootObjectID = try #require(project["rootObject"] as? String)
        let mainGroup = try #require(objects[rootObjectID]?["mainGroup"] as? String)

        var missing: [String] = []
        var grouped = Set<String>()
        func walk(_ id: String, base: URL) {
            guard let item = objects[id] else { return }
            let isInGroup = item["sourceTree"] as? String == "<group>"
            var url = base
            if isInGroup, let path = item["path"] as? String {
                url = base.appendingPathComponent(path)
            }
            if item["isa"] as? String == "PBXGroup" {
                (item["children"] as? [String] ?? []).forEach { walk($0, base: url) }
            } else if isInGroup {
                grouped.insert(id)
                if !FileManager.default.fileExists(atPath: url.path) {
                    missing.append(url.path)
                }
            }
        }
        walk(mainGroup, base: root)

        let sources = objects.values
            .filter { $0["isa"] as? String == "PBXSourcesBuildPhase" }
            .flatMap { $0["files"] as? [String] ?? [] }
            .compactMap { objects[$0]?["fileRef"] as? String }
        let sourceNames = Set(sources.compactMap { objects[$0]?["path"] as? String })

        var unbuilt: [String] = []
        let appDirectory = root.appendingPathComponent("SignDrop").path
        for case let path as String in FileManager.default.enumerator(atPath: appDirectory)
            ?? FileManager.DirectoryEnumerator() where path.hasSuffix(".swift")
        {
            if !sourceNames.contains((path as NSString).lastPathComponent) {
                unbuilt.append(path)
            }
        }

        missingEntries = missing
        orphanBuildFiles = sources.filter { !grouped.contains($0) }.map {
            objects[$0]?["path"] as? String ?? $0
        }
        unbuiltSwiftFiles = unbuilt.sorted()
    }
}

struct ProjectFileTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func everyProjectEntryExistsOnDisk() throws {
        #expect(try ProjectFile(root: Self.root).missingEntries == [])
    }

    @Test func everyBuiltFileBelongsToAGroup() throws {
        #expect(try ProjectFile(root: Self.root).orphanBuildFiles == [])
    }

    @Test func everySwiftFileIsBuilt() throws {
        #expect(try ProjectFile(root: Self.root).unbuiltSwiftFiles == [])
    }
}
