#Requires -Version 7.0
<#
.SYNOPSIS
    bucket 清单自动更新流水线：逐清单隔离执行，失败清单跳过并上报。

.DESCRIPTION
    分层结构（每层只依赖下一层的产物）：
      L0 Get-ManifestQueue        发现清单 + 预检（JSON 可解析、声明了 checkver）
      L1 Invoke-ManifestUpdate    每个清单在独立子进程中执行 checkver（超时保护、日志落盘）
      L2 Test-UpdatedManifest → Send-ManifestCommit → Push-Commits
                                  校验更新结果 → 提交 → 推送（含 rebase 重试）
      L3 Write-RunReport          控制台汇总 + Actions 摘要 + 注解 + 滚动 issue

    失败语义：
      · 单清单失败/超时 → 还原该清单文件、记录原因、继续处理其它清单，不中断流水线
      · 未成功提交的清单一律还原，工作区不残留半成品
      · 所有清单均失败 或 推送最终失败 → 退出码 1（流水线级故障）
      · 部分清单失败 → 退出码 0，通过摘要 / 注解 / issue 上报待修清单

.PARAMETER App
    只处理名称匹配的清单，支持通配符，默认 *（全部）。
.PARAMETER BucketDir
    清单目录，默认 <仓库根>/bucket。
.PARAMETER ScoopHome
    Scoop 核心目录，默认 $env:SCOOP_HOME；缺失时回退到 `scoop prefix scoop`。
.PARAMETER TimeoutSeconds
    单个清单子进程的超时秒数，默认 600。
.PARAMETER LogDir
    子进程日志与备份目录，默认 <仓库根>/.update-logs。
.PARAMETER DryRun
    只执行检查与校验：不提交、不推送、不写 issue。
    成功的更新会保留在工作区供人工检查，失败的清单照常还原。

.EXAMPLE
    pwsh bin/update-bucket.ps1
.EXAMPLE
    pwsh bin/update-bucket.ps1 -App 'ZedG' -DryRun
#>
[CmdletBinding()]
param(
    [string]$App = '*',
    [string]$BucketDir,
    [string]$ScoopHome = $env:SCOOP_HOME,
    [int]$TimeoutSeconds = 600,
    [string]$LogDir,
    [switch]$DryRun
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
# 原生命令的非零退出码由 Invoke-Git 显式检查，不交给 ErrorActionPreference 处理
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# ─────────────────────────── 常量与运行环境 ───────────────────────────

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:DryRun = $DryRun.IsPresent
$script:SkipUpdated = $env:SKIP_UPDATED -eq '1'
$script:DeliveryBranch = 'main'
$script:BotName = 'github-actions[bot]'
$script:BotEmail = '41898282+github-actions[bot]@users.noreply.github.com'
$script:FailureIssueTitle = '自动更新失败清单'
$script:PushBlocked = $false
$script:DeliveryEnabled = $true

if (-not $BucketDir) { $BucketDir = Join-Path $script:RepoRoot 'bucket' }
if (-not $LogDir) { $LogDir = Join-Path $script:RepoRoot '.update-logs' }

if (-not $ScoopHome) { $ScoopHome = $env:SCOOP_HOME }
if (-not $ScoopHome -and (Get-Command scoop -ErrorAction SilentlyContinue)) {
    $ScoopHome = (& scoop prefix scoop) | Select-Object -First 1
}
if (-not $ScoopHome -or -not (Test-Path $ScoopHome)) {
    throw "找不到 Scoop 核心目录（-ScoopHome / `$env:SCOOP_HOME）：无法执行 checkver"
}
$script:CheckverPath = Join-Path $ScoopHome 'bin/checkver.ps1'
if (-not (Test-Path $script:CheckverPath)) {
    throw "Scoop 核心目录中缺少 bin/checkver.ps1：$ScoopHome"
}

$script:PwshPath = if ($IsWindows) { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'pwsh' }
if (-not (Test-Path $script:PwshPath)) {
    $pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwshCommand) { throw '找不到 pwsh，无法以子进程方式执行 checkver' }
    $script:PwshPath = $pwshCommand.Source
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# ─────────────────────────── 通用工具 ───────────────────────────

function Write-Log {
    param(
        [ValidateSet('info', 'ok', 'warn', 'fail', 'step')]
        [string]$Level,
        [string]$Message
    )
    $prefix = switch ($Level) {
        'ok' { '  [OK]  ' }
        'warn' { '  [!!]  ' }
        'fail' { '  [XX]  ' }
        'step' { '  [--]  ' }
        default { '  [..]  ' }
    }
    $color = switch ($Level) {
        'ok' { 'Green' }
        'warn' { 'Yellow' }
        'fail' { 'Red' }
        'step' { 'DarkCyan' }
        default { 'Gray' }
    }
    Write-Host "$prefix$Message" -ForegroundColor $color
}

function Remove-Ansi {
    param([string]$Text)
    if (-not $Text) { return '' }
    return ($Text -replace '\x1b\[[0-9;]*[A-Za-z]', '')
}

function Invoke-Git {
    # 显式检查退出码：原生命令失败不抛异常，也不受 ErrorActionPreference 影响
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure
    )
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & git -C $script:RepoRoot @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $output = (($raw | ForEach-Object { Remove-Ansi "$_" }) -join [Environment]::NewLine).Trim()
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') 失败（exit $exitCode）：`n$output"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Get-RelativePath {
    param([string]$Path)
    return [System.IO.Path]::GetRelativePath($script:RepoRoot, $Path).Replace('\', '/')
}

function New-Result {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Reason = '',
        [string]$Version = '',
        [double]$Seconds = 0
    )
    return [pscustomobject]@{
        Name    = $Name
        Status  = $Status
        Reason  = $Reason
        Version = $Version
        Seconds = [math]::Round($Seconds, 1)
    }
}

