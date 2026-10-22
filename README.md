# XP3Compat

让旧版 XP3Player 在新系统上继续顺畅运行。

XP3Compat 修复了 XP3Player 1.3.11 在较新 iOS/iPadOS 下使用弹窗时闪退的问题。新建/删除确认、游戏消息和文字输入等对话框现在可以正常弹出和使用。修复版叫 **XP3Player Fix**，可与原版共存；游戏文件无需修改，游戏和存档需自行复制到修复版中。

## 支持平台

- iPhone / iPad：需要自行签名安装
- Mac (PlayCover)：已签名版本可直接导入使用

## 安装

仓库提供插件源码和打包工具。

1. 准备你自己可用的 XP3Player 1.3.11 IPA
2. 根据技术文档生成本地修复包
3. iPhone / iPad 用户用任意签名工具重签后安装；Mac 用户按技术文档为包签名后导入 PlayCover

详情参考 [技术文档](docs/TECHNICAL.zh-CN.md)。

[Duo 调试分支](https://github.com/rwx9032/KrKr2_iOS_fix/tree/experimental/iphone-duo) 继续调试显示与折叠切换。
