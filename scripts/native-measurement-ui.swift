import Foundation
import ApplicationServices
import CoreGraphics
import Vision

let pid = pid_t(CommandLine.arguments[1])!
let mode = CommandLine.arguments[2]
let expected = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""
let app = AXUIElementCreateApplication(pid)
func attribute(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(e, key as CFString, &value)
    return value
}
func children(_ e: AXUIElement) -> [AXUIElement] {
    attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
}
func label(_ e: AXUIElement) -> String {
    [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
        .compactMap { attribute(e, $0) as? String }.filter { !$0.isEmpty }.joined(separator: " | ")
}
func find(_ e: AXUIElement) -> AXUIElement? {
    let text = label(e)
    if mode == "click" {
        if attribute(e, kAXRoleAttribute) as? String == kAXButtonRole &&
            (text == expected || text.hasPrefix(expected + ",") || text.hasPrefix(expected + " ")) { return e }
    } else if text.contains(expected) { return e }
    for child in children(e) { if let found = find(child) { return found } }
    return nil
}
precondition(AXIsProcessTrusted(), "existing accessibility permission required")
if mode == "ocr" {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    try VNImageRequestHandler(url: URL(fileURLWithPath: expected)).perform([request])
    print((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
} else if mode == "short-date" {
    print(Date(timeIntervalSince1970: Double(expected)!).formatted(date: .abbreviated, time: .shortened))
} else if mode == "date" {
    print(Date(timeIntervalSince1970: Double(expected)!).formatted(date: .abbreviated, time: .standard))
} else if mode == "dump" {
    func dump(_ e: AXUIElement) {
        if !label(e).isEmpty { print(label(e)) }
        children(e).forEach(dump)
    }
    dump(app)
} else if mode == "window" {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
    for item in windows where item[kCGWindowOwnerPID as String] as? Int == Int(pid) {
        if let b = item[kCGWindowBounds as String] as? [String: Any], (b["Height"] as? Double ?? 0) > 100 {
            print(item[kCGWindowNumber as String]!); exit(0)
        }
    }
    exit(1)
} else if mode == "click" {
    guard var element = find(app) else { fatalError("missing label: \(expected)") }
    while attribute(element, kAXRoleAttribute) as? String != kAXButtonRole {
        guard let parent = attribute(element, kAXParentAttribute) else { fatalError("no button: \(expected)") }
        element = unsafeBitCast(parent, to: AXUIElement.self)
    }
    precondition(AXUIElementPerformAction(element, kAXPressAction as CFString) == .success)
} else if mode == "wait" {
    var observer: AXObserver?
    precondition(AXObserverCreate(pid, { _, _, _, _ in
        if find(app) != nil { CFRunLoopStop(CFRunLoopGetMain()) }
    }, &observer) == .success)
    let active = observer!
    func observe(_ e: AXUIElement) {
        for n in [kAXLayoutChangedNotification, kAXValueChangedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(active, e, n as CFString, nil)
        }
        children(e).forEach(observe)
    }
    observe(app)
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(active), .defaultMode)
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { fputs("missing label: \(expected)\n", stderr); exit(1) }
    if find(app) == nil { CFRunLoopRun() }
    precondition(find(app) != nil)
} else { fatalError("unknown UI operation") }
