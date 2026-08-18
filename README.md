# Exlei Bucket

[![GitHub Actions CI Status](https://img.shields.io/github/actions/workflow/status/Exlei/Scoop-Bucket/ci.yml?style=flat-square&logo=github&label=Tests)](https://github.com/Exlei/Scoop-Bucket/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/Exlei/Scoop-Bucket.svg?style=flat-square)](./LICENSE)
[![Target Windows 10/11](https://img.shields.io/badge/Target-Windows%2010%2F11-0067B8.svg?style=flat-square)](https://www.microsoft.com/en-us/windows)
[![Manifest Count](https://img.shields.io/github/directory-file-count/Exlei/Scoop-Bucket/bucket?type=file&extension=json&style=flat-square&logo=JSON&label=Manifests)](https://github.com/Exlei/Scoop-Bucket/tree/master/bucket)

一个 [Scoop](https://scoop.sh/) 软件仓库（bucket），由 Exlei 维护。

## 使用方法

```powershell
# 添加本仓库
scoop bucket add exlei https://github.com/Exlei/Scoop-Bucket

# 安装软件
scoop install exlei/{软件包ID}
```
## 包含的软件

| 软件 | 描述 | 数据目录 |
|------|------|---------|
| QQ | QQ NT 版本，腾讯的一款聊天通讯工具 | `persist\QQ_Data` |
| 微信 | 微信，腾讯的一款聊天通讯工具 | `persist\xwechat_files` |
| Codex++ | Codex++ - OpenAI Codex / ChatGPT 桌面应用的外部启动器与管理工具，支持供应商切换、协议转换、会话管理与界面增强 | `%APPDATA%\Codex++` |
| QuickClipboard | 剪贴板管理工具 (便携版)，支持文本/图片/文件历史、截图/OCR | `persist\data` |
| FluxDown | Rust 驱动的多协议下载管理器（便携版，开源 AGPL-3.0，支持 x64/arm64）| `persist\flux_down.db等` |
| FluxDown Preview | FluxDown 预览版（pre-release），抢先体验最新功能（便携版，开源 AGPL-3.0，支持 x64/arm64）| `persist\portable_data` |
| FluxDown CLI | FluxDown 命令行客户端，远程管理下载任务（支持 x64/arm64）| - |
| Watt Toolkit | Watt Toolkit (原名 Steam++) - 开源跨平台的多功能游戏工具箱，集成网络加速、账号切换、库存管理等功能 | `persist\AppData` |
| Velotype | 基于 Rust + GPUI 的原生 Markdown 编辑器（便携版），支持所见即所得与源码编辑双模式 | `persist\data` |
| Bili23-Downloader | 开源、免费、跨平台的 B 站视频下载工具，支持多线程加速、音视频分离、弹幕元数据获取、自定义命名与分类 | `persist\data` |
| BootICE | BootICE - USB启动盘制作/引导维护工具 MBR/PBR编辑及BCD配置管理 | - |
| Context Menu Manager Plus | Context Menu Manager Plus - Windows 右键菜单管理工具，支持新菜单监控、传统菜单管理、Win11 新菜单管理、Shell Extension 探测等功能 | `%ProgramData%\ContextMenuMgr\` |
| mpv-lazy | 全格式视频播放懒人包，基于 mpv 播放器集成大量配置和脚本 | - |
| Motrix Next | 全功能下载管理器重构版，支持 HTTP/FTP/SFTP/BitTorrent/Magnet 等多种协议 | `persist\LocalAppData` |
| HEU KMS Activator | KMS/OEM 智能激活工具，支持 Windows/Office 全系列版本一键激活 | - |
| ZedG | Zed Editor（汉化版），基于 Rust 的高性能代码编辑器本地化版本 | `persist\appdata`, `persist\local` |
| Starlight GUI | 基于 C++/WinRT WinUI3 的 Windows 内核级工具箱，集成任务管理、文件管理、系统监控等功能 | `persist\StarlightGUI.json` |
| Task Explorer | 高级任务管理器，深度洞察进程行为，支持内核驱动级监控 | `persist\TaskExplorer.ini` |
| FFmpegFreeUI | FFmpeg 在 Windows 上的轻度专业交互外壳，收录大量参数，界面美观，交互友好 | `persist\Preset`, `persist\Plugin` |
| WPS Office | 一站式办公集成平台，免费无广告，支持 AI 办公 | - |
| XDown | 免费无广告的专业文件下载与分享工具，支持 HTTP/BitTorrent/FTP/Magnet 等多种协议 | `persist\LocalData`, `persist\RoamingData`, `persist\LocalDotData` |
| Game Cheats Manager | 游戏修改器管理工具，集成多来源修改器搜索、下载、自动更新等功能 | `persist\data` |
| Game Save Manager | 游戏存档管理工具，支持自动检测、备份、还原游戏存档，集成 PCGamingWiki 数据库 | `persist\data` |
| 123云盘 | 123云盘，一款空间大、不限速、专注大文件传输分发的云存储服务产品 | `persist\AppData` |
| 阿里云盘 | 阿里云盘，一款速度快、不打扰、够安全、易于分享的网盘 | `persist\AppData` |
| 夸克 | 夸克浏览器，学习、工作、生活的高效拍档 | `persist\LocalAppData`, `persist\AppData` |
| 百度网盘 | 百度网盘，百度的一款云存储客户端 | `persist\BaiduNetdisk_Data` |
| HMCL | HMCL - 多功能、跨平台的 Minecraft 启动器 | `persist\data` |
| PCL2-CE | PCL 社区版 - Minecraft Java 版启动器，基于 PCL 开源代码二次开发的社区版本 | `persist\data` |
| 图吧工具箱 | DIY 爱好者的硬件检测工具合集，集成 CPU/显卡/内存/硬盘检测、烤机、信息查询等 80+ 工具 | `persist\Config.ini`, `persist\skin\user` |

## 自动更新

本仓库使用 GitHub Actions 自动检查并更新软件版本，每天执行四次（UTC 00:00、06:00、12:00、18:00）。

## 手动触发更新

如需手动触发更新检查，请在 GitHub 仓库的 Actions 页面找到 "Excavator" 工作流，点击 "Run workflow" 即可。

## 许可证

本仓库采用 [MIT 许可证](./LICENSE)，**允许商业使用**。

本仓库 manifest 所引用的第三方软件，其知识产权归各自的权利人所有，请遵守相应的许可协议。
