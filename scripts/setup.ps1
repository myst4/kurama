#Requires -Version 5.1

<#
.SYNOPSIS
    Kurama — Full Setup Script for Windows
.DESCRIPTION
    Detects installed agents, copies skills, and configures orchestrator prompts.
    Idempotent: safe to run multiple times (uses markers to avoid duplication).
.PARAMETER Agent
    Install for a specific agent.
    Valid values: claude-code, opencode, gemini-cli, cursor, vscode, codex, pi
.PARAMETER All
    Auto-detect and install for all found agents.
.PARAMETER OpenCodeMode
    OpenCode agent mode: 'single' (default) or 'multi' (one agent per phase with its own model).
.PARAMETER NonInteractive
    No prompts (for external installers like gentle-ai).
.EXAMPLE
    .\setup.ps1
.EXAMPLE
    .\setup.ps1 -All
.EXAMPLE
    .\setup.ps1 -Agent opencode -OpenCodeMode multi
.EXAMPLE
    .\setup.ps1 -NonInteractive
#>

[CmdletBinding()]
param(
    [ValidateSet('claude-code', 'opencode', 'gemini-cli', 'cursor', 'vscode', 'codex', 'pi')]
    [string]$Agent,
    [ValidateSet('single', 'multi')]
    [string]$OpenCodeMode,
    # O1: install scope. 'global' (default) writes to the per-user config dirs;
    # 'project' installs everything into a single git repo (-Path) to trial Kurama.
    [ValidateSet('global', 'project')]
    [string]$Scope = 'global',
    [string]$Path,
    [switch]$WithPiPackages,
    [switch]$WithoutPiPackages,
    # O5: Engram optional persistence engine. -WithEngram registers its MCP into
    # the client being configured; -WithoutEngram keeps the markdown fallback.
    [switch]$WithEngram,
    [switch]$WithoutEngram,
    [switch]$All,
    [switch]$NonInteractive,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Paths
# ============================================================================

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoDir = Split-Path -Parent $ScriptRoot
$SkillsSrc = Join-Path $RepoDir 'skills'
$ExamplesDir = Join-Path $RepoDir 'examples'
$VersionFile = Join-Path $RepoDir 'VERSION'

# Name of the per-target install manifest — identical to install.ps1 and setup.sh
# so scripts/uninstall can remove exactly what a setup.ps1 install wrote (skills,
# _shared conventions, and the native Claude Code agents). Without this receipt a
# setup.ps1 install would be un-uninstallable (orphaned skills + agents).
$InstallManifestName = '.kurama-install-manifest.json'

$MarkerBegin = '<!-- BEGIN:kurama -->'
$MarkerEnd = '<!-- END:kurama -->'

# gentle-ai-installer markers (detect to avoid duplication)
$GaiMarkerBegin = '<!-- gentle-ai:sdd-orchestrator -->'
$GaiMarkerEnd = '<!-- /gentle-ai:sdd-orchestrator -->'

# Pinned npm dependency for the OpenCode background-agents plugin.
# Version-locked and installed with --ignore-scripts to limit supply-chain risk.
$UniqueNamesGeneratorVersion = '4.7.1'

# ----------------------------------------------------------------------------
# N5: Pi package stack (opt-in). Mirrors setup.sh. Versions are PINNED — they
# were resolved once with `npm view <pkg> version` (the only network call) and
# hardcoded for a reproducible, auditable install. Refresh a pin with
# `npm view <pkg> version`.
#
# EXCLUSION — gentle-pi is deliberately NOT installed. It is a rival harness
# that conflicts with Kurama's own orchestrator rule and skills on Pi. Never
# add it here.
$PiPkgGentleEngramVersion = '0.1.10'
$PiPkgMcpAdapterVersion   = '2.11.0'
$PiPkgSubagentsVersion    = '1.4.1'
$PiPkgAskUserVersion      = '2.0.0'
$PiPkgWebAccessVersion    = '0.13.0'
$PiPkgTodoVersion         = '2.0.0'
$PiPkgBtwVersion          = '0.4.1'

# Content headings that indicate orchestrator is already present
$OrchestratorHeadings = @(
    '## Kurama Orchestrator',
    '## Spec-Driven Development (SDD) Orchestrator',
    '## Spec-Driven Development (SDD)'
)

$SkillsPaths = @{
    'claude-code' = Join-Path $env:USERPROFILE '.claude\skills'
    'opencode'    = Join-Path $env:USERPROFILE '.config\opencode\skills'
    'gemini-cli'  = Join-Path $env:USERPROFILE '.gemini\skills'
    'cursor'      = Join-Path $env:USERPROFILE '.cursor\skills'
    'vscode'      = Join-Path $env:USERPROFILE '.copilot\skills'
    'codex'       = Join-Path $env:USERPROFILE '.codex\skills'
    'pi'          = Join-Path $env:USERPROFILE '.pi\agent\skills'
}

$PromptPaths = @{
    'claude-code' = Join-Path $env:USERPROFILE '.claude\CLAUDE.md'
    'opencode'    = Join-Path $env:USERPROFILE '.config\opencode\AGENTS.md'
    'gemini-cli'  = Join-Path $env:USERPROFILE '.gemini\GEMINI.md'
    'cursor'      = Join-Path $env:USERPROFILE '.cursor\rules\kurama.mdc'
    'vscode'      = Join-Path $env:APPDATA 'Code\User\prompts\kurama.instructions.md'
    'codex'       = Join-Path $env:USERPROFILE '.codex\agents.md'
    'pi'          = Join-Path $env:USERPROFILE '.pi\agent\AGENTS.md'
}

$ExampleFiles = @{
    'claude-code' = Join-Path $ExamplesDir 'claude-code\CLAUDE.md'
    'gemini-cli'  = Join-Path $ExamplesDir 'gemini-cli\GEMINI.md'
    'cursor'      = Join-Path $ExamplesDir 'cursor\.cursor\rules\sdd-orchestrator.mdc'
    'vscode'      = Join-Path $ExamplesDir 'vscode\copilot-instructions.md'
    'codex'       = Join-Path $ExamplesDir 'codex\agents.md'
    'pi'          = Join-Path $ExamplesDir 'pi\AGENTS.md'
}

$AgentBinaries = @{
    'claude-code' = 'claude'
    'opencode'    = 'opencode'
    'gemini-cli'  = 'gemini'
    'cursor'      = 'cursor'
    'vscode'      = 'code'
    'codex'       = 'codex'
    'pi'          = 'pi'
}

# O2: Claude Code hooks source (always installed for claude-code, both scopes).
$HooksSrc = Join-Path $ExamplesDir 'claude-code\hooks'
$HookScripts = @('orchestrator-write-guard.sh', 'archive-gate.sh', 'README.md')

# O1: resolved once by Confirm-ProjectTarget when Scope=project (absolute repo root).
$script:TargetPath = ''

# Receipt accumulators — filled across Install-Skills / Install-Hooks / Pi steps,
# flushed once by Write-Receipt at the end of Set-Agent (mirrors setup.sh).
$script:ReceiptDir = ''
$script:ReceiptTool = ''
$script:ReceiptFiles = $null
$script:ReceiptSettings = $null
$script:ReceiptPiPackages = $null
$script:ReceiptEngramMcp = $null   # O5: config files an Engram MCP server was written to

# O5: Engram optional persistence engine state (mirrors setup.sh).
$script:Engram = ''                # '', 'yes', or 'no'
$script:EngramBinaryChecked = $false
$EngramReleasesUrl = 'https://github.com/Gentleman-Programming/engram/releases'

# ---- Scope-aware target resolution (mirrors setup.sh scoped_* helpers) ----

function Get-ScopedSkillsPath {
    param([string]$AgentName)
    if ($Scope -eq 'project') {
        if ($AgentName -eq 'pi') { return (Join-Path $script:TargetPath '.pi\skills') }
        return (Join-Path $script:TargetPath '.claude\skills')
    }
    return $SkillsPaths[$AgentName]
}

function Get-ScopedAgentsPath {
    param([string]$AgentName)
    if ($Scope -eq 'project') {
        if ($AgentName -eq 'pi') { return (Join-Path $script:TargetPath '.pi\agents') }
        return (Join-Path $script:TargetPath '.claude\agents')
    }
    if ($AgentName -eq 'pi') { return (Join-Path $env:USERPROFILE '.pi\agent\agents') }
    return (Join-Path (Split-Path -Parent $SkillsPaths[$AgentName]) 'agents')
}

function Get-ScopedPromptPath {
    param([string]$AgentName)
    if ($Scope -eq 'project') {
        if ($AgentName -eq 'pi' -or $AgentName -eq 'opencode') { return (Join-Path $script:TargetPath 'AGENTS.md') }
        return (Join-Path $script:TargetPath 'CLAUDE.md')
    }
    return $PromptPaths[$AgentName]
}

function Get-ScopedHooksDir {
    if ($Scope -eq 'project') { return (Join-Path $script:TargetPath '.claude\hooks\kurama') }
    return (Join-Path $env:USERPROFILE '.claude\hooks\kurama')
}

function Get-ScopedSettingsFile {
    if ($Scope -eq 'project') { return (Join-Path $script:TargetPath '.claude\settings.json') }
    return (Join-Path $env:USERPROFILE '.claude\settings.json')
}

function Get-ScopedReceiptDir {
    param([string]$AgentName)
    if ($Scope -eq 'project') { return $script:TargetPath }
    return (Get-ScopedSkillsPath $AgentName)
}

# Compute a path relative to $script:ReceiptDir (mirrors setup.sh receipt_rel).
function Get-ReceiptRel {
    param([string]$AbsPath)
    $root = $script:ReceiptDir
    $abs = [System.IO.Path]::GetFullPath($AbsPath)
    $rootFull = [System.IO.Path]::GetFullPath($root)
    if ($abs.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar)) {
        $rel = $abs.Substring($rootFull.Length + 1)
    } else {
        $parent = Split-Path -Parent $rootFull
        if ($abs.StartsWith($parent + [System.IO.Path]::DirectorySeparatorChar)) {
            $rel = '../' + $abs.Substring($parent.Length + 1)
        } else {
            $rel = $abs
        }
    }
    return ($rel -replace '\\', '/')
}

