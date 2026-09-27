import Foundation
import ApplicationServices

// Observe only the specified acceptance app; no global accessibility traversal.
let pid = pid_t(CommandLine.arguments[1])!
let expected = CommandLine.arguments[2]
let app = AXUIElementCreateApplication(pid)
var observer: AXObserver?
var found = false
func children(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
    return value as? [AXUIElement] ?? []
}
func hasLabel(_ element: AXUIElement) -> Bool {
    var role: CFTypeRef?
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
    if role as? String == kAXStaticTextRole && value as? String == expected { return true }
    return children(element).contains(where: hasLabel)
}
func check() {
    if hasLabel(app) {
        found = true
        CFRunLoopStop(CFRunLoopGetMain())
    }
}
precondition(AXIsProcessTrusted(), "existing accessibility permission required")
precondition(AXObserverCreate(pid, { _, _, _, _ in check() }, &observer) == .success)
let active = observer!
var registrations = 0
func observe(_ element: AXUIElement) {
    for notification in [kAXLayoutChangedNotification, kAXValueChangedNotification,
                         kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
        if AXObserverAddNotification(active, element, notification as CFString, nil) == .success {
            registrations += 1
        }
    }
    children(element).forEach(observe)
}
observe(app)
precondition(registrations > 0, "no accessibility events available")
CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(active), .defaultMode)
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    fputs("native label did not arrive: \(expected)\n", stderr)
    exit(1)
}
check()
if !found { CFRunLoopRun() }
precondition(found)
print("native label observed: \(expected)")
