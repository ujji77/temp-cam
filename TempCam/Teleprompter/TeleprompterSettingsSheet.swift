import SwiftUI
import UIKit

struct TeleprompterSettingsSheet: View {
    @Bindable var model: TeleprompterManager
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool
    @State private var detent: PresentationDetent = .medium
    @State private var clipboardMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    editor
                    clipboardMessageText
                    actionRow
                    sliderBlock(
                        title: "Speed",
                        value: model.speedLabel,
                        systemImage: "gauge.with.needle"
                    ) {
                        Slider(value: $model.speed, in: TeleprompterManager.minimumSpeed...TeleprompterManager.maximumSpeed)
                    }
                    sliderBlock(
                        title: "Text Size",
                        value: "\(Int(model.fontSize.rounded()))",
                        systemImage: "textformat.size"
                    ) {
                        Slider(value: $model.fontSize, in: 20...48)
                    }
                    sliderBlock(
                        title: "Background",
                        value: "\(Int((model.backgroundOpacity * 100).rounded()))%",
                        systemImage: "circle.lefthalf.filled"
                    ) {
                        Slider(value: $model.backgroundOpacity, in: 0.15...0.72)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                commitControls
            }
            .navigationTitle("Teleprompter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .fontWeight(.medium)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(28)
        .preferredColorScheme(.dark)
        .tint(.white)
        .onChange(of: editorFocused) { _, focused in
            if focused {
                detent = .large
            }
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if !model.hasScript {
                Text("Paste or type a script")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.top, 10)
                    .padding(.leading, 6)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $model.script)
                .focused($editorFocused)
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 148)
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var clipboardMessageText: some View {
        if let clipboardMessage {
            Text(clipboardMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            sheetButton(title: "Paste", systemImage: "doc.on.clipboard") {
                if model.pasteFromClipboard() {
                    clipboardMessage = nil
                    Haptics.tap()
                } else {
                    clipboardMessage = "Nothing on the clipboard"
                }
            }
            sheetButton(title: "Clear", systemImage: "xmark") {
                model.script = ""
                clipboardMessage = nil
            }
            .disabled(!model.hasScript)
        }
    }

    private var commitControls: some View {
        VStack(spacing: 8) {
            Button(action: commit) {
                Text(model.isActive ? "Done" : "Start")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white, in: Capsule())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .disabled(!model.hasScript && !model.isActive)

            if model.hasScript || model.isActive {
                Button("Discard Script") {
                    model.discard()
                    dismiss()
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func commit() {
        if model.isActive {
            if !model.hasScript {
                model.discard()
            }
        } else {
            model.start()
            Haptics.tap()
        }
        dismiss()
    }

    private func sheetButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.1), in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func sliderBlock<Control: View>(
        title: String,
        value: String,
        systemImage: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text(value)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            control()
                .tint(.white)
        }
    }
}