# O1: validate -Path for project scope (exists, git repo, never the Kurama repo).
function Confirm-ProjectTarget {
    if ($Scope -ne 'project') { return }
    if (-not $script:TargetPath) { $script:TargetPath = (Get-Location).Path }
    if (-not (Test-Path $script:TargetPath -PathType Container)) {
        throw "Project target does not exist: $script:TargetPath"
    }
    $script:TargetPath = (Resolve-Path $script:TargetPath).Path
    $repoAbs = (Resolve-Path $RepoDir).Path
    if ($script:TargetPath -eq $repoAbs) {
        throw "Refusing to install into the Kurama repo itself: $script:TargetPath"
    }
    $isGit = $false
    try { git -C $script:TargetPath rev-parse --is-inside-work-tree 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $isGit = $true } } catch {}
    if (-not $isGit) {
        if ($NonInteractive) { throw "Project target is not a git repository: $script:TargetPath" }
        Write-Warn "Project target is not a git repository: $script:TargetPath"
        $ans = Read-Host '  Install anyway? [y/N]'
        if ($ans -notmatch '^[Yy]') { throw 'Aborted.' }
    }
    Write-Ok "Project scope target: $script:TargetPath"
}

# ============================================================================
# Display Helpers
# ============================================================================

function Write-Ok    { param([string]$Msg) Write-Host '  ' -NoNewline; Write-Host ([char]0x2713) -ForegroundColor Green -NoNewline; Write-Host " $Msg" }
function Write-Warn  { param([string]$Msg) Write-Host '  ! ' -ForegroundColor Yellow -NoNewline; Write-Host $Msg }
function Write-Fail  { param([string]$Msg) Write-Host '  ' -NoNewline; Write-Host ([char]0x2717) -ForegroundColor Red -NoNewline; Write-Host " $Msg" }
function Write-Info  { param([string]$Msg) Write-Host '  ' -NoNewline; Write-Host ([char]0x2192) -ForegroundColor Blue -NoNewline; Write-Host " $Msg" }
function Write-Head  { param([string]$Msg) Write-Host ''; Write-Host $Msg -ForegroundColor Cyan }

# ============================================================================
# Agent Detection
# ============================================================================

function Find-Agents {
    Write-Head 'Detecting installed agents...'

    $found = @()
    foreach ($agent in $AgentBinaries.Keys | Sort-Object) {
        $binary = $AgentBinaries[$agent]
        $cmd = Get-Command $binary -ErrorAction SilentlyContinue
        if ($cmd) {
            Write-Ok "$agent ($binary found in PATH)"
            $found += $agent
        }
    }

    Write-Host ''
    if ($found.Count -eq 0) {
        Write-Warn 'No agents detected in PATH'
        Write-Info 'You can still install manually with: .\install.ps1'
    } else {
        Write-Host "  $($found.Count) agent(s) detected" -ForegroundColor Green
    }

    return $found
}

# ============================================================================
# Version + manifest helpers
# Kept in sync with install.ps1 / setup.sh so every installer writes the SAME
# per-target receipt. uninstall then removes exactly what was written.
# ============================================================================

function Get-KuramaVersion {
    if (Test-Path $VersionFile) {
        $v = Get-Content -Path $VersionFile -TotalCount 1 -ErrorAction SilentlyContinue
        if ($v) { return $v.Trim() }
    }
    return 'unknown'
}

# Short commit SHA of the Kurama repo this setup runs from, used to stamp the
# receipt (V3). Returns '' when git is unavailable or HEAD is missing; the caller
# then omits the "commit" field so it never breaks a parser or a git-less host.
function Get-KuramaCommit {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return '' }
    try {
        $c = & git -C $RepoDir rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $c) { return ([string]$c).Trim() }
    } catch { }
    return ''
}

