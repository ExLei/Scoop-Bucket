#Requires -Version 5.1
<#
.SYNOPSIS
    Scoop Bucket manifest linter - validates bucket/*.json against Scoop Schema and AGENTS.md conventions

.DESCRIPTION
    Two-layer validation:
    1. Scoop Schema structural checks - based on ScoopInstaller/Scoop schema.json,
       validates manifest field structure, format, and types
    2. AGENTS.md convention checks - validates project-specific rules (SPDX identifiers, process termination, etc.)

    Only includes rules that can be reliably detected via field/pattern matching.
    Medium/high-risk rules (e.g. Junction delete-then-recreate, registry protocol paths) require
    contextual semantic analysis and are deferred to future iterations.

.PARAMETER CI
    CI mode: output GitHub Actions annotation format (::error / ::warning / ::notice),
    annotating errors/warnings directly on the corresponding PR files.

.EXAMPLE
    pwsh bin/lint.ps1              # Local run, colored console output
    pwsh bin/lint.ps1 -CI          # CI mode, GitHub Actions annotation format

.NOTES
    Schema reference: https://github.com/ScoopInstaller/Scoop/blob/master/schema.json
    Convention docs: AGENTS.md conventions section
#>

param(
    [switch]$CI
)

$ErrorActionPreference = 'Continue'
$hasError = $false
$warningCount = 0
$errorCount = 0

# ─────────────────────────── Helper Functions ───────────────────────────

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
                Write-Host "  [X] $Message" -ForegroundColor Red
            }
        }
        'warning' {
            $script:warningCount++
            if ($CI) {
                Write-Host "::warning file=$File::$Message"
            } else {
                Write-Host "  [!] $Message" -ForegroundColor Yellow
            }
        }
        'info' {
            if ($CI) {
                Write-Host "::notice file=$File::$Message"
            } else {
                Write-Host "  [i] $Message" -ForegroundColor Cyan
            }
        }
    }
}

# ─────────────────────────── Schema Valid Field Definitions ───────────────────────────
# Source: ScoopInstaller/Scoop schema.json "properties" + "additionalProperties": false

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

# ─────────────────────────── Deprecated SPDX Identifier List ───────────────────────────

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

# ─────────────────────────── Hash Format Validation ───────────────────────────
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

# ─────────────────────────── Script Line Extraction ───────────────────────────

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

# ─────────────────────────── SourceForge URL Check ───────────────────────────

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

# ─────────────────────────── Main Check Logic ───────────────────────────

$files = Get-ChildItem bucket/*.json
if ($files.Count -eq 0) {
    Write-Host "::warning::Bucket is empty - no manifest files found"
    exit 0
}

foreach ($file in $files) {
    $name = $file.Name
    if (-not $CI) {
        Write-Host "Linting: $name" -NoNewline
    }

    # ── CRLF line endings ──
    # Convention (AGENTS.md): JSON manifests must use CRLF line endings, LF is prohibited
    # Reason: Scoop community standard, CRLF is the Windows standard
    # Check: read raw bytes, detect bare \n not preceded by \r
    # False positive risk: very low
    $rawContent = [System.IO.File]::ReadAllText($file.FullName)
    if ($rawContent -match '(?<!\r)\n') {
        Write-Result -Level error -File $file.FullName -Message "JSON file must use CRLF line endings (AGENTS.md convention)"
    }

    # ── JSON syntax parsing ──
    try {
        $json = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Result -Level error -File $file.FullName -Message "JSON parse failed: $($_.Exception.Message)"
        if (-not $CI) { Write-Host '' }
        continue
    }

    # ══════════════════════════════════════════════════════════════
    #  Schema Structural Checks
    # ══════════════════════════════════════════════════════════════

    # ── Required top-level fields ──
    # Schema: "required": ["version", "homepage", "license"]
    # This project additionally requires description and architecture
    $required = @('version', 'description', 'homepage', 'architecture')
    $missing = $required | Where-Object { $json.PSObject.Properties.Name -notcontains $_ }
    if ($missing) {
        Write-Result -Level error -File $file.FullName -Message "Missing required fields: $($missing -join ', ')"
        if (-not $CI) { Write-Host '' }
        continue
    }

    # ── Unknown top-level fields ──
    # Schema: "additionalProperties": false
    # Reason: misspelled field names are silently ignored by Scoop, causing config to not take effect
    # Check: top-level property names not in schema.json properties list
    # False positive risk: very low
    $unknownFields = $json.PSObject.Properties.Name | Where-Object { $_ -notin $ValidTopLevelFields }
    if ($unknownFields) {
        Write-Result -Level error -File $file.FullName -Message "Unknown top-level fields: $($unknownFields -join ', ') (see Scoop schema.json)"
    }

    # ── Version format ──
    # Schema: "pattern": "^[\w\.\-+_]+$"
    # Reason: Scoop validates version with this regex, non-matching versions cause install/update failures
    # Check: match against schema.json version regex
    # False positive risk: very low
    if ([string]::IsNullOrWhiteSpace($json.version) -or $json.version -eq '0') {
        Write-Result -Level error -File $file.FullName -Message "Invalid version: '$($json.version)'"
    } elseif ($json.version -notmatch '^[\w\.\-+_]+$') {
        Write-Result -Level error -File $file.FullName -Message "Invalid version format: '$($json.version)' (should match ^[\w\.\-+_]+$)"
    }

    # ── description non-empty ──
    if ([string]::IsNullOrWhiteSpace($json.description)) {
        Write-Result -Level error -File $file.FullName -Message "description is empty"
    }

    # ── homepage URL format ──
    # Schema: "format": "uri"
    if ($json.homepage -notmatch '^https?://') {
        Write-Result -Level warning -File $file.FullName -Message "homepage does not start with http(s): $($json.homepage)"
    }

    # ── License required ──
    # Schema: "required": ["version", "homepage", "license"]
    # Reason: Scoop schema requires license field, missing causes schema validation failure
    # Check: license field does not exist
    # False positive risk: very low
    if (-not $json.license) {
        Write-Result -Level error -File $file.FullName -Message "Missing license field (required by Scoop Schema)"
    }

    # ── autoupdate and checkver pairing ──
    if ($json.autoupdate -and -not $json.checkver) {
        Write-Result -Level error -File $file.FullName -Message "Has autoupdate but missing checkver"
    }

    # ── Architecture name validity + unknown architecture sub-fields ──
    # Schema: architecture.additionalProperties = false
    $validArchNames = @('64bit', '32bit', 'arm64')
    foreach ($arch in $json.architecture.PSObject.Properties) {
        $archName = $arch.Name
        if ($archName -notin $validArchNames) {
            Write-Result -Level error -File $file.FullName -Message "Invalid architecture name '$archName' (expected 64bit / 32bit / arm64)"
            continue
        }

        $cfg = $arch.Value

        # Unknown architecture sub-fields
        $unknownArchFields = $cfg.PSObject.Properties.Name | Where-Object { $_ -notin $ValidArchSubFields }
        if ($unknownArchFields) {
            Write-Result -Level error -File $file.FullName -Message "$archName has unknown fields: $($unknownArchFields -join ', ')"
        }

        # url is required
        if (-not $cfg.url) {
            Write-Result -Level error -File $file.FullName -Message "$archName missing url"
            continue
        }

        # Download URL must be HTTPS
        if ($cfg.url -is [string] -and $cfg.url -notmatch '^https://') {
            Write-Result -Level error -File $file.FullName -Message "$archName url must start with https://"
        } elseif ($cfg.url -is [array]) {
            foreach ($u in $cfg.url) {
                if ($u -notmatch '^https://') {
                    Write-Result -Level error -File $file.FullName -Message "$archName url must start with https://: $u"
                }
            }
        }

        # Hash format check (Schema exact mode)
        if ($cfg.PSObject.Properties.Name -contains 'hash' -and $null -ne $cfg.hash) {
            if (-not (Test-HashFormat $cfg.hash)) {
                Write-Result -Level error -File $file.FullName -Message "$archName invalid hash format (expected SHA256 64-char hex or sha256:xxx prefix format)"
            }
        }
    }

    # ── Top-level hash format check ──
    if ($json.PSObject.Properties.Name -contains 'hash' -and $null -ne $json.hash) {
        if (-not (Test-HashFormat $json.hash)) {
            Write-Result -Level error -File $file.FullName -Message "Top-level invalid hash format (expected SHA256 64-char hex or sha256:xxx prefix format)"
        }
    }

    # ── Shortcuts format ──
    # Schema: items.minItems=2, maxItems=4
    # Reason: shortcut entry format is [exe_path, shortcut_name(, start_dir, icon)],
    #        fewer than 2 items lacks essential info, more than 4 exceeds Scoop parsing scope
    # Check: iterate shortcuts array, validate element count per entry
    # False positive risk: very low
    if ($json.shortcuts) {
        foreach ($shortcut in $json.shortcuts) {
            if ($shortcut.Count -lt 2 -or $shortcut.Count -gt 4) {
                Write-Result -Level error -File $file.FullName -Message "Shortcut entry must have 2-4 elements (got $($shortcut.Count)): [$($shortcut -join ', ')]"
            }
        }
    }

    # ── Uninstaller structure ──
    # Schema: "oneOf": [{"required": ["file"]}, {"required": ["script"]}]
    # Reason: uninstaller must specify file (executable uninstall) or script (script uninstall),
    #        neither means Scoop cannot uninstall, both is a semantic conflict
    # Check: when uninstaller exists, validate file/script exclusivity
    # False positive risk: very low
    if ($json.PSObject.Properties.Name -contains 'uninstaller') {
        $hasFile = $json.uninstaller.PSObject.Properties.Name -contains 'file'
        $hasScript = $json.uninstaller.PSObject.Properties.Name -contains 'script'
        if (-not $hasFile -and -not $hasScript) {
            Write-Result -Level error -File $file.FullName -Message "uninstaller must contain file or script"
        }
        if ($hasFile -and $hasScript) {
            Write-Result -Level error -File $file.FullName -Message "uninstaller file and script are mutually exclusive, specify only one"
        }
    }

    # ══════════════════════════════════════════════════════════════
    #  AGENTS.md Convention Checks
    # ══════════════════════════════════════════════════════════════

    # ── Hash values lowercase ──
    # Convention (AGENTS.md): SHA256 hash values must use lowercase letters
    foreach ($arch in $json.architecture.PSObject.Properties) {
        $cfg = $arch.Value
        if ($cfg.PSObject.Properties.Name -contains 'hash' -and $cfg.hash -is [string] -and $cfg.hash -ne '0') {
            if ($cfg.hash -cmatch '[A-F]') {
                Write-Result -Level error -File $file.FullName -Message "$($arch.Name) hash contains uppercase letters, must be all lowercase: $($cfg.hash)"
            }
        }
        if ($cfg.hash -is [array]) {
            foreach ($h in $cfg.hash) {
                if ($h -is [string] -and $h -ne '0' -and $h -cmatch '[A-F]') {
                    Write-Result -Level error -File $file.FullName -Message "$($arch.Name) hash contains uppercase letters, must be all lowercase: $h"
                }
            }
        }
    }

    # ── GitHub Releases hash ──
    # Per official Scoop schema: hash.mode does not include "github" enum value
    # GitHub source hash is automatically fetched by Scoop autoupdate from release, no explicit declaration needed
    if ($json.checkver -and $json.checkver.PSObject.Properties.Name -contains 'github') {
        if ($json.autoupdate -and $json.autoupdate.PSObject.Properties.Name -contains 'hash') {
            if ($json.autoupdate.hash.mode -eq 'github') {
                Write-Result -Level warning -File $file.FullName -Message "autoupdate.hash.mode is 'github', not supported by official Scoop schema enum, consider removing hash block (Scoop auto-fetches hash from GitHub release)"
            }
        }
    }

    # ── checkver.github explicit form ──
    # Convention (AGENTS.md): must use checkver: {github: "..."} object form
    if ($json.checkver -is [string] -and $json.checkver -eq 'github') {
        if ($json.homepage -notmatch '^https://github\.com/') {
            Write-Result -Level error -File $file.FullName -Message "checkver uses shorthand 'github' but homepage is not a GitHub URL, must use object form {github: '...'}"
        } else {
            Write-Result -Level warning -File $file.FullName -Message "checkver uses shorthand 'github', consider using object form {github: '$($json.homepage)'}"
        }
    }

    # ── Dependency management ──
    # Convention (AGENTS.md): prefer suggest over depends for .NET runtime and other external dependencies
    if ($json.depends) {
        $dotnetPatterns = @('dotnet', '.NETRuntime', 'netcore', 'net-framework', 'dotnet-desktop')
        foreach ($dep in $json.depends) {
            foreach ($pat in $dotnetPatterns) {
                if ($dep -match $pat) {
                    Write-Result -Level warning -File $file.FullName -Message "depends contains .NET dependency '$dep', consider using suggest instead (avoids redundant install if user already has runtime)"
                }
            }
        }
    }

    # ── License identifier ──
    # Convention (AGENTS.md): use correct SPDX identifiers, deprecated forms are prohibited
    if ($json.license) {
        $ident = if ($json.license -is [string]) { $json.license } else { $json.license.identifier }
        if ($ident -and $DeprecatedSpdx.ContainsKey($ident)) {
            Write-Result -Level error -File $file.FullName -Message "license.identifier '$ident' is deprecated, use '$($DeprecatedSpdx[$ident])'"
        }
    }

    # ── SourceForge URL suffix ──
    # Convention (AGENTS.md): SourceForge download URLs must end with /download
    # Reason: SourceForge URLs without /download suffix return HTML page instead of binary,
    #        Scoop would download a webpage instead of the installer
    # Check: URL contains sourceforge but not /download
    # False positive risk: very low
    foreach ($arch in $json.architecture.PSObject.Properties) {
        if (-not (Test-SourceForgeUrl $arch.Value.url)) {
            Write-Result -Level error -File $file.FullName -Message "$($arch.Name) SourceForge URL missing /download suffix (AGENTS.md convention)"
        }
    }
    if ($json.PSObject.Properties.Name -contains 'url') {
        if (-not (Test-SourceForgeUrl $json.url)) {
            Write-Result -Level error -File $file.FullName -Message "Top-level SourceForge URL missing /download suffix (AGENTS.md convention)"
        }
    }

    # ── Autoupdate no hardcoded version ──
    # Convention (AGENTS.md): autoupdate URLs must use $version variables, no hardcoded version numbers
    # Reason: autoupdate purpose is to auto-generate new version URLs, hardcoded version means URL won't change on update
    # Check: autoupdate URL contains X.Y.Z format without $ variable
    # False positive risk: low
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
                Write-Result -Level error -File $file.FullName -Message "autoupdate URL contains hardcoded version: $aurl (should use $version variable)"
            }
        }
    }

    # ── Autoupdate hash.mode valid values ──
    # Schema: hash.mode enum ["download","extract","json","xpath","rdf","metalink","fosshub","sourceforge"]
    # Reason: Scoop only supports these hash extraction modes, other values are likely typos
    # Note: "github" works functionally but is not in official schema, consider removing hash block for auto-detection
    # Check: hash.mode not in Schema enum list -> warning
    # False positive risk: very low
    $validHashModes = @('download', 'extract', 'json', 'xpath', 'rdf', 'metalink', 'fosshub', 'sourceforge')
    if ($json.autoupdate -and $json.autoupdate.hash -and $json.autoupdate.hash.mode) {
        if ($json.autoupdate.hash.mode -notin $validHashModes) {
            Write-Result -Level warning -File $file.FullName -Message "autoupdate.hash.mode unconventional value: $($json.autoupdate.hash.mode) (expected $($validHashModes -join '/'))"
        }
    }

    # ── Collect script lines (shared by multiple rules below) ──
    $scriptLines = Get-ScriptLines $json

    # ── Process termination convention ──
    # Convention (AGENTS.md): Stop-Process must use -Force -ErrorAction SilentlyContinue, -Name must not include .exe
    foreach ($line in $scriptLines) {
        if ($line -match 'Stop-Process') {
            if ($line -notmatch '-Force') {
                Write-Result -Level error -File $file.FullName -Message "Stop-Process missing -Force: $line"
            }
            if ($line -notmatch '-ErrorAction\s+SilentlyContinue') {
                Write-Result -Level error -File $file.FullName -Message "Stop-Process missing -ErrorAction SilentlyContinue: $line"
            }
            if ($line -match '-Name\s+.*\.exe') {
                Write-Result -Level error -File $file.FullName -Message "Stop-Process -Name contains .exe suffix (PS -Name does not match .exe): $line"
            }
        }
    }

    # ── GUI apps must terminate process ──
    # Convention (AGENTS.md): GUI apps with shortcuts must terminate the process in uninstaller.script
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
            Write-Result -Level error -File $file.FullName -Message "Has shortcuts (GUI app) but no Stop-Process in uninstaller.script"
        }
    }

    # ── uninstaller.script takes priority ──
    # Convention (AGENTS.md): process/service termination logic must be in uninstaller.script, not pre_uninstall
    if ($json.pre_uninstall) {
        $preUninstall = $json.pre_uninstall
        if ($preUninstall -is [string]) { $preUninstall = @($preUninstall) }
        foreach ($line in $preUninstall) {
            if ($line -match 'Stop-Process') {
                Write-Result -Level error -File $file.FullName -Message "Stop-Process in pre_uninstall, should be in uninstaller.script (Scoop prompts user to save work before uninstaller.script)"
                break
            }
        }
    }

    # ── Registry operations ──
    # Convention (AGENTS.md): New-ItemProperty must have -Force; Remove-ItemProperty must have -ErrorAction SilentlyContinue
    foreach ($line in $scriptLines) {
        if ($line -match 'New-ItemProperty') {
            if ($line -notmatch '-Force') {
                Write-Result -Level error -File $file.FullName -Message "New-ItemProperty missing -Force (fails on reinstall when property exists): $line"
            }
        }
        if ($line -match 'Remove-ItemProperty') {
            if ($line -notmatch '-ErrorAction\s+SilentlyContinue') {
                Write-Result -Level error -File $file.FullName -Message "Remove-ItemProperty missing -ErrorAction SilentlyContinue (errors when registry key does not exist): $line"
            }
        }
    }

    # ── Invoke-Expression prohibited ──
    # Convention (AGENTS.md): use & operator to invoke scripts, never Invoke-Expression
    # Reason: Invoke-Expression accepts and executes strings, improper concatenation can cause code injection;
    #        & operator invokes commands directly without string parsing, safer
    # Check: search script lines for Invoke-Expression
    # False positive risk: very low
    foreach ($line in $scriptLines) {
        if ($line -match 'Invoke-Expression') {
            Write-Result -Level error -File $file.FullName -Message "Invoke-Expression is prohibited (use '&' operator instead): $line"
        }
    }

    # ── User directory paths ──
    # Convention (AGENTS.md): must use [Environment]::GetFolderPath('MyDocuments') for user documents,
    #                       hardcoding $home\Documents is prohibited
    # Reason: OneDrive folder backup, enterprise GPO folder redirection etc.
    #        $home\Documents may not exist or point to wrong location
    # Check: search script lines for $home\Documents or $home/Documents pattern
    # False positive risk: very low
    foreach ($line in $scriptLines) {
        if ($line -match '(?i)\$home[/\\]+Documents') {
            Write-Result -Level error -File $file.FullName -Message "Hardcoded `$home\Documents is prohibited (use [Environment]::GetFolderPath('MyDocuments')): $line"
        }
    }

    # ── New-Item with -Force ──
    # Convention (AGENTS.md): add -Force when creating file placeholders to avoid errors on reinstall
    # Reason: placeholder file may already exist on reinstall, New-Item without -Force fails with "file already exists"
    # Check: New-Item call without -Force (excluding Junction, which has its own delete-then-recreate rule)
    # False positive risk: low
    foreach ($line in $scriptLines) {
        if ($line -match 'New-Item\b' -and $line -notmatch '-Force' -and $line -notmatch 'Junction') {
            Write-Result -Level warning -File $file.FullName -Message "New-Item missing -Force (may error on reinstall): $line"
        }
    }

    # ── Uninstaller existence check ──
    # Convention (AGENTS.md): must use Test-Path to check file existence before calling app's built-in uninstaller
    # Reason: uninstaller may not exist (user deleted or incomplete install), direct call causes script abort
    # Check: script calls $dir\Uninstall etc. but lacks Test-Path guard
    # False positive risk: low
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
        Write-Result -Level error -File $file.FullName -Message "Uninstaller called without Test-Path existence check (AGENTS.md convention)"
    }

    # ── Registry protocol paths must use current ──
    # Convention (AGENTS.md): registry paths must use $(Split-Path $dir -Parent)\current\<exe>,
    #                       not "$dir\<exe>" (versioned path, invalid after update)
    # Reason: Scoop deletes old version dir and creates new current symlink on update,
    #        hardcoded versioned path in registry points to deleted dir after update
    # Check: registry script line contains $dir\ but not current\
    # False positive risk: low
    foreach ($line in $scriptLines) {
        if ($line -match 'Set-ItemProperty|New-ItemProperty|New-Item.*HK' -and
            $line -match '\$dir\\' -and $line -notmatch 'current\\') {
            Write-Result -Level error -File $file.FullName -Message "Registry path uses versioned `$dir\ (should use $(Split-Path $dir -Parent)\current\): $line"
        }
    }

    # ── Shortcuts name starts with ..\ ──
    # Convention (AGENTS.md): shortcut name starts with "..\", Chinese display name, separated by "-"
    # Reason: Scoop shortcuts are placed in Scoop Apps directory by default, "..\" makes shortcut appear
    #        in Start Menu's parent folder instead of nested in Scoop subfolder
    # Check: second element of shortcut entry does not start with "..\"
    # False positive risk: low
    if ($json.shortcuts) {
        foreach ($shortcut in $json.shortcuts) {
            if ($shortcut.Count -ge 2 -and $shortcut[1] -notmatch '^\.\.[/\\]') {
                Write-Result -Level warning -File $file.FullName -Message "Shortcut name '$($shortcut[1])' does not start with '..\' (AGENTS.md convention: shortcuts should appear in Start Menu parent directory)"
            }
        }
    }

    # ── Single file persist requires placeholder ──
    # Convention (AGENTS.md): when persisting a single file (not folder), must create empty file placeholder in pre_install
    # Reason: Scoop persist mechanism creates folder symlink for non-existent targets,
    #        causing app to fail reading/writing config files (e.g. SQLite DB, JSON config)
    # Check: persist is a string with file extension, pre_install should create corresponding file placeholder
    # False positive risk: low
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
            Write-Result -Level error -File $file.FullName -Message "persist '$persistFile' is a single file but no placeholder created in pre_install (Scoop will create folder symlink, causing app read/write failure)"
        }
    }

    # ── Output current file check result ──
    if (-not $CI) {
        Write-Host " [OK] $($json.version)" -ForegroundColor Green
    }
}

# ─────────────────────────── Summary ───────────────────────────

Write-Host ''
if ($hasError) {
    Write-Host "Found $errorCount error(s), $warningCount warning(s)" -ForegroundColor Red
    exit 1
}
if ($warningCount -gt 0) {
    Write-Host "Found $warningCount warning(s) (non-blocking)" -ForegroundColor Yellow
}
Write-Host "All manifests passed validation" -ForegroundColor Green
exit 0
