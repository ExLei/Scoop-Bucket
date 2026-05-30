#Requires -Version 7.0
<#
.SYNOPSIS
    Scoop Bucket 清单验证脚本 —— 检查 bucket/*.json 是否符合 Scoop Schema 与 AGENTS.md 约定

.DESCRIPTION
    本脚本实现两层验证：
    1. Scoop Schema 结构检查 —— 基于 ScoopInstaller/Scoop 的 schema.json 定义，
       验证清单字段结构、格式、类型是否符合规范
    2. AGENTS.md 约定检查 —— 验证项目特定约定（SPDX 标识符、进程终止规范等）

    只包含可通过纯字段/模式匹配可靠检测的规则，避免正则过于粗糙导致误报。
    中/高风险规则（如 Junction 先删后建、注册表协议路径等）需上下文语义分析，
    暂不纳入，待后续迭代。

.PARAMETER CI
    CI 模式：输出 GitHub Actions 注解格式（::error / ::warning / ::notice），
    使错误/警告直接标注在 PR 对应文件上。

.EXAMPLE
    pwsh bin/lint.ps1              # 本地运行，彩色控制台输出
    pwsh bin/lint.ps1 -CI          # CI 模式，GitHub Actions 注解格式

.NOTES
    Schema 参考：https://github.com/ScoopInstaller/Scoop/blob/master/schema.json
    约定文档：AGENTS.md「约定」章节
#>

param(
    [switch]$CI
)

$ErrorActionPreference = 'Continue'
$hasError = $false
$warningCount = 0
$errorCount = 0

# ─────────────────────────── 辅助函数 ───────────────────────────

function Write-Result {
    param(
        [ValidateSet('error', 'warning', 'info')]
        [string]$Level,
        [string]$File,
        [string]$Message
    )

    switch ($Level) {
        'error' {
            $script:hasError = $true
            $script:errorCount++
            if ($CI) {
                Write-Host "::error file=$File::$Message"
            } else {
                Write-Host "  ✗ $Message" -ForegroundColor Red
            }
        }
        'warning' {
            $script:warningCount++
            if ($CI) {
                Write-Host "::warning file=$File::$Message"
            } else {
                Write-Host "  ⚠ $Message" -ForegroundColor Yellow
            }
        }
        'info' {
            if ($CI) {
                Write-Host "::notice file=$File::$Message"
            } else {
                Write-Host "  ℹ $Message" -ForegroundColor Cyan
            }
        }
    }
}

# ─────────────────────────── Schema 合法字段定义 ───────────────────────────
# 来源：ScoopInstaller/Scoop schema.json "properties" + "additionalProperties": false

$ValidTopLevelFields = @(
    '$schema', '_comment', '##',
    'architecture', 'autoupdate', 'bin', 'persist', 'checkver',
    'cookie', 'depends', 'description', 'env_add_path', 'env_set',
    'extract_dir', 'extract_to', 'hash', 'homepage', 'innosetup',
    'installer', 'license', 'notes',
    'post_install', 'post_uninstall', 'pre_install', 'pre_uninstall',
    'psmodule', 'shortcuts', 'suggest', 'uninstaller', 'url', 'version'
)

$ValidArchSubFields = @(
    'bin', 'checkver', 'env_add_path', 'env_set', 'extract_dir',
    'hash', 'installer', 'post_install', 'post_uninstall',
    'pre_install', 'pre_uninstall', 'shortcuts', 'uninstaller', 'url'
)

# ─────────────────────────── 弃用 SPDX 标识符列表 ───────────────────────────

$DeprecatedSpdx = @{
    'GPL-2.0'   = 'GPL-2.0-only'
    'GPL-3.0'   = 'GPL-3.0-only'
    'LGPL-2.1'  = 'LGPL-2.1-only'
    'LGPL-3.0'  = 'LGPL-3.0-only'
    'AGPL-3.0'  = 'AGPL-3.0-only'
    'GFDL-1.3'  = 'GFDL-1.3-only'
    'GPL-2.0+'  = 'GPL-2.0-or-later'
    'GPL-3.0+'  = 'GPL-3.0-or-later'
    'LGPL-2.1+' = 'LGPL-2.1-or-later'
    'LGPL-3.0+' = 'LGPL-3.0-or-later'
    'AGPL-3.0+' = 'AGPL-3.0-or-later'
    'GFDL-1.3+' = 'GFDL-1.3-or-later'
    'EUPL-1.1'  = 'EUPL-1.2'
    'Nunit'     = 'Nunit-2.6.1'
}

# ─────────────────────────── Hash 格式校验 ───────────────────────────
# Schema pattern: ^([a-fA-F0-9]{64}|(sha1|sha256|sha512|md5):([a-fA-F0-9]{32}|[a-fA-F0-9]{40}|[a-fA-F0-9]{64}|[a-fA-F0-9]{128}))$

$HashPattern = '^([a-fA-F0-9]{64}|(sha1|sha256|sha512|md5):([a-fA-F0-9]{32}|[a-fA-F0-9]{40}|[a-fA-F0-9]{64}|[a-fA-F0-9]{128}))$'

function Test-HashFormat {
    param([object]$Hash)

    if ($null -eq $Hash) { return $true }
    if ($Hash -is [string]) {
        return $Hash -eq '0' -or $Hash -match $HashPattern
    }
    if ($Hash -is [array]) {
        foreach ($h in $Hash) {
            if ($h -ne '0' -and $h -notmatch $HashPattern) { return $false }
        }
        return $true
    }
    return $true
}

# ─────────────────────────── 脚本行提取 ───────────────────────────

function Get-ScriptLines {
    param([psobject]$Json)

    $lines = @()
    foreach ($prop in @('pre_install', 'post_install', 'pre_uninstall', 'post_uninstall')) {
        if ($Json.PSObject.Properties.Name -contains $prop) {
            $val = $Json.$prop
            if ($val -is [string]) { $lines += $val }
            elseif ($val -is [array]) { $lines += $val }
        }
    }
    if ($Json.PSObject.Properties.Name -contains 'uninstaller' -and
        $Json.uninstaller.PSObject.Properties.Name -contains 'script') {
        $val = $Json.uninstaller.script
        if ($val -is [string]) { $lines += $val }
        elseif ($val -is [array]) { $lines += $val }
    }
    return $lines
}

# ─────────────────────────── SourceForge URL 检查 ───────────────────────────

function Test-SourceForgeUrl {
    param([object]$Url)

    if ($null -eq $Url) { return $true }
    if ($Url -is [string]) {
        if ($Url -match 'sourceforge' -and $Url -notmatch '/download') {
            return $false
        }
    } elseif ($Url -is [array]) {
        foreach ($u in $Url) {
            if ($u -match 'sourceforge' -and $u -notmatch '/download') {
                return $false
            }
        }
    }
    return $true
}

# ─────────────────────────── 主检查逻辑 ───────────────────────────

$files = Get-ChildItem bucket/*.json
if ($files.Count -eq 0) {
    Write-Host "::warning::Bucket 为空 - 未找到清单文件"
    exit 0
}

foreach ($file in $files) {
    $name = $file.Name
    if (-not $CI) {
        Write-Host "检查: $name" -NoNewline
    }

    # ── CRLF 换行符 ──
    # 约定（AGENTS.md）：JSON 清单文件必须使用 CRLF 换行符，禁止 LF
    # 原因：Scoop 社区规范，Windows 环境下 CRLF 是标准行尾
    # 检查方式：读取原始字节，检测是否存在未被 \r 前置的 \n
    # 误报风险：极低。二进制级别的行尾检测
    $rawContent = [System.IO.File]::ReadAllText($file.FullName)
    if ($rawContent -match '(?<!\r)\n') {
        Write-Result -Level error -File $file.FullName -Message "JSON 文件必须使用 CRLF 换行符（AGENTS.md 约定）"
    }

    # ── JSON 语法解析 ──
    try {
        $json = Get-Content $file.FullName -Raw | ConvertFrom-Json
    } catch {
        Write-Result -Level error -File $file.FullName -Message "JSON 解析失败: $($_.Exception.Message)"
        if (-not $CI) { Write-Host '' }
        continue
    }

    # ══════════════════════════════════════════════════════════════
    #  Schema 结构检查
    # ══════════════════════════════════════════════════════════════

    # ── 必填顶层字段 ──
    # Schema: "required": ["version", "homepage", "license"]
    # 本项目额外要求 description 和 architecture
    $required = @('version', 'description', 'homepage', 'architecture')
    $missing = $required | Where-Object { $json.PSObject.Properties.Name -notcontains $_ }
    if ($missing) {
        Write-Result -Level error -File $file.FullName -Message "缺少必填字段: $($missing -join ', ')"
        if (-not $CI) { Write-Host '' }
        continue
    }

    # ── 未知顶层字段 ──
    # Schema: "additionalProperties": false
    # 原因：拼写错误的字段名会被 Scoop 静默忽略，导致配置不生效且难以排查
    # 检查方式：顶层属性名不在 schema.json properties 列表中
    # 误报风险：极低。合法字段列表来自官方 schema.json
    $unknownFields = $json.PSObject.Properties.Name | Where-Object { $_ -notin $ValidTopLevelFields }
    if ($unknownFields) {
        Write-Result -Level error -File $file.FullName -Message "存在未知顶层字段: $($unknownFields -join ', ')（参考 Scoop schema.json）"
    }

    # ── version 格式 ──
    # Schema: "pattern": "^[\w\.\-+_]+$"
    # 原因：Scoop 使用此正则验证版本号，不符合的版本号会导致安装/更新失败
    # 检查方式：匹配 schema.json 中定义的 version 正则
    # 误报风险：极低。正则来自官方 schema
    if ([string]::IsNullOrWhiteSpace($json.version) -or $json.version -eq '0') {
        Write-Result -Level error -File $file.FullName -Message "version 无效: '$($json.version)'"
    } elseif ($json.version -notmatch '^[\w\.\-+_]+$') {
        Write-Result -Level error -File $file.FullName -Message "version 格式非法: '$($json.version)'（应匹配 ^[\w\.\-+_]+$）"
    }

    # ── description 非空 ──
    if ([string]::IsNullOrWhiteSpace($json.description)) {
        Write-Result -Level error -File $file.FullName -Message "description 为空"
    }

    # ── homepage URL 格式 ──
    # Schema: "format": "uri"
    if ($json.homepage -notmatch '^https?://') {
        Write-Result -Level warning -File $file.FullName -Message "homepage 非 http(s) 开头: $($json.homepage)"
    }

    # ── license 必填 ──
    # Schema: "required": ["version", "homepage", "license"]
    # 原因：Scoop schema 将 license 列为必填字段，缺失会导致 Schema 验证失败
    # 检查方式：license 字段不存在
    # 误报风险：极低。字段存在性检查
    if (-not $json.license) {
        Write-Result -Level error -File $file.FullName -Message "缺少 license 字段（Scoop Schema 必填）"
    }

    # ── autoupdate 与 checkver 配对 ──
    if ($json.autoupdate -and -not $json.checkver) {
        Write-Result -Level error -File $file.FullName -Message "有 autoupdate 但缺少 checkver"
    }

    # ── 架构名合法性 + 未知架构子字段 ──
    # Schema: architecture.additionalProperties = false
    $validArchNames = @('64bit', '32bit', 'arm64')
    foreach ($arch in $json.architecture.PSObject.Properties) {
        $archName = $arch.Name
        if ($archName -notin $validArchNames) {
            Write-Result -Level error -File $file.FullName -Message "架构名 '$archName' 非法（应为 64bit / 32bit / arm64）"
            continue
        }

        $cfg = $arch.Value

        # 未知架构子字段
        $unknownArchFields = $cfg.PSObject.Properties.Name | Where-Object { $_ -notin $ValidArchSubFields }
        if ($unknownArchFields) {
            Write-Result -Level error -File $file.FullName -Message "$archName 存在未知字段: $($unknownArchFields -join ', ')"
        }

        # url 必须存在
        if (-not $cfg.url) {
            Write-Result -Level error -File $file.FullName -Message "$archName 缺少 url"
            continue
        }

        # 下载 URL 必须为 HTTPS
        if ($cfg.url -is [string] -and $cfg.url -notmatch '^https://') {
            Write-Result -Level error -File $file.FullName -Message "$archName url 必须以 https:// 开头"
        } elseif ($cfg.url -is [array]) {
            foreach ($u in $cfg.url) {
                if ($u -notmatch '^https://') {
                    Write-Result -Level error -File $file.FullName -Message "$archName url 必须以 https:// 开头: $u"
                }
            }
        }

        # hash 格式检查（Schema 精确模式）
        if ($cfg.PSObject.Properties.Name -contains 'hash' -and $null -ne $cfg.hash) {
            if (-not (Test-HashFormat $cfg.hash)) {
                Write-Result -Level error -File $file.FullName -Message "$archName hash 格式非法（应为 SHA256 十六进制64位 或 sha256:xxx 等前缀格式）"
            }
        }
    }

    # ── 顶层 hash 格式检查 ──
    if ($json.PSObject.Properties.Name -contains 'hash' -and $null -ne $json.hash) {
        if (-not (Test-HashFormat $json.hash)) {
            Write-Result -Level error -File $file.FullName -Message "顶层 hash 格式非法（应为 SHA256 十六进制64位 或 sha256:xxx 等前缀格式）"
        }
    }

    # ── shortcuts 格式 ──
    # Schema: items.minItems=2, maxItems=4
    # 原因：shortcuts 条目格式为 [程序路径, 快捷方式名(, 启动目录, 图标)]，
    #       少于2项缺少必要信息，多于4项超出 Scoop 解析范围
    # 检查方式：遍历 shortcuts 数组，验证每个条目的元素数量
    # 误报风险：极低。Scoop 快捷方式格式是固定的
    if ($json.shortcuts) {
        foreach ($shortcut in $json.shortcuts) {
            if ($shortcut.Count -lt 2 -or $shortcut.Count -gt 4) {
                Write-Result -Level error -File $file.FullName -Message "shortcuts 条目必须有 2-4 个元素（当前 $($shortcut.Count) 个）: [$($shortcut -join ', ')]"
            }
        }
    }

    # ── uninstaller 结构 ──
    # Schema: "oneOf": [{"required": ["file"]}, {"required": ["script"]}]
    # 原因：uninstaller 必须指定 file（可执行文件卸载）或 script（脚本卸载）之一，
    #       两者都无则 Scoop 不知道如何卸载，两者都有则语义冲突
    # 检查方式：uninstaller 存在时，验证 file/script 二选一
    # 误报风险：极低。Schema oneOf 约束
    if ($json.PSObject.Properties.Name -contains 'uninstaller') {
        $hasFile = $json.uninstaller.PSObject.Properties.Name -contains 'file'
        $hasScript = $json.uninstaller.PSObject.Properties.Name -contains 'script'
        if (-not $hasFile -and -not $hasScript) {
            Write-Result -Level error -File $file.FullName -Message "uninstaller 必须包含 file 或 script"
        }
        if ($hasFile -and $hasScript) {
            Write-Result -Level error -File $file.FullName -Message "uninstaller 的 file 和 script 互斥，只能指定一个"
        }
    }

    # ══════════════════════════════════════════════════════════════
    #  AGENTS.md 约定检查
    # ══════════════════════════════════════════════════════════════

    # ── Hash 值小写 ──
    # 约定（AGENTS.md）：SHA256 哈希值必须使用小写字母
    foreach ($arch in $json.architecture.PSObject.Properties) {
        $cfg = $arch.Value
        if ($cfg.PSObject.Properties.Name -contains 'hash' -and $cfg.hash -is [string] -and $cfg.hash -ne '0') {
            if ($cfg.hash -cmatch '[A-F]') {
                Write-Result -Level error -File $file.FullName -Message "$($arch.Name) hash 含大写字母，必须全部小写: $($cfg.hash)"
            }
        }
        if ($cfg.hash -is [array]) {
            foreach ($h in $cfg.hash) {
                if ($h -is [string] -and $h -ne '0' -and $h -cmatch '[A-F]') {
                    Write-Result -Level error -File $file.FullName -Message "$($arch.Name) hash 含大写字母，必须全部小写: $h"
                }
            }
        }
    }

    # ── GitHub Releases 哈希 ──
    # 约定（AGENTS.md）：拥有 GitHub 发行版的软件包，autoupdate 中必须使用 hash.mode=github
    if ($json.checkver -and $json.checkver.PSObject.Properties.Name -contains 'github') {
        if ($json.autoupdate) {
            if ($json.autoupdate.PSObject.Properties.Name -contains 'hash' -and
                $json.autoupdate.hash.PSObject.Properties.Name -contains 'mode') {
                if ($json.autoupdate.hash.mode -ne 'github') {
                    Write-Result -Level error -File $file.FullName -Message "checkver.github 存在但 autoupdate.hash.mode 为 '$($json.autoupdate.hash.mode)'，应为 'github'"
                }
            } else {
                Write-Result -Level warning -File $file.FullName -Message "checkver.github 存在但 autoupdate 未配置 hash.mode，应为 'github'"
            }
        }
    }

    # ── checkver.github 显式指定 ──
    # 约定（AGENTS.md）：必须用 checkver: {github: "..."} 对象形式
    if ($json.checkver -is [string] -and $json.checkver -eq 'github') {
        if ($json.homepage -notmatch '^https://github\.com/') {
            Write-Result -Level error -File $file.FullName -Message "checkver 使用简写 'github' 但 homepage 非 GitHub URL，必须用对象形式 {github: '...'}"
        } else {
            Write-Result -Level warning -File $file.FullName -Message "checkver 使用简写 'github'，建议改为对象形式 {github: '$($json.homepage)'}"
        }
    }

    # ── 依赖管理 ──
    # 约定（AGENTS.md）：对 .NET 运行时等外部依赖，优先使用 suggest 而非 depends
    if ($json.depends) {
        $dotnetPatterns = @('dotnet', '.NETRuntime', 'netcore', 'net-framework', 'dotnet-desktop')
        foreach ($dep in $json.depends) {
            foreach ($pat in $dotnetPatterns) {
                if ($dep -match $pat) {
                    Write-Result -Level warning -File $file.FullName -Message "depends 中含 .NET 依赖 '$dep'，建议改用 suggest（避免用户已有运行时重复安装）"
                }
            }
        }
    }

    # ── 许可证标识符 ──
    # 约定（AGENTS.md）：使用正确的 SPDX 标识符，禁止弃用形式
    if ($json.license) {
        $ident = if ($json.license -is [string]) { $json.license } else { $json.license.identifier }
        if ($ident -and $DeprecatedSpdx.ContainsKey($ident)) {
            Write-Result -Level error -File $file.FullName -Message "license.identifier '$ident' 已弃用，应使用 '$($DeprecatedSpdx[$ident])'"
        }
    }

    # ── SourceForge URL 后缀 ──
    # 约定（AGENTS.md）：使用 SourceForge 下载源时，URL 必须以 /download 结尾
    # 原因：不带 /download 后缀的 SourceForge URL 返回 HTML 页面而非二进制文件，
    #       Scoop 下载到的将是网页而非安装包
    # 检查方式：URL 含 sourceforge 且不含 /download
    # 误报风险：极低。SourceForge 的 /download 是固定的下载触发路径
    foreach ($arch in $json.architecture.PSObject.Properties) {
        if (-not (Test-SourceForgeUrl $arch.Value.url)) {
            Write-Result -Level error -File $file.FullName -Message "$($arch.Name) SourceForge URL 缺少 /download 后缀（AGENTS.md 约定）"
        }
    }
    if ($json.PSObject.Properties.Name -contains 'url') {
        if (-not (Test-SourceForgeUrl $json.url)) {
            Write-Result -Level error -File $file.FullName -Message "顶层 SourceForge URL 缺少 /download 后缀（AGENTS.md 约定）"
        }
    }

    # ── autoupdate 禁止硬编码版本 ──
    # 约定（AGENTS.md）：autoupdate 中的 URL 必须使用 $version 等变量，不得出现写死的版本号
    # 原因：autoupdate 的目的是自动生成新版本的 URL，硬编码版本号意味着更新后 URL 不会变化
    # 检查方式：autoupdate URL 中出现 X.Y.Z 格式且不含 $ 变量
    # 误报风险：低。autoupdate URL 不含 $ 变量几乎一定是错误
    if ($json.autoupdate) {
        $autoupdateUrls = @()
        if ($json.autoupdate.url) {
            if ($json.autoupdate.url -is [string]) { $autoupdateUrls += $json.autoupdate.url }
            elseif ($json.autoupdate.url -is [array]) { $autoupdateUrls += $json.autoupdate.url }
        }
        if ($json.autoupdate.architecture) {
            foreach ($arch in $json.autoupdate.architecture.PSObject.Properties) {
                if ($arch.Value.url) {
                    if ($arch.Value.url -is [string]) { $autoupdateUrls += $arch.Value.url }
                    elseif ($arch.Value.url -is [array]) { $autoupdateUrls += $arch.Value.url }
                }
            }
        }
        foreach ($aurl in $autoupdateUrls) {
            if ($aurl -match '\d+\.\d+\.\d+' -and $aurl -notmatch '\$') {
                Write-Result -Level error -File $file.FullName -Message "autoupdate URL 含硬编码版本号: $aurl（应使用 `$version 等变量）"
            }
        }
    }

    # ── autoupdate hash.mode 合法值 ──
    # Schema: hash.mode enum ["download","extract","json","xpath","rdf","metalink","fosshub","sourceforge"]
    # 原因：Scoop 仅支持这些 hash 获取模式，其他值通常是拼写错误
    # 检查方式：hash.mode 不在 Schema 枚举列表中 → 警告
    # 误报风险：极低。Schema 枚举值是固定的
    $validHashModes = @('download', 'extract', 'json', 'xpath', 'rdf', 'metalink', 'fosshub', 'sourceforge', 'github')
    if ($json.autoupdate -and $json.autoupdate.hash -and $json.autoupdate.hash.mode) {
        if ($json.autoupdate.hash.mode -notin $validHashModes) {
            Write-Result -Level warning -File $file.FullName -Message "autoupdate.hash.mode 非常规值: $($json.autoupdate.hash.mode)（期望 $($validHashModes -join '/')）"
        }
    }

    # ── 收集脚本行（后续多条规则共用） ──
    $scriptLines = Get-ScriptLines $json

    # ── 进程终止规范 ──
    # 约定（AGENTS.md）：Stop-Process 必须使用 -Force -ErrorAction SilentlyContinue，-Name 禁止加 .exe
    foreach ($line in $scriptLines) {
        if ($line -match 'Stop-Process') {
            if ($line -notmatch '-Force') {
                Write-Result -Level error -File $file.FullName -Message "Stop-Process 缺少 -Force 参数: $line"
            }
            if ($line -notmatch '-ErrorAction\s+SilentlyContinue') {
                Write-Result -Level error -File $file.FullName -Message "Stop-Process 缺少 -ErrorAction SilentlyContinue: $line"
            }
            if ($line -match '-Name\s+.*\.exe') {
                Write-Result -Level error -File $file.FullName -Message "Stop-Process -Name 含 .exe 后缀（PS -Name 不匹配 .exe）: $line"
            }
        }
    }

    # ── GUI 应用必须终结进程 ──
    # 约定（AGENTS.md）：凡有 shortcuts 的 GUI 应用，必须在 uninstaller.script 中终止对应进程
    if ($json.shortcuts -and $json.shortcuts.Count -gt 0) {
        $uninstallerScript = $null
        if ($json.PSObject.Properties.Name -contains 'uninstaller' -and
            $json.uninstaller.PSObject.Properties.Name -contains 'script') {
            $uninstallerScript = $json.uninstaller.script
            if ($uninstallerScript -is [string]) { $uninstallerScript = @($uninstallerScript) }
        }
        $hasStopProcess = $false
        if ($uninstallerScript) {
            foreach ($line in $uninstallerScript) {
                if ($line -match 'Stop-Process') { $hasStopProcess = $true; break }
            }
        }
        if (-not $hasStopProcess) {
            Write-Result -Level error -File $file.FullName -Message "有 shortcuts（GUI 应用）但 uninstaller.script 中无 Stop-Process"
        }
    }

    # ── uninstaller.script 优先 ──
    # 约定（AGENTS.md）：进程/服务终止逻辑必须放在 uninstaller.script 而非 pre_uninstall
    if ($json.pre_uninstall) {
        $preUninstall = $json.pre_uninstall
        if ($preUninstall -is [string]) { $preUninstall = @($preUninstall) }
        foreach ($line in $preUninstall) {
            if ($line -match 'Stop-Process') {
                Write-Result -Level error -File $file.FullName -Message "Stop-Process 出现在 pre_uninstall 中，应移至 uninstaller.script（Scoop 会在 uninstaller.script 前提示用户保存工作）"
                break
            }
        }
    }

    # ── 注册表操作 ──
    # 约定（AGENTS.md）：New-ItemProperty 必须加 -Force；Remove-ItemProperty 必须加 -ErrorAction SilentlyContinue
    foreach ($line in $scriptLines) {
        if ($line -match 'New-ItemProperty') {
            if ($line -notmatch '-Force') {
                Write-Result -Level error -File $file.FullName -Message "New-ItemProperty 缺少 -Force（重装时属性已存在会失败）: $line"
            }
        }
        if ($line -match 'Remove-ItemProperty') {
            if ($line -notmatch '-ErrorAction\s+SilentlyContinue') {
                Write-Result -Level error -File $file.FullName -Message "Remove-ItemProperty 缺少 -ErrorAction SilentlyContinue（注册表项不存在时会报错）: $line"
            }
        }
    }

    # ── 禁止 Invoke-Expression ──
    # 约定（AGENTS.md）：调用脚本文件应使用 & 运算符，不得使用 Invoke-Expression
    # 原因：Invoke-Expression 接受字符串并执行，拼接不当可导致代码注入；
    #       & 运算符直接调用命令，不经过字符串解析，更安全
    # 检查方式：脚本行中搜索 Invoke-Expression
    # 误报风险：极低。Invoke-Expression 在清单脚本中几乎无合法用途
    foreach ($line in $scriptLines) {
        if ($line -match 'Invoke-Expression') {
            Write-Result -Level error -File $file.FullName -Message "禁止使用 Invoke-Expression（应使用 & 运算符）: $line"
        }
    }

    # ── 用户目录路径 ──
    # 约定（AGENTS.md）：涉及用户文档目录时，必须使用 [Environment]::GetFolderPath('MyDocuments')，
    #                   禁止硬编码 $home\Documents
    # 原因：OneDrive 文件夹备份、企业 GPO 文件夹重定向等场景下，
    #       $home\Documents 可能不存在或指向错误位置
    # 检查方式：脚本行中搜索 $home\Documents 或 $home/Documents 模式（PowerShell 两种分隔符均合法）
    # 误报风险：极低。$home\Documents 是明确的硬编码路径模式
    foreach ($line in $scriptLines) {
        if ($line -match '(?i)\$home[/\\]+Documents') {
            Write-Result -Level error -File $file.FullName -Message "禁止硬coded `$home\Documents（应使用 [Environment]::GetFolderPath('MyDocuments')）: $line"
        }
    }

    # ── New-Item 加 -Force ──
    # 约定（AGENTS.md）：创建文件占位时加 -Force，避免重装时报错
    # 原因：重装时占位文件可能已存在，New-Item 不加 -Force 会因"文件已存在"报错
    # 检查方式：New-Item 调用不含 -Force（排除 Junction，Junction 有独立的先删后建规则）
    # 误报风险：低。大部分 New-Item 调用都应加 -Force
    foreach ($line in $scriptLines) {
        if ($line -match 'New-Item\b' -and $line -notmatch '-Force' -and $line -notmatch 'Junction') {
            Write-Result -Level warning -File $file.FullName -Message "New-Item 缺少 -Force（重装时可能报错）: $line"
        }
    }

    # ── 卸载程序存在性检查 ──
    # 约定（AGENTS.md）：调用应用自带的卸载程序前，必须用 Test-Path 检查文件是否存在
    # 原因：卸载程序可能不存在（用户手动删除或安装不完整），直接调用会导致脚本中断
    # 检查方式：脚本中调用了 $dir\Uninstall 等卸载程序，但缺少 Test-Path 守卫
    # 误报风险：低。跨行检测可能遗漏 Test-Path 在其他行的情况，但大多数清单会写在同一代码块
    $hasUninstallerCall = $false
    $hasTestPathGuard = $false
    foreach ($line in $scriptLines) {
        if ($line -match '&\s*"?(\$dir\\[^"]*[Uu]ninstall)' -or $line -match '&\s*"?(\$dir\\[^"]*uninst)') {
            $hasUninstallerCall = $true
        }
        if ($line -match 'Test-Path.*\$dir\\.*[Uu]ninstall' -or $line -match 'Test-Path.*\$dir\\.*uninst') {
            $hasTestPathGuard = $true
        }
    }
    if ($hasUninstallerCall -and -not $hasTestPathGuard) {
        Write-Result -Level error -File $file.FullName -Message "调用了卸载程序但缺少 Test-Path 存在性检查（AGENTS.md 约定）"
    }

    # ── 注册表协议路径必须用 current ──
    # 约定（AGENTS.md）：注册表写入的路径必须使用 $(Split-Path $dir -Parent)\current\<程序.exe>，
    #                   不得使用 "$dir\<程序.exe>"（版本化路径，更新后即失效）
    # 原因：Scoop 更新时会删除旧版本目录并创建新的 current 符号链接，
    #       注册表中写死的版本化路径在更新后会指向已删除的目录
    # 检查方式：脚本行中注册表路径含 $dir\ 但不含 current
    # 误报风险：低。注册表路径中使用 $dir 几乎总是错误
    foreach ($line in $scriptLines) {
        if ($line -match 'Set-ItemProperty|New-ItemProperty|New-Item.*HK' -and
            $line -match '\$dir\\' -and $line -notmatch 'current\\') {
            Write-Result -Level error -File $file.FullName -Message "注册表路径使用了 `"`$dir\`" 版本化路径（应使用 `$(Split-Path `$dir -Parent)\current\`"）: $line"
        }
    }

    # ── shortcuts 名称以 ..\ 开头 ──
    # 约定（AGENTS.md）：快捷方式名以 "..\" 开头，中文显示名，用 "-" 分隔
    # 原因：Scoop 快捷方式默认放在 Scoop Apps 目录下，"..\" 使快捷方式出现在
    #       开始菜单的 Scoop 文件夹上级，而非嵌套在 Scoop 子文件夹中
    # 检查方式：shortcuts 条目的第二个元素不以 "..\" 开头
    # 误报风险：低。这是本项目的统一约定
    if ($json.shortcuts) {
        foreach ($shortcut in $json.shortcuts) {
            if ($shortcut.Count -ge 2 -and $shortcut[1] -notmatch '^\.\.[/\\]') {
                Write-Result -Level warning -File $file.FullName -Message "shortcuts 名称 '$($shortcut[1])' 不以 '..\' 开头（AGENTS.md 约定：快捷方式应出现在开始菜单上级目录）"
            }
        }
    }

    # ── 单文件 persist 需空文件占位 ──
    # 约定（AGENTS.md）：对单个文件（而非文件夹）做 persist 时，必须在 pre_install 中创建空文件占位
    # 原因：Scoop 的 persist 机制对不存在的目标会创建文件夹链接而非文件链接，
    #       导致应用无法读写配置文件（如 SQLite 数据库、JSON 配置等）
    # 检查方式：persist 为字符串且含文件扩展名时，pre_install 中应创建对应文件占位
    # 误报风险：低。仅对含扩展名的 persist 项检查（排除目录型 persist 如 data、AppData）
    if ($json.persist -is [string] -and $json.persist -match '\.\w+$') {
        $persistFile = $json.persist
        $hasPlaceholder = $false
        foreach ($line in $scriptLines) {
            if ($line -match [regex]::Escape($persistFile) -and
                $line -match 'New-Item|Set-Content|Out-File|Add-Content') {
                $hasPlaceholder = $true
                break
            }
        }
        if (-not $hasPlaceholder) {
            Write-Result -Level error -File $file.FullName -Message "persist '$persistFile' 为单文件但 pre_install 中未创建空文件占位（Scoop 会将其创建为文件夹链接，导致应用无法读写）"
        }
    }

    # ── 输出当前文件检查结果 ──
    if (-not $CI) {
        Write-Host " ✓ $($json.version)" -ForegroundColor Green
    }
}

# ─────────────────────────── 汇总 ───────────────────────────

Write-Host ''
if ($hasError) {
    Write-Host "✗ 发现 $errorCount 个错误，$warningCount 个警告" -ForegroundColor Red
    exit 1
}
if ($warningCount -gt 0) {
    Write-Host "⚠ 发现 $warningCount 个警告（不阻断 CI）" -ForegroundColor Yellow
}
Write-Host "✓ 所有清单验证通过" -ForegroundColor Green
exit 0