# Flush the receipt accumulators to $script:ReceiptDir. Extends the base schema
# with additive 'scope', 'settings' and 'pi_packages' fields (mirrors setup.sh's
# finalize_receipt); older consumers ignore what they do not know.
function Write-Receipt {
    if (-not $script:ReceiptDir) { return }
    $obj = [ordered]@{
        name        = 'kurama'
        version     = (Get-KuramaVersion)
    }
    $commit = Get-KuramaCommit
    if ($commit) { $obj.commit = $commit }
    $obj.tool        = $script:ReceiptTool
    $obj.scope       = $Scope
    $obj.engram      = $(if ($script:Engram) { $script:Engram } else { 'no' })
    $obj.files       = @($script:ReceiptFiles)
    $obj.settings    = @($script:ReceiptSettings)
    $obj.pi_packages = @($script:ReceiptPiPackages)
    $obj.engram_mcp  = @($script:ReceiptEngramMcp)
    $json = $obj | ConvertTo-Json -Depth 4
    New-Item -ItemType Directory -Path $script:ReceiptDir -Force | Out-Null
    $manifestPath = Join-Path $script:ReceiptDir $InstallManifestName
    Set-Content -Path $manifestPath -Value $json -Encoding UTF8
}

# ============================================================================
# Install Skills
# ============================================================================

function Install-Skills {
    param([string]$AgentName)

    $TargetDir = Get-ScopedSkillsPath $AgentName
    $script:ReceiptTool = $AgentName
    $script:ReceiptDir = Get-ScopedReceiptDir $AgentName

    Write-Info "Installing skills -> $TargetDir"
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null

    # Receipt-relative paths we write (recorded so uninstall removes exactly what
    # we installed: skills, _shared, native agents, and — claude-code — hooks).
    $installedFiles = $script:ReceiptFiles

    # Copy _shared
    $sharedSrc = Join-Path $SkillsSrc '_shared'
    $sharedTarget = Join-Path $TargetDir '_shared'
    if (Test-Path $sharedSrc) {
        New-Item -ItemType Directory -Path $sharedTarget -Force | Out-Null
        foreach ($sharedFile in @(Get-ChildItem -Path $sharedSrc -Filter '*.md' -File)) {
            Copy-Item -Path $sharedFile.FullName -Destination $sharedTarget -Force
            $installedFiles.Add((Get-ReceiptRel (Join-Path $sharedTarget $sharedFile.Name)))
        }
        Write-Ok '_shared conventions'
    }

    # Copy all distributable skills, manifest-driven: skills/manifest.json is the
    # single source of truth (mirrors setup.sh's manifest_skill_lines and
    # install.ps1's Get-ManifestSkills — a hardcoded list here already drifted
    # once, silently omitting kanban-github). The default set is every
    # default-on group; installing the `tdd` module does NOT activate TDD
    # (activation stays opt-in per project).
    $count = 0
    $manifestFile = Join-Path $SkillsSrc 'manifest.json'
    if (-not (Test-Path $manifestFile)) {
        throw "Missing skills/manifest.json (the skill list source of truth)"
    }
    $defaultGroups = @{ 'sdd-core' = $true; 'quality' = $true; 'review' = $true; 'optional' = $true; 'tdd' = $true }
    $manifest = Get-Content -Path $manifestFile -Raw | ConvertFrom-Json
    $skillDirs = @()
    foreach ($entry in $manifest.skills) {
        if (-not $defaultGroups.ContainsKey($entry.group)) { continue }
        $entryDir = Join-Path $SkillsSrc $entry.name
        if (Test-Path $entryDir) {
            $skillDirs += Get-Item $entryDir
        }
    }

    foreach ($skillDir in $skillDirs) {
        $skillFile = Join-Path $skillDir.FullName 'SKILL.md'
        if (-not (Test-Path $skillFile)) { continue }

        $targetSkillDir = Join-Path $TargetDir $skillDir.Name
        New-Item -ItemType Directory -Path $targetSkillDir -Force | Out-Null
        Copy-Item -Path $skillFile -Destination (Join-Path $targetSkillDir 'SKILL.md') -Force
        $installedFiles.Add((Get-ReceiptRel (Join-Path $targetSkillDir 'SKILL.md')))
        $count++
    }

    Write-Ok "$count skills installed"

    # Native subagents: claude-code ships Claude-format agents; pi ships the
    # Pi-format agents (O4 wiring). Every other target has none. Pre-existing
    # files are backed up then atomically replaced; each is recorded in the
    # receipt so uninstall removes them too.
    switch ($AgentName) {
        'claude-code' { Install-NativeAgents (Join-Path $ExamplesDir 'claude-code\agents') 'Claude Code' $AgentName }
        'pi'          { Install-NativeAgents (Join-Path $ExamplesDir 'pi\agents') 'Pi' $AgentName }
    }
}

# Install every *.md agent from $AgentsSrc into the scoped agents dir, backing up
# any pre-existing same-named file and recording each in the receipt.
function Install-NativeAgents {
    param([string]$AgentsSrc, [string]$Label, [string]$AgentName)
    $agentsTarget = Get-ScopedAgentsPath $AgentName
    if (-not (Test-Path $AgentsSrc)) {
        Write-Warn "$Label agents source not found: $AgentsSrc (skipped)"
        return
    }
    New-Item -ItemType Directory -Path $agentsTarget -Force | Out-Null
    $acount = 0
    foreach ($agentFile in @(Get-ChildItem -Path $AgentsSrc -Filter '*.md' -File)) {
        $agentDest = Join-Path $agentsTarget $agentFile.Name
        if (Test-Path $agentDest) { Backup-File -Path $agentDest }
        Write-AtomicFile -Path $agentDest -Content (Get-Content -Path $agentFile.FullName -Raw) -NoNewline
        $script:ReceiptFiles.Add((Get-ReceiptRel $agentDest))
        $acount++
    }
    Write-Ok "$acount $Label agents installed -> $agentsTarget"
}

# ============================================================================
# O2: Claude Code hooks (ALWAYS installed for claude-code, both scopes)
#
# Copies the two gate scripts to <target>/hooks/kurama/ and merges a PreToolUse
# block into the matching settings.json using PowerShell-native JSON (idempotent,
# backed up, atomic). Every command string contains 'hooks/kurama/' so uninstall
# can filter our entries out surgically.
# ============================================================================

