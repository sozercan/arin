@testable import ArinCore
import Foundation
import Testing

extension Sandbox {
    /// A minimal app bundle in the sandbox's ~/Applications.
    func app(_ name: String, id: String, executable: String? = nil, in folder: String = "Applications") throws -> String {
        let bundle = "\(root)/\(folder)/\(name).app"
        _ = try mkdir("\(folder)/\(name).app/Contents/MacOS")
        let info: [String: Any] = [
            "CFBundleIdentifier": id,
            "CFBundleName": name,
            "CFBundleExecutable": executable ?? name,
            "CFBundleShortVersionString": "1.0",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: "\(bundle)/Contents/Info.plist"))
        _ = try write("\(folder)/\(name).app/Contents/MacOS/\(executable ?? name)", "binary")
        return bundle
    }
}

@Suite struct UninstallGuardrailTests {
    let g = Guardrails(home: "/Users/test", tmpDir: "/var/folders/ab/cdef/T/")

    @Test func allowsAppBundlesAndPerAppLibraryItems() throws {
        try g.checkUninstall("/Applications/Foo.app")
        try g.checkUninstall("/Applications/Vendor/Foo.app")
        try g.checkUninstall("/Users/test/Applications/Foo.app")
        try g.checkUninstall("/Users/test/Library/Preferences/com.foo.app.plist")
        try g.checkUninstall("/Users/test/Library/Preferences/ByHost/com.foo.app.1234.plist")
        try g.checkUninstall("/Users/test/Library/Group Containers/ABCDE12345.com.foo.app")
        try g.checkUninstall("/Users/test/Library/Application Support/Foo")
        try g.checkUninstall("/Users/test/Library/Logs/DiagnosticReports/Foo-2026-01-01.ips")
    }

    @Test func refusesEverythingElse() {
        let refused = [
            "relative/Foo.app",
            "/Applications",
            "/Applications/Foo.app/Contents/Library/LoginItems/Helper.app",
            "/Applications/a/b/Foo.app",
            "/System/Applications/Notes.app",
            "/Users/test/Documents/Foo.app",
            "/Users/test/Library/Preferences",
            "/Users/test/Library/Preferences/com.apple.finder.plist",
            "/Users/test/Library/Preferences/.GlobalPreferences.plist",
            "/Users/test/Library/Group Containers/group.com.apple.notes",
            "/Users/test/Library/Application Support/AddressBook",
            "/Users/test/Library/Application Support/MobileSync",
            "/Users/test/Library/Containers/com.docker.docker",
            "/Users/test/Library/Keychains/login.keychain-db",
            "/Users/test/Library/Caches/com.foo.app/nested",
            "/Users/test/Library/Preferences/../Documents/x",
            "/Users/other/Library/Preferences/com.foo.app.plist",
        ]
        for path in refused {
            #expect(throws: Guardrails.Violation.self, "\(path)") { try g.checkUninstall(path) }
        }
    }

    @Test func cleanupsStillCantReachUninstallPlaces() {
        #expect(throws: Guardrails.Violation.self) { try g.check("/Applications/Foo.app") }
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test/Library/Preferences/com.foo.app.plist") }
        #expect(throws: Guardrails.Violation.self) { try g.check("/Users/test/Library/Group Containers/ABCDE12345.com.foo.app") }
    }

