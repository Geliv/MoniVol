import SwiftUI
import AppKit

/// Window for prompting driver updates
class DriverUpdateWindow: NSWindow {
	init(currentVersion: String, newVersion: String, onUpdate: @escaping () -> Void, onDismiss: @escaping () -> Void) {
		let language = AppLanguage.selected
		super.init(
			contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false
		)

		self.title = language.text("Driver Update Available", "有可用的驱动更新")
		self.isReleasedWhenClosed = false
		self.contentView = NSHostingView(
			rootView: DriverUpdateView(
				currentVersion: currentVersion,
				newVersion: newVersion,
				onUpdate: onUpdate,
				onDismiss: onDismiss
			)
		)
	}
}

struct DriverUpdateView: View {
	let currentVersion: String
	let newVersion: String
	let onUpdate: () -> Void
	let onDismiss: () -> Void
	private let language = AppLanguage.selected

	var body: some View {
		VStack(spacing: 16) {
			// Version comparison
			HStack(spacing: 12) {
				VStack(alignment: .leading, spacing: 2) {
					Text(language.text("Current", "当前版本"))
						.font(.caption)
						.foregroundColor(.secondary)
					Text(currentVersion)
						.font(.system(.body, design: .monospaced))
						.fontWeight(.semibold)
				}

				Image(systemName: "arrow.right")
					.font(.caption)
					.foregroundColor(.secondary)

				VStack(alignment: .leading, spacing: 2) {
					Text(language.text("New", "新版本"))
						.font(.caption)
						.foregroundColor(.secondary)
					Text(newVersion)
						.font(.system(.body, design: .monospaced))
						.fontWeight(.semibold)
						.foregroundColor(.accentColor)
				}
			}
			.padding(12)
			.frame(maxWidth: .infinity)
			.background(Color.secondary.opacity(0.1))
			.cornerRadius(8)

			// Info message
			Text(language.text("Requires administrator privileges", "需要管理员权限"))
				.font(.caption)
				.foregroundColor(.secondary)

			// Buttons
			HStack(spacing: 12) {
				Button(language.text("Later", "稍后")) {
					onDismiss()
				}
				.keyboardShortcut(.cancelAction)

				Button(language.text("Update Now", "立即更新")) {
					onUpdate()
				}
				.keyboardShortcut(.defaultAction)
				.buttonStyle(.borderedProminent)
			}
		}
		.padding(20)
		.frame(width: 400, height: 180)
	}
}
