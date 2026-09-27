# MoniVol

MoniVol 是一款 macOS 菜单栏应用，让通过 HDMI 或 DisplayPort 连接、原本无法在 macOS 中调节音量的外接显示器支持软件音量控制。

<p align="center"><img src="app.png" alt="MoniVol 图标" width="160"></p>

## 功能

- 为不支持硬件音量调节的 HDMI/DisplayPort 显示器创建虚拟输出设备，并将音频转发到实际显示器。
- 支持系统音量键、菜单栏音量滑块和静音控制。
- 内建扬声器、蓝牙耳机和 USB 音频设备直接使用 macOS 原生输出，不经过虚拟设备。
- 断开显示器时移除对应的虚拟设备并切回内建输出；重新连接后自动恢复该显示器的虚拟输出。
- 从菜单栏手动检查更新。

支持 macOS 13 或更新版本，Apple Silicon 和 Intel Mac。

## 安装

目前请先按下文从源码构建。构建完成后，将应用复制到“应用程序”目录并打开：

```bash
sudo ditto dist/MoniVol.app /Applications/MoniVol.app
open /Applications/MoniVol.app
```

首次启动时按引导安装音频驱动，需要输入管理员密码。安装后，在系统声音输出列表中选择显示器对应的 `（MoniVol）` 设备，即可使用系统音量键调节音量。

## 从源码构建

需要 macOS 13 或更新版本、Xcode Command Line Tools、Swift 5.9 或更新版本、CMake 3.20 或更新版本，以及 Git。先安装命令行工具和 CMake：

```bash
xcode-select --install
brew install cmake
```

克隆仓库时一并获取 HAL 驱动依赖的 libASPL 子模块，然后运行构建脚本：

```bash
git clone --recurse-submodules https://github.com/Geliv/MoniVol.git
cd MoniVol
./tools/build_release.sh
```

构建产物位于 `dist/MoniVol.app`，包含菜单栏应用、音频 Host 和 HAL 虚拟驱动。构建脚本会生成 Apple Silicon 与 Intel 双架构程序。本地构建无需签名；若要对外分发，还需自行完成代码签名与公证。

## 致谢

本项目参考了 [SoundBridge](https://github.com/chenjy16/SoundBridge)。
