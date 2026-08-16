[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$FastCtxBinary,
  [Parameter(Mandatory = $true)][string]$GitBash,
  [Parameter(Mandatory = $true)][string]$NativeHome,
  [Parameter(Mandatory = $true)][string]$CodexHome,
  [string]$ClaudeConfigDir,
  [string]$ClaudeCommand,
  [switch]$SkipClaudeCode,
  [switch]$SkipCcSwitch,
  [string]$CcSwitchApps,
  [switch]$NoLaunchCcSwitch,
  [switch]$RequireCcSwitch,
  [switch]$ForceMcpRegistration,
  [switch]$PreflightOnly,
  [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[fastctx-agent-integrations]'
$BeginMarker = '<!-- fastctx:begin -->'
$EndMarker = '<!-- fastctx:end -->'
$Utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$Utf8Bom = [byte[]](0xEF, 0xBB, 0xBF)
$ExpectedEnvironment = [ordered]@{
  CODEX_HOME = [System.IO.Path]::GetFullPath($CodexHome)
  FASTCTX_BASH = [System.IO.Path]::GetFullPath($GitBash)
  FASTCTX_GLOB_TOKEN_BUDGET = '5400'
  FASTCTX_GREP_TOKEN_BUDGET = '10800'
  FASTCTX_JOB_OUTPUT_TOKEN_BUDGET = '5400'
  FASTCTX_RUN_TOKEN_BUDGET = '10800'
  FASTCTX_TOKEN_BUDGET = '54000'
  HOME = [System.IO.Path]::GetFullPath($NativeHome)
  USERPROFILE = [System.IO.Path]::GetFullPath($NativeHome)
}

function Write-Log {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Resolve-GuidanceSource {
  $candidates = @(
    (Join-Path $PSScriptRoot 'fastctx-agent-guidance.md'),
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\fastctx-agent-guidance.md')
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return [System.IO.Path]::GetFullPath($candidate)
    }
  }
  throw "FastCtx agent guidance template is missing. Checked: $($candidates -join ', ')"
}

function Read-Utf8Snapshot {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$AllowMissing
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    if ($AllowMissing) {
      return [pscustomobject]@{ Exists = $false; Bytes = [byte[]]@(); Text = ''; HasBom = $false }
    }
    throw "required UTF-8 file does not exist: $Path"
  }
  $item = Get-Item -LiteralPath $Path -Force
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "refusing to edit a reparse-point instruction file: $Path"
  }
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
  $offset = if ($hasBom) { 3 } else { 0 }
  try {
    $text = $Utf8Strict.GetString($bytes, $offset, $bytes.Length - $offset)
  } catch {
    throw "cannot edit $($Path): the file is not valid UTF-8"
  }
  return [pscustomobject]@{ Exists = $true; Bytes = $bytes; Text = $text; HasBom = $hasBom }
}

function ConvertTo-Utf8Bytes {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][bool]$WithBom
  )
  $body = $Utf8NoBom.GetBytes($Text)
  if (-not $WithBom) { return [byte[]]$body }
  $combined = New-Object byte[] ($Utf8Bom.Length + $body.Length)
  [System.Array]::Copy($Utf8Bom, 0, $combined, 0, $Utf8Bom.Length)
  [System.Array]::Copy($body, 0, $combined, $Utf8Bom.Length, $body.Length)
  return [byte[]]$combined
}

function Test-ByteArrayEqual {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Left,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Right
  )
  if ($Left.Length -ne $Right.Length) { return $false }
  for ($index = 0; $index -lt $Left.Length; $index++) {
    if ($Left[$index] -ne $Right[$index]) { return $false }
  }
  return $true
}

function Get-ManagedRange {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
    [Parameter(Mandatory = $true)][string]$Path
  )
  $begins = [regex]::Matches($Text, [regex]::Escape($BeginMarker))
  $ends = [regex]::Matches($Text, [regex]::Escape($EndMarker))
  if ($begins.Count -eq 0 -and $ends.Count -eq 0) { return $null }
  if ($begins.Count -ne 1 -or $ends.Count -ne 1) {
    throw "$Path contains duplicate or unmatched FastCtx markers; repair the block manually and retry"
  }
  if ($ends[0].Index -lt $begins[0].Index) {
    throw "$Path has the FastCtx end marker before its begin marker; repair the block manually and retry"
  }
  return [pscustomobject]@{
    Start = $begins[0].Index
    End = $ends[0].Index + $EndMarker.Length
  }
}