# ─────────────────────────── L0：环境自检 + 队列构建 ───────────────────────────

function Test-GitHubTokenAccess {
    <#
    .SYNOPSIS
        环境自检：确认 GitHub token 可用。
    .DESCRIPTION
        token 失效时整批 GitHub 清单都会失败，逐条读日志才能定位；这里先探一次并给出提示。
        探测失败不中断流水线（部分清单可能不依赖 GitHub API）。
    #>
    $token = @($env:SCOOP_GH_TOKEN, $env:GH_TOKEN, $env:GITHUB_TOKEN) | Where-Object { $_ } | Select-Object -First 1
    if (-not $token) {
        Write-Log warn '未提供 GitHub token（SCOOP_GH_TOKEN / GITHUB_TOKEN），checkver 可能被限流'
        return
    }
    try {
        $headers = @{ Authorization = "token $token"; Accept = 'application/vnd.github+json' }
        $limit = Invoke-RestMethod -Uri 'https://api.github.com/rate_limit' -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        Write-Log info "GitHub token 可用，剩余 API 额度 $($limit.resources.core.remaining)/$($limit.resources.core.limit)"
    } catch {
        Write-Log warn "GitHub token 校验失败（$($_.Exception.Message)）：依赖 GitHub API 的清单本次可能全部失败"
    }
}

function Get-ManifestQueue {
    <#
    .SYNOPSIS
        发现清单并预检，产出「待更新队列」与「预检跳过清单」。
    .DESCRIPTION
        预检只判断两件流水线必需的事：JSON 能否解析、是否声明了 checkver。
        其余清单质量问题交给 CI（bin/lint.ps1 + Pester），此处不重复实现规则。
    #>
    param(
        [string]$BucketDir,
        [string]$App
    )

    $queued = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()

    $files = Get-ChildItem -LiteralPath $BucketDir -Filter '*.json' -File | Sort-Object Name
    if ($App -and $App -ne '*') {
        $files = @($files | Where-Object { $_.BaseName -like $App })
    }

    foreach ($file in $files) {
        $name = $file.BaseName
        try {
            $manifest = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $skipped.Add((New-Result $name 'InvalidJson' "JSON 解析失败：$($_.Exception.Message)"))
            continue
        }

        $checkverProperty = $manifest.PSObject.Properties['checkver']
        if (-not $checkverProperty -or -not $checkverProperty.Value) {
            $skipped.Add((New-Result $name 'NoCheckver' '清单未声明 checkver，不参与自动更新'))
            continue
        }

        $queued.Add([pscustomobject]@{ Name = $name; Path = $file.FullName })
    }

    return [pscustomobject]@{ Queued = $queued; Skipped = $skipped }
}

