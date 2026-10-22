# XP3Compat — iOS 版 krkr2 / XP3Player 弹窗修复

XP3Player 是 iOS 上的吉里吉里游戏播放器，也常以 **krkr、krkr2、Kirikiroid、Kirikiroid2** 的名字被提起。XP3Compat 为 **XP3Player 1.3.11** 提供兼容修复，让这个旧播放器在新系统上继续使用。

随着 iOS 更新，原版在新建文件夹、确认删除、显示游戏消息或输入文字时可能闪退。这个项目通过注入插件修复这些弹窗，让按钮选择和输入内容正常返回应用，游戏文件保持原样。

修复版支持 **iPhone 和 iPad（iOS / iPadOS）**，无需越狱，重新签名后安装即可；**Apple Silicon Mac** 可以通过 **PlayCover** 运行。生成的应用叫 **XP3Player Fix**，可以与原版共存。

## 修复内容

目前修复了以下交互：

- **新建文件夹**：目录管理中新建文件夹可以正常完成。
- **删除确认**：删除操作的系统确认弹窗正常弹出，选择结果能正确传回应用。
- **游戏消息（Info / Warning）**：游戏触发的信息、警告对话框正常显示，确认后能正确关闭。
- **按钮选择弹窗**：多按钮选择的返回值正确，选哪个走哪个分支。
- **文字输入对话框**：调起系统输入时不再闪退，输入内容正常回传。
- **Mac（PlayCover）**：原生弹窗的普通鼠标事件可以正常传入，用鼠标点按钮、输入文字都没问题。

## 运行截图

以下为 iPad Air（第 5 代）/ iPadOS 27.0 模拟器上的实际运行画面。

**文件管理**

![文件管理界面](docs/images/file-manager.png)

**游戏消息弹窗**

![游戏消息弹窗](docs/images/game-message.png)

**文字输入弹窗**

![文字输入弹窗](docs/images/text-input.png)

## 分支与仓库内容