function Install-Hooks {
    $hooksDir = Get-ScopedHooksDir
    $settingsFile = Get-ScopedSettingsFile

    if (-not (Test-Path $HooksSrc)) {
        Write-Warn "Hooks source not found: $HooksSrc (skipped)"
        return
    }

    Write-Head 'Installing Claude Code hooks'
    New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null

    foreach ($script in $HookScripts) {
        $src = Join-Path $HooksSrc $script
        if (-not (Test-Path $src)) { Write-Warn "Missing hook script: $script"; continue }
        $dest = Join-Path $hooksDir $script
        Write-AtomicFile -Path $dest -Content (Get-Content -Path $src -Raw) -NoNewline
        $script:ReceiptFiles.Add((Get-ReceiptRel $dest))
    }
    Write-Ok "hook scripts -> $hooksDir"

    if ($Scope -eq 'project') {
        $guardCmd = '$CLAUDE_PROJECT_DIR/.claude/hooks/kurama/orchestrator-write-guard.sh'
        $gateCmd  = '$CLAUDE_PROJECT_DIR/.claude/hooks/kurama/archive-gate.sh'
    } else {
        $guardCmd = ((Join-Path $hooksDir 'orchestrator-write-guard.sh') -replace '\\', '/')
        $gateCmd  = ((Join-Path $hooksDir 'archive-gate.sh') -replace '\\', '/')
    }

    Merge-HooksSettings -SettingsFile $settingsFile -GuardCmd $guardCmd -GateCmd $gateCmd
    $script:ReceiptSettings.Add((Get-ReceiptRel $settingsFile))
}

