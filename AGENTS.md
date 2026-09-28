# MoniVol 项目说明

## 代码结构

- `apps/mac/MoniVolApp/`：Swift 菜单栏应用、界面、驱动安装与手动更新检查。
- `packages/host/`：Swift 音频 Host，负责设备发现、代理切换、共享内存和向真实显示器播放音频。
- `packages/driver/`：基于 `vendor/libASPL` 子模块的 CoreAudio HAL 虚拟驱动。
- `packages/dsp/`：独立的 C++ DSP 库及测试；当前音量中转链路不使用旧 EQ 功能。
- `tools/`：构建、打包、签名和驱动管理脚本。面向用户的安装与构建说明见 `README.md`。

## 开发与验证

- 本项目的 build 由用户自行执行。Agent 修改代码后提供准确的构建命令；除非用户当次明确要求，否则不要运行 `make build`、`make quick` 或其他构建命令。
- 首次构建前运行 `git submodule update --init --recursive`。项目使用 macOS 13+、Swift 5.9+、CMake 3.20+；源码构建使用 Xcode Command Line Tools。
- `./tools/build_release.sh` 构建 arm64 与 x86_64 的驱动、Host 和 App，并生成 `dist/MoniVol.app`。`make quick` 只重新构建 Swift 组件并复用已有驱动；修改驱动后不要用它验证结果。
- `make test` 运行 `packages/dsp` 的测试，不能代替音频设备插拔、默认输出切换和实际播放验证。
- `make build` 会先运行 `tools/update_versions.sh`，按最新 Git tag 更新 App、Host 和驱动版本文件。构建前后检查版本文件差异；没有 tag 时脚本使用 `1.0.0`。
- `make reset`、`packages/driver/install.sh` 和驱动卸载脚本会改动本机音频环境；不要把它们当作普通静态检查命令。

## 音频链路约束

- 仅为通过校验、没有可写音量控制的 HDMI／DisplayPort 输出创建设备代理；内建扬声器、蓝牙和普通 USB 音频设备保持原生输出。设备筛选入口是 `DeviceDiscovery.swift` 的 `needsDisplayProxy`。
- 用物理设备 UID 保存显示器选择与音量状态；`AudioDeviceID` 只在当前设备枚举中有效。断开时移除代理并切回内建输出，重连同一 UID 后等待代理出现再恢复输出。
- Host 启动和新增设备时，先建立共享内存，再发布驱动控制文件。保持控制文件原子写入，避免无变化的设备通知重复发布；延迟清理共享内存前复查设备是否已重新连接。
- 修改共享内存协议时同步检查三份 `RFSharedAudio.h`：`packages/driver/include/`、`packages/host/Sources/CMoniVolAudio/include/`、`apps/mac/MoniVolApp/Sources/CMoniVolAudio/include/`。
- 驱动代码更新后，旧的已安装 HAL 驱动不会随 App 源码变化自动替换；运行时验证需确认安装的驱动版本，并在替换后重启 `coreaudiod`。
- 控制中心漏列设备时，先核对 CoreAudio 和系统设置中的实际设备状态。重启 `ControlCenter` 可以刷新界面，但不能据此认定根因已经修复。

## 图标资源

- App 图标由 `apps/mac/MoniVolApp/Sources/Resources/MyIcon.icns` 打包，根目录 `app.png` 用于 README；替换时同步两者，并检查透明边距与实际可见大小。菜单栏图标是 `Resources/icons/monivol-menu.svg`，修改后检查约 16 px 的显示效果。
