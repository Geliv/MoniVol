import SwiftUI
import AppKit

/// Settings window for MoniVol preferences
class SettingsWindow: NSWindow {
	init() {
		let language = AppLanguage.selected
		super.init(
			contentRect: NSRect(x: 0, y: 0, width: 500, height: 450),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false
		)

		self.title = language.text("MoniVol Settings", "MoniVol 设置")
		self.isReleasedWhenClosed = false
		self.contentView = NSHostingView(
			rootView: SettingsView()
		)
	}
}

struct SettingsView: View {
	private let language = AppLanguage.selected

	var body: some View {
		VStack(spacing: 0) {
			// Header
			VStack(spacing: 12) {
				AppIconView(size: 64)

				Text("MoniVol")
					.font(.title)
					.fontWeight(.semibold)

				if let version = VersionManager.appVersion() {
					Text("\(language.text("Version", "版本")) \(version)")
						.font(.subheadline)
						.foregroundColor(.secondary)
				}
			}
			.padding(.top, 30)
			.padding(.bottom, 20)

			Divider()

			// Content
			ScrollView {
				VStack(spacing: 24) {
					// Update Settings Section
					VStack(alignment: .leading, spacing: 16) {
						Text(language.text("Updates", "更新"))
							.font(.headline)
							.foregroundColor(.primary)

						VStack(alignment: .leading, spacing: 12) {
							Button(action: UpdateChecker.checkForUpdates) {
								HStack {
									Image(systemName: "arrow.triangle.2.circlepath")
									Text(language.text("Check for Updates", "检查更新"))
								}
								.frame(maxWidth: .infinity)
							}
							.controlSize(.large)
						}
					}
					.padding(16)
					.background(Color.secondary.opacity(0.05))
					.cornerRadius(12)

					// System Info Section
					VStack(alignment: .leading, spacing: 16) {
						Text(language.text("System Info", "系统信息"))
							.font(.headline)
							.foregroundColor(.primary)

						VStack(alignment: .leading, spacing: 10) {
							if let appVersion = VersionManager.appVersion() {
								InfoRow(label: language.text("App Version", "应用版本"), value: appVersion)
							}

							if VersionManager.isDriverInstalled() {
								if let driverVersion = VersionManager.installedDriverVersion() {
									InfoRow(label: language.text("Driver Version", "驱动版本"), value: driverVersion)
								}
							} else {
								InfoRow(
									label: language.text("Driver Status", "驱动状态"),
									value: language.text("Not Installed", "未安装")
								)
									.foregroundColor(.orange)
							}

							if let installDate = OnboardingState.driverInstallDate() {
								InfoRow(
									label: language.text("Driver Installed", "驱动安装时间"),
									value: formatDate(installDate)
								)
							}
						}
					}
					.padding(16)
					.background(Color.secondary.opacity(0.05))
					.cornerRadius(12)

					// About Section
					VStack(alignment: .leading, spacing: 16) {
						Text(language.text("About", "关于"))
							.font(.headline)
							.foregroundColor(.primary)

						VStack(alignment: .leading, spacing: 8) {
							Text(language.text(
								"MoniVol controls the volume of external display audio on macOS.",
								"MoniVol 用于控制 macOS 外接显示器的音频音量。"
							))
								.font(.caption)
								.foregroundColor(.secondary)

							Link(destination: URL(string: "https://monivol.app")!) {
								Text(language.text("Visit Website", "访问网站"))
									.font(.caption)
							}
						}
					}
					.padding(16)
					.background(Color.secondary.opacity(0.05))
					.cornerRadius(12)
				}
				.padding(20)
			}
		}
		.frame(width: 500, height: 450)
	}

	private func formatDate(_ date: Date) -> String {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: language.rawValue)
		formatter.dateStyle = .medium
		formatter.timeStyle = .none
		return formatter.string(from: date)
	}
}

/// 从应用资源目录加载应用图标。
struct AppIconView: View {
	let size: CGFloat

	var body: some View {
		Group {
			if let image = loadAppIcon() {
				Image(nsImage: image)
					.resizable()
					.aspectRatio(contentMode: .fit)
					.frame(width: size, height: size)
					.clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
			} else {
				Image(systemName: "waveform.circle.fill")
					.font(.system(size: size * 0.8))
					.foregroundColor(.accentColor)
			}
		}
	}

	private func loadAppIcon() -> NSImage? {
		// Try resource bundle first
		if let resourceBundleURL = Bundle.main.url(forResource: "MoniVolApp_MoniVolApp", withExtension: "bundle"),
		   let resourceBundle = Bundle(url: resourceBundleURL),
		   let path = resourceBundle.url(forResource: "MyIcon", withExtension: "icns") {
			return NSImage(contentsOf: path)
		}
		// Try main bundle Resources
		if let path = Bundle.main.url(forResource: "MyIcon", withExtension: "icns") {
			return NSImage(contentsOf: path)
		}
		// Try resourcePath directly
		if let resourcePath = Bundle.main.resourcePath {
			for subpath in ["Resources/MyIcon.icns", "MyIcon.icns"] {
				let fullPath = (resourcePath as NSString).appendingPathComponent(subpath)
				if FileManager.default.fileExists(atPath: fullPath) {
					return NSImage(contentsOfFile: fullPath)
				}
			}
		}
		return nil
	}
}

struct InfoRow: View {
	let label: String
	let value: String

	var body: some View {
		HStack {
			Text(label)
				.font(.caption)
				.foregroundColor(.secondary)
			Spacer()
			Text(value)
				.font(.caption)
				.fontWeight(.medium)
		}
	}
}