# Careful, idempotent JSON merge of the Kurama PreToolUse hooks. Removes any
# prior kurama entries (matched by the 'hooks/kurama/' substring) before adding.
function Merge-HooksSettings {
    param([string]$SettingsFile, [string]$GuardCmd, [string]$GateCmd)

    New-Item -ItemType Directory -Path (Split-Path -Parent $SettingsFile) -Force | Out-Null

    if (Test-Path $SettingsFile) {
        try { $settings = Get-Content -Path $SettingsFile -Raw | ConvertFrom-Json } catch { $settings = [PSCustomObject]@{} }
        Backup-File $SettingsFile
    } else {
        $settings = [PSCustomObject]@{}
    }

    if (-not $settings.PSObject.Properties['hooks']) {
        $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    if (-not $settings.hooks.PSObject.Properties['PreToolUse']) {
        $settings.hooks | Add-Member -NotePropertyName 'PreToolUse' -NotePropertyValue @() -Force
    }

    # Drop any existing kurama entries (idempotent re-run).
    $kept = @()
    foreach ($entry in @($settings.hooks.PreToolUse)) {
        $cmds = @()
        if ($entry.PSObject.Properties['hooks']) {
            foreach ($h in @($entry.hooks)) { if ($h.PSObject.Properties['command']) { $cmds += $h.command } }
        }
        if (($cmds -join ' ') -notmatch 'hooks/kurama/') { $kept += $entry }
    }
    $kept += [PSCustomObject]@{ matcher = 'Edit|Write|MultiEdit'; hooks = @([PSCustomObject]@{ type = 'command'; command = $GuardCmd }) }
    $kept += [PSCustomObject]@{ matcher = 'Task|Skill';           hooks = @([PSCustomObject]@{ type = 'command'; command = $GateCmd }) }
    $settings.hooks.PreToolUse = $kept

    Write-AtomicFile -Path $SettingsFile -Content ($settings | ConvertTo-Json -Depth 12)
    Write-Ok "hooks merged into $SettingsFile"
}

# ============================================================================
# Safe File Operations
# Mirror the bash setup.sh guarantees: never truncate user content, always back
# up before modifying, and replace files atomically via a temp file + move.
# ============================================================================

function Assert-BalancedMarkers {
    param(
        [string]$Content,
        [string]$Begin,
        [string]$End,
        [string]$Label,
        [string]$Path
    )
    # A marker pair present on only one side (BEGIN without END, or vice versa)
    # would make the regex replace below either no-op (false success) or, worse,
    # match too greedily. Refuse to touch the file instead of risking data loss.
    $hasBegin = $Content -match [regex]::Escape($Begin)
    $hasEnd = $Content -match [regex]::Escape($End)
    if ($hasBegin -ne $hasEnd) {
        $missing = if ($hasBegin) { $End } else { $Begin }
        throw "Unbalanced $Label markers in $Path (missing '$missing'). Refusing to modify the file to avoid data loss. Fix the markers and re-run."
    }
}

function Backup-File {
    param([string]$Path)
    if (Test-Path $Path) {
        $ts = Get-Date -Format 'yyyyMMddHHmmss'
        $backup = "$Path.bak.$ts"
        Copy-Item -Path $Path -Destination $backup -Force
        Write-Info "Backup written: $backup"
    }
}

function Write-AtomicFile {
    param(
        [string]$Path,
        [string]$Content,
        [switch]$NoNewline
    )
    # Write to a temp file in the SAME directory, then move over the target so an
    # interrupted write can never leave the destination half-written.
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = Join-Path $dir ("." + [System.IO.Path]::GetRandomFileName() + ".tmp")
    if ($NoNewline) {
        Set-Content -Path $tmp -Value $Content -NoNewline
    } else {
        Set-Content -Path $tmp -Value $Content
    }
    Move-Item -Path $tmp -Destination $Path -Force
}

# ============================================================================
# Setup Orchestrator Prompt (idempotent with markers)
# ============================================================================

function Set-Orchestrator {
    param([string]$PromptPath, [string]$ExampleFile, [string]$AgentName)

    if (-not $ExampleFile -or -not (Test-Path $ExampleFile)) { return }

    $promptDir = Split-Path -Parent $PromptPath
    New-Item -ItemType Directory -Path $promptDir -Force | Out-Null

    # Cursor's target is a dedicated .mdc file owned by this tool, and .mdc YAML
    # frontmatter must start at byte 0 — marker wrapping would break it. Copy the
    # generated rule verbatim (with backup) instead of marker-merging.
    if ($AgentName -eq 'cursor') {
        if (Test-Path $PromptPath) { Backup-File -Path $PromptPath }
        Write-AtomicFile -Path $PromptPath -Content (Get-Content -Path $ExampleFile -Raw)
        Write-Info "Wrote $PromptPath (verbatim .mdc copy)"
        return
    }

    # Strip preamble (human-readable header) — only inject from "## Kurama" onward
    $rawContent = Get-Content -Path $ExampleFile -Raw
    if ($rawContent -match '(?s)(## Kurama.*)') {
        $content = $Matches[1]
    } else {
        $content = $rawContent
    }

    if (Test-Path $PromptPath) {
        $existing = Get-Content -Path $PromptPath -Raw

        # Guard against data loss from an unbalanced marker pair before rewriting.
        Assert-BalancedMarkers -Content $existing -Begin $MarkerBegin -End $MarkerEnd -Label 'kurama' -Path $PromptPath
        Assert-BalancedMarkers -Content $existing -Begin $GaiMarkerBegin -End $GaiMarkerEnd -Label 'gentle-ai' -Path $PromptPath

        if ($existing -match [regex]::Escape($MarkerBegin)) {
            # Our markers exist — replace content between them. Markers are
            # balanced (asserted above), so the replace is guaranteed to match.
            Backup-File $PromptPath
            $pattern = "(?s)$([regex]::Escape($MarkerBegin)).*?$([regex]::Escape($MarkerEnd))"
            $replacement = "$MarkerBegin`n$content`n$MarkerEnd"
            $updated = [regex]::Replace($existing, $pattern, $replacement)
            Write-AtomicFile -Path $PromptPath -Content $updated -NoNewline
            Write-Ok "Orchestrator updated in $PromptPath"
        } elseif ($existing -match [regex]::Escape($GaiMarkerBegin)) {
            # gentle-ai markers exist — replace with ours
            Backup-File $PromptPath
            $pattern = "(?s)$([regex]::Escape($GaiMarkerBegin)).*?$([regex]::Escape($GaiMarkerEnd))"
            $replacement = "$MarkerBegin`n$content`n$MarkerEnd"
            $updated = [regex]::Replace($existing, $pattern, $replacement)
            Write-AtomicFile -Path $PromptPath -Content $updated -NoNewline
            Write-Ok "Orchestrator updated in $PromptPath (replaced gentle-ai section)"
        } else {
            # Check if orchestrator content already exists (no markers)
            $alreadyPresent = $false
            foreach ($heading in $OrchestratorHeadings) {
                if ($existing.Contains($heading)) {
                    $alreadyPresent = $true
                    break
                }
            }

            if ($alreadyPresent) {
                Write-Warn "Orchestrator already present in $PromptPath (no markers found)"
                Write-Info "To enable auto-updates, wrap the SDD section with:"
                Write-Info "  $MarkerBegin"
                Write-Info "  $MarkerEnd"
            } else {
                # No existing content — append our marked section atomically
                Backup-File $PromptPath
                $appendContent = "$existing`n`n$MarkerBegin`n$content`n$MarkerEnd"
                Write-AtomicFile -Path $PromptPath -Content $appendContent -NoNewline
                Write-Ok "Orchestrator appended to $PromptPath"
            }
        }
    } else {
        # Create new file
        $newContent = "$MarkerBegin`n$content`n$MarkerEnd"
        Write-AtomicFile -Path $PromptPath -Content $newContent
        Write-Ok "Orchestrator created at $PromptPath"
    }
}

# ============================================================================
# OpenCode Special Handling
# ============================================================================

function Ask-OpenCodeMode {
    # If already set via parameter, skip
    if ($script:OpenCodeMode) { return }

    # Non-interactive defaults to single
    if ($NonInteractive) {
        $script:OpenCodeMode = 'single'
        return
    }

    Write-Host ''
    Write-Host '  OpenCode agent mode:' -ForegroundColor White
    Write-Host ''
    Write-Host '  1) Single model  - one agent handles all phases (simple, recommended)'
    Write-Host '  2) Multi-model   - one agent per phase, each with its own model'
    Write-Host ''
    $choice = Read-Host '  Choice [1]'
    if (-not $choice) { $choice = '1' }

    switch ($choice) {
        { $_ -eq '2' -or $_ -eq 'multi' } { $script:OpenCodeMode = 'multi' }
        default { $script:OpenCodeMode = 'single' }
    }
}

function Set-OpenCode {
    $commandsSrc = Join-Path $ExamplesDir 'opencode\commands'
    $commandsTarget = Join-Path $env:USERPROFILE '.config\opencode\commands'
    $configFile = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'

    # Determine mode and pick the right config template
    Ask-OpenCodeMode
    $exampleConfig = Join-Path $ExamplesDir "opencode\opencode.$($script:OpenCodeMode).json"
    Write-Info "OpenCode mode: $($script:OpenCodeMode)"

    # Install commands
    if (Test-Path $commandsSrc) {
        New-Item -ItemType Directory -Path $commandsTarget -Force | Out-Null
        $count = 0
        Get-ChildItem -Path $commandsSrc -Filter 'sdd-*.md' | ForEach-Object {
            $cmdName = $_.BaseName
            $content = Get-Content -Path $_.FullName -Raw

            if ($script:OpenCodeMode -eq 'multi' -and $content -match '(?m)^subtask:') {
                # Multi mode: subtask commands point to their dedicated subagent
                $modified = $content -replace '(?m)^agent: sdd-orchestrator', "agent: $cmdName"
                Set-Content -Path (Join-Path $commandsTarget $_.Name) -Value $modified -NoNewline
            } else {
                Copy-Item -Path $_.FullName -Destination (Join-Path $commandsTarget $_.Name) -Force
            }
            $count++
        }
        Write-Ok "$count OpenCode commands installed ($($script:OpenCodeMode) mode)"
    }

    # Merge opencode.json
    if (Test-Path $exampleConfig) {
        if (Test-Path $configFile) {
            try {
                $existing = Get-Content -Path $configFile -Raw | ConvertFrom-Json
                $example = Get-Content -Path $exampleConfig -Raw | ConvertFrom-Json

                # Merge agent config (OpenCode uses "agent" singular)
                # Strategy: replace all sdd-* agents with template, preserve user model choices
                if ($example.PSObject.Properties['agent']) {
                    if (-not $existing.PSObject.Properties['agent']) {
                        $existing | Add-Member -NotePropertyName 'agent' -NotePropertyValue ([PSCustomObject]@{})
                    }

                    # 1. Save existing model fields from sdd-* agents
                    $savedModels = @{}
                    foreach ($prop in @($existing.agent.PSObject.Properties)) {
                        if ($prop.Name -like 'sdd-*' -and $prop.Value.PSObject.Properties['model']) {
                            $savedModels[$prop.Name] = $prop.Value.model
                        }
                    }

                    # 2. Remove all existing sdd-* agents (clean slate)
                    foreach ($prop in @($existing.agent.PSObject.Properties)) {
                        if ($prop.Name -like 'sdd-*') {
                            $existing.agent.PSObject.Properties.Remove($prop.Name)
                        }
                    }

                    # 3. Add new agents from template
                    foreach ($prop in $example.agent.PSObject.Properties) {
                        $existing.agent | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
                    }

                    # 4. Restore user model choices
                    foreach ($name in $savedModels.Keys) {
                        if ($existing.agent.PSObject.Properties[$name]) {
                            $existing.agent.$name | Add-Member -NotePropertyName 'model' -NotePropertyValue $savedModels[$name] -Force
                        }
                    }
                }

                # Clean up stale "agents" (plural) key from older script versions
                if ($existing.PSObject.Properties['agents']) {
                    $existing.PSObject.Properties.Remove('agents')
                }

                Backup-File $configFile
                $mergedJson = $existing | ConvertTo-Json -Depth 10
                Write-AtomicFile -Path $configFile -Content $mergedJson
                Write-Ok "Agent config merged into $configFile ($($script:OpenCodeMode) mode)"
            }
            catch {
                Write-Warn "Could not merge opencode.json: $_"
                Write-Info "Merge manually from examples\opencode\opencode.$($script:OpenCodeMode).json"
            }
        } else {
            $configDir = Split-Path -Parent $configFile
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
            Copy-Item -Path $exampleConfig -Destination $configFile
            Write-Ok "Config created at $configFile ($($script:OpenCodeMode) mode)"
        }
    }

    # Install AGENTS.md prompt file for prompt references in config templates
    $agentsSrc = Join-Path $ExamplesDir 'opencode\AGENTS.md'
    $agentsTarget = Join-Path $env:USERPROFILE '.config\opencode\AGENTS.md'
    if (Test-Path $agentsSrc) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $agentsTarget) -Force | Out-Null
        Copy-Item -Path $agentsSrc -Destination $agentsTarget -Force
        Write-Ok "AGENTS.md installed -> $agentsTarget"
    }

    # Install background-agents plugin
    $pluginsDir = Join-Path $env:USERPROFILE '.config\opencode\plugins'
    $pluginSrc = Join-Path $ScriptRoot '..\examples\opencode\plugins\background-agents.ts'
    New-Item -ItemType Directory -Path $pluginsDir -Force | Out-Null
    if (Test-Path $pluginSrc) {
        Copy-Item -Path $pluginSrc -Destination (Join-Path $pluginsDir 'background-agents.ts') -Force
        Write-Ok "background-agents plugin installed -> $pluginsDir"
    } else {
        Write-Warn "Plugin source not found: $pluginSrc (skipped)"
    }

    # Install the plugin's npm dependency. Pin the exact version and disable
    # lifecycle scripts so a compromised release cannot execute code during setup.
    # Degrade gracefully (warn, don't abort) when npm is unavailable.
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Info "Installing npm dependency: unique-names-generator@$UniqueNamesGeneratorVersion"
        Push-Location (Join-Path $env:USERPROFILE '.config\opencode')
        try {
            npm install --ignore-scripts "unique-names-generator@$UniqueNamesGeneratorVersion"
            Write-Ok "unique-names-generator@$UniqueNamesGeneratorVersion installed"
        } finally {
            Pop-Location
        }
    } else {
        Write-Warn 'npm not found - skipping unique-names-generator dependency'
        Write-Info "Install it manually: cd $env:USERPROFILE\.config\opencode && npm install --ignore-scripts unique-names-generator@$UniqueNamesGeneratorVersion"
    }
}

