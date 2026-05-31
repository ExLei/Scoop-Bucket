# Scoop-Bucket (exlei)

[Scoop](https://scoop.sh/) bucket —— 只含 JSON，无应用源码。

- **添加:** `scoop bucket add exlei https://github.com/Exlei/Scoop-Bucket`
- **安装:** `scoop install exlei/<清单名>`

## 约定

### 安装与更新行为

- **目录联接目标路径** —— 在 `pre_install` 中创建目录联接 (junction) 指向持久化数据时，目标路径必须使用 `$persist_dir\<子目录>`（Scoop persist 稳定路径），不得使用 `$dir\<子目录>`（版本化路径，更新后即失效）。参考 `bucket\Tencent.QQ.NT.json` 的 `$persistDir` 用法。
- **目录联接先删后建** —— 每次安装/更新时，对已有 junction 先用 `[System.IO.Directory]::Delete()` 删除（该 API 仅删重解析点，不穿透到目标数据），再重建 junction。禁止用 `New-Item -ItemType Junction -Force` 尝试覆盖（PowerShell 5.1 上不可靠），也禁止用 `if (!(Test-Path ...))` 守卫跳过（Scoop 目录迁移等场景下 junction 可能指向错误目标）。
  ```powershell
  # ✅ 正确：先删后建
  if (Test-Path $junction) {
      if ((Get-Item $junction).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
          [System.IO.Directory]::Delete($junction)
      } else {
          # 真实目录 → 迁移数据到 persist
          Move-Item $junction $persistTarget -Force
      }
  }
  New-Item -ItemType Junction -Path $junction -Target $persistTarget | Out-Null
  ```
- **Junction 检测与清理** —— 判断 junction 用 `Attributes -band [System.IO.FileAttributes]::ReparsePoint`（禁止 `.LinkType`，PS 5.1 不支持）；删除 junction 用 `[System.IO.Directory]::Delete()`（禁止 `Remove-Item -Recurse`，会穿透删除目标数据）。

### 路径与注册表

- **用户目录路径** —— 涉及用户文档目录（如 `Documents\xxx`）时，必须使用 `[Environment]::GetFolderPath('MyDocuments')` 获取真实路径，禁止硬编码 `$home\Documents\`。OneDrive 文件夹备份、企业 GPO 文件夹重定向等场景下，`$home\Documents` 可能不存在或指向错误位置。
- **注册表协议路径** —— 在 `pre_install` 中注册协议/文件关联（如 `weixin://`）时，注册表写入的路径必须使用 `$(Split-Path $dir -Parent)\current\<程序.exe>`（Scoop `current` 符号链接），不得使用 `"$dir\<程序.exe>"`（版本化路径，更新后即失效）。同时禁止用 `if (!(Test-Path $regPath))` 守卫仅写一次，必须每次安装/更新都刷新注册表，否则更新后协议链接指向已删除的旧版本目录。

### 卸载流程

- **GUI 应用必须终结进程** —— 有 shortcuts 须 Stop-Process
- **进程终止规范** —— 须 -Force -EA SilentlyContinue，-Name 禁 .exe
- **uninstaller.script 优先** —— 进程终止须在 uninstaller.script
- **快捷方式显式清理** —— 须在 `uninstaller.script` 中清理用户与全局开始菜单残留 因为**快捷方式:** 名以 `..\\` 开头，须校验目标
- **卸载程序存在性检查** —— 调用应用自带的卸载程序（如 `Uninstall.exe`）前，必须用 `Test-Path` 检查文件是否存在，避免脚本因文件缺失中断：
  ```powershell
  if (Test-Path "$dir\\Uninstall.exe") {
      & "$dir\\Uninstall.exe"
  }
  ```

### 其他

- **快捷方式:** 名以 `..\\` 开头，中文显示名，用 `-` 分隔。CLI 工具无需创建。
- **许可证标识符:** 禁用弃用 SPDX 标识符
- **Hash 值小写:** 哈希值必须小写
- **GitHub Releases 哈希:** checkver.github 须 hash.mode=github
- **checkver.github 显式指定:** 须用对象形式
- **autoupdate 禁止硬编码版本:** `autoupdate` 中的 URL 和正则字段必须使用 `$version`、`$matchHead`、`$matchBuild` 等变量，不得出现写死的版本号字符串。
- **SourceForge URL 后缀:** 使用 SourceForge 下载源时，URL 必须以 `/download` 结尾，否则返回 HTML 页面而非二进制文件。
- **依赖管理:** .NET 依赖用 suggest 非 depends

### 脚本安全

- **PowerShell 调用运算符:** Scoop JSON 中可执行路径必须用 `"& \"$dir\\程序.exe\""` 格式（`&` 调用），不能仅写路径字符串（不执行）。
- **注册表操作:** New-ItemProperty 须 -Force，Remove-ItemProperty 须 -EA SilentlyContinue
- **New-Item 加 -Force:** 创建文件占位时加 `-Force`，避免重装时报错。
- **配置文件占位需有效内容:** persist 的单个 JSON 配置文件占位应写入 `{}`，不得创建空文件，否则应用可能抛出 `JsonException`。
- **禁止 Invoke-Expression:** 调用脚本文件应使用 `&` 运算符（如 `& "$dir\\script.ps1"`），不得使用 `Invoke-Expression`，避免字符串拼接导致的注入风险。

## CI

- **Update:** UTC 00:00/06:00/12:00/18:00 自动更新，`SKIP_UPDATED: '1'`，Actions 可手动触发。
- **验证:** 所有清单 JSON 语法校验：
  ```powershell
  Get-ChildItem bucket/*.json | ForEach-Object { $_ | Get-Content -Raw | ConvertFrom-Json }
  ```

## 约束

- **不提交** **`bin/`**（`.gitignore` 已排除，仅白名单例外）
- **没有** **`opencode.json`**，项目配置在 `.agents/skills/`
- **只需** **`GITHUB_TOKEN`**，无需其他密钥
- **README 与清单同步** —— 新增/删除/更新软件包配置时，必须同步修改 `README.md` 中的软件表格（安装命令、版本、描述）
- **文件持久化需空文件占位** —— 对单个文件（而非文件夹）做 `persist` 时，必须在 `pre_install` 中创建空文件占位，否则 Scoop 会将 persist 链接创建为**文件夹链接**导致应用无法读写配置。参考 `bucket\zerx.FluxDown.json` 的模式
- **所有提交信息必须为中文**
- **Lint:** 更改软件包配置后运行 `pwsh bin/lint.ps1` 检查，覆盖规则详见脚本注释

