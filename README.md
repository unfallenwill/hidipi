# HiDPI CLI

免费的本机 macOS 命令行工具，Python 标准库实现，使用 `ctypes` 调用系统显示接口。
不依赖 BetterDisplay，不修改 EDID 或系统配置文件，不需要 sudo、关闭 SIP 或付费软件。

## 安装与目录

在项目目录安装为独立工具（普通安装，不使用 `--editable`）：

```sh
uv tool install .
```

安装后在任意目录都可以运行 `hidpi`。uv 会把程序复制到独立工具环境，运行时不需要源码目录。
如果提示找不到 `hidpi`，确保 uv 输出的工具 bin 目录（通常 `~/.local/bin`）在 PATH 中。
开发时仍可在仓库运行 `uv run hidpi ...`，两种方式默认共用同一份用户数据：

```text
~/.config/hidpi-cli/
├── autostart.json       # 自启动记录：屏幕 UUID、尺寸、刷新率、安装前备份路径
├── backups/            # 历次显示设置备份
└── logs/               # 自启动日志和错误日志
```

`hidpi paths` 显示实际目录。数据路径不依赖调用时的工作目录，也不在工具虚拟环境内，
重新安装工具不会主动删除这些数据。`autostart.json` 是安装状态记录；修改自启动参数请卸载后重新安装，
单独编辑该 JSON 不会更改已经加载的 LaunchAgent。

## 使用

在已登录 macOS 桌面的终端运行：

```sh
hidpi list
hidpi backup
hidpi enable --size 1920x1080
```

`enable` 每次先写入并回读核验备份，再切换系统已有的 HiDPI 模式。
默认预览 20 秒后恢复。在交互终端里输入 `y` 并回车可继续使用，按 `Ctrl+C` 恢复。
**保持 HiDPI 时需要保留进程；关闭终端、正常终止进程会触发恢复。**

```sh
# 跳过预览倒计时，直到 Ctrl+C 才恢复
hidpi enable --size 1920x1080 --keep

# 仅当系统存在对应的 60 Hz HiDPI 模式时才切换
hidpi enable --size 1920x1080 --refresh 60

# 多显示器时，使用 list 返回的 ID
hidpi enable --display 3 --size 1920x1080

# 非交互测试：5 秒后自动恢复
hidpi enable --size 1920x1080 --seconds 5

# 查看包括普通 DPI 在内的模式
hidpi list --all

# 用控制台输出的真实备份路径替换下方示例
hidpi restore ~/.config/hidpi-cli/backups/display-YYYYMMDD-HHMMSS-xxxxxxxx.json
```

可以省略 `--size`，默认寻找当前界面逻辑尺寸对应的 HiDPI 模式。
未指定 `--refresh` 时优先保持原刷新率，否则选择该尺寸可用的最高刷新率并明确提示。

## 无实体屏幕 / 远程桌面

Apple Silicon Mac 可以创建独立的 HiDPI 虚拟屏幕，无需 HDMI 显示器或 HDMI 欺骗器：

```sh
# 前台预览 20 秒，之后自动移除；输入 y 可保留
hidpi virtual --size 1920x1080

# 持续运行，Ctrl+C 移除虚拟屏幕并恢复仍连接的原屏幕
hidpi virtual --size 1920x1080 --keep

# 使用虚拟屏幕作为登录自启动模式
# 如果已经安装了物理模式的自启动，先卸载它
hidpi autostart uninstall
hidpi autostart install --virtual --size 1920x1080
hidpi autostart status
```

逻辑尺寸 `1920x1080` 对应 `3840x2160` 渲染，默认请求 60 Hz。
屏幕名称为 **HiDPI Virtual Display**。远程客户端若支持选择显示器，请选择该屏幕；
本工具提供显示画布，不包含远程连接服务，也不会自动开启屏幕共享或修改登录设置。
如果实体屏幕仍连接，虚拟屏幕是额外的桌面，不自动镜像到 HDMI。

虚拟屏幕也会先备份。没有实体屏幕时，保存明确的无屏幕备份；macOS 临时生成的占位桌面
只记入元数据，不把它易变化的 ID 和模式当作硬件恢复。退出时释放虚拟屏幕；原实体屏幕
若已拔出，保留其备份，待接回后可手动 `restore`。

通过 `hidpi autostart uninstall` 可停止后台虚拟屏幕、取消自启动，并恢复仍连接的原屏幕。
**停止唯一虚拟屏幕时，远程会话可能短暂重排、改变分辨率或断开。**

虚拟功能使用 macOS 私有 `CGVirtualDisplay` 接口，目前支持原生 ARM64 Python。
系统更新可能改变接口，因此实际创建后会核验逻辑尺寸及 2× 渲染尺寸，不只检查 API 返回成功。
某些无屏幕会话不提供 CoreGraphics 模式列表，此时使用 NSScreen 的 backingScaleFactor 核验 HiDPI；
实际刷新率无法读出时明确显示“刷新率未报告”，请求的 Hz 不代表远程视频传输帧率。
创建者进程必须保持运行；登录自启动仍发生在进入桌面后，不能绕过 FileVault 解锁或登录。

## 登录自启动

安装为工具后，在任意目录运行一次：

```sh
hidpi autostart install --size 1920x1080
hidpi autostart status
```

安装会保存安装前的显示设置，创建 `~/Library/LaunchAgents/local.hidpi-cli.agent.plist`，
并立即在后台启用 HiDPI。之后每次**登录桌面**自动启动，无需保留终端。
它不在 FileVault 解锁界面或用户登录前运行。

