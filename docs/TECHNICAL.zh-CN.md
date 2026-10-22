# XP3Compat 技术说明

> 当前分支：`experimental/iphone-duo`。这里保留 iPhone Duo 的显示、Scene 和窗口迁移研究源码，尚未完成适配。普通 iPhone、iPad 和 PlayCover 的 0.3 路线在 [`main`](https://github.com/rwx9032/KrKr2_iOS_fix/tree/main)。实验进度、构建方法与边界见 [Diagnostics/README.zh-CN.md](../Diagnostics/README.zh-CN.md)。

为 XP3Player 1.3.11（15，arm64）制作的 Objective-C 注入插件，目标是修复新系统上的创建目录、删除确认和游戏消息／输入弹窗问题。适用目标包括 iOS、iPadOS 和 Mac 上的 PlayCover。

本仓库发布插件源码、注入／共存打包工具及测试。注入时需自行准备原始程序。

## 当前状态

- 以公开 `NSRunLoop` API 替换旧 `DAFRunLoop` 对系统私有结构固定偏移的访问。
- 将目标 `MessageBoxEventRecevier` 使用的旧 `UIAlertView` 桥接至现代弹窗，保留按钮编号和输入框对象。
- iOS／iPadOS 使用 `UIAlertController`；检测到 AppKit 的 PlayCover 环境使用 `NSAlert`。插件不硬链接 AppKit。
- 仅对插件当前活动的原生模态窗口放行被 PlayTools 本地事件监视器消费的鼠标事件，不修改持久按键映射设置。
- 提供独立 Bundle ID `tvp.XP3Player.Compat`（显示名 `XP3Player Fix`），可与原版共存。
- 将引擎触摸与帧回调调度到 UIKit 更新阶段之外，使旧引擎的同步弹窗等待能够正常返回。
- 补齐 iPad 的现代启动配置和主程序 SDK 声明，使文件管理界面使用完整显示区域。

**`Sources/XP3Compat.m` 保持与 main 一致；实验位于 `Diagnostics/`，默认 `build.sh` 构建正式插件。** Duo 的 SDK／Scene／窗口迁移候选独立构建且默认关闭。显示与折叠测试结果见 [实验记录](../Diagnostics/README.zh-CN.md)。

## 修复原理

### 替换旧 RunLoop 实现

原程序的 `DAFRunLoop.runMode:beforeDate:` 通过固定内存偏移访问和修改 Core Foundation 的内部对象。系统内部布局变化后，这些访问可能导致闪退。`Sources/XP3Compat.m` 将整个方法替换为公开的 `NSRunLoop` 调用，以 50 毫秒为等待时间片，让旧引擎定期检查用户是否完成选择。

### 桥接系统弹窗和返回值

插件识别代理为 `MessageBoxEventRecevier` 的旧 `UIAlertView`，用 `UIAlertController` 显示标题、消息、按钮和输入框。按钮编号按原顺序回传，输入框在展示前后保持同一对象，旧调用者可以从原先保存的文本框读取结果。

PlayCover 环境中，插件在运行时查找 AppKit 的公开类，并使用 `NSAlert.runModal`。原生模态窗口活动期间，事件桥接将该窗口的鼠标事件交回 AppKit；其他窗口继续使用原有事件处理。

### 避免在 UIKit 更新阶段同步等待

旧引擎显示弹窗后会同步等待按钮结果。若调用来自 UIKit 的触摸派发或显示刷新回调，等待循环就会嵌套在尚未结束的 UIKit 更新阶段里。此时公开 RunLoop 仍可能继续运行，但弹窗的展示转换没有完成，表现为弹窗不出现或按钮无法响应。仅关闭动画或改变 SDK 声明不能解决这一调用时机问题。UIKit 对更新阶段的约束见 [UIUpdateActionPhase](https://developer.apple.com/documentation/uikit/uiupdateactionphase)。

`Sources/XP3EngineScheduling.h` 在引擎自己的 `CCEAGLView` 和 `CCDirectorCaller` 方法上加入调度层：

- 触摸回调立即复制位置、压力等公开值，并为同一手势保留稳定的引擎触摸身份。UIKit 会复用触摸和事件对象，因此排队任务使用值快照；相关约定见 [UIEvent](https://developer.apple.com/documentation/uikit/uievent)。
- 通过 `CFRunLoopPerformBlock` 在 UIKit 当前回调返回后执行引擎处理，执行线程仍为主线程。
- 触摸和帧处理共用有序队列。弹窗等待期间，系统事件和计时器可以继续运行，后续引擎任务等外层回调结束后再执行，避免重入游戏逻辑。
- 待执行的帧回调合并为一帧；暂停或重建刷新循环时使旧帧任务失效，避免使用已经停止的刷新对象。

安装前会检查目标方法是否属于引擎类及其参数类型；四种触摸回调一并替换，保持开始、移动、结束和取消的身份一致性。

### 适配 iPad 的完整显示区域

打包工具对低于 26.0 的主程序 SDK 声明设置 26.0 下限，并在缺少现代 iPad 启动配置时补充 `UILaunchScreen~ipad = {}`。两者配合，使旧应用获得当前窗口的完整显示区域。

处理同时支持 `LC_BUILD_VERSION` 与 `LC_VERSION_MIN_IPHONEOS`，保留原部署版本及加载命令之外的程序内容。已有的现代启动配置继续保留。此适配使用系统提供的显示区域，文件管理界面随窗口尺寸显示，游戏自身画布仍按原有比例呈现。

## 构建和注入

需要 macOS、Python 3，以及 Xcode／对应工具链。工具不会覆盖输入；每次请使用尚不存在的输出路径。

```sh
bash build.sh
python3 tools/inject_ipa.py /path/to/XP3Player.ipa XP3Compat.dylib /tmp/XP3Player-injected.ipa
python3 tools/clone_ipa.py /tmp/XP3Player-injected.ipa /tmp/XP3Player-Fix.ipa
```

注入器会把输入主程序的实际 SHA-256 写入 JSON 报告，供完整性追溯。同一个 XP3Player 1.3.11 的不同砸壳／签名副本可能字节不同、哈希也不同，仍可处理。处理前会校验应用标识与版本、Mach-O arm64／未加密、注入空间、ZIP 安全与不覆盖输入。

最终 IPA 需要重新签名，主程序和内嵌 dylib 必须一起签。iPhone／iPad 安装还需要自己的有效签名与配置；Mac 的 ad-hoc 签名不等于真机安装签名。共存版使用独立数据容器，不会自动迁移原版的游戏和存档。

`build.sh` 自动选择可用 SDK；可用 `XP3_BUILD_MODE=sdk` 或 `XP3_BUILD_MODE=minimal` 显式指定构建方式。最小 ABI 构建生成的链接桩仅用于链接，不应打进 IPA。

## 测试

iPadOS 真机验证覆盖文件夹输入、创建、删除确认取消，以及游戏消息、按钮选择和中文输入回传。连续弹窗和具体返回值通过带诊断信息的同源调度实现核验；正式无诊断重签包已复测文件夹输入取消与游戏弹窗。

最新包已在 iPadOS 模拟器验证启动、横屏文件界面、Info／Warning 弹窗、按钮选择和文字输入回传。实体 iPhone 的本次修复尚未验证。PlayCover 的原生弹窗路径有先前运行记录，最新包尚未重新进行界面测试。

自动测试使用真实 Foundation、模拟 UIKit 和公开 RunLoop，覆盖弹窗返回语义、触摸快照与手势身份、嵌套等待时的队列顺序、帧合并和暂停失效，以及 IPA 注入与打包完整性。

以上真机结果针对通用弹窗核心。Duo 组合已通过构建和自动测试，合入调度修复后的运行回归待完成；显示与折叠验证记录见 [实验记录](../Diagnostics/README.zh-CN.md)。

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

下面的生成器产生自制 XP3 测试脚本：

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

选择未被占用的输出文件名，将最后生成的包导入 PlayCover。