# ─────────────────────────── L1：单清单更新（子进程隔离） ───────────────────────────

function Invoke-ManifestUpdate {
    <#
    .SYNOPSIS
        在独立子进程中执行单个清单的 checkver/autoupdate。
    .DESCRIPTION
        进程隔离是这一层的核心：checkver 在处理某个清单时可能抛异常、卡死或直接退出，
        这些都只影响该子进程。父进程记录退出码、日志与文件是否变化，并把原始文件备份，
        交给调用方决定提交还是还原。
    #>
    param(
        [string]$Name,
        [string]$Path,
        [string]$BackupDir,
        [string]$LogDir,
        [int]$TimeoutSeconds
    )

    $logFile = Join-Path $LogDir "$Name.log"
    $backupFile = Join-Path $BackupDir "$Name.json"
    Copy-Item -LiteralPath $Path -Destination $backupFile -Force

    $beforeHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $beforeKeys = @((Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties.Name | Sort-Object)

    $arguments = @(
        '-NoProfile', '-NonInteractive', '-NoLogo',
        '-File', $script:CheckverPath,
        '-App', $Name,
        '-Dir', (Split-Path -Parent $Path),
        '-Update',
        '-ThrowError'
    )
    if ($script:SkipUpdated) { $arguments += '-SkipUpdated' }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:PwshPath
    $startInfo.WorkingDirectory = $script:RepoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new()
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new()
    foreach ($argument in $arguments) { $startInfo.ArgumentList.Add($argument) }

    $startedAt = Get-Date
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        Write-Log warn "$Name 超过 ${TimeoutSeconds}s 未结束，终止子进程"
        try { $process.Kill($true) } catch { Write-Log warn "$Name 终止子进程失败：$($_.Exception.Message)" }
        $process.WaitForExit(10000) | Out-Null
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $seconds = ((Get-Date) - $startedAt).TotalSeconds
    $exitCode = if ($timedOut) { $null } else { $process.ExitCode }

    @(
        "### $Name",
        "exit=$exitCode timeout=$timedOut seconds=$([math]::Round($seconds, 1))",
        '',
        '--- stdout ---',
        (Remove-Ansi $stdout),
        '--- stderr ---',
        (Remove-Ansi $stderr)
    ) -join [Environment]::NewLine | Set-Content -LiteralPath $logFile -Encoding utf8

    $afterHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $changed = $afterHash -ne $beforeHash

    # 失败判定用三个信号：子进程退出码、checkver/autoupdate 的问题输出、PowerShell 非终止错误（stderr）
    # （checkver 有大量「打印错误后 continue」的路径，退出码仍是 0，只看退出码会漏报）
    $marker = Get-ProblemMarker -Stdout $stdout -Stderr $stderr
    $stderrText = (Remove-Ansi $stderr).Trim()

    $outcome = 'Current'
    $reason = ''
    if ($timedOut) {
        $outcome = 'Timeout'
        $reason = "执行超过 ${TimeoutSeconds}s"
    } elseif ($exitCode -ne 0 -or $marker -or $stderrText) {
        $outcome = 'Failed'
        $reason = if ($marker) { $marker } elseif ($stderrText) { Get-FirstLine $stderrText } else { "checkver 退出码 $exitCode" }
    } elseif ($changed) {
        # 字节变了但语义没变（换行/缩进被重写）时按「无更新」处理，避免产生噪音提交
        $beforeSemantic = (Get-Content -LiteralPath $backupFile -Raw -Encoding UTF8 | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress)
        $afterSemantic = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress)
        if ($beforeSemantic -eq $afterSemantic) {
            $reason = '内容未变化，仅格式差异，已还原'
        } else {
            $outcome = 'Updated'
        }
    }

    return [pscustomobject]@{
        Name      = $Name
        Path      = $Path
        Backup    = $backupFile
        Log       = $logFile
        Outcome   = $outcome
        Reason    = $reason
        Changed   = $changed
        Seconds   = $seconds
        BeforeKeys = $beforeKeys
    }
}

function Get-FirstLine {
    param([string]$Text)
    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = (Remove-Ansi $line).Trim()
        if ($trimmed) { return $trimmed }
    }
    return ''
}