    @Test func refusesASymlinkedFolderThatLeadsElsewhere() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let docs = try box.mkdir("Documents/private")
        _ = try box.mkdir("Library")
        try FileManager.default.createSymbolicLink(atPath: "\(box.root)/Library/Caches", withDestinationPath: docs)
        #expect(throws: Guardrails.Violation.self) { try box.guardrails.checkUninstall("\(box.root)/Library/Caches/com.foo.app") }
    }

    @Test func refusesApplesAppsByBundleID() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let notes = try box.app("Notes", id: "com.apple.Notes")
        let arin = try box.app("Arin", id: "com.sertacozercan.Arin")
        #expect(throws: Guardrails.Violation.self) { try box.guardrails.checkUninstall(notes) }
        #expect(throws: Guardrails.Violation.self) { try box.guardrails.checkUninstall(arin) }
    }

    @Test func caskTokensAreNamesOnly() {
        #expect(Guardrails.isCaskToken("visual-studio-code"))
        #expect(Guardrails.isCaskToken("ghostty@tip"))
        #expect(!Guardrails.isCaskToken("--zap"))
        #expect(!Guardrails.isCaskToken("../x"))
        #expect(!Guardrails.isCaskToken("foo bar"))
    }
}

@Suite struct AppCatalogTests {
    @Test func findsAppsOneFolderDeepWithoutApplesOrSymlinks() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        _ = try box.app("Foo", id: "com.example.Foo")
        _ = try box.app("Bar", id: "com.example.Bar", in: "Applications/Vendor")
        _ = try box.app("Notes", id: "com.apple.Notes")
        _ = try box.app("Weird", id: "notreversedns")
        _ = try box.app("Deep", id: "com.example.Deep", in: "Applications/a/b")
        try FileManager.default.createSymbolicLink(atPath: "\(box.root)/Applications/Link.app", withDestinationPath: "\(box.root)/Applications/Foo.app")
        let apps = AppCatalog.installed(roots: ["\(box.root)/Applications"])
        #expect(apps.map(\.bundleID) == ["com.example.Bar", "com.example.Foo"])
        #expect(apps.first?.version == "1.0" && apps.first?.executable == "Bar")
    }

    @Test func mapsCasksToTheirInstalledApps() {
        let json = """
        {"casks": [
          {"token": "ghostty@tip", "artifacts": [{"app": ["Ghostty.app"], "target": "/Applications/Ghostty.app"}]},
          {"token": "foo", "artifacts": [{"app": ["Foo.app"]}, {"zap": []}]},
          {"token": "renamed", "artifacts": [{"app": ["Old.app", {"target": "New.app"}]}]},
          {"token": "--zap", "artifacts": [{"app": ["Evil.app"]}]}
        ]}
        """
        let tokens = AppCatalog.parseCasks(Data(json.utf8))
        #expect(tokens == [
            "/applications/ghostty.app": "ghostty@tip",
            "/applications/foo.app": "foo",
            "/applications/new.app": "renamed",
        ])
    }
}

@Suite struct AppFilesTests {
    @Test func findsFilesByBundleIDAndFlagsLooserMatches() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let foo = try #require(AppCatalog.app(at: try box.app("Foo", id: "com.example.Foo")))
        let pro = try #require(AppCatalog.app(at: try box.app("Foo Pro", id: "com.example.Foo.Pro")))
        let lib = "Library"
        let mine = [
            try box.mkdir("\(lib)/Application Support/com.example.Foo"),
            try box.mkdir("\(lib)/Caches/com.example.foo.ShipIt"),
            try box.write("\(lib)/Preferences/com.example.Foo.plist"),
            try box.write("\(lib)/Preferences/ByHost/com.example.Foo.0000-1111.plist"),
            try box.mkdir("\(lib)/Containers/com.example.Foo.ShareExtension"),
            try box.mkdir("\(lib)/Saved Application State/com.example.Foo.savedState"),
            try box.write("\(lib)/Cookies/com.example.Foo.binarycookies"),
            try box.write("\(lib)/LaunchAgents/com.example.Foo.helper.plist"),
            try box.write("\(lib)/Logs/DiagnosticReports/Foo-2026-01-01-000000.ips"),
        ]
        let review = [
            try box.mkdir("\(lib)/Application Support/Foo"),
            try box.mkdir("\(lib)/Group Containers/ABCDE12345.com.example.Foo"),
        ]
        // Another app's files, look-alikes, and Apple's.
        for path in [
            "Preferences/com.example.Foo.Pro.plist", "Containers/com.example.FooBar", "Caches/com.example",
            "Application Support/Foo Pro", "Application Support/Other", "Logs/DiagnosticReports/Foo Pro-2026.ips",
            "Logs/DiagnosticReports/Foo-notes.txt", "Preferences/com.apple.Foo.plist",
        ] {
            _ = try box.write("\(lib)/\(path)")
        }

