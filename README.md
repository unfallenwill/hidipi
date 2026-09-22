# hidipi

免费开源的 macOS 命令行工具，一条命令开启 HiDPI 显示模式，让屏幕文字和图标更清晰细腻。

## 它解决什么问题？

你是否遇到过这些情况：

- 外接 4K 显示器后，字体发虚、图标模糊，想把界面切到 HiDPI，却发现系统设置里根本没有这个选项；
- 用远程桌面连接 Mac mini，手边没有实体显示器，想要清晰的 HiDPI 画面只能去买 HDMI 欺骗器；
- 网上的教程要么让你购买 BetterDisplay 付费版，要么让你修改系统文件、关闭 SIP，风险大还麻烦。

hidipi 专门解决这些问题。它有两个核心能力：

1. **启用隐藏的 HiDPI 模式（实体显示器）**：macOS 其实内置了 HiDPI 模式，只是系统设置里不展示。hidipi 帮你列出这些模式并安全切换。
2. **创建 HiDPI 虚拟屏幕（Apple Silicon）**：没有 HDMI 显示器也能凭空创建一块 HiDPI 虚拟屏，远程桌面直接使用，无需欺骗器。

同时，你**不需要**：付费软件、sudo 权限、修改系统文件、关闭 SIP、安装任何第三方依赖（纯 Python 标准库实现）。

## 安装

