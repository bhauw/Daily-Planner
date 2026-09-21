import AppKit
import DailyPlannerDomain
import SwiftUI

struct PlannerAccessibilityMarker: NSViewRepresentable {
    let identifier: String
    let label: String
    let value: String

    func makeNSView(context: Context) -> NSView {
        PlannerAccessibilityMarkerView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityValue(value)
    }
}

private final class PlannerAccessibilityMarkerView: NSView {
    override var intrinsicContentSize: NSSize { .zero }
}

struct PlannerActionButton: NSViewRepresentable {
    let title: String
    let identifier: String
    let accessibilityValue: String
    var systemImage: String? = nil
    var isEnabled = true
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = PlannerKeyboardNavigableButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.performAction)
        )
        button.bezelStyle = .rounded
        if let systemImage {
            button.image = NSImage(
                systemSymbolName: systemImage,
                accessibilityDescription: nil
            )
            button.imagePosition = .imageLeading
        }
        button.setAccessibilityRole(.button)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        button.isEnabled = isEnabled
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.isEnabled = isEnabled
        button.image = systemImage.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        button.imagePosition = systemImage == nil ? .noImage : .imageLeading
        button.setAccessibilityValue(accessibilityValue)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            action()
        }
    }
}

struct GoogleClientIdentifierSecureField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = PlannerKeyboardNavigableSecureTextField()
        field.placeholderString = "OAuth client identifier"
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.delegate = context.coordinator
        field.setAccessibilityRole(.textField)
        field.setAccessibilityIdentifier("google-client-identifier-field")
        field.setAccessibilityLabel("Google OAuth client identifier")
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
        field.setAccessibilityValue("Secure input")
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSecureTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                movePlannerKeyboardFocus(from: control, reverse: false)
            case #selector(NSResponder.insertBacktab(_:)):
                movePlannerKeyboardFocus(from: control, reverse: true)
            default:
                false
            }
        }
    }
}

struct GoogleClientSecretSecureField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> GoogleClientIdentifierSecureField.Coordinator {
        GoogleClientIdentifierSecureField.Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = PlannerKeyboardNavigableSecureTextField()
        field.placeholderString = "OAuth client secret"
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.delegate = context.coordinator
        field.setAccessibilityRole(.textField)
        field.setAccessibilityIdentifier("google-client-secret-field")
        field.setAccessibilityLabel("Google OAuth client secret")
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
        field.setAccessibilityValue("Secure input")
    }
}

private final class PlannerKeyboardNavigableButton: NSButton {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48,
           movePlannerKeyboardFocus(from: self, reverse: event.modifierFlags.contains(.shift)) {
            return
        }
        super.keyDown(with: event)
    }
}

private final class PlannerKeyboardNavigableSecureTextField: NSSecureTextField {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48,
           movePlannerKeyboardFocus(from: self, reverse: event.modifierFlags.contains(.shift)) {
            return
        }
        super.keyDown(with: event)
    }
}

struct VaultSelectionButton: NSViewRepresentable {
    let accessibilityValue: String
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = InitialKeyboardFocusButton(
            title: "Choose vault folder…",
            target: context.coordinator,
            action: #selector(Coordinator.performAction)
        )
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.setAccessibilityRole(.button)
        button.setAccessibilityIdentifier("choose-vault-root-button")
        button.setAccessibilityLabel("Choose vault root")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.setAccessibilityValue(accessibilityValue)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            action()
        }
    }
}

private final class InitialKeyboardFocusButton: NSButton {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.initialFirstResponder = self
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, movePlannerKeyboardFocus(from: self, reverse: event.modifierFlags.contains(.shift)) {
            return
        }
        super.keyDown(with: event)
    }
}

struct CalendarRolePopUpButton: NSViewRepresentable {
    let displayName: String
    let role: CalendarRole
    let action: @MainActor (CalendarRole) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popUp = KeyboardNavigablePopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: ["Planning", "Excluded reference"])
        popUp.target = context.coordinator
        popUp.action = #selector(Coordinator.selectionChanged(_:))
        popUp.setAccessibilityRole(.popUpButton)
        popUp.setAccessibilityIdentifier("calendar-role-picker")
        return popUp
    }

    func updateNSView(_ popUp: NSPopUpButton, context: Context) {
        context.coordinator.action = action
        popUp.selectItem(at: role == .planning ? 0 : 1)
        popUp.setAccessibilityLabel("Calendar role for \(displayName)")
        popUp.setAccessibilityValue(role.accessibilityLabel)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: @MainActor (CalendarRole) -> Void

        init(action: @escaping @MainActor (CalendarRole) -> Void) {
            self.action = action
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            action(sender.indexOfSelectedItem == 0 ? .planning : .excludedReference)
        }
    }
}

private final class KeyboardNavigablePopUpButton: NSPopUpButton {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, movePlannerKeyboardFocus(from: self, reverse: event.modifierFlags.contains(.shift)) {
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private func movePlannerKeyboardFocus(from current: NSView, reverse: Bool) -> Bool {
    guard let window = current.window, let contentView = window.contentView else { return false }

    let identifiers = Set([
        "refresh-planning-preview-button", "planner-settings-button",
        "choose-vault-root-button", "refresh-calendar-roles-button", "calendar-role-picker",
        "load-google-connection-state-button", "google-client-identifier-field",
        "google-client-secret-field",
        "save-google-client-button", "connect-google-button", "cancel-google-button",
        "confirm-google-identity-button", "disconnect-google-button",
    ])
    var controls: [NSControl] = []

    func collect(from view: NSView) {
        if let control = view as? NSControl,
           identifiers.contains(control.accessibilityIdentifier()),
           control.isEnabled {
            controls.append(control)
        }
        view.subviews.forEach(collect)
    }

    collect(from: contentView)
    controls.sort { lhs, rhs in
        let lhsFrame = lhs.convert(lhs.bounds, to: nil)
        let rhsFrame = rhs.convert(rhs.bounds, to: nil)
        if abs(lhsFrame.midY - rhsFrame.midY) > 1 {
            return lhsFrame.midY > rhsFrame.midY
        }
        return lhsFrame.minX < rhsFrame.minX
    }

    guard controls.count > 1,
          let currentIndex = controls.firstIndex(where: { $0 === current }) else { return false }
    let offset = reverse ? controls.count - 1 : 1
    let next = controls[(currentIndex + offset) % controls.count]
    return window.makeFirstResponder(next)
}

extension CalendarRole {
    var accessibilityLabel: String {
        switch self {
        case .planning: "Planning"
        case .excludedReference: "Excluded reference"
        }
    }
}