        func paths(_ list: [String]) -> Set<String> { Set(list.map(Uninstaller.canonical)) }
        let files = await AppFiles.find(for: foo, others: [pro], guardrails: box.guardrails)
        #expect(paths(files.map(\.path)) == paths([foo.path] + mine + review))
        #expect(paths(files.filter(\.needsReview).map(\.path)) == paths(review))
        #expect(files.first { $0.kind == .launchAgents }?.note == "Stays loaded until you log out")

        // With a second copy installed, its files are shared: nothing but the bundle is checked.
        var copy = foo
        copy.path = "\(box.root)/Applications/Vendor/Foo.app"
        let shared = await AppFiles.find(for: foo, others: [pro, copy], guardrails: box.guardrails)
        #expect(shared.filter { !$0.needsReview }.map(\.kind) == [.app])
    }

    @Test func aNameAnotherAppUsesIsLeftAlone() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let code = try #require(AppCatalog.app(at: try box.app("Code", id: "com.example.code")))
        let insiders = InstalledApp(path: "/x", name: "Code", bundleID: "com.example.code-insiders", names: ["Code"],
                                    fromAppStore: false)
        #expect(AppFiles.match("Code", kind: .applicationSupport, app: code, others: [insiders]) == nil)
        #expect(AppFiles.match("Code", kind: .applicationSupport, app: code, others: []) == true)
        // Names only count where apps use them.
        #expect(AppFiles.match("Code", kind: .containers, app: code, others: []) == nil)
    }
}

@Suite struct UninstallerTests {
    func uninstaller(_ box: Sandbox, running: [String] = [], keep: URL? = nil) -> Uninstaller {
        Uninstaller(guardrails: box.guardrails, keepListURL: keep) {
            SystemState(processPaths: running, openPaths: [], openFilesKnown: false)
        }
    }

    @Test func movesTheAppAndItsFilesToTheTrashAndPutsThemBack() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let id = "com.example.arin-test-\(UUID().uuidString.prefix(8))"
        let app = try #require(AppCatalog.app(at: try box.app("ArinTest\(UUID().uuidString.prefix(8))", id: id)))
        let prefs = try box.write("Library/Preferences/\(id).plist")
        let support = try box.mkdir("Library/Application Support/\(id)")
        let files = await AppFiles.find(for: app, others: [], guardrails: box.guardrails)
        #expect(files.count == 3)

        let report = await uninstaller(box).run(app, files: files)
        #expect(report.items.allSatisfy { $0.status == .cleaned }, "\(report.items.map(\.message))")
        #expect(!FileInfo.exists(app.path) && !FileInfo.exists(prefs) && !FileInfo.exists(support))