物理模式配置绑定显示器 UUID 和安装时核验的尺寸、刷新率；登录时最多等候 60 秒。
虚拟模式保存创建参数，不依赖实体显示器 UUID。
多屏时安装命令可增加 `--display ID`，安装后不依赖可能变化的数字 ID。
不需要 sudo。登录启动直接使用执行安装命令时的 Python 环境，以 `~/.config/hidpi-cli` 为工作目录，
不会运行 uv 或联网安装依赖。通过 `hidpi autostart install` 配置时，使用 uv tool 的独立环境，
可以移动源码仓库；如果使用 `uv run hidpi autostart install`，则仍依赖项目 `.venv`。
升级/卸载工具前，请先 `hidpi autostart uninstall`；重新安装工具后，再安装自启动。

```sh
# 只查看将生成的配置，不写入启动项
hidpi autostart install --size 1920x1080 --dry-run

# 停止后台进程、取消以后的自启动、恢复安装前设置，保留所有备份
hidpi autostart uninstall
```

卸载后可以继续用 `restore` 恢复任意历史备份。手动运行 `enable` 或 `restore` 前，
先卸载后台服务，避免两个进程同时修改显示器。
正常运行日志位于 `~/.config/hidpi-cli/logs/autostart.log`，错误位于同目录的 `autostart-error.log`。
`status` 会显示服务状态和最近日志；“已加载”不等于显示模式切换成功，请查看日志中的核验结果。

这个版本仅自动处理登录启动，不在进程退出后反复重启。物理模式拔插屏幕、睡眠唤醒导致模式变化或运行失败时，
进程会尝试恢复并退出；可先卸载再安装重启服务。这样可以避免持续抢占你在系统设置中手动选择的模式。

## 备份与恢复

- 备份包含所有在线屏幕的 UUID、模式、渲染尺寸、刷新率、原点位置和镜像关系。
- 每次产生独立 JSON，默认保存在 `~/.config/hidpi-cli/backups/`，不会覆盖旧备份。
- 写入使用临时文件、`fsync`、原子重命名；回读核验完成之前不会修改显示器。
- `restore` 在恢复前也保存一份当前状态。通过 UUID 匹配屏幕，避免重启后数字 ID 变化恢复到错误设备。
- 正常退出、Ctrl+C、SIGTERM、SIGHUP、切换失败或预览超时，都会尝试还原并核验。
- 显示修改使用 CoreGraphics 的进程级配置；macOS 还提供进程退出后的会话配置回退。
  崩溃、断电或强制结束不能执行 Python 清理，不能承诺百分之百自动回退；重新运行 `restore` 可从磁盘备份恢复。
- 恢复时如果原显示器未连接或原模式已不可用，会明确失败并保留备份；连接原屏幕后再试。
- 不同时运行多个修改命令。先在运行中的 `enable` 终端按 Ctrl+C，然后执行独立恢复。
- JSON 是显示模式备份，不是整个 macOS 配置备份；不备份应用窗口位置、HDR、色彩配置、亮度或显示器 OSD 设置。

自定义备份目录放在子命令前：

```sh
hidpi --backup-dir /path/to/backups backup
```

## 能力与限制

物理模式枚举系统额外显示模式并选择真正的 HiDPI 模式（两个方向的渲染像素均至少为逻辑尺寸的两倍）。
它能启用已有但系统设置未展示的模式，不修改实体屏幕 EDID 来添加模式；虚拟模式则独立创建显示画布。
物理模式的目标屏幕正在镜像时会停止，避免改动镜像组。可先手动解除镜像再运行。

当前机器读取到：1920×1080 普通 DPI / 60 Hz；同界面尺寸的 HiDPI 为 3840×2160 渲染 / 50 Hz。
这表示渲染精度与刷新率之间存在取舍，不表示显示器物理面板变成 4K。

只读查询在受限沙箱内可能返回零台显示器，请在本机终端运行。macOS 27 的显示 UUID 接口
需要从 SkyLight 加载，这个兼容入口可能随 macOS 更新改变；其余模式查询与切换使用 CoreGraphics。

## 验证

```sh
uv run python -m unittest discover -s tests -v
```

2026-09-21 在本机 M4 Mac mini / macOS 27.0 上完成：

- 34 项自动化测试通过，覆盖备份与恢复故障、自启动安装/卸载、UUID 选择、无屏幕备份、虚拟屏幕清理等。
- 实机切换到 1920×1080 逻辑尺寸、3840×2160 渲染、50 Hz，读取当前模式核验成功。
- 5 秒预览结束后恢复 1920×1080 渲染、60 Hz，核验成功。
- 另起进程通过 JSON 备份执行 `restore`，核验成功。
- 原实体屏幕不在线、macOS 提供临时占位桌面时，实机创建 1920×1080 / 3840×2160 虚拟屏幕，NSScreen 核验 2× HiDPI；5 秒后自动移除成功。

测试证明系统模式切换和恢复可用；文字清晰度的主观改善仍需你查看实际屏幕。

参考：
- [Apple：CGDisplayCopyAllDisplayModes](https://developer.apple.com/documentation/coregraphics/cgdisplaycopyalldisplaymodes(_:_:))
- [Apple：进程级显示配置回退](https://developer.apple.com/documentation/coregraphics/cgconfigureoption/forapponly)
- [Apple：显示配置事务](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/DisplayTransactions.html)
- [Apple：LaunchAgent 登录启动](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [uv：独立工具环境](https://docs.astral.sh/uv/concepts/tools/)
- [Chromium：CGVirtualDisplay 接口与无屏幕检测](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm)