要求：macOS + [uv](https://docs.astral.sh/uv/)，在**已登录桌面的本机终端**操作（部分受限沙箱终端读不到显示器信息）。

在项目目录执行：

```sh
uv tool install .
```

安装后在任意目录都能运行 `hidipi`。如果提示找不到命令，请把 uv 的工具目录（通常 `~/.local/bin`）加入 PATH。

```sh
# 验证安装，同时查看备份和日志目录位置
hidipi paths
```

> 开发调试时可以不安装，直接在项目目录运行 `uv run hidipi ...`。两种方式共用同一份用户数据（`~/.config/hidipi/`）。
> 旧命令 `hidpi` 仍然可用，是 `hidipi` 的兼容别名。

## 快速上手（三步）

### 第 1 步：查看支持的 HiDPI 模式

```sh
hidipi list
```

列出每台显示器的 HiDPI 模式（界面尺寸、渲染分辨率、刷新率）。想看包括普通 DPI 在内的所有模式，加 `--all`。

### 第 2 步：安全预览 20 秒

```sh
hidipi enable --size 1920x1080
```

- 切换前会**自动备份**当前显示设置，随时可以恢复；
- 默认预览 20 秒：觉得不错就输入 `y` 回车继续使用；不想要就按 `Ctrl+C`（或等倒计时结束），自动恢复原样。

### 第 3 步：满意后长期使用

```sh
# 方式一：保持终端窗口打开，直到按 Ctrl+C 才恢复
hidipi enable --size 1920x1080 --keep

# 方式二：开机自动启用，后台运行，无需保留终端（推荐）
hidipi autostart install --size 1920x1080
hidipi autostart status
```

> **重要**：方式一需要 hidipi 进程保持运行，关闭终端会恢复原设置。想长期使用请选方式二。

## 常用场景速查

### 多显示器 / 指定刷新率

```sh
# 多显示器时，用 list 输出中的 ID 指定目标屏幕
hidipi enable --display 3 --size 1920x1080

# 指定刷新率（系统不支持时直接报错，不会偷偷降级）
hidipi enable --size 1920x1080 --refresh 60

# 省略 --size，默认使用当前界面尺寸对应的 HiDPI 模式
hidipi enable

# 非交互场景：固定预览 5 秒后自动恢复
hidipi enable --size 1920x1080 --seconds 5
```

### 远程桌面 / 没有实体显示器

Apple Silicon Mac 可以创建独立的 HiDPI 虚拟屏幕，屏幕名称为 **HiDPI Virtual Display**：

```sh
# 前台预览 20 秒，之后自动移除；输入 y 可保留
hidipi virtual --size 1920x1080

# 持续运行，按 Ctrl+C 移除虚拟屏幕
hidipi virtual --size 1920x1080 --keep

# 开机自动创建虚拟屏幕
# （如果之前装过物理屏幕的自启动，先执行 hidipi autostart uninstall）
hidipi autostart install --virtual --size 1920x1080
hidipi autostart status
```

逻辑尺寸 `1920x1080` 按 `3840x2160`（2 倍像素）渲染，默认 60 Hz。

注意事项：

- hidipi 只负责"造屏幕"，**不包含远程连接功能**，也不会自动开启屏幕共享；
- 在远程软件中选择 HiDPI Virtual Display 这块屏即可；
- 如果实体屏幕仍连着，虚拟屏是额外的独立桌面，不会自动镜像；
- 停止唯一的虚拟屏幕时，远程会话可能短暂重排或断开，请在方便重连时操作。

### 开机自动启用（登录自启动）

安装一次，之后每次登录桌面自动启用 HiDPI，无需保留终端：

```sh
# 启用（物理屏幕模式）
hidipi autostart install --size 1920x1080

# 查看运行状态和最近日志
hidipi autostart status

# 只预览将生成的配置，不实际写入
hidipi autostart install --size 1920x1080 --dry-run

# 停止后台进程、取消自启动、恢复安装前的显示设置（所有备份仍保留）
hidipi autostart uninstall
```

注意：

- 手动运行 `enable` / `virtual` / `restore` 前，先 `hidipi autostart uninstall`，避免两个进程同时修改显示器；
- 升级或卸载工具前，也请先执行 `hidipi autostart uninstall`；
- 运行日志在 `~/.config/hidipi/logs/`（`autostart.log` 和 `autostart-error.log`）。

### 恢复原样

每次修改显示设置前，hidipi 都会自动备份一份完整快照，存放在 `~/.config/hidipi/backups/`，从不覆盖：

```sh
# 查看所有历史备份
ls ~/.config/hidipi/backups/

# 用实际文件名恢复
hidipi restore ~/.config/hidipi/backups/display-20260921-153000-abcdef12.json

# 只备份当前设置，不做任何修改
hidipi backup
```

- 备份按屏幕 UUID 匹配，重启后也能恢复到正确的显示器；
- 恢复前若原显示器没接上，会明确报错而不是乱改，接回屏幕后再试即可；
- `restore` 执行前也会先备份一份当前状态，放心操作。

## 安全机制

- **先备份再动手**：每次切换前自动备份并回读核验，核验通过才会修改显示器。
- **退出即恢复**：`Ctrl+C`、关闭终端、预览超时、切换失败，都会自动恢复原设置并核验。
- **随时可回退**：所有备份长期保留，`hidipi restore <文件>` 一条命令回到任意历史状态。
- **不碰系统底层**：不修改显示器 EDID、不写系统配置文件，只使用系统已有的显示模式。

## 常见问题

**Q：开启 HiDPI 到底有什么效果？**
界面元素尺寸不变，但用双倍像素渲染（例如 1920×1080 的界面实际按 3840×2160 渲染），文字和图标更细腻。它不会把普通面板"变成" 4K，实际清晰度提升请以你的观感为准。

**Q：为什么开了 HiDPI 刷新率变低了？**
渲染像素翻倍，部分显示器带宽不够。例如 4K 屏在 HiDPI 模式下可能只有 50 Hz（普通模式 60 Hz）。用 `hidipi list` 可提前查看各模式刷新率；也可用 `--refresh 60` 指定，不支持时直接报错，不会静默降级。

**Q：终端窗口能关吗？**
`enable` 和 `virtual` 需要进程保持运行：关闭终端、按 `Ctrl+C` 或进程退出都会恢复原设置。想长期使用请用 `autostart install`，它后台运行、不占终端、不出现在 Dock。

**Q：出问题了怎么彻底还原？**

1. 结束前台进程（`Ctrl+C`），或执行 `hidipi autostart uninstall` 停止后台服务；
2. 需要时用 `hidipi restore <备份文件>` 恢复任意历史备份。

**Q：为什么切换失败，提示屏幕正在镜像？**
hidipi 不会改动镜像组，请先在系统设置中解除镜像，再重新运行。

**Q：`hidipi list` 看不到任何显示器？**
请在已登录桌面的本机终端运行。某些受限沙箱（如 IDE 内嵌终端、远程 shell）中系统接口读不到显示器。

**Q：和 BetterDisplay 有什么区别？**
hidipi 免费、开源、零第三方依赖，专注"开启 HiDPI + 自动备份回滚"这一件事。BetterDisplay 是功能更全面的商业工具；如果你还需要缩放、色彩控制等高级功能，请使用它们。

**Q：支持哪些系统？**
macOS。实体屏幕的 HiDPI 模式通过系统公开接口启用；虚拟屏幕功能使用 macOS 私有接口，目前仅支持 Apple Silicon（原生 ARM64 Python）。

## 进阶与开发

```sh
# 自定义备份目录（注意参数放在子命令前面）
hidipi --backup-dir /path/to/backups backup

# 运行自动化测试（使用模拟接口，不切换真实屏幕）
uv run python -m unittest discover -s tests -v

# 真实系统接口冒烟测试（仅限已登录桌面的本机终端，勿在沙箱中运行）
HIDPI_NATIVE_TESTS=1 uv run python -m unittest discover -s tests -p test_native.py -v
```

代码结构一览：`cli.py`（命令入口）、`display.py` / `virtual.py`（实体 / 虚拟屏幕流程）、`backup.py`（备份核验）、`autostart.py`（登录自启动）、`runtime.py`（进程与信号处理）、`macos.py`（macOS 系统接口）、`modes.py` / `state.py` / `errors.py`。

2026-09 已在 M4 Mac mini / macOS 27.0 上完成实机验证：模式切换与恢复、预览超时回退、跨进程备份恢复、虚拟屏幕创建与移除均通过。更多实现细节（锁文件、状态记录、故障重试）见源码与测试。

## 许可证

[MIT](LICENSE)

## 参考

- [Apple：CGDisplayCopyAllDisplayModes](https://developer.apple.com/documentation/coregraphics/cgdisplaycopyalldisplaymodes(_:_:))
- [Apple：进程级显示配置回退](https://developer.apple.com/documentation/coregraphics/cgconfigureoption/forapponly)
- [Apple：显示配置事务](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/DisplayTransactions.html)
- [Apple：LaunchAgent 登录启动](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [uv：独立工具环境](https://docs.astral.sh/uv/concepts/tools/)
- [Chromium：CGVirtualDisplay 接口与无屏幕检测](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm)