function New-GuidancePlan {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Guidance
  )
  $snapshot = Read-Utf8Snapshot -Path $Path -AllowMissing
  $range = Get-ManagedRange -Text $snapshot.Text -Path $Path
  $newline = if ($snapshot.Text.Contains("`r`n")) { "`r`n" } else { "`n" }
  $managedGuidance = $Guidance.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", $newline)
  if ($null -ne $range) {
    $updated = $snapshot.Text.Substring(0, $range.Start) + $managedGuidance + $snapshot.Text.Substring($range.End)
  } elseif ($snapshot.Text.Length -eq 0) {
    $updated = $managedGuidance + $newline
  } else {
    $separator = if ($snapshot.Text.EndsWith($newline + $newline)) {
      ''
    } elseif ($snapshot.Text.EndsWith($newline)) {
      $newline
    } else {
      $newline + $newline
    }
    $updated = $snapshot.Text + $separator + $managedGuidance + $newline
  }
  $updatedBytes = ConvertTo-Utf8Bytes -Text $updated -WithBom $snapshot.HasBom
  return [pscustomobject]@{
    Path = [System.IO.Path]::GetFullPath($Path)
    OriginalExists = $snapshot.Exists
    OriginalBytes = [byte[]]$snapshot.Bytes
    UpdatedBytes = [byte[]]$updatedBytes
    Changed = -not (Test-ByteArrayEqual -Left $snapshot.Bytes -Right $updatedBytes)
  }
}