- **main（主线）**：即 0.3 路线，保持原版显示与启动行为，只做上面列出的系统交互修复；`bash build.sh` 默认构建的就是这个正式核心。
- **[experimental/iphone-duo](https://github.com/rwx9032/KrKr2_iOS_fix/tree/experimental/iphone-duo)**：iPhone Duo 的显示实验分支。模拟器上的展开/折叠、游戏比例与点击、弹窗输入已经跑通，适配仍在继续，尚未合并进主线。

仓库提供插件源码、打包工具和测试脚本。请准备自己的 **XP3Player 1.3.11（build 15，arm64）已解密 IPA**，按下面的步骤生成修复包；仓库没有附带原程序、游戏或预编译安装包。

安装步骤中 `clone_ipa.py` 生成的共存包身份如下，可与原版并排安装、互不覆盖：

| | 原版 | 共存包 |
|---|---|---|
| 桌面显示名 | XP3Player | **XP3Player Fix** |
| Bundle ID | `tvp.XP3Player` | `tvp.XP3Player.Compat` |

## 安装：从空目录到装进设备

整体流程：准备环境 → 取源码 → 构建 → 注入 IPA → 生成共存包 → 按平台签名安装 → 打开新图标、复制数据。逐步展开如下。

### 1. 准备环境

- 一台 **Mac**：用于构建插件、处理 IPA，以及为 PlayCover 签名。
- **Xcode**（或带 iPhoneOS SDK 的对应开发工具）：安装完整 Xcode 最省事，`build.sh` 会自动选用可用的 SDK，无需手动指定。
- **Python 3** 与 **Git**。
- 一份你自己的 **XP3Player 1.3.11（build 15）IPA**（已解密、可直接处理）。
- iPhone / iPad：准备你使用的 IPA 签名工具及对应签名方式。
- Mac（使用 PlayCover 时）：已安装 PlayCover，签名用系统自带命令完成，见第 6 步。

### 2. 获取源码

```bash
git clone https://github.com/rwx9032/KrKr2_iOS_fix.git
cd KrKr2_iOS_fix
```

### 3. 构建

```bash
bash build.sh
```

产出 **XP3Compat.dylib**，也就是后面注入用的修复动态库。默认只构建主线正式核心，不会自动把 Duo 实验编进去。

### 4. 注入

```bash
python3 tools/inject_ipa.py "/path/to/XP3Player.ipa" XP3Compat.dylib /tmp/XP3Player-injected.ipa
```

- `/path/to/XP3Player.ipa` 请换成你自己 IPA 的路径；**路径带空格时保留双引号**。
- **输出文件必须用尚未占用的新文件名**：脚本不覆盖同名文件。重复执行时换个输出名（例如 `XP3Player-injected-2.ipa`）继续即可；后续命令的输入路径也要对应修改。
- 这一步得到的 `/tmp/XP3Player-injected.ipa` 仅完成注入，应用身份仍是原版，还不能与原版共存，继续下一步。

### 5. 生成共存包

```bash
python3 tools/clone_ipa.py /tmp/XP3Player-injected.ipa /tmp/XP3Player-Fix.ipa
```

同样使用未占用的新输出名。此步把应用改为共存身份（显示名 **XP3Player Fix**、Bundle ID `tvp.XP3Player.Compat`），产出 **`/tmp/XP3Player-Fix.ipa`**。注意这个包此时**尚未签名**，不能直接安装，请按你的平台走第 6 步。

### 6. 按平台签名并安装

**iPhone / iPad（重签安装，不需要越狱）**

用你的签名工具导入 `/tmp/XP3Player-Fix.ipa`，按该工具的正常流程配置证书与签名方式。最关键的一条：**主应用和内嵌的 `Frameworks/XP3Compat.dylib` 必须一起重签**——只签主程序、漏掉内嵌库，应用会启动失败。签好后通过工具正常安装；若系统提示应用未受信任，按系统指引信任你的证书即可。完成后桌面会出现新图标 **XP3Player Fix**。

**Mac（PlayCover，先完整签名再导入）**

先为插件和应用签名，再把打包好的 IPA 导入 PlayCover。在终端执行：

```bash
XP3_STAGE="$(mktemp -d /tmp/xp3-playcover.XXXXXX)"
ditto -xk /tmp/XP3Player-Fix.ipa "$XP3_STAGE"
chmod +x "$XP3_STAGE/Payload/XP3Player.app/XP3Player"
codesign --force --sign - "$XP3_STAGE/Payload/XP3Player.app/Frameworks/XP3Compat.dylib"
codesign --force --sign - "$XP3_STAGE/Payload/XP3Player.app"
codesign --verify --deep --strict "$XP3_STAGE/Payload/XP3Player.app"
(cd "$XP3_STAGE" && ditto -c -k --keepParent Payload /tmp/XP3Player-Fix-PlayCover.ipa)
```

这一段依次做的是：新建临时目录 → 解开 IPA → 恢复主程序可执行权限 → 先给内嵌的 `XP3Compat.dylib` 做 ad-hoc 签名，再签整个 `.app` → 整体校验 → 重新压缩为 `/tmp/XP3Player-Fix-PlayCover.ipa`。**把最后生成的这个包**导入 PlayCover。

如果 PlayCover 报 `code object is not signed at all`，请检查两条 `codesign --force --sign -` 命令与最后的打包步骤。这里的 ad-hoc 签名用于 Mac；iPhone / iPad 仍使用前面的重签安装流程。

### 7. 打开新图标

在桌面找到 **XP3Player Fix** 打开。共存版使用独立数据目录，接下来把要用的游戏和存档复制进去。

## 迁移数据

原版与 XP3Player Fix 使用各自的数据目录。游戏、存档和配置需要手动复制：按你当初往原版导入游戏的方式（例如文件共享或应用内的 Web 文件服务器），把游戏封包与存档重新导入到 XP3Player Fix。之后两个应用各用各的目录，互不干扰。

## 常见问题

**必须要越狱吗？**
不需要。全程就是“处理 IPA 副本 → 自己的证书重签 → 正常安装”，和侧载普通应用是一回事。

**会影响原版 XP3Player 吗？**
不会。所有步骤处理的都是你自己那份 IPA 的副本；Fix 版是独立应用（Bundle ID 不同），与原版并排安装、互不覆盖。

**装好打开后发现游戏和存档不见了？**
Fix 版数据目录独立，请看“迁移数据”一节，从原版手动复制游戏和存档。

**仓库里没有现成的 IPA 或 dylib 可以下载吗？**
没有。仓库只有源码、工具和测试，不含原程序与游戏资源，也不提供预编译包。请自行准备 XP3Player 1.3.11（build 15）已解密、可直接处理的 IPA。

**全屏、旋转这些问题解决了吗？**
主线保留原版显示行为。Duo 显示适配在独立的 `experimental/iphone-duo` 分支进行，已有模拟器测试进展。

**PlayCover 提示应用未签名？**
先确认导入的是最终签好并重新打包的 `/tmp/XP3Player-Fix-PlayCover.ipa`；若报 `code object is not signed at all`，回到第 6 步的 Mac 部分，逐条核对两条签名命令与打包步骤。

## 验证情况

- Mac PlayCover：在真实环境中验证过消息与输入弹窗、目录的创建和删除。
- iPhone / iPad 模拟器：系统弹窗相关用例通过。
- 自制 640×480 比例点击测试夹具：通过。
- 实体 iPhone / iPad：尚未测试。

## 相关文档

- [技术说明](docs/TECHNICAL.zh-CN.md)：修复原理、构建选项、测试命令等更深入的内容。
- [experimental/iphone-duo 分支](https://github.com/rwx9032/KrKr2_iOS_fix/tree/experimental/iphone-duo)：iPhone Duo 显示实验。