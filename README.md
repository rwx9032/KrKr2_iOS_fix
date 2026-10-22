# XP3Compat · iPhone Duo 实验分支

为 **iOS 版 XP3Player 1.3.11（build 15，arm64）**探索 iPhone Duo 的展开、折叠和显示适配。XP3Player 是运行 krkr / krkr2 游戏的播放器，也常被称作 iOS 版 Kirikiroid / Kirikiroid2。

本分支在 XP3Compat 通用弹窗修复的基础上，让旧播放器的窗口、游戏画面和触摸坐标能够跟随 Duo 的显示区域变化。目前已有模拟器中的展开与折叠测试结果，适配仍在进行。

## 目前进展

Duo 的 C1 实验组合已在模拟器中完成以下测试：

- **展开、折叠、再展开**：同一进程内切换，文件界面文字方向正常，菜单可以点击，渲染区域随窗口变化。
- **游戏画面比例**：自制 640×480 测试画面的四角和正方形可见，展开、折叠状态下的中心点击均落在预期位置附近。
- **游戏弹窗**：Info、Warning 可以确认；多按钮弹窗选择 Second 返回编号 `1`；输入内容能够完整传回游戏。

本分支也已同步主分支的通用修复，包括新建文件夹、删除确认、游戏消息和文字输入，以及 iPad 文件管理界面的全屏显示。

上述 Duo 运行结果来自已测的 C1 组合。同步最新弹窗调度修复后，实验组合已通过构建和自动测试，Duo 的运行回归仍待完成。窗口迁移的新版 KVC 路径与 KeepDesign 候选也尚未完成运行验证。详细配置和测试记录见[实验说明](Diagnostics/README.zh-CN.md)。

## 选择哪个分支

| 分支 | 用途 |
| --- | --- |
| [`main`](https://github.com/rwx9032/KrKr2_iOS_fix/tree/main) | 普通 iPhone、iPad 和 PlayCover 的通用兼容修复及安装说明 |
| `experimental/iphone-duo` | Duo 显示与折叠适配的实验源码、构建工具和测试记录 |

**本分支的 `bash build.sh` 构建通用修复插件。** Duo 实验通过 `Diagnostics/` 下的脚本单独构建，并需要配套的启动配置。

## 获取源码

需要一台 Mac、Xcode、Python 3 和 Git。实验构建已在 Xcode 27.1 工具链下验证。

```bash
git clone --branch experimental/iphone-duo --single-branch https://github.com/rwx9032/KrKr2_iOS_fix.git
cd KrKr2_iOS_fix
```

## 构建与安装通用修复

如果要从本分支构建通用弹窗修复，准备自己的已解密 XP3Player 1.3.11（build 15，arm64）IPA，然后依次执行：

```bash
bash build.sh
python3 tools/inject_ipa.py "/path/to/XP3Player.ipa" XP3Compat.dylib /tmp/XP3Player-injected.ipa
python3 tools/clone_ipa.py /tmp/XP3Player-injected.ipa /tmp/XP3Player-Fix.ipa
```

将 `/path/to/XP3Player.ipa` 换成实际 IPA 路径。两个输出路径都必须使用尚未占用的新文件名；脚本不会覆盖同名文件。

构建得到的共存应用显示为 **XP3Player Fix**，Bundle ID 为 `tvp.XP3Player.Compat`。使用自己的签名工具，对主应用和内嵌的 `Frameworks/XP3Compat.dylib` 一起重签后安装，无需越狱。签名步骤及 PlayCover 安装方法见[主分支安装说明](https://github.com/rwx9032/KrKr2_iOS_fix/tree/main#安装)。

共存应用使用独立的数据目录。游戏和存档需通过文件共享或应用内的 Web 文件服务器重新导入。

## 构建 Duo 实验

实验按用途分为三组：

| 目录 | 用途 |
| --- | --- |
| [`Diagnostics/DisplayLab/`](Diagnostics/DisplayLab/) | 观察窗口、视图和渲染区域，生成启动配置对照 |
| [`Diagnostics/SceneLab/`](Diagnostics/SceneLab/) | Scene 接入、引擎活动状态和自适应几何实验 |
| [`Diagnostics/OfflineContinuation-20261021/`](Diagnostics/OfflineContinuation-20261021/) | 窗口上下文探针、窗口迁移与 KeepDesign 候选 |

从仓库根目录执行：

```bash
bash Diagnostics/DisplayLab/build_displayprobe.sh --both
bash Diagnostics/SceneLab/build_sceneprobe.sh
bash Diagnostics/OfflineContinuation-20261021/build/build_offline_probe.sh
```

产物保存在对应的 `build/` 目录。脚本会进行本地 ad-hoc 签名和完整性检查；安装到实体设备仍需有效的应用签名。

实验库需与目标主程序的 SDK 声明、Scene 配置和功能开关配套。已测 C1 使用 Scene 接入与 Adaptive，窗口迁移和 KeepDesign 关闭。具体组合、开关和后续验证要求见[实验说明](Diagnostics/README.zh-CN.md#开关和后续验证)。

## 测试

通用修复的语义与打包测试：

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
bash tests/run_native_tests.sh
```

Duo 启动配置生成测试：

```bash
python3 -m unittest discover -s Diagnostics/DisplayLab -p 'test_*.py'
```

Duo 的显示、折叠与点击结果以模拟器运行记录为依据，实体设备尚未验证。通用修复的真机测试范围见[技术说明](docs/TECHNICAL.zh-CN.md#测试)。

## 相关文档

- [Duo 实验说明](Diagnostics/README.zh-CN.md)：已测配置、运行结果、实验开关和待验证事项。
- [技术说明](docs/TECHNICAL.zh-CN.md)：通用修复原理、构建选项、签名与测试方法。
- [主分支](https://github.com/rwx9032/KrKr2_iOS_fix/tree/main)：通用修复的使用与安装说明。