        let trashed = report.items.flatMap { $0.trashedPaths ?? [] }
        #expect(trashed.count == 3 && trashed.allSatisfy(\.canPutBack))
        for item in trashed { try item.putBack(guardrails: box.guardrails) }
        #expect(FileInfo.exists("\(app.path)/Contents/Info.plist") && FileInfo.exists(prefs) && FileInfo.exists(support))
    }

    @Test func refusesEverythingWhileTheAppRuns() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let app = try #require(AppCatalog.app(at: try box.app("Foo", id: "com.example.Foo")))
        let prefs = try box.write("Library/Preferences/com.example.Foo.plist")
        let files = await AppFiles.find(for: app, others: [], guardrails: box.guardrails)
        let report = await uninstaller(box, running: ["\(app.path)/Contents/MacOS/Foo"]).run(app, files: files)
        #expect(report.items.count == 2 && report.items.allSatisfy { $0.status == .skipped })
        #expect(report.items[0].message.contains("is running"))
        #expect(FileInfo.exists(app.path) && FileInfo.exists(prefs))
    }

    @Test func refusesFilesThatArentTheApps() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let app = try #require(AppCatalog.app(at: try box.app("Foo", id: "com.example.Foo")))
        let notes = try box.write("Documents/notes.txt", "precious")
        let other = try box.mkdir("Library/Caches/com.example.Other")
        let nested = try box.write("Library/Preferences/com.example.Foo/inner.plist")
        let wrongKind = try box.write("Library/Caches/com.example.Foo.plist")
        let forged = [
            AppFile(path: notes, kind: .preferences, bytes: 1, needsReview: false),
            AppFile(path: other, kind: .caches, bytes: 1, needsReview: false),
            AppFile(path: nested, kind: .preferences, bytes: 1, needsReview: false),
            AppFile(path: wrongKind, kind: .preferences, bytes: 1, needsReview: false),
        ]
        let report = await uninstaller(box).run(app, files: forged)
        #expect(report.items.allSatisfy { $0.status == .skipped && $0.message.hasPrefix("not one of") }, "\(report.items.map(\.message))")
        #expect(FileInfo.exists(notes) && FileInfo.exists(other) && FileInfo.exists(nested) && FileInfo.exists(wrongKind))

        let otherApp = try box.app("Other", id: "com.example.Other")
        let wrongApp = await uninstaller(box).run(app, files: [AppFile(path: otherApp, kind: .app, bytes: 1, needsReview: false)])
        #expect(wrongApp.items.first?.status == .skipped && FileInfo.exists(otherApp))
    }

    @Test func refusesAnAppThatChangedSinceItWasChecked() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        var app = try #require(AppCatalog.app(at: try box.app("Foo", id: "com.example.Foo")))
        app.bundleID = "com.example.Bar"
        let report = await uninstaller(box).run(app, files: [AppFile(path: app.path, kind: .app, bytes: 0, needsReview: false)])
        #expect(report.items.first?.status == .skipped && FileInfo.exists(app.path))
    }

    @Test func keepsKeptPathsAndStopsWhenTheKeepListIsUnreadable() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let app = try #require(AppCatalog.app(at: try box.app("Foo", id: "com.example.Foo")))
        let support = try box.mkdir("Library/Application Support/com.example.Foo")
        let url = URL(fileURLWithPath: "\(box.root)/keep.json")
        var list = KeepList()
        list.add(id: "t:\(support)/db", title: "Foo's database", paths: ["\(support)/db"])
        try list.save(to: url)
        let file = AppFile(path: support, kind: .applicationSupport, bytes: 0, needsReview: false)

        let kept = await uninstaller(box, keep: url).run(app, files: [file])
        #expect(kept.items.first?.status == .skipped && FileInfo.exists(support))

        try "{ not json".write(to: url, atomically: true, encoding: .utf8)
        let unreadable = await uninstaller(box, keep: url).run(app, files: [file])
        #expect(unreadable.items.first?.status == .skipped && FileInfo.exists(support))
    }

    @Test func leavesFilesWhenTheBundleCantBeRemoved() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let app = try #require(AppCatalog.app(at: try box.app("Foo", id: "com.example.Foo")))
        let prefs = try box.write("Library/Preferences/com.example.Foo.plist")
        // A bundle Arin can't move: its folder is read-only.
        let applications = "\(box.root)/Applications"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: applications)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: applications) }
        let files = await AppFiles.find(for: app, others: [], guardrails: box.guardrails)
        let report = await uninstaller(box).run(app, files: files)
        #expect(report.items.first?.status == .failed)
        #expect(report.items.last?.status == .skipped && FileInfo.exists(prefs))
    }
}
