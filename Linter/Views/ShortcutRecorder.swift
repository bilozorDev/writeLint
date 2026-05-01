import SwiftUI
import AppKit

struct ShortcutRecorderView: View {
    @Binding var hotkey: Hotkey
    let dark: Bool
    @State private var recording = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button { recording.toggle(); error = nil } label: {
                HStack(spacing: 6) {
                    if recording {
                        Circle().fill(Palette.accent).frame(width: 6, height: 6)
                        Text("Press keys…")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                    } else {
                        Text(hotkey.display)
                            .font(.system(size: 14, weight: .medium))
                            .tracking(1)
                            .foregroundStyle(Palette.text(dark))
                    }
                }
                .frame(minWidth: 110)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Palette.surfaceStrong(dark))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(strokeColor, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .background(KeyCaptureView(active: $recording, onCapture: { hk in
                if let err = hk.validationError {
                    error = err
                    // Stay in recording mode so the user can try again.
                    return
                }
                // Try to register globally BEFORE committing the binding —
                // otherwise we'd update the displayed chord and silently leave
                // the user without a working shortcut. On failure HotkeyStore
                // rolls back to the previous chord and we surface an inline
                // error so the user can pick another.
                if HotkeyStore.shared.set(hk) {
                    hotkey = hk
                    error = nil
                    recording = false
                } else {
                    error = "\(hk.display) is in use by another app or system service. Pick another chord."
                }
            }))
            .onChange(of: recording) { _, new in
                HotkeyRecordingState.shared.isRecording = new
                if !new { error = nil }
            }
            .onDisappear {
                HotkeyRecordingState.shared.isRecording = false
            }

            if let error {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.removed)
                    .frame(maxWidth: 240, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var strokeColor: Color {
        if error != nil { return Palette.removed }
        if recording { return Palette.accent }
        return Palette.divider(dark)
    }
}

/// NSViewRepresentable that becomes first responder while `active` is true and
/// turns the next modifier+key event into a `Hotkey`.
struct KeyCaptureView: NSViewRepresentable {
    @Binding var active: Bool
    var onCapture: (Hotkey) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = CaptureNSView()
        v.onCapture = onCapture
        v.isActive = active
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? CaptureNSView else { return }
        v.onCapture = onCapture
        v.isActive = active
        if active {
            DispatchQueue.main.async {
                v.window?.makeFirstResponder(v)
            }
        } else if v.window?.firstResponder === v {
            v.window?.makeFirstResponder(nil)
        }
    }

    final class CaptureNSView: NSView {
        var onCapture: ((Hotkey) -> Void)?
        /// Only capture key events while actively recording. Without this gate
        /// `performKeyEquivalent` would swallow every ⌘-chord in the window
        /// (⌘C/⌘V in a TextField, etc.) — even when the recorder isn't open.
        var isActive: Bool = false

        override var acceptsFirstResponder: Bool { isActive }

        override func keyDown(with event: NSEvent) {
            guard isActive else { super.keyDown(with: event); return }
            if let hk = Hotkey.fromNSEvent(event) {
                onCapture?(hk)
            }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isActive else { return super.performKeyEquivalent(with: event) }
            if let hk = Hotkey.fromNSEvent(event) {
                onCapture?(hk)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
