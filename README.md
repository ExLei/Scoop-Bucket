# Exlei Bucket

一个 [Scoop](https://scoop.sh/) 软件仓库（bucket），由 Exlei 维护。

## 使用方法

```powershell
# 添加本仓库
scoop bucket add exlei https://github.com/Exlei/Scoop-Bucket

# 安装软件
scoop install exlei/{软件包ID}
```
## 包含的软件

| 软件 | 版本 | 描述 | 数据目录 |
|------|------|------|---------|
| QQ | 9.9.31.260528 | QQ NT 版本，腾讯的一款聊天通讯工具 | `persist\QQ_Data` |
| 微信 | 4.1.10.27 | 微信，腾讯的一款聊天通讯工具 | `persist\xwechat_files` |
| QuickClipboard | 0.3.2 | 剪贴板管理工具 (便携版)，支持文本/图片/文件历史、截图/OCR | `persist\data` |
| FluxDown | 0.1.42 | Rust 驱动的多协议下载管理器 (便携版) | `persist\flux_down.db` |
| Watt Toolkit | 3.1.0 | Watt Toolkit (原名 Steam++) - 开源跨平台的多功能游戏工具箱，集成网络加速、账号切换、库存管理等功能 | `persist\AppData` |
| Velotype | 0.5.0 | 基于 Rust + GPUI 的原生 Markdown 编辑器（便携版），支持所见即所得与源码编辑双模式 | `persist\data` |
| Bili23-Downloader | 2.00.6 | 开源、免费、跨平台的 B 站视频下载工具，支持多线程加速、音视频分离、弹幕元数据获取、自定义命名与分类 | `persist\data` |
| Context Menu Manager Plus | 1.6.8 | Context Menu Manager Plus - Windows 右键菜单管理工具，支持新菜单监控、传统菜单管理、Win11 新菜单管理、Shell Extension 探测等功能 | `%LocalAppData%\ContextMenuMgr\` |
| ZedG | 1.4.4 | Zed Editor（汉化版），基于 Rust 的高性能代码编辑器本地化版本 | `persist\appdata`, `persist\local` |
| Starlight GUI | 3.0.0-pre3 | 基于 C++/WinRT WinUI3 的 Windows 内核级工具箱，集成任务管理、文件管理、系统监控等功能 | `persist\StarlightGUI.json` |
| FFmpegFreeUI | 5.2 | FFmpeg 在 Windows 上的轻度专业交互外壳，收录大量参数，界面美观，交互友好 | `persist\Presets`, `persist\Plugin` |

## 自动更新

本仓库使用 GitHub Actions 自动检查并更新软件版本，每天执行四次（UTC 00:00、06:00、12:00、18:00）。

## 手动触发更新

如需手动触发更新检查，请在 GitHub 仓库的 Actions 页面找到 "Excavator" 工作流，点击 "Run workflow" 即可。

## 许可证

本仓库采用 [MIT 许可证](./LICENSE)，**允许商业使用**。

本仓库 manifest 所引用的第三方软件，其知识产权归各自的权利人所有，请遵守相应的许可协议。