function Get-ProblemMarker {
    <#
    .SYNOPSIS
        从子进程输出里提取一句能定位问题的原因（完整日志见日志文件）。
    .DESCRIPTION
        按信息量排序匹配上游的几种问题输出形态；匹配不到就返回空串，
        由调用方决定是否回落到 stderr 首行。
    #>
    param([string]$Stdout, [string]$Stderr)

    # PowerShell 渲染异常时会按控制台宽度折行（续行形如 "     | 后半句"）。
    # 这里把带 "|" 前缀的片段拼回一行，否则取到的消息会被截断成半句。
    # 注意先去 ANSI：着色码可能插在行首空白与 "|" 之间，先匹配会一条都匹配不到。
    $cleanStderr = Remove-Ansi $Stderr
    $fragments = @($cleanStderr -split "`r?`n" | Where-Object { $_ -match '^\s*\|\s' } | ForEach-Object { $_ -replace '^\s*\|\s?', '' })
    $stderrText = if ($fragments.Count -gt 1) { $fragments -join ' ' } else { $cleanStderr }

    $combined = $stderrText + "`n" + (Remove-Ansi $Stdout)
    $patterns = @(
        'Could not update [^\r\n]*',
        'couldn''t [^\r\n]*',
        '(?m)^ERROR [^\r\n]*',
        'URL \S+ is not valid'
    )
    foreach ($pattern in $patterns) {
        $found = [regex]::Matches($combined, $pattern)
        if ($found.Count -gt 0) {
            # 异常栈里既会出现源码模板行（含 $AppName、$(...)，信息量为负），也会出现真正抛出的消息行，优先取后者
            $candidate = $found | Where-Object { $_.Value -notmatch '\$\(|\$[A-Za-z]' } | Select-Object -First 1
            if (-not $candidate) { $candidate = $found[$found.Count - 1] }
            $text = $candidate.Value.Trim()
            if ($text.Length -gt 300) { $text = $text.Substring(0, 297) + '...' }
            return $text
        }
    }
    return ''
}

function Restore-ManifestFile {
    param(
        [string]$Path,
        [string]$Backup
    )
    Copy-Item -LiteralPath $Backup -Destination $Path -Force
}

# ─────────────────────────── L2：校验 / 提交 / 推送 ───────────────────────────

function Test-UpdatedManifest {
    <#
    .SYNOPSIS
        提交前校验自动更新结果，保证写出的清单没被写坏。
    #>
    param(
        [string]$Path,
        [string[]]$BeforeKeys
    )

    try {
        $manifest = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Ok = $false; Reason = "更新后 JSON 解析失败：$($_.Exception.Message)"; Manifest = $null }
    }

    # 用 PSObject 属性表取值：严格模式下访问不存在的属性会抛异常，而这里必须安全返回失败
    $versionProperty = $manifest.PSObject.Properties['version']
    if (-not $versionProperty -or $versionProperty.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($versionProperty.Value)) {
        return [pscustomobject]@{ Ok = $false; Reason = '更新后 version 字段缺失或不是字符串'; Manifest = $null }
    }

    $afterKeys = @($manifest.PSObject.Properties.Name | Sort-Object)
    if (($BeforeKeys -join ',') -ne ($afterKeys -join ',')) {
        $added = @($afterKeys | Where-Object { $_ -notin $BeforeKeys })
        $removed = @($BeforeKeys | Where-Object { $_ -notin $afterKeys })
        $detail = @()
        if ($added.Count -gt 0) { $detail += "新增 $($added -join ',')" }
        if ($removed.Count -gt 0) { $detail += "丢失 $($removed -join ',')" }
        return [pscustomobject]@{ Ok = $false; Reason = "更新改动了顶层字段结构（$($detail -join '；')）"; Manifest = $null }
    }

    return [pscustomobject]@{ Ok = $true; Reason = ''; Manifest = $manifest }
}

function Send-ManifestCommit {
    param(
        [string]$Name,
        [string]$Path,
        [string]$Version
    )
    $relativePath = Get-RelativePath -Path $Path
    $message = "chore(${Name}): 更新至 $Version"
    Invoke-Git -Arguments @('add', '--', $relativePath) | Out-Null
    Invoke-Git -Arguments @(
        '-c', "user.name=$script:BotName",
        '-c', "user.email=$script:BotEmail",
        'commit', '-q', '-m', $message, '--', $relativePath
    ) | Out-Null
}

