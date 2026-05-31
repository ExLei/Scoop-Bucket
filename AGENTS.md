# Scoop-Bucket (exlei)

[Scoop](https://scoop.sh/) bucket —— 只含 JSON，无应用源码。

- **添加:** `scoop bucket add exlei https://github.com/Exlei/Scoop-Bucket`
- **安装:** `scoop install exlei/<清单名>`

## 约定

> 以下规则需人工审查，CI（`bin/lint.ps1`）无法自动检测。lint 覆盖的规则（SPDX 标识符、Hash 大小写、进程终止参数、注册表操作、Invoke-Expression 禁止等）由 CI 自动拦截，此处不再重复。

### 目录联接（Junction）

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
- **pre_uninstall 清理 junction** —— 卸载前删除已创建的目录联接，避免残留空 junction 指向已不存在的目录。
- **post_install 重建 junction** —— Scoop 更新流程：pre_uninstall（删 junction）→ 安装新版 → post_install。需在 post_install 中重新创建 junction，否则更新后数据映射丢失。

### 安装流程

- **注册表协议路径** —— `pre_install` 中注册协议/文件关联（如 `weixin://`）时，禁止用 `if (!(Test-Path $regPath))` 守卫仅写一次，必须每次安装/更新都刷新注册表，否则更新后协议链接指向已删除的旧版本目录。
- **预创建 persist 子目录** —— `pre_install` 阶段 Scoop 尚未创建 persist 子目录（如 `$persist_dir\data`），需手动调用 `New-Item -ItemType Directory -Force` 确保存在：
  ```powershell
  if (!(Test-Path "$persist_dir\data")) {
      New-Item -ItemType Directory -Force -Path "$persist_dir\data" | Out-Null
  }
  ```
- **InnoSetup 解包** —— 下载的安装包为 InnoSetup 格式时，使用 `installer.script` 调用 `Expand-InnoArchive "$dir\$fname" -Removable` 解包。
- **#/dl.7z 重命名** —— 下载 exe 文件但需作为 7z 解压时，URL 末尾加 `#/dl.7z` fragment 触发 Scoop 重命名后自动解压。
- **两阶段解压** —— NSIS 安装包内嵌 `install.7z` 时，先解压外层 NSIS，再对内部 `install.7z` 调用 `Expand-7zipArchive` 二次解压。
- **单文件 persist 占位** —— 对单个文件（而非文件夹）做 `persist` 时，必须在 `pre_install` 中创建空文件占位，否则 Scoop 会将 persist 链接创建为**文件夹链接**导致应用无法读写配置。参考 `bucket\zerx.FluxDown.json`。
- **配置文件占位需有效内容** —— persist 的单个 JSON 配置文件占位应写入 `{}`，不得创建空文件，否则应用可能抛出 `JsonException`。
- **New-Item 加 -Force** —— 创建文件/目录占位时加 `-Force`，避免重装时报错。

### 卸载流程

- **Stop-Process 后 Start-Sleep** —— 终止进程后添加 `Start-Sleep -Milliseconds 1500`，等待文件句柄释放后继续执行，避免后续操作因文件锁定失败。
- **快捷方式显式清理** —— 在 `uninstaller.script` 中清理用户与全局开始菜单残留，校验目标路径指向本应用目录，避免误删同名非 Scoop 快捷方式：
  ```powershell
  $shell = New-Object -ComObject WScript.Shell
  "@(\"$env:APPDATA\", \"$env:ProgramData\") | ForEach-Object {
      $lnk = \"$_\\Microsoft\\Windows\\Start Menu\\Programs\\快捷方式名.lnk\"
      if ((Test-Path $lnk) -and ($shell.CreateShortcut($lnk).TargetPath -like \"$appDir\\*\")) {
          Remove-Item $lnk -Force -ErrorAction SilentlyContinue
      }
  }
  ```
- **post_uninstall 清理注册表** —— 已注册协议/文件关联的清单，在 `post_uninstall` 中删除对应的注册表项。

### 清单结构

- **快捷方式:** 中文显示名，多个词用 `-` 分隔。CLI 工具无需创建 shortcuts。快捷方式名以 `..\\` 开头。
- **checkver 使用 jp** —— 上游 API 返回 JSON 格式时，优先使用 `jp` 字段替代正则提取版本。参考 `bucket\BaiduNetdisk.json`（`$.gui Jia.url`）、`bucket\zerx.FluxDown.json`（`version`）。
- **checkver.github 对象形式** —— 必须用 `{ "github": "..." }` 对象形式，禁止字符串 `"github"` 简写。
- **notes 标注持久化路径** —— 有持久化或 junction 重定向的清单，应在 `notes` 中说明数据存储位置，方便用户了解数据映射关系。
- **PowerShell 调用运算符** —— Scoop JSON 中可执行路径必须用 `"& \"$dir\\程序.exe\""` 格式（`&` 调用），不能仅写路径字符串（不执行）。
- **autoupdate.hash.mode 选择** —— GitHub 源用 `github`，非 GitHub 源用 `download`。
- **autoupdate 禁止硬编码版本** —— `autoupdate` 中 URL 必须使用 `$version` 等变量，不得出现写死的版本号字符串。
- **依赖管理** —— .NET 运行时等外部依赖用 `suggest`，禁止 `depends`。

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
- **所有提交信息必须为中文**
- **Lint:** 更改软件包配置后运行 `pwsh bin/lint.ps1` 检查，覆盖规则详见脚本注释