function Write-GuidancePlan {
  param([Parameter(Mandatory = $true)]$Plan)
  if (-not $Plan.Changed) {
    Write-Log "agent guidance already matches: $($Plan.Path)"
    return
  }
  $parent = Split-Path -Parent $Plan.Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $temporary = Join-Path $parent ('.fastctx-guidance-' + [guid]::NewGuid().ToString('N') + '.tmp')
  $replacementBackup = Join-Path $parent ('.fastctx-guidance-' + [guid]::NewGuid().ToString('N') + '.bak')
  $guard = $null
  try {
    if ($Plan.OriginalExists) {
      try {
        $share = [System.IO.FileShare]::Read -bor [System.IO.FileShare]::Delete
        $guard = [System.IO.File]::Open($Plan.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
      } catch {
        throw "instruction file could not be locked for atomic publication: $($Plan.Path)"
      }
    }
    [System.IO.File]::WriteAllBytes($temporary, $Plan.UpdatedBytes)
    $delay = 0
    if ([int]::TryParse($env:FASTCTX_TEST_GUIDANCE_COMMIT_DELAY_MS, [ref]$delay)) {
      Start-Sleep -Milliseconds ([Math]::Min([Math]::Max($delay, 0), 5000))
    }
    if ($Plan.OriginalExists) {
      $currentBytes = [System.IO.File]::ReadAllBytes($Plan.Path)
      if (-not (Test-ByteArrayEqual -Left $currentBytes -Right $Plan.OriginalBytes)) {
        throw "instruction file changed after preflight; no FastCtx block was written: $($Plan.Path)"
      }
      [System.IO.File]::Replace($temporary, $Plan.Path, $replacementBackup)
      $guard.Dispose()
      $guard = $null
      Remove-Item -LiteralPath $replacementBackup -Force
    } else {
      if (Test-Path -LiteralPath $Plan.Path) {
        throw "instruction file appeared during installation; no FastCtx block was written: $($Plan.Path)"
      }
      [System.IO.File]::Move($temporary, $Plan.Path)
    }
    Write-Log "updated only the FastCtx guidance block: $($Plan.Path)"
  } finally {
    if ($null -ne $guard) { $guard.Dispose() }
    foreach ($artifact in @($temporary, $replacementBackup)) {
      if (Test-Path -LiteralPath $artifact) {
        Remove-Item -LiteralPath $artifact -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function Get-CodexGuidancePath {
  $override = Join-Path $ExpectedEnvironment.CODEX_HOME 'AGENTS.override.md'
  if (Test-Path -LiteralPath $override -PathType Leaf) {
    $snapshot = Read-Utf8Snapshot -Path $override
    if (-not [string]::IsNullOrWhiteSpace($snapshot.Text)) {
      return $override
    }
  }
  return (Join-Path $ExpectedEnvironment.CODEX_HOME 'AGENTS.md')
}

function Get-ClaudeConfigDirectory {
  if (-not [string]::IsNullOrWhiteSpace($ClaudeConfigDir)) {
    return [System.IO.Path]::GetFullPath($ClaudeConfigDir)
  }
  if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_CONFIG_DIR)) {
    return [System.IO.Path]::GetFullPath($env:CLAUDE_CONFIG_DIR)
  }
  return (Join-Path $ExpectedEnvironment.USERPROFILE '.claude')
}

function Get-ClaudeCliConfigDirectory {
  if (-not [string]::IsNullOrWhiteSpace($ClaudeConfigDir)) {
    return [System.IO.Path]::GetFullPath($ClaudeConfigDir)
  }
  if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_CONFIG_DIR)) {
    return [System.IO.Path]::GetFullPath($env:CLAUDE_CONFIG_DIR)
  }
  return $null
}

function Get-ClaudeUserConfigPath {
  param([AllowNull()][string]$ConfigDirectory)
  if ([string]::IsNullOrWhiteSpace($ConfigDirectory)) {
    return (Join-Path $ExpectedEnvironment.USERPROFILE '.claude.json')
  }
  return (Join-Path $ConfigDirectory '.claude.json')
}

function Get-ClaudeUserMcpState {
  param([AllowNull()][string]$ConfigDirectory)
  $path = Get-ClaudeUserConfigPath -ConfigDirectory $ConfigDirectory
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  $snapshot = Read-Utf8Snapshot -Path $path
  try {
    $document = $snapshot.Text | ConvertFrom-Json
  } catch {
    throw "Claude Code user configuration is not valid JSON: $path"
  }
  $servers = $document.PSObject.Properties['mcpServers']
  if ($null -eq $servers -or $null -eq $servers.Value) { return $null }
  $serverProperty = $servers.Value.PSObject.Properties['fastctx']
  if ($null -eq $serverProperty -or $null -eq $serverProperty.Value) { return $null }
  $server = $serverProperty.Value
  $state = [ordered]@{
    Scope = 'User config'
    Type = if ($server.PSObject.Properties['type']) { [string]$server.type } else { $null }
    Command = if ($server.PSObject.Properties['command']) { [string]$server.command } else { $null }
    Args = if ($server.PSObject.Properties['args']) { @($server.args) -join ' ' } else { $null }
    Environment = @{}
  }
  if ($server.PSObject.Properties['env'] -and $null -ne $server.env) {
    foreach ($property in $server.env.PSObject.Properties) {
      $state.Environment[$property.Name] = [string]$property.Value
    }
  }
  return [pscustomobject]$state
}

function Resolve-ClaudeExecutable {
  if (-not [string]::IsNullOrWhiteSpace($ClaudeCommand)) {
    if (-not (Test-Path -LiteralPath $ClaudeCommand -PathType Leaf)) {
      throw "Claude Code command does not exist: $ClaudeCommand"
    }
    return [System.IO.Path]::GetFullPath($ClaudeCommand)
  }
  $command = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $command) {
    throw 'Claude Code was not found. Install it, pass -ClaudeCommand <path>, or explicitly use -SkipClaudeCode.'
  }
  return $command.Source
}

function Invoke-ClaudeCommand {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [AllowNull()][string]$ConfigDirectory
  )
  $saved = @{}
  foreach ($name in @('HOME', 'USERPROFILE', 'CODEX_HOME', 'CLAUDE_CONFIG_DIR')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
  }
  $savedLocation = Get-Location
  try {
    [Environment]::SetEnvironmentVariable('HOME', $ExpectedEnvironment.HOME, 'Process')
    [Environment]::SetEnvironmentVariable('USERPROFILE', $ExpectedEnvironment.USERPROFILE, 'Process')
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $ExpectedEnvironment.CODEX_HOME, 'Process')
    if ([string]::IsNullOrWhiteSpace($ConfigDirectory)) {
      [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $null, 'Process')
    } else {
      [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $ConfigDirectory, 'Process')
    }
    $workingDirectory = if (Test-Path -LiteralPath $ExpectedEnvironment.HOME -PathType Container) {
      $ExpectedEnvironment.HOME
    } else {
      [System.IO.Path]::GetTempPath()
    }
    Set-Location -LiteralPath $workingDirectory
    $savedPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $output = @(& $Executable @Arguments 2>&1)
      $exitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $savedPreference
    }
    return [pscustomobject]@{
      ExitCode = $exitCode
      Lines = @($output | ForEach-Object { [string]$_ })
      Text = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    }
  } finally {
    Set-Location -LiteralPath $savedLocation.Path
    foreach ($name in $saved.Keys) {
      [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
    }
  }
}