function Push-Commits {
    <#
    .SYNOPSIS
        推送本地提交；被拒绝时先 rebase 再重试。
    .DESCRIPTION
        每个清单提交后立即推送：任何后续故障都不会丢掉已经完成的更新。
    #>
    if ($script:DryRun -or -not $script:DeliveryEnabled -or $script:PushBlocked) { return $false }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $push = Invoke-Git -Arguments @('push', 'origin', "HEAD:$script:DeliveryBranch") -AllowFailure
        if ($push.ExitCode -eq 0) { return $true }

        Write-Log warn "推送失败（第 $attempt 次），尝试 rebase 远端提交后重试"
        $pull = Invoke-Git -Arguments @('pull', '--rebase', '--autostash', 'origin', $script:DeliveryBranch) -AllowFailure
        if ($pull.ExitCode -ne 0) {
            Invoke-Git -Arguments @('rebase', '--abort') -AllowFailure | Out-Null
            Write-Log fail 'rebase 失败，本次运行剩余提交不再重试推送'
            break
        }
        Start-Sleep -Seconds (5 * $attempt)
    }

    $script:PushBlocked = $true
    return $false
}

# ─────────────────────────── L3：结果上报 ───────────────────────────

function Invoke-Gh {
    # 同 Invoke-Git：外部命令失败不抛异常，统一返回退出码与输出
    param([string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & gh @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = (($raw | ForEach-Object { Remove-Ansi "$_" }) -join [Environment]::NewLine).Trim() }
}

function Get-StatusLabel {
    param([string]$Status)
    switch ($Status) {
        'Updated' { '已更新' }
        'Current' { '已是最新' }
        'Failed' { '失败（已还原）' }
        'Timeout' { '超时（已还原）' }
        'InvalidJson' { 'JSON 无效' }
        'NoCheckver' { '无 checkver' }
        default { $Status }
    }
}

function New-ReportTable {
    param([object[]]$Entries)
    $lines = @('| 清单 | 结果 | 版本 | 耗时(s) | 说明 |', '| --- | --- | --- | --- | --- |')
    foreach ($entry in $Entries) {
        $reason = ($entry.Reason -replace '\r?\n', ' ' -replace '\|', '\|')
        if ($reason.Length -gt 160) { $reason = $reason.Substring(0, 157) + '...' }
        $version = if ($entry.Version) { $entry.Version } else { '-' }
        $lines += "| ``$($entry.Name)`` | $(Get-StatusLabel $entry.Status) | $version | $($entry.Seconds) | $reason |"
    }
    return ($lines -join [Environment]::NewLine)
}

function Update-FailureIssue {
    <#
    .SYNOPSIS
        维护一个滚动 issue：有失败清单时创建/更新，全部恢复正常时关闭。
    #>
    param([object[]]$Failed)

    if ($script:DryRun) { return }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Log warn '未找到 gh，跳过 issue 上报'
        return
    }
    if (-not $env:GH_TOKEN) {
        Write-Log warn '缺少 GH_TOKEN，跳过 issue 上报'
        return
    }

    try {
        $repoArgs = @()
        if ($env:GITHUB_REPOSITORY) { $repoArgs = @('--repo', $env:GITHUB_REPOSITORY) }

        # gh 是外部命令：失败不抛异常，必须显式检查退出码，否则「创建失败」会被静默当成成功
        $listed = Invoke-Gh -Arguments (@('issue', 'list') + $repoArgs + @('--state', 'open', '--search', "in:title $script:FailureIssueTitle", '--json', 'number,title', '--limit', '20'))
        if ($listed.ExitCode -ne 0) {
            Write-Log warn "读取失败清单 issue 失败：$($listed.Output)"
            return
        }
        $existing = $null
        if ($listed.Output) {
            $existing = @($listed.Output | ConvertFrom-Json | Where-Object { $_.title -eq $script:FailureIssueTitle }) | Select-Object -First 1
        }

        if ($Failed.Count -gt 0) {
            $runUrl = if ($env:GITHUB_RUN_ID) { "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID" } else { '' }
            $body = @(
                '自动更新流水线跳过了以下清单（文件已还原，仓库其余清单照常更新）。',
                '',
                (New-ReportTable -Entries $Failed),
                '',
                "最近一次运行：$(Get-Date -Format 'yyyy-MM-dd HH:mm') UTC$(if ($runUrl) { " · $runUrl" })",
                '',
                '排查方向：`checkver` 规则是否仍匹配上游页面、`autoupdate` 引用的发布资产/校验文件是否已被上游删除或改名。修好后可在 Actions 里用 `Run workflow` 指定该清单单独验证。'
            ) -join [Environment]::NewLine
            if ($existing) {
                $result = Invoke-Gh -Arguments (@('issue', 'edit', "$($existing.number)") + $repoArgs + @('--body', $body))
                if ($result.ExitCode -ne 0) { Write-Log warn "更新 issue #$($existing.number) 失败：$($result.Output)"; return }
                Write-Log info "已更新失败清单 issue #$($existing.number)"
            } else {
                $result = Invoke-Gh -Arguments (@('issue', 'create') + $repoArgs + @('--title', $script:FailureIssueTitle, '--body', $body))
                if ($result.ExitCode -ne 0) { Write-Log warn "创建失败清单 issue 失败：$($result.Output)"; return }
                Write-Log info "已创建失败清单 issue：$($result.Output)"
            }
        } elseif ($existing) {
            $result = Invoke-Gh -Arguments (@('issue', 'close', "$($existing.number)") + $repoArgs + @('--comment', '本次运行所有清单均更新成功，关闭该报告。'))
            if ($result.ExitCode -ne 0) { Write-Log warn "关闭 issue #$($existing.number) 失败：$($result.Output)"; return }
            Write-Log info "已关闭失败清单 issue #$($existing.number)"
        }
    } catch {
        Write-Log warn "issue 上报失败（不影响更新结果）：$($_.Exception.Message)"
    }
}

