# iPhone Duo 实验分支

本目录保存截至 2026-10-22 的生成实验源码，供独立继续研究。它没有完成 Duo 适配，不改变 `main` 的 0.3 插件；默认 `build.sh` 仍只构建 `Sources/XP3Compat.m`。

## 保存内容

| 目录 | 内容 |
| --- | --- |
| `DisplayLab/` | 窗口、视图与 drawable 的几何观察；引擎缓存只读探针；启动元数据对照工具和生成测试 |
| `SceneLab/` | Scene 接入、生命周期／activity 观察、旧与新路径对照，以及早期 Bootstrap／Adaptive 候选 |
| `OfflineContinuation-20261021/` | 窗口 context 探针、默认关闭的 scene 原生窗口迁移和保留 design 候选；device／simulator 构建脚本 |

只发布生成源码和脚本。原始 IPA／主程序、预编译 dylib、游戏、存档、证书、截图、运行记录 JSON、完整崩溃日志和本机绝对路径分析文档均未加入分支。本地完整历史文件仍保留，没有删除。

## 当前事实与未解决项

- Duo 的旧 SDK 兼容模式与普通 iPhone 不同；仅将主程序 SDK 改标为 27.1 不能完成迁移，缺少 Scene 接入会触发系统检查。不得绕过该检查。
- 早期 Scene 接入在 iPad 对照中出现过侧转和黑区；2026-10-22 对 Duo 做了独立、安装身份核验后的测试，结果见下节。两组配置与设备不同，分别记录。
- Adaptive 能让部分引擎尺寸缓存跟随 surface，但字段自洽不能证明实际方向、画布比例或点击坐标正确。
- activity 计数和时间戳会推进，不支持“完全没有 tick”的判断；不能据此制造 tick 或强行解除 paused。
- context 探针显示的 window／root／render bounds、变换与方向掩码未解释实际侧转；模型层几何检查也不能排除所有合成器问题。
- `XP3SceneBootstrap.m` 的临时 UIScreen 替换属于失败实验，保留供分析，不作为推荐方案。
- `XP3CompatEnableSceneWindowHandoff` 保持默认关闭。已补充 delegate 所有权核验、先分离再附加 root、异常回滚与回滚失败停止连接。新版 KVC 路径已构建，尚未运行验证。
- `XP3CompatEnableAdaptiveKeepDesign` 未完成设备验证。文件界面尺寸与游戏自身逻辑画布应分别处理，不能以拉伸游戏来消除黑边。
- UIDeviceOrientation 与 UIInterfaceOrientation 的左右枚举相反可对应同一物理方向，不能单凭枚举名判错。

普通 iPad 的原 0.3、原始启动元数据回归中，横屏文件文字正向；原有两侧黑边仍在。自制消息／输入弹窗与比例点击夹具通过。这些结果不能扩展成 Duo 或真机通过。

## 2026-10-22 Duo 受控运行

使用唯一一台 iPhone Duo / iOS 27.1 模拟器。C1 启用 Scene、Adaptive 和只读探针，窗口迁移与 KeepDesign 关闭；主程序实际 SDK 为 27.1。启动前核验已安装主程序、配置和插件与待测副本一致，并通过完整签名检查。

- 展开：文件界面文字正向，菜单可点击；scene/window/render 为 951×669 pt，surface 和 viewport 为 2853×2007 px。
- 折叠：同一进程继续运行，菜单可点击；scene/window/render 更新为 678×466 pt，surface 和 viewport 为 2034×1398 px。
- 再展开：恢复到 951×669 pt 与 2853×2007 px，文字正向；上述过程中没有重启应用。驱动保持 active、unpaused，回调计数持续增加。
- 内屏处于展开状态时，`UIScreen.mainScreen` 仍反映外屏尺寸。内屏覆盖应结合 `windowScene.screen` 与实际画面判断。
- C2 请求窗口迁移，但初版访问器检查拒绝了只有 KVC window 的旧 delegate，实际上仍走既有窗口路径。因此 C2 的显示结果不证明窗口迁移有效。最新源码已改为核验 KVC 所有权；它与已测的 C1/C2 插件版本分开记录。

随后重新启动 C1 刷新文件列表，运行自制 640×480 比例夹具：Open 和 Closed 均可见四角标记与正方形；中心点击分别返回 `(320,239)`、`(318,240)`，预期为 `(320,240)`。游戏前台折叠后仍可响应点击，再展开已显示横向画面。后续观察被 Mac 锁屏阻断，Duo 的消息与输入完整回归继续等待。当前正式安装包仍为 0.3，未混入此实验。

## 构建（macOS / Xcode 27.1）

从仓库根目录执行，均只构建，不启动或安装模拟器：

```sh
# 正式 0.3 核心；不含本目录实验
bash build.sh

# 只读显示探针
bash Diagnostics/DisplayLab/build_displayprobe.sh --both

# Scene 基础实验，simulator arm64
bash Diagnostics/SceneLab/build_sceneprobe.sh

# Context 与默认关闭的窗口迁移／保留 design 候选，device + simulator
bash Diagnostics/OfflineContinuation-20261021/build/build_offline_probe.sh

# 纯生成启动配置测试，不读取真实 IPA
python3 -m unittest discover -s Diagnostics/DisplayLab -p 'test_*.py'
```

输出位于相应 `build/`，被 Git 忽略。device 的 ad-hoc 签名只用于本地完整性检查，安装真机仍须用户自己的有效签名。

本分支整理后已核对上述三个实验构建脚本：显示探针 device／simulator、Scene simulator、OfflineProbe device／simulator 均编译并通过签名检查；生成启动配置的 13 项测试通过。构建检查与上述 Duo 运行记录分别核验。

## 开关和后续验证

实验不由注入器默认开启。组合 target、Scene manifest 与 Info 开关需要配套；没有 Scene delegate 的 target 不能带 Scene manifest。

| 键 | 作用 |
| --- | --- |
| `XP3CompatEnableSceneAdapter` | 接入实验 Scene delegate |
| `XP3CompatEnableActivityProbe` | 观察现有 driver 的回调和状态 |
| `XP3CompatEnableSceneContextProbe` | 只读记录公开窗口上下文 |
| `XP3CompatEnableAdaptiveGeometry` | 实验引擎尺寸更新 |
| `XP3CompatEnableSceneWindowHandoff` | 窗口迁移候选；新版 KVC 路径待测，默认关闭 |
| `XP3CompatEnableAdaptiveKeepDesign` | 未实测的 design 保留候选，保持关闭 |

优先验证已通过文件界面折叠切换的 C1 组合；只有证据需要时再单独对照窗口迁移。每次只开一台模拟器；不清除或删除用户数据。测试中发现过同 Bundle ID 安装保留旧主程序、同时更新新配置和 dylib 的混合包：必须在启动前核对**已安装**主程序 SHA／实际 SDK、Info.plist 和 dylib SHA，并做完整签名检查。仅核对输入文件或 dylib 不足以确定运行版本。

SHA 用于记录测试产物身份，不恢复注入器的固定 SHA 准入限制。少数引擎观察实验依赖已分析 ABI，保留其只读范围与身份防护；不能将未知版本的原始指针解释为该 ABI。

通过标准须同时包含实际画面方向、真实内屏覆盖、按钮返回／输入，以及游戏画布比例和点击结果。不得把硬件边框、aspect-fit 黑边或几何字段一致当作已经修好 Duo。