function Get-ClaudeMcpState {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string]$ConfigDirectory
  )
  $result = Invoke-ClaudeCommand -Executable $Executable -Arguments @('mcp', 'get', 'fastctx') -ConfigDirectory $ConfigDirectory
  if ($result.ExitCode -ne 0) {
    if ($result.Text -match 'No MCP server named ["'']fastctx["'']') { return $null }
    throw "Claude Code MCP inspection failed: $($result.Text)"
  }
  $state = [ordered]@{ Scope = $null; Type = $null; Command = $null; Args = $null; Environment = @{} }
  $inEnvironment = $false
  foreach ($line in $result.Lines) {
    if ($line -match '^\s*Scope:\s*(.+?)\s*$') { $state.Scope = $Matches[1]; $inEnvironment = $false; continue }
    if ($line -match '^\s*Type:\s*(.+?)\s*$') { $state.Type = $Matches[1]; $inEnvironment = $false; continue }
    if ($line -match '^\s*Command:\s*(.+?)\s*$') { $state.Command = $Matches[1]; $inEnvironment = $false; continue }
    if ($line -match '^\s*Args:\s*(.*?)\s*$') { $state.Args = $Matches[1]; $inEnvironment = $false; continue }
    if ($line -match '^\s*Environment:\s*$') { $inEnvironment = $true; continue }
    if ($inEnvironment -and $line -match '^\s{4}([^=]+)=(.*)$') {
      $state.Environment[$Matches[1].Trim()] = $Matches[2]
      continue
    }
    if ($inEnvironment -and $line -notmatch '^\s{4}') { $inEnvironment = $false }
  }
  return [pscustomobject]$state
}

function Test-ClaudeMcpState {
  param([Parameter(Mandatory = $true)]$State)
  if ($State.Scope -notlike 'User config*' -or $State.Type -ne 'stdio' -or
      $State.Command -ne $ExpectedBinary -or $State.Args -ne 'serve --enable-shell') {
    return $false
  }
  if ($State.Environment.Count -ne $ExpectedEnvironment.Count) { return $false }
  foreach ($entry in $ExpectedEnvironment.GetEnumerator()) {
    if (-not $State.Environment.ContainsKey($entry.Key) -or $State.Environment[$entry.Key] -cne $entry.Value) {
      return $false
    }
  }
  return $true
}

function Add-ClaudeMcpState {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string]$ConfigDirectory
  )
  $arguments = @('mcp', 'add', '--scope', 'user', '--transport', 'stdio', 'fastctx')
  foreach ($entry in $ExpectedEnvironment.GetEnumerator()) {
    $arguments += @('-e', "$($entry.Key)=$($entry.Value)")
  }
  $arguments += @('--', $ExpectedBinary, 'serve', '--enable-shell')
  $result = Invoke-ClaudeCommand -Executable $Executable -Arguments $arguments -ConfigDirectory $ConfigDirectory
  if ($result.ExitCode -ne 0) {
    throw "Claude Code MCP registration failed: $($result.Text)"
  }
}

function Test-OrApplyClaudeMcp {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [AllowNull()][string]$ConfigDirectory,
    [Parameter(Mandatory = $true)][bool]$Apply
  )
  $state = Get-ClaudeUserMcpState -ConfigDirectory $ConfigDirectory
  if ($null -ne $state -and (Test-ClaudeMcpState -State $state)) {
    Write-Log 'Claude Code user MCP definition already matches the verified standard profile'
    return
  }
  if (-not $Apply) {
    if ($VerifyOnly) {
      throw 'Claude Code user MCP definition is missing or differs from the verified standard profile.'
    }
    if ($null -ne $state -and -not $ForceMcpRegistration) {
      throw 'A different Claude Code MCP definition named fastctx already exists. Re-run with -ForceMcpRegistration only after reviewing that conflict.'
    }
    return
  }
  if ($null -ne $state) {
    if (-not $ForceMcpRegistration) {
      throw 'A different Claude Code MCP definition named fastctx already exists. Re-run with -ForceMcpRegistration only after reviewing that conflict.'
    }
    $remove = Invoke-ClaudeCommand -Executable $Executable -Arguments @('mcp', 'remove', 'fastctx', '--scope', 'user') -ConfigDirectory $ConfigDirectory
    if ($remove.ExitCode -ne 0) {
      throw "Cannot remove the conflicting Claude Code user MCP definition: $($remove.Text)"
    }
  }
  Add-ClaudeMcpState -Executable $Executable -ConfigDirectory $ConfigDirectory
  $verified = Get-ClaudeUserMcpState -ConfigDirectory $ConfigDirectory
  if ($null -eq $verified -or -not (Test-ClaudeMcpState -State $verified)) {
    throw 'Claude Code accepted the registration command but the resulting user MCP definition does not match.'
  }
  Write-Log 'registered the Claude Code user MCP definition with the verified standard profile'
}