function Write-RunReport {
    param(
        [object[]]$Results,
        [object[]]$Skipped,
        [bool]$PushOk
    )

    $failed = @($Results | Where-Object { $_.Status -in @('Failed', 'Timeout') })
    $updated = @($Results | Where-Object { $_.Status -eq 'Updated' })
    $all = @($Results) + @($Skipped)

    Write-Host ''
    Write-Log step "更新完成：成功 $($updated.Count) · 失败 $($failed.Count) · 未变化 $(@($Results | Where-Object { $_.Status -eq 'Current' }).Count) · 预检跳过 $($Skipped.Count)"
    foreach ($entry in $Skipped) {
        Write-Log warn "$($entry.Name)：$(Get-StatusLabel $entry.Status)（$($entry.Reason)）"
    }

    # Actions 注解：失败清单直接标在对应文件上
    foreach ($entry in $failed) {
        $reason = ($entry.Reason -replace '\r?\n', ' ' -replace '%', '%25' -replace '\r', '%0D' -replace '\n', '%0A')
        Write-Host "::warning file=bucket/$($entry.Name).json::$reason"
    }
    foreach ($entry in $Skipped) {
        Write-Host "::notice file=bucket/$($entry.Name).json::$($entry.Reason)"
    }

    # Actions 步骤摘要
    if ($env:GITHUB_STEP_SUMMARY) {
        $summary = @(
            '## 清单自动更新',
            '',
            "- 已更新：**$($updated.Count)**",
            "- 未变化：**$(@($Results | Where-Object { $_.Status -eq 'Current' }).Count)**",
            "- 失败（已还原，跳过）：**$($failed.Count)**",
            "- 预检跳过：**$($Skipped.Count)**",
            "- 推送：$(if ($updated.Count -eq 0) { '无新提交' } elseif ($script:DryRun) { 'DryRun 未推送' } elseif ($PushOk) { '已推送' } else { '未推送（见下）' })",
            ''
        )
        if ($all.Count -gt 0) { $summary += (New-ReportTable -Entries $all) }
        if ($failed.Count -gt 0) {
            $summary += @('', '### 失败清单（已还原，未提交）')
            foreach ($entry in $failed) {
                $logName = "$($entry.Name).log"
                $summary += "- ``$($entry.Name)``：$($entry.Reason)（日志：``.update-logs/$logName``）"
            }
        }
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($summary -join [Environment]::NewLine) -Encoding utf8
    }

    Update-FailureIssue -Failed $failed

    return [pscustomobject]@{ Failed = $failed; Updated = $updated }
}

