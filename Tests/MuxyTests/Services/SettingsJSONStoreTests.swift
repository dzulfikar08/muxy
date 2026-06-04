import Foundation
import Testing

@testable import Muxy

private let testPortKey = AIUsageSettingsStore.autoRefreshIntervalKey

@Suite("SettingsJSONStore", .serialized)
@MainActor
struct SettingsJSONStoreTests {
    @Test
    func saveAppliesKnownSettingsAndPreservesUnknownKeys() throws {
        let snapshot = SettingsJSONStoreSnapshot.capture(keys: [testPortKey])
        defer { snapshot.restore() }

        try SettingsJSONStore.saveUserSettingsText("{\"unknown.setting\":{\"nested\":true},\"\(testPortKey)\":900}")

        let savedText = try String(contentsOf: SettingsJSONStore.userSettingsURL, encoding: .utf8)

        #expect(UserDefaults.standard.integer(forKey: testPortKey) == 900)
        #expect(savedText.contains("\"unknown.setting\""))
        #expect(savedText.contains("  \"nested\" : true"))
        #expect(savedText.hasSuffix("\n"))
    }

    @Test
    func invalidKnownValueDoesNotWriteOrApplySettings() throws {
        let snapshot = SettingsJSONStoreSnapshot.capture(keys: [testPortKey])
        defer { snapshot.restore() }
        let originalText = "{\"unchanged\":true}\n"

        try originalText.write(to: SettingsJSONStore.userSettingsURL, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(900, forKey: testPortKey)

        #expect(throws: SettingsJSONError.self) {
            try SettingsJSONStore.saveUserSettingsText("""
            {
              "\(testPortKey)": 0
            }
            """)
        }

        let savedText = try String(contentsOf: SettingsJSONStore.userSettingsURL, encoding: .utf8)

        #expect(savedText == originalText)
        #expect(UserDefaults.standard.integer(forKey: testPortKey) == 900)
    }

    @Test
    func invalidSpecialValueDoesNotWriteSettings() throws {
        let snapshot = SettingsJSONStoreSnapshot.capture(keys: [])
        defer { snapshot.restore() }
        let originalText = "{\"unchanged\":true}\n"

        try originalText.write(to: SettingsJSONStore.userSettingsURL, atomically: true, encoding: .utf8)

        #expect(throws: SettingsJSONError.self) {
            try SettingsJSONStore.saveUserSettingsText("""
            {
              "ai.providers": []
            }
            """)
        }

        let savedText = try String(contentsOf: SettingsJSONStore.userSettingsURL, encoding: .utf8)

        #expect(savedText == originalText)
    }

    @Test
    func invalidAppShortcutsDoNotReplaceBindings() throws {
        let snapshot = SettingsJSONStoreSnapshot.capture(keys: [])
        let originalBindings = KeyBindingStore.shared.bindings
        defer {
            KeyBindingStore.shared.replaceBindings(originalBindings)
            snapshot.restore()
        }

        #expect(throws: SettingsJSONError.self) {
            try SettingsJSONStore.saveUserSettingsText("""
            {
              "shortcuts.app": {
                "unknownAction": {}
              }
            }
            """)
        }

        #expect(KeyBindingStore.shared.bindings.count == originalBindings.count)
        for binding in originalBindings {
            let current = KeyBindingStore.shared.bindings.first { $0.action == binding.action }
            #expect(current?.combo == binding.combo)
        }
    }

    @Test
    func appShortcutsAllowUnassignedBindings() throws {
        let snapshot = SettingsJSONStoreSnapshot.capture(keys: [])
        let originalBindings = KeyBindingStore.shared.bindings
        defer {
            KeyBindingStore.shared.replaceBindings(originalBindings)
            snapshot.restore()
        }

        try SettingsJSONStore.saveUserSettingsText("""
        {
          "shortcuts.app": {
            "openVCSTab": {
              "key": "",
              "modifiers": 0
            }
          }
        }
        """)

        #expect(KeyBindingStore.shared.combo(for: .openVCSTab) == KeyCombo(key: "", modifiers: 0))
    }

    @Test
    func omittedKnownSettingsRemainUnchanged() throws {
        let snapshot = SettingsJSONStoreSnapshot.capture(keys: [testPortKey])
        defer { snapshot.restore() }

        UserDefaults.standard.set(900, forKey: testPortKey)

        try SettingsJSONStore.saveUserSettingsText("""
        {
          "unknown.setting": true
        }
        """)

        #expect(UserDefaults.standard.integer(forKey: testPortKey) == 900)
    }

    @Test
    func prettifiedSettingsTextSortsAndFormatsJSONObject() throws {
        let text = try SettingsJSONStore.prettifiedSettingsText("{\"z\":1,\"a\":{\"b\":true}}")

        #expect(text == """
        {
          "a" : {
            "b" : true
          },
          "z" : 1
        }

        """)
    }

    @Test
    func saveAppliesEditorSettings() throws {
        let settings = EditorSettings.shared
        let originalDefaultEditor = settings.defaultEditor
        let originalFontSize = settings.fontSize
        let originalLineWrapping = settings.lineWrapping
        defer {
            settings.defaultEditor = originalDefaultEditor
            settings.fontSize = originalFontSize
            settings.lineWrapping = originalLineWrapping
        }

        try SettingsJSONStore.saveUserSettingsText("""
        {
          "editor.defaultEditor": "terminalCommand",
          "editor.fontSize": 18,
          "editor.lineWrapping": true
        }
        """)

        #expect(settings.defaultEditor == .terminalCommand)
        #expect(settings.fontSize == 18)
        #expect(settings.lineWrapping)
    }

    @Test
    func systemSettingsIncludeAllBackedSettings() throws {
        let data = Data(SettingsJSONStore.systemSettingsText.utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        for item in SettingsCatalog.jsonEditableItems {
            #expect(object.keys.contains(item.key))
        }
        #expect(object.keys.contains("shortcuts.app"))
        #expect(object.keys.contains("shortcuts.customCommands"))
        #expect(object.keys.contains("ai.providers"))
        #expect(object.keys.contains("aiUsage.providers"))
    }

    @Test
    func syncWritesCurrentSettingsToUserJSON() throws {
        let snapshot = SettingsJSONStoreSnapshot.capture(keys: [testPortKey])
        defer { snapshot.restore() }

        UserDefaults.standard.set(900, forKey: testPortKey)
        SettingsJSONStore.syncUserSettingsFileWithCurrentSettings()

        let data = try Data(contentsOf: SettingsJSONStore.userSettingsURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object[testPortKey] as? Int == 900)
        #expect(object.keys.contains("shortcuts.app"))
    }
}

private struct SettingsJSONStoreSnapshot {
    let data: Data?
    let defaults: [String: Any]

    @MainActor
    static func capture(keys: [String]) -> SettingsJSONStoreSnapshot {
        SettingsJSONStoreSnapshot(
            data: try? Data(contentsOf: SettingsJSONStore.userSettingsURL),
            defaults: Dictionary(uniqueKeysWithValues: keys.map { key in
                (key, UserDefaults.standard.object(forKey: key) ?? NSNull())
            })
        )
    }

    @MainActor
    func restore() {
        if let data {
            try? data.write(to: SettingsJSONStore.userSettingsURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: SettingsJSONStore.userSettingsURL)
        }

        for (key, value) in defaults {
            if value is NSNull {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
    }
}