# ============================================================================
# N5: Pi package stack (opt-in, consent-gated) — mirrors setup.sh
# ============================================================================

function Get-PiPackagesDecision {
    # Honor explicit switches first, then ask (default No), then non-interactive No.
    if ($WithPiPackages) { return $true }
    if ($WithoutPiPackages) { return $false }
    if ($NonInteractive) { return $false }

    Write-Host ''
    Write-Host '  Install the Pi package stack?' -ForegroundColor White
    Write-Host '  Adds: gentle-engram (memory), pi-mcp-adapter, pi-subagents-j0k3r,'
    Write-Host '  rpiv-ask-user-question, pi-web-access, rpiv-todo, pi-btw.'
    Write-Host '  (gentle-pi is intentionally excluded - it conflicts with Kurama.)'
    Write-Host ''
    $answer = Read-Host '  Install Pi packages? [y/N]'
    return ($answer -match '^[Yy]')
}

function Invoke-PiStep {
    param([string]$Label, [scriptblock]$Action)
    Write-Info "Pi: $Label"
    try {
        & $Action
        if ($LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
        Write-Ok $Label
        $script:PiInstallOk += "  [ok] $Label"
    } catch {
        Write-Warn "$Label failed - continuing"
        $script:PiInstallFail += "  [x] $Label"
    }
}

function Install-PiPackages {
    if (-not (Get-PiPackagesDecision)) {
        Write-Info 'Skipping Pi package stack (opt-in)'
        return
    }

    Write-Head 'Installing Pi package stack'

    if (-not (Get-Command pi -ErrorAction SilentlyContinue)) {
        Write-Warn 'pi not found in PATH - skipping the Pi package stack'
        Write-Info 'Install Pi first, then re-run: .\setup.ps1 -Agent pi -WithPiPackages'
        return
    }

    $script:PiInstallOk = @()
    $script:PiInstallFail = @()

    # Approved order — pins hardcoded above and refreshed via `npm view`.
    Invoke-PiStep "gentle-engram@$PiPkgGentleEngramVersion" { pi install "npm:gentle-engram@$PiPkgGentleEngramVersion" }
    Invoke-PiStep "pi-mcp-adapter@$PiPkgMcpAdapterVersion" { pi install "npm:pi-mcp-adapter@$PiPkgMcpAdapterVersion" }
    Invoke-PiStep "pi-engram init (gentle-engram@$PiPkgGentleEngramVersion)" { npm exec --yes --package "gentle-engram@$PiPkgGentleEngramVersion" -- pi-engram init }
    Invoke-PiStep "pi-subagents-j0k3r@$PiPkgSubagentsVersion" { pi install "npm:pi-subagents-j0k3r@$PiPkgSubagentsVersion" }
    Invoke-PiStep "@juicesharp/rpiv-ask-user-question@$PiPkgAskUserVersion" { pi install "npm:@juicesharp/rpiv-ask-user-question@$PiPkgAskUserVersion" }
    Invoke-PiStep "pi-web-access@$PiPkgWebAccessVersion" { pi install "npm:pi-web-access@$PiPkgWebAccessVersion" }
    Invoke-PiStep "@juicesharp/rpiv-todo@$PiPkgTodoVersion" { pi install "npm:@juicesharp/rpiv-todo@$PiPkgTodoVersion" }
    Invoke-PiStep "pi-btw@$PiPkgBtwVersion" { pi install "npm:pi-btw@$PiPkgBtwVersion" }

    # Record the packages Kurama installs so uninstall can offer to revert them (O3).
    $script:ReceiptPiPackages.Add("npm:gentle-engram@$PiPkgGentleEngramVersion")
    $script:ReceiptPiPackages.Add("npm:pi-mcp-adapter@$PiPkgMcpAdapterVersion")
    $script:ReceiptPiPackages.Add("npm:pi-subagents-j0k3r@$PiPkgSubagentsVersion")
    $script:ReceiptPiPackages.Add("npm:@juicesharp/rpiv-ask-user-question@$PiPkgAskUserVersion")
    $script:ReceiptPiPackages.Add("npm:pi-web-access@$PiPkgWebAccessVersion")
    $script:ReceiptPiPackages.Add("npm:@juicesharp/rpiv-todo@$PiPkgTodoVersion")
    $script:ReceiptPiPackages.Add("npm:pi-btw@$PiPkgBtwVersion")

    Write-Host ''
    if ($script:PiInstallOk.Count -gt 0) {
        Write-Info 'Pi packages installed:'
        $script:PiInstallOk | ForEach-Object { Write-Host $_ }
    }
    if ($script:PiInstallFail.Count -gt 0) {
        Write-Warn 'Pi packages that failed (setup continued anyway):'
        $script:PiInstallFail | ForEach-Object { Write-Host $_ }
    }
}

# ============================================================================
# O5: Engram optional persistence engine (asked once; MCP registered per client)
#
# Mirrors setup.sh: ask ONCE (or honor -WithEngram/-WithoutEngram), ensure the
# binary (guide on Windows — Homebrew is a macOS concern), then register the
# Engram MCP server into the client being configured using gentle-ai's exact
# per-client shapes. JSON edits back up + write atomically; Codex is TOML upsert.
# Every file written is recorded in the receipt (engram_mcp[]).
# ============================================================================

function Confirm-Engram {
    if ($script:Engram -eq 'yes' -or $script:Engram -eq 'no') { return }
    if ($NonInteractive) { $script:Engram = 'no'; return }
    Write-Host ''
    $ans = Read-Host '  Use Engram as the persistence engine? [y/N]'
    if ($ans -match '^[Yy]') { $script:Engram = 'yes' } else { $script:Engram = 'no' }
}

function Resolve-EngramCommand {
    $c = Get-Command engram -ErrorAction SilentlyContinue
    if ($c -and $c.Source) {
        # Collapse a versioned Homebrew Cellar path back to bare 'engram'.
        if ($c.Source -notmatch '[/\\]Cellar[/\\]engram[/\\]') { return $c.Source }
    }
    return 'engram'
}

function Confirm-EngramBinary {
    if ($script:EngramBinaryChecked) { return }
    $script:EngramBinaryChecked = $true
    if (Get-Command engram -ErrorAction SilentlyContinue) {
        Write-Ok "engram found: $((Get-Command engram).Source)"
        return
    }
    Write-Warn 'engram not found in PATH'
    Write-Info "Install engram from: $EngramReleasesUrl"
    Write-Info 'The MCP registration is still written; it activates once engram is on PATH.'
}

# Load a JSON config as a PSCustomObject (empty object when missing/invalid).
function Get-JsonObject {
    param([string]$File)
    if (Test-Path $File) {
        try { return (Get-Content -Path $File -Raw | ConvertFrom-Json) } catch { return ([PSCustomObject]@{}) }
    }
    return ([PSCustomObject]@{})
}

# Ensure $Obj has a container property (mcpServers / servers / mcp) holding the
# engram server object, then persist + record. $ServerValue is the server object.
function Set-EngramServer {
    param([string]$File, [string]$ContainerKey, $ServerValue)
    New-Item -ItemType Directory -Path (Split-Path -Parent $File) -Force | Out-Null
    $obj = Get-JsonObject $File
    if (Test-Path $File) { Backup-File $File }
    if (-not $obj.PSObject.Properties[$ContainerKey]) {
        $obj | Add-Member -NotePropertyName $ContainerKey -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    $obj.$ContainerKey | Add-Member -NotePropertyName 'engram' -NotePropertyValue $ServerValue -Force
    Write-AtomicFile -Path $File -Content ($obj | ConvertTo-Json -Depth 12)
    Write-Ok "Engram MCP registered -> $File"
    $script:ReceiptEngramMcp.Add((Get-ReceiptRel $File))
}

# Codex TOML: strip any existing [mcp_servers.engram] block, append a fresh one.
function Register-EngramCodex {
    param([string]$File, [string]$Cmd)
    New-Item -ItemType Directory -Path (Split-Path -Parent $File) -Force | Out-Null
    $existing = ''
    if (Test-Path $File) { Backup-File $File; $existing = Get-Content -Path $File -Raw }
    $lines = $existing -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($ln in $lines) {
        if ($ln -match '^\[mcp_servers\.engram\]') { $skip = $true; continue }
        if ($skip -and $ln -match '^\[') { $skip = $false }
        if (-not $skip) { $out.Add($ln) }
    }
    while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }
    $block = @('[mcp_servers.engram]', "command = `"$Cmd`"", 'args = ["mcp", "--tools=agent"]')
    if ($out.Count -gt 0) { $content = ($out -join "`n") + "`n`n" + ($block -join "`n") + "`n" }
    else { $content = ($block -join "`n") + "`n" }
    Write-AtomicFile -Path $File -Content $content
    Write-Ok "Engram MCP registered -> $File (codex TOML)"
    $script:ReceiptEngramMcp.Add((Get-ReceiptRel $File))
}

function Register-EngramMcp {
    param([string]$AgentName)
    $cmd = Resolve-EngramCommand
    $homeDir = $env:USERPROFILE
    $genericServer = [PSCustomObject]@{ command = $cmd; args = @('mcp', '--tools=agent') }

    switch ($AgentName) {
        'pi' {
            Write-Info 'Engram on Pi is provided by the Pi package stack (gentle-engram) — no extra MCP registration needed.'
        }
        'claude-code' {
            $file = if ($Scope -eq 'project') { Join-Path $script:TargetPath '.mcp.json' } else { Join-Path $homeDir '.claude.json' }
            Set-EngramServer -File $file -ContainerKey 'mcpServers' -ServerValue $genericServer
        }
        'opencode' {
            $file = if ($Scope -eq 'project') { Join-Path $script:TargetPath 'opencode.json' } else { Join-Path $homeDir '.config\opencode\opencode.json' }
            $ocServer = [PSCustomObject]@{ command = @($cmd, 'mcp', '--tools=agent'); type = 'local' }
            Set-EngramServer -File $file -ContainerKey 'mcp' -ServerValue $ocServer
        }
        'cursor' {
            $file = if ($Scope -eq 'project') { Join-Path $script:TargetPath '.cursor\mcp.json' } else { Join-Path $homeDir '.cursor\mcp.json' }
            Set-EngramServer -File $file -ContainerKey 'mcpServers' -ServerValue $genericServer
        }
        'gemini-cli' {
            $file = if ($Scope -eq 'project') { Join-Path $script:TargetPath '.gemini\settings.json' } else { Join-Path $homeDir '.gemini\settings.json' }
            Set-EngramServer -File $file -ContainerKey 'mcpServers' -ServerValue $genericServer
        }
        'vscode' {
            $file = if ($Scope -eq 'project') { Join-Path $script:TargetPath '.vscode\mcp.json' } else { Join-Path ($env:APPDATA) 'Code\User\mcp.json' }
            Set-EngramServer -File $file -ContainerKey 'servers' -ServerValue $genericServer
        }
        'codex' {
            if ($Scope -eq 'project') {
                Write-Info 'Codex uses a single global MCP config; skipping Engram registration for project scope.'
                Write-Info 'Run: .\setup.ps1 -Agent codex -WithEngram   (global) to register it.'
                return
            }
            Register-EngramCodex -File (Join-Path $homeDir '.codex\config.toml') -Cmd $cmd
        }
    }
}

function Set-Engram {
    param([string]$AgentName)
    Confirm-Engram
    if ($script:Engram -ne 'yes') { return }
    Write-Head 'Engram persistence engine'
    Confirm-EngramBinary
    Register-EngramMcp -AgentName $AgentName
}

# ============================================================================
# Full Setup for One Agent
# ============================================================================

function Set-Agent {
    param([string]$AgentName)

    Write-Head "Setting up $AgentName (scope: $Scope)"

    # Reset per-agent receipt accumulators.
    $script:ReceiptFiles = New-Object System.Collections.Generic.List[string]
    $script:ReceiptSettings = New-Object System.Collections.Generic.List[string]
    $script:ReceiptPiPackages = New-Object System.Collections.Generic.List[string]
    $script:ReceiptEngramMcp = New-Object System.Collections.Generic.List[string]

    Install-Skills -AgentName $AgentName

    if ($AgentName -eq 'opencode' -and $Scope -ne 'project') {
        Set-OpenCode
    } else {
        $promptPath = Get-ScopedPromptPath $AgentName
        $exampleFile = if ($AgentName -eq 'opencode') { Join-Path $ExamplesDir 'pi\AGENTS.md' } else { $ExampleFiles[$AgentName] }
        if ($exampleFile) {
            Set-Orchestrator -PromptPath $promptPath -ExampleFile $exampleFile -AgentName $AgentName
        }
    }

    # O2: Claude Code hooks are ALWAYS installed for claude-code (both scopes).
    if ($AgentName -eq 'claude-code') {
        Install-Hooks
    }

    # N5: offer the Pi package stack only for the Pi target.
    if ($AgentName -eq 'pi') {
        Install-PiPackages
    }

    # O5: Engram optional persistence engine — asked once, then registered.
    Set-Engram -AgentName $AgentName

    # Flush the single per-agent receipt.
    Write-Receipt
}

# ============================================================================
# Main
# ============================================================================

try {
    if ($Help) {
        Write-Host 'Usage: .\setup.ps1 [OPTIONS]'
        Write-Host ''
        Write-Host 'Options:'
        Write-Host '  -All               Auto-detect and install for all found agents'
        Write-Host '  -Agent NAME        Install for a specific agent'
        Write-Host '  -OpenCodeMode M    OpenCode agent mode: single or multi (per-phase models)'
        Write-Host '  -Scope SCOPE       Install scope: global (default) or project'
        Write-Host '  -Path DIR          Target repo for -Scope project (default cwd; must be a git repo)'
        Write-Host '  -WithPiPackages    Install the Pi package stack (-Agent pi, non-interactive)'
        Write-Host '  -WithoutPiPackages Skip the Pi package stack (-Agent pi, non-interactive)'
        Write-Host '  -WithEngram        Use Engram as the persistence engine (register its MCP)'
        Write-Host '  -WithoutEngram     Keep the built-in markdown persistence (default)'
        Write-Host '  -NonInteractive    No prompts (for external installers)'
        Write-Host '  -Help              Show this help'
        Write-Host ''
        Write-Host 'Agents: claude-code, opencode, gemini-cli, cursor, vscode, codex, pi'
        Write-Host ''
        Write-Host 'Scope:'
        Write-Host '  global   Install to the per-user config dirs (~/.claude, ~/.pi, ...).'
        Write-Host '  project  Install everything into one git repo (-Path) to trial Kurama.'
        exit 0
    }

    if ($Path -and $Scope -ne 'project') {
        throw '-Path requires -Scope project'
    }
    if ($Path) { $script:TargetPath = $Path }
    # O5: resolve the Engram flags up front (interactive prompt happens once later).
    if ($WithEngram) { $script:Engram = 'yes' }
    if ($WithoutEngram) { $script:Engram = 'no' }
    Confirm-ProjectTarget

    Write-Host ''
    Write-Host ([char]0x2554 + ([string][char]0x2550 * 42) + [char]0x2557) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '    Kurama - Full Setup          ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x2551 + '   Detect - Install - Configure            ' + [char]0x2551) -ForegroundColor Cyan
    Write-Host ([char]0x255A + ([string][char]0x2550 * 42) + [char]0x255D) -ForegroundColor Cyan

    # Validate source
    $skillDirs = Get-ChildItem -Path $SkillsSrc -Directory -Filter 'sdd-*'
    foreach ($dir in $skillDirs) {
        if (-not (Test-Path (Join-Path $dir.FullName 'SKILL.md'))) {
            Write-Fail "Missing: $($dir.Name)/SKILL.md"
            Write-Fail 'Is this a complete clone? git clone https://github.com/myst4/kurama.git'
            exit 1
        }
    }

    $installedAgents = @()

    if ($Agent) {
        Set-Agent -AgentName $Agent
        $installedAgents += $Agent
    }
    elseif ($All -or $NonInteractive) {
        $detected = Find-Agents
        foreach ($a in $detected) {
            Set-Agent -AgentName $a
            $installedAgents += $a
        }
    }
    else {
        $detected = Find-Agents
        if ($detected.Count -eq 0) {
            Write-Host ''
            Write-Warn 'No agents detected. Use .\install.ps1 for manual installation.'
            exit 0
        }

        Write-Host ''
        $answer = Read-Host 'Set up all detected agents? [Y/n]'
        if (-not $answer -or $answer -match '^[Yy]') {
            foreach ($a in $detected) {
                Set-Agent -AgentName $a
                $installedAgents += $a
            }
        } else {
            Write-Host ''
            Write-Host 'Select agents to set up (space-separated numbers):' -ForegroundColor White
            Write-Host ''
            $i = 1
            foreach ($a in $detected) {
                Write-Host "  $i) $a"
                $i++
            }
            Write-Host ''
            $choices = (Read-Host 'Choice') -split '\s+'
            foreach ($c in $choices) {
                $idx = [int]$c - 1
                if ($idx -ge 0 -and $idx -lt $detected.Count) {
                    Set-Agent -AgentName $detected[$idx]
                    $installedAgents += $detected[$idx]
                }
            }
        }
    }

    # Summary
    if ($installedAgents.Count -gt 0) {
        Write-Head 'Setup Complete'
        Write-Host ''
        foreach ($a in $installedAgents) {
            Write-Host '  ' -NoNewline
            Write-Host ([char]0x2713) -ForegroundColor Green -NoNewline
            Write-Host " $a ($Scope)" -ForegroundColor White
            Write-Host "    Skills: $(Get-ScopedSkillsPath $a)"
            Write-Host "    Prompt: $(Get-ScopedPromptPath $a)"
            if ($a -eq 'claude-code') { Write-Host "    Hooks:  $(Get-ScopedHooksDir)" }
            Write-Host "    Receipt: $(Join-Path (Get-ScopedReceiptDir $a) $InstallManifestName)"
        }
        Write-Host ''
        Write-Host 'Done!' -ForegroundColor Green -NoNewline
        Write-Host ' Start using SDD: open any project and type ' -NoNewline
        Write-Host '/sdd-init' -ForegroundColor Cyan
        Write-Host ''
        # O5: persistence-engine status.
        if ($script:Engram -eq 'yes') {
            Write-Host 'Engram: ' -ForegroundColor Green -NoNewline
            Write-Host 'enabled as the persistence engine (MCP registered per client).'
            if (-not (Get-Command engram -ErrorAction SilentlyContinue)) {
                Write-Host "  Install the binary to activate it: $EngramReleasesUrl" -ForegroundColor Cyan
            }
        } else {
            Write-Host 'Persistence: ' -ForegroundColor Yellow -NoNewline
            Write-Host 'using the built-in markdown fallback (openspec/.kurama).'
            Write-Host '  Enable cross-session memory anytime with -WithEngram (installs Engram).'
            Write-Host "  $EngramReleasesUrl" -ForegroundColor Cyan
        }
        Write-Host ''
    } else {
        Write-Host ''
        Write-Warn 'No agents were set up.'
    }
}
catch {
    Write-Host ''
    Write-Fail "Setup failed: $_"
    Write-Host ''
    exit 1
}
