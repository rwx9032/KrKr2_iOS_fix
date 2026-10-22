# XP3Compat — XP3Player 弹窗兼容插件

为 XP3Player 1.3.11（15，arm64）制作的 Objective-C 注入插件，目标是修复新系统上的创建目录、删除确认和游戏消息／输入弹窗问题。适用目标包括 iOS、iPadOS 和 Mac 上的 PlayCover。

本仓库发布插件源码、注入／共存打包工具及测试，不包含 XP3Player 原程序、IPA、游戏、存档、签名证书或预编译插件。请自行准备有权使用的原始程序。

## 当前状态

- 以公开 `NSRunLoop` API 替换旧 `DAFRunLoop` 对系统私有结构固定偏移的访问。
- 将目标 `MessageBoxEventRecevier` 使用的旧 `UIAlertView` 桥接至现代弹窗，保留按钮编号和输入框对象。
- iOS／iPadOS 使用 `UIAlertController`；检测到 AppKit 的 PlayCover 环境使用 `NSAlert`。插件不硬链接 AppKit。
- 仅对插件当前活动的原生模态窗口放行被 PlayTools 本地事件监视器消费的鼠标事件，不修改持久按键映射设置。
- 提供独立 Bundle ID `tvp.XP3Player.Compat`（显示名 `XP3Player Fix`），可与原版共存。

**当前发布的是弹窗修复候选源码，目标为普通 iPhone、iPad 和 PlayCover；iPhone Duo 折叠屏适配不在本次范围内。** 保留原程序的窗口与启动行为，不纳入 Duo 实验中的 SDK 改标、Scene 接入或窗口迁移。插件核心没有固定设备尺寸、强制旋转或游戏拉伸补丁；全屏和窗口缩放仍不能视为已普遍修复。

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