function Invoke-CcSwitchIntegration {
  param(
    [switch]$CheckOnly,
    [switch]$Preflight
  )
  if ($SkipCcSwitch) { return }
  $parameters = @{
    FastCtxBinary = $ExpectedBinary
    GitBash = $ExpectedEnvironment.FASTCTX_BASH
    NativeHome = $ExpectedEnvironment.HOME
    CodexHome = $ExpectedEnvironment.CODEX_HOME
  }
  if ($CcSwitchApps) { $parameters.Apps = $CcSwitchApps }
  if ($NoLaunchCcSwitch) { $parameters.NoLaunch = $true }
  if ($RequireCcSwitch) { $parameters.RequireCcSwitch = $true }
  if ($Preflight) { $parameters.PreflightOnly = $true }
  if ($CheckOnly) { $parameters.VerifyOnly = $true }
  & $CcSwitchHelper @parameters
}

$ExpectedBinary = [System.IO.Path]::GetFullPath($FastCtxBinary)
$CcSwitchHelper = Join-Path $PSScriptRoot 'configure-ccswitch-fastctx.ps1'
if (-not $SkipCcSwitch -and -not (Test-Path -LiteralPath $CcSwitchHelper -PathType Leaf)) {
  throw "CC Switch integration helper is missing: $CcSwitchHelper"
}
$guidancePath = Resolve-GuidanceSource
$guidanceSnapshot = Read-Utf8Snapshot -Path $guidancePath
$guidance = $guidanceSnapshot.Text.TrimEnd("`r", "`n")
$guidanceRange = Get-ManagedRange -Text $guidance -Path $guidancePath
if ($null -eq $guidanceRange -or $guidanceRange.Start -ne 0 -or $guidanceRange.End -ne $guidance.Length) {
  throw "FastCtx guidance template must contain exactly one complete managed block: $guidancePath"
}

$codexGuidance = Get-CodexGuidancePath
$plans = @(New-GuidancePlan -Path $codexGuidance -Guidance $guidance)
$claudeExecutable = $null
$claudeDirectory = $null
$claudeCliDirectory = $null
if (-not $SkipClaudeCode) {
  $claudeDirectory = Get-ClaudeConfigDirectory
  $claudeCliDirectory = Get-ClaudeCliConfigDirectory
  $plans += New-GuidancePlan -Path (Join-Path $claudeDirectory 'CLAUDE.md') -Guidance $guidance
  $claudeExecutable = Resolve-ClaudeExecutable
  Test-OrApplyClaudeMcp -Executable $claudeExecutable -ConfigDirectory $claudeCliDirectory -Apply $false
}

if ($PreflightOnly) {
  Invoke-CcSwitchIntegration -Preflight
  Write-Log 'agent integration preflight passed; no files were written'
  return
}
if ($VerifyOnly) {
  foreach ($plan in $plans) {
    if ($plan.Changed) { throw "FastCtx guidance block is missing or stale: $($plan.Path)" }
  }
  if (-not $SkipClaudeCode) {
    Test-OrApplyClaudeMcp -Executable $claudeExecutable -ConfigDirectory $claudeCliDirectory -Apply $false
  }
  Invoke-CcSwitchIntegration -CheckOnly
  Write-Log 'Claude Code, Codex, and optional CC Switch agent integration verification passed'
  return
}

foreach ($plan in $plans) { Write-GuidancePlan -Plan $plan }
if (-not $SkipClaudeCode) {
  Test-OrApplyClaudeMcp -Executable $claudeExecutable -ConfigDirectory $claudeCliDirectory -Apply $true
}
Invoke-CcSwitchIntegration
Write-Log "Codex guidance target: $codexGuidance"
if (-not $SkipClaudeCode) { Write-Log "Claude Code guidance target: $(Join-Path $claudeDirectory 'CLAUDE.md')" }
