# Exlei Bucket

一个 [Scoop](https://scoop.sh/) 软件仓库（bucket），由 Exlei 维护。

## 使用方法

```powershell
# 添加本仓库
scoop bucket add exlei https://github.com/Exlei/Scoop-Bucket

# 安装软件
scoop install exlei/tencent-qq-nt
scoop install exlei/tencent-weixin
scoop install exlei/quickclipboard
scoop install exlei/fluxdown
scoop install exlei/velotype
scoop install exlei/zedg
```

## 包含的软件

| 软件 | 安装命令 | 版本 | 描述 |
|------|---------|------|------|
| QQ | `scoop install exlei/tencent-qq-nt` | 9.9.31.260528 | QQ NT 版本，腾讯的一款聊天通讯工具 |
| 微信 | `scoop install exlei/tencent-weixin` | 4.1.10.24 | 微信，腾讯的一款聊天通讯工具 |
| QuickClipboard | `scoop install exlei/quickclipboard` | 0.3.2 | 剪贴板管理工具 (便携版)，支持文本/图片/文件历史、截图/OCR |
| FluxDown | `scoop install exlei/fluxdown` | 0.1.42 | Rust 驱动的多协议下载管理器 (便携版) |
| Velotype | `scoop install exlei/velotype` | 0.5.0 | 基于 Rust + GPUI 的原生 Markdown 编辑器（便携版），支持所见即所得与源码编辑双模式 |
| ZedG | `scoop install exlei/zedg` | 1.4.2 | Zed Editor（汉化版），基于 Rust 的高性能代码编辑器本地化版本 |

## 自动更新

本仓库使用 GitHub Actions 自动检查并更新软件版本，每天执行两次（UTC 02:00 和 14:00）。

## 手动触发更新

如需手动触发更新检查，请在 GitHub 仓库的 Actions 页面找到 "Excavator" 工作流，点击 "Run workflow" 即可。

## 许可证

本仓库采用 [MIT 许可证](./LICENSE)，**允许商业使用**。

本仓库 manifest 所引用的第三方软件，其知识产权归各自的权利人所有，请遵守相应的许可协议。
