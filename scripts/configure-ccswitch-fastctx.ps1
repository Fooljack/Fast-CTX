[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$FastCtxBinary,
  [Parameter(Mandatory = $true)][string]$GitBash,
  [Parameter(Mandatory = $true)][string]$NativeHome,
  [Parameter(Mandatory = $true)][string]$CodexHome,
  [string]$Apps = 'claude,codex',
  [switch]$NoLaunch,
  [switch]$RequireCcSwitch,
  [switch]$PreflightOnly,
  [switch]$VerifyOnly,
  [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[fastctx-ccswitch]'

# Canonical order of the MCP-capable CC Switch applications. Import links are emitted in
# this order so the same -Apps set always produces the same deep link.
$KnownApps = @('claude', 'codex', 'gemini', 'grokbuild', 'opencode', 'hermes')
$AppDisplayNames = @{
  claude = 'Claude Code'
  codex = 'Codex'
  gemini = 'Gemini'
  grokbuild = 'Grok Build'
  opencode = 'OpenCode'
  hermes = 'Hermes'
}

$requestedApps = @(
  $Apps.Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ }
)
if ($requestedApps.Count -eq 0) {
  throw '-Apps must name at least one CC Switch application.'
}
$unknownApps = @($requestedApps | Where-Object { $KnownApps -notcontains $_ })
if ($unknownApps.Count -gt 0) {
  throw "unsupported CC Switch application(s): $($unknownApps -join ', '). Supported: $($KnownApps -join ', ')."
}
# CC Switch merges the app set as a union on import, so a narrow default is the reversible
# direction: widening later is one more import, narrowing is not.
$TargetAppList = @($KnownApps | Where-Object { $requestedApps -contains $_ })
$TargetApps = $TargetAppList -join ','
$TargetAppDisplay = ($TargetAppList | ForEach-Object { $AppDisplayNames[$_] }) -join ', '

function Write-Log {
  param([Parameter(Mandatory = $true)][string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Test-CcSwitchProtocol {
  $key = $null
  try {
    $key = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey('ccswitch\shell\open\command')
    if ($null -eq $key) { return $false }
    return -not [string]::IsNullOrWhiteSpace([string]$key.GetValue(''))
  } catch {
    Write-Log "could not inspect the ccswitch:// protocol registration: $($_.Exception.Message)"
    return $false
  } finally {
    if ($null -ne $key) { $key.Dispose() }
  }
}

function New-CcSwitchImportUri {
  $environment = [ordered]@{
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
  $payload = [ordered]@{
    mcpServers = [ordered]@{
      fastctx = [ordered]@{
        type = 'stdio'
        command = [System.IO.Path]::GetFullPath($FastCtxBinary)
        args = @('serve', '--enable-shell')
        # Codex reads these two; the other applications ignore unknown keys. CC Switch keeps a
        # single shared spec per server id and preserves it on re-import, so omitting them here
        # would leave Codex without the timeouts that configure-fastctx.ps1 writes directly.
        # Keep in step with the canonical Codex profile in configure-fastctx.ps1.
        startup_timeout_sec = 120
        tool_timeout_sec = 300
        env = $environment
      }
    }
  }
  $json = $payload | ConvertTo-Json -Depth 8 -Compress
  $base64 = [System.Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($json))
  return 'ccswitch://v1/import?resource=mcp&apps=' +
    [System.Uri]::EscapeDataString($TargetApps) +
    '&config=' + [System.Uri]::EscapeDataString($base64)
}

if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
  throw 'CC Switch automatic import is supported by this helper on Windows only.'
}
if (-not $PreflightOnly) {
  foreach ($path in @($FastCtxBinary, $GitBash)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "CC Switch FastCtx import requires this file: $path"
    }
  }
}

$uri = New-CcSwitchImportUri
if ($PassThru -or $NoLaunch) { Write-Output $uri }

$available = Test-CcSwitchProtocol
if ($RequireCcSwitch -and -not $available) {
  throw 'CC Switch was required, but the ccswitch:// protocol is not registered for this user.'
}
if ($PreflightOnly) {
  if ($available) {
    Write-Log 'ccswitch:// preflight passed; no files or external applications were modified'
  } else {
    Write-Log 'ccswitch:// is not registered; optional CC Switch integration will be skipped'
  }
  return
}
if ($VerifyOnly) {
  if ($available) {
    Write-Log "ccswitch:// is registered; the verified FastCtx import link targets: $TargetAppDisplay"
  } else {
    Write-Log 'ccswitch:// is not registered; Claude Code and Codex remain configured directly'
  }
  Write-Log 'verification does not inspect or modify the CC Switch SQLite database'
  return
}
if ($NoLaunch) {
  Write-Log 'CC Switch launch was disabled; the verified import link was generated without opening another application'
  return
}
if (-not $available) {
  Write-Log 'CC Switch was not detected; install or start CC Switch, then rerun this installer to import FastCtx there'
  return
}

Start-Process -FilePath $uri
Write-Log "opened the official CC Switch import confirmation for: $TargetAppDisplay"
Write-Log 'review the displayed command, arguments, and environment, then confirm Import in CC Switch'
