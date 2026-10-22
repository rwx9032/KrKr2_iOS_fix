# XP3Compat 技术说明

> 当前分支：`experimental/iphone-duo`。这里保留 iPhone Duo 的显示、Scene 和窗口迁移研究源码，尚未完成适配。普通 iPhone、iPad 和 PlayCover 的 0.3 路线在 [`main`](https://github.com/rwx9032/KrKr2_iOS_fix/tree/main)。实验进度、构建方法与边界见 [Diagnostics/README.zh-CN.md](../Diagnostics/README.zh-CN.md)。

为 XP3Player 1.3.11（15，arm64）制作的 Objective-C 注入插件，目标是修复新系统上的创建目录、删除确认和游戏消息／输入弹窗问题。适用目标包括 iOS、iPadOS 和 Mac 上的 PlayCover。

本仓库发布插件源码、注入／共存打包工具及测试，不包含 XP3Player 原程序、IPA、游戏、存档、签名证书或预编译插件。请自行准备有权使用的原始程序。

## 当前状态

- 以公开 `NSRunLoop` API 替换旧 `DAFRunLoop` 对系统私有结构固定偏移的访问。
- 将目标 `MessageBoxEventRecevier` 使用的旧 `UIAlertView` 桥接至现代弹窗，保留按钮编号和输入框对象。
- iOS／iPadOS 使用 `UIAlertController`；检测到 AppKit 的 PlayCover 环境使用 `NSAlert`。插件不硬链接 AppKit。
- 仅对插件当前活动的原生模态窗口放行被 PlayTools 本地事件监视器消费的鼠标事件，不修改持久按键映射设置。
- 提供独立 Bundle ID `tvp.XP3Player.Compat`（显示名 `XP3Player Fix`），可与原版共存。

**`Sources/XP3Compat.m` 保持与 main 一致；新增实验全部位于 `Diagnostics/`，不会由默认 `build.sh` 编入正式插件。** Duo 的 SDK／Scene／窗口迁移候选独立构建且默认关闭，不能把本分支视为可直接交付的 Duo 修复。显示与折叠测试的最新结果见 [实验记录](../Diagnostics/README.zh-CN.md)。

已完成 PlayCover 实际弹窗测试，以及实际程序转换副本在 iPhone／iPad 模拟器上的部分 UIKit 测试；物理 iPhone／iPad 尚未验证。自动测试使用真实 Foundation 与模拟 UIKit，不能代替真机测试。PlayTools 的主文件界面假触摸问题属于仍需区分的输入路径。

## 构建和注入

需要 macOS、Python 3，以及 Xcode／对应工具链。工具不会覆盖输入；每次请使用尚不存在的输出路径。

```sh
bash build.sh
python3 tools/inject_ipa.py /path/to/XP3Player.ipa XP3Compat.dylib /tmp/XP3Player-injected.ipa
python3 tools/clone_ipa.py /tmp/XP3Player-injected.ipa /tmp/XP3Player-Fix.ipa
```

注入器会把输入主程序的实际 SHA-256 写入 JSON 报告，供完整性追溯；不再用固定哈希把注入绑定到某一份二进制。同一个 XP3Player 1.3.11 的不同砸壳／签名副本可能字节不同、哈希也不同，仍可处理。仍会校验应用标识与版本、Mach-O arm64／未加密、注入空间、ZIP 安全与不覆盖输入；这不表示支持任意版本或任意程序。

最终 IPA 需要重新签名，主程序和内嵌 dylib 必须一起签。iPhone／iPad 安装还需要自己的有效签名与配置；Mac 的 ad-hoc 签名不等于真机安装签名。共存版使用独立数据容器，不会自动迁移原版的游戏和存档。

`build.sh` 自动选择可用 SDK；可用 `XP3_BUILD_MODE=sdk` 或 `XP3_BUILD_MODE=minimal` 显式指定构建方式。最小 ABI 构建生成的链接桩仅用于链接，不应打进 IPA。

## 测试

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
bash tests/run_native_tests.sh
```

真实 IPA 往返测试默认跳过。需要时显式提供本机文件：

```sh
XP3COMPAT_ORIGINAL_IPA=/path/to/XP3Player.ipa \
XP3COMPAT_DYLIB="$PWD/XP3Compat.dylib" \
XP3COMPAT_CLONE_INPUT_IPA=/tmp/XP3Player-injected.ipa \
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

下面的生成器只产生自制、无第三方资源的 XP3 测试脚本：

```sh
python3 tests/make_dialog_smoke.py
python3 tests/make_aspect_fixture.py
```

前者验证消息、按钮返回值与输入；后者验证 640×480 画布的四角、方形比例和点击坐标。画布比例正确不等于应用窗口已铺满屏幕。

## 目录

| 路径 | 内容 |
| --- | --- |
| `Sources/` | 插件、公开 ABI 声明和 AppKit 事件桥接声明 |
| `tools/` | IPA 注入、独立包名打包及最小链接桩工具 |
| `tests/` | Foundation／模拟 UIKit 语义测试、打包测试和自制夹具生成器 |
| `build.sh` | 构建脚本 |

显示诊断实验、模拟器应用副本和本机分析产物未混入本次插件源码发布。

## Mac / PlayCover 签名和导入

前面的工具输出尚未签名。为 PlayCover 准备安装包时，签名内嵌插件与整个应用，再重新压缩：

```sh
XP3_STAGE="$(mktemp -d /tmp/xp3-playcover.XXXXXX)"
ditto -xk /tmp/XP3Player-Fix.ipa "$XP3_STAGE"
chmod +x "$XP3_STAGE/Payload/XP3Player.app/XP3Player"
codesign --force --sign - "$XP3_STAGE/Payload/XP3Player.app/Frameworks/XP3Compat.dylib"
codesign --force --sign - "$XP3_STAGE/Payload/XP3Player.app"
codesign --verify --deep --strict "$XP3_STAGE/Payload/XP3Player.app"
(cd "$XP3_STAGE" && ditto -c -k --keepParent Payload /tmp/XP3Player-Fix-PlayCover.ipa)
```

选择未被占用的输出文件名，将最后生成的包导入 PlayCover。iPhone／iPad 使用自己的签名工具对应用及内嵌插件重签后安装；Mac 的 ad-hoc 签名不用于真机安装。
