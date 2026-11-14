import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Computer use contract: geometry and coordinate codecs")
struct ComputerUseGeometryTests {
    /// A 1512×982 pt window on a 2x display captured into a 1024×665 image.
    private let geometry = ScreenshotGeometry(
        capturedRect: DisplayRect(x: 100, y: 50, width: 1512, height: 982),
        imageSize: ImagePixelSize(width: 1024, height: 665),
        scaleFactor: 2
    )

    @Test("Image pixels map back to logical points through the recorded geometry")
    func imageToGlobal() {
        let origin = geometry.toGlobal(DisplayPoint(x: 0, y: 0))
        #expect(origin == DisplayPoint(x: 100, y: 50))
        let far = geometry.toGlobal(DisplayPoint(x: 1024, y: 665))
        #expect(abs(far.x - 1612) < 0.0001)
        #expect(abs(far.y - 1032) < 0.0001)
    }

    @Test("Global points round-trip through image space")
    func roundTrip() {
        let point = DisplayPoint(x: 733.5, y: 412.25)
        let back = geometry.toGlobal(geometry.toImage(point))
        #expect(abs(back.x - point.x) < 0.0001)
        #expect(abs(back.y - point.y) < 0.0001)
    }

    @Test("Negative display origins on secondary displays are preserved")
    func negativeOrigin() {
        let left = ScreenshotGeometry(
            capturedRect: DisplayRect(x: -1920, y: -200, width: 1920, height: 1080),
            imageSize: ImagePixelSize(width: 960, height: 540),
            scaleFactor: 1
        )
        #expect(left.toGlobal(DisplayPoint(x: 480, y: 270)) == DisplayPoint(x: -960, y: 340))
    }

    @Test("The pixel codec decodes image coordinates and rejects points outside the image")
    func pixelCodec() throws {
        let codec = ComputerUseCoordinateCodec(mode: .imagePixels)
        let point = try codec.decode(x: 512, y: 0, geometry: geometry)
        #expect(abs(point.x - 856) < 0.0001)
        #expect(point.y == 50)
        #expect(throws: ComputerUseCoordinateError.self) { try codec.decode(x: 1025, y: 10, geometry: geometry) }
        #expect(throws: ComputerUseCoordinateError.self) { try codec.decode(x: -1, y: 10, geometry: geometry) }
        #expect(throws: ComputerUseCoordinateError.self) { try codec.decode(x: .nan, y: 10, geometry: geometry) }
    }

    @Test("The normalized codec maps the 0–999 grid independently of image size")
    func normalizedCodec() throws {
        let codec = ComputerUseCoordinateCodec(mode: .normalized1000)
        let center = try codec.decode(x: 500, y: 500, geometry: geometry)
        #expect(abs(center.x - (100 + 756)) < 0.0001)
        #expect(abs(center.y - (50 + 491)) < 0.0001)
        #expect(throws: ComputerUseCoordinateError.self) { try codec.decode(x: 1000, y: 0, geometry: geometry) }
    }

    @Test("Rect decoding maps both corners through the codec")
    func rectDecoding() throws {
        let codec = ComputerUseCoordinateCodec(mode: .imagePixels)
        let rect = try codec.decodeRect(x: 0, y: 0, width: 512, height: 665, geometry: geometry)
        #expect(rect.minX == 100)
        #expect(abs(rect.width - 756) < 0.0001)
        #expect(abs(rect.height - 982) < 0.0001)
    }

    @Test("Rect containment is half-open on the far edges")
    func rectContains() {
        let rect = DisplayRect(x: 0, y: 0, width: 10, height: 10)
        #expect(rect.contains(DisplayPoint(x: 0, y: 0)))
        #expect(rect.contains(DisplayPoint(x: 9.9, y: 9.9)))
        #expect(!rect.contains(DisplayPoint(x: 10, y: 5)))
    }
}

@Suite("Computer use contract: key combos")
struct ComputerUseKeyComboTests {
    @Test("Modifier aliases and ordering normalize to one canonical form")
    func normalization() throws {
        let a = try KeyCombo(parsing: "Command+Shift+A")
        let b = try KeyCombo(parsing: "shift+cmd+a")
        let c = try KeyCombo(parsing: "meta + SHIFT + a")
        #expect(a == b)
        #expect(b == c)
        #expect(a.description == "shift+cmd+a")
    }

    @Test("Key aliases normalize")
    func keyAliases() throws {
        #expect(try KeyCombo(parsing: "esc") == KeyCombo(parsing: "Escape"))
        #expect(try KeyCombo(parsing: "enter") == KeyCombo(parsing: "return"))
        #expect(try KeyCombo(parsing: "opt+ctrl+del").description == "ctrl+option+delete")
    }