# ─────────────────────────── 主流程 ───────────────────────────

Write-Log step "更新流水线启动：Scoop 核心 $ScoopHome"
Write-Log step "清单目录 $BucketDir · 超时 ${TimeoutSeconds}s · DryRun=$($script:DryRun)"

if (-not $script:DryRun) {
    $branch = (Invoke-Git -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')).Output
    if ($branch -ne $script:DeliveryBranch) {
        $script:DeliveryEnabled = $false
        Write-Log warn "当前分支为 $branch（非 $script:DeliveryBranch），本次只更新工作区，不提交不推送"
    }
}

$backupDir = Join-Path $LogDir 'backup'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

Test-GitHubTokenAccess

$queue = Get-ManifestQueue -BucketDir $BucketDir -App $App
Write-Log step "待更新清单 $($queue.Queued.Count) 个 · 预检跳过 $($queue.Skipped.Count) 个"

$results = [System.Collections.Generic.List[object]]::new()
foreach ($item in $queue.Queued) {
    Write-Log step "[$($results.Count + 1)/$($queue.Queued.Count)] $($item.Name)"

    $update = $null
    $status = 'Failed'
    $reason = ''
    $version = ''
    $seconds = 0

    try {
        $update = Invoke-ManifestUpdate -Name $item.Name -Path $item.Path -BackupDir $backupDir -LogDir $LogDir -TimeoutSeconds $TimeoutSeconds
        $status = $update.Outcome
        $reason = $update.Reason
        $seconds = $update.Seconds

        if ($update.Outcome -eq 'Updated') {
            $validation = Test-UpdatedManifest -Path $update.Path -BeforeKeys $update.BeforeKeys
            if ($validation.Ok) {
                $version = $validation.Manifest.version
                if ($script:DeliveryEnabled -and -not $script:DryRun) {
                    Send-ManifestCommit -Name $item.Name -Path $update.Path -Version $version
                    Push-Commits | Out-Null
                }
            } else {
                $status = 'Failed'
                $reason = $validation.Reason
                Restore-ManifestFile -Path $update.Path -Backup $update.Backup
            }
        } elseif ($update.Changed) {
            Restore-ManifestFile -Path $update.Path -Backup $update.Backup
        }
    } catch {
        # 父进程侧的意外错误（备份/校验/提交/推送）同样只影响该清单，不中断整批
        $status = 'Failed'
        $reason = "流水线内部错误：$($_.Exception.Message)"
        if ($update -and $update.Changed -and (Test-Path -LiteralPath $update.Backup)) {
            Restore-ManifestFile -Path $update.Path -Backup $update.Backup
        }
    }

    $results.Add((New-Result -Name $item.Name -Status $status -Reason $reason -Version $version -Seconds $seconds))
    switch ($status) {
        'Updated' { Write-Log ok "$($item.Name) → $version（$([math]::Round($seconds, 1))s）" }
        'Current' { Write-Log info "$($item.Name) 已是最新" }
        default { Write-Log fail "$($item.Name)：$reason" }
    }
}

# 收尾推送：中途可能因 rebase 冲突暂停推送，这里最后再试一次
$pushOk = if ($script:DryRun -or -not $script:DeliveryEnabled) { $false } else { Push-Commits }

$report = Write-RunReport -Results $results.ToArray() -Skipped $queue.Skipped.ToArray() -PushOk $pushOk

$exitCode = 0
if ($script:DeliveryEnabled -and -not $script:DryRun -and -not $pushOk -and $report.Updated.Count -gt 0) {
    Write-Log fail '更新已提交但推送失败：请在本地重新拉取，或查看 .update-logs 中的日志'
    $exitCode = 1
} elseif ($results.Count -gt 0 -and $report.Failed.Count -eq $results.Count) {
    Write-Log fail "全部 $($results.Count) 个清单均失败，判定为流水线级故障"
    $exitCode = 1
}

Write-Log step "流水线结束（exit $exitCode）"
exit $exitCode