    @Test("Malformed combos are rejected")
    func malformed() {
        #expect(throws: KeyComboParseError.self) { try KeyCombo(parsing: "") }
        #expect(throws: KeyComboParseError.self) { try KeyCombo(parsing: "cmd+shift") }
        #expect(throws: KeyComboParseError.self) { try KeyCombo(parsing: "a+b") }
    }

    @Test("Combos encode as their canonical string")
    func codable() throws {
        let combo = try KeyCombo(parsing: "cmd+option+esc")
        let data = try JSONEncoder().encode(combo)
        #expect(String(decoding: data, as: UTF8.self) == "\"option+cmd+escape\"")
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == combo)
    }
}

@Suite("Computer use contract: manifests, observations, actions")
struct ComputerUseValueTypeTests {
    @Test("A display-target manifest decodes from the template's JSON shape")
    func manifestDecodes() throws {
        let json = """
        {
          "id": "macos-host",
          "label": "This Mac (host desktop)",
          "kind": "display-target",
          "platform": "macos",
          "isolation": "host",
          "perception": ["pixels", "accessibility", "ocr"],
          "delivery": ["background", "foreground"],
          "semanticActions": ["press", "set-value", "focus", "menu-path", "launch-app", "open-url", "run-shortcut"],
          "multiDisplay": true,
          "observerAccess": "none",
          "requires": ["screen-capture", "accessibility", "post-events"],
          "humanPresence": "shared"
        }
        """
        let manifest = try JSONDecoder().decode(DisplayTargetManifest.self, from: Data(json.utf8))
        #expect(manifest.id == "macos-host")
        #expect(manifest.isolation == .host)
        #expect(manifest.perception == [.pixels, .accessibility, .ocr])
        #expect(manifest.semanticActions.contains(.menuPath))
        #expect(manifest.requires == [.screenCapture, .accessibility, .postEvents])
        #expect(manifest.humanPresence == .shared)
    }

    @Test("A manifest with a different kind is rejected")
    func manifestRejectsKind() {
        let json = """
        {"id":"x","label":"x","kind":"sandbox","platform":"linux","isolation":"vm","perception":["pixels"],
         "delivery":["background"],"semanticActions":[],"multiDisplay":false,"observerAccess":"vnc",
         "requires":[],"humanPresence":"none"}
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DisplayTargetManifest.self, from: Data(json.utf8))
        }
    }

    @Test("Observations are always untrusted, including after decoding")
    func observationUntrusted() throws {
        let observation = ComputerUseFixtures.observation(id: "o_1")
        #expect(observation.untrusted)
        let decoded = try JSONDecoder().decode(DisplayObservation.self, from: JSONEncoder().encode(observation))
        #expect(decoded.untrusted)
        #expect(decoded == observation)
    }

    @Test("Canonical actions round-trip through Codable")
    func actionsRoundTrip() throws {
        let actions: [ComputerAction] = [
            .click(at: .ref("e6", observation: "o_1"), button: .right, count: 2, modifiers: [.cmd]),
            .drag(path: [.point(DisplayPoint(x: 1, y: 2), observation: "o_1"), .ref("e2", observation: "o_1")], modifiers: []),
            .type(text: "héllo 👋", into: .ref("e5", observation: "o_1"), mode: .paste),
            .key(combo: try KeyCombo(parsing: "cmd+s"), repeatCount: 1),
            .scroll(at: nil, dx: 0, dy: -3, unit: .line),
            .menu(path: ["File", "Save"], app: "com.apple.TextEdit"),
            .openURL("https://example.com"),
            .observe(ObserveRequest(modes: [.pixels, .accessibility], scope: .display(nil))),
            .zoom(region: DisplayRect(x: 0, y: 0, width: 100, height: 50), observation: "o_1"),
        ]
        let data = try JSONEncoder().encode(actions)
        #expect(try JSONDecoder().decode([ComputerAction].self, from: data) == actions)
    }

    @Test("Pointer actions expose the observations they cite")
    func citedObservations() {
        let drag = ComputerAction.drag(
            path: [.point(DisplayPoint(x: 1, y: 2), observation: "o_1"), .ref("e2", observation: "o_2")],
            modifiers: []
        )
        #expect(drag.citedTargets.map(\.observation) == ["o_1", "o_2"])
        #expect(ComputerAction.wait(milliseconds: 10).citedTargets.isEmpty)
        #expect(ComputerAction.zoom(region: DisplayRect(x: 0, y: 0, width: 1, height: 1), observation: "o_3").citedObservations == ["o_3"])
    }
}
