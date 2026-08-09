[CmdletBinding()]
param(
  [string]$FastCtxBinary,
  [string]$GitBash,
  [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
  [string]$FastCtxHome = (Join-Path $env:USERPROFILE '.fastctx'),
  [switch]$VerifyOnly,
  [switch]$ForceBinary
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[fastctx-configure]'
$script:ConfigBackedUp = $false

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Resolve-FullPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  return [System.IO.Path]::GetFullPath($Path)
}

function ConvertTo-TomlBasicString {
  param([Parameter(Mandatory = $true)][string]$Value)
  return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Read-Utf8NoBom {
  param([Parameter(Mandatory = $true)][string]$Path)
  return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

function Write-Utf8NoBomAtomic {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Content
  )

  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $temporary = Join-Path $parent ('.fastctx-config-' + [guid]::NewGuid().ToString('N') + '.tmp')
  try {
    [System.IO.File]::WriteAllText($temporary, $Content, [System.Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      try {
        [System.IO.File]::Replace($temporary, $Path, $null)
      } catch {
        Copy-Item -LiteralPath $temporary -Destination $Path -Force
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
      }
    } else {
      Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
  } finally {
    if (Test-Path -LiteralPath $temporary) {
      Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
  }
}

function Backup-CodexConfig {
  param([Parameter(Mandatory = $true)][string]$ConfigPath)
  if ($script:ConfigBackedUp -or -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    return
  }

  $backupRoot = Join-Path (Split-Path -Parent $ConfigPath) 'backups\config'
  New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
  $backupPath = Join-Path $backupRoot "config.toml.$stamp.fastctx.bak"
  Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
  $script:ConfigBackedUp = $true
  Write-Log "config backup: $backupPath"
}

function Get-Newline {
  param([string]$Content)
  if ($Content.Contains("`r`n")) { return "`r`n" }
  return "`n"
}

function Update-TomlSection {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Header,
    [Parameter(Mandatory = $true)][hashtable]$Values,
    [string[]]$PreserveExistingKeys = @()
  )

  $newline = Get-Newline $Content
  $hadTrailingNewline = $Content.EndsWith($newline)
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($line in ($Content -split "\r?\n", -1)) {
    $lines.Add($line)
  }
  if ($hadTrailingNewline -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
    $lines.RemoveAt($lines.Count - 1)
  }

  $start = -1
  for ($index = 0; $index -lt $lines.Count; $index++) {
    if ($lines[$index].Trim() -eq $Header) {
      $start = $index
      break
    }
  }

  if ($start -lt 0) {
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
      $lines.RemoveAt($lines.Count - 1)
    }
    if ($lines.Count -gt 0) { $lines.Add('') }
    $lines.Add($Header)
    foreach ($key in ($Values.Keys | Sort-Object)) {
      $lines.Add("$key = $($Values[$key])")
    }
  } else {
    $end = $lines.Count
    for ($index = $start + 1; $index -lt $lines.Count; $index++) {
      if ($lines[$index] -match '^\s*\[.*\]\s*$') {
        $end = $index
        break
      }
    }

    $body = New-Object System.Collections.Generic.List[string]
    for ($index = $start + 1; $index -lt $end; $index++) {
      $body.Add($lines[$index])
    }

    foreach ($key in ($Values.Keys | Sort-Object)) {
      $keyPattern = '^\s*' + [regex]::Escape([string]$key) + '\s*='
      $matchIndexes = @()
      for ($index = 0; $index -lt $body.Count; $index++) {
        if ($body[$index] -match $keyPattern) { $matchIndexes += $index }
      }
      if ($matchIndexes.Count -gt 0) {
        if ($PreserveExistingKeys -contains [string]$key) { continue }
        $body[$matchIndexes[0]] = "$key = $($Values[$key])"
        for ($index = $matchIndexes.Count - 1; $index -ge 1; $index--) {
          $body.RemoveAt($matchIndexes[$index])
        }
      } else {
        $body.Add("$key = $($Values[$key])")
      }
    }

    $rebuilt = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $start; $index++) { $rebuilt.Add($lines[$index]) }
    $rebuilt.Add($Header)
    foreach ($line in $body) { $rebuilt.Add($line) }
    for ($index = $end; $index -lt $lines.Count; $index++) { $rebuilt.Add($lines[$index]) }
    $lines = $rebuilt
  }

  $result = [string]::Join($newline, [string[]]$lines)
  if ($hadTrailingNewline -or $result.Length -gt 0) { $result += $newline }
  return $result
}

function Get-TomlSectionBody {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Header
  )
  $pattern = '(?ms)^\s*' + [regex]::Escape($Header) + '\s*\r?\n(?<body>(?:(?!^\s*\[).)*)'
  $match = [regex]::Match($Content, $pattern)
  if (-not $match.Success) {
    throw "missing TOML table: $Header"
  }
  return $match.Groups['body'].Value
}

function Assert-TomlValue {
  param(
    [Parameter(Mandatory = $true)][string]$Body,
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][string]$Expected
  )
  $pattern = '(?m)^\s*' + [regex]::Escape($Key) + '\s*=\s*' + [regex]::Escape($Expected) + '\s*(?:#.*)?$'
  if (-not [regex]::IsMatch($Body, $pattern)) {
    throw "unexpected or missing TOML value: $Key = $Expected"
  }
}

function Assert-FastCtxMcpConfig {
  param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$Binary,
    [Parameter(Mandatory = $true)][string]$NativeHome,
    [Parameter(Mandatory = $true)][string]$Profile,
    [Parameter(Mandatory = $true)][string]$Bash
  )
  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Codex config does not exist: $ConfigPath"
  }
  if (-not (Test-Path -LiteralPath $Binary -PathType Leaf)) {
    throw "configured FastCtx binary does not exist: $Binary"
  }
  if (-not (Test-Path -LiteralPath $Bash -PathType Leaf)) {
    throw "configured Git Bash does not exist: $Bash"
  }

  $content = Read-Utf8NoBom $ConfigPath
  $server = Get-TomlSectionBody -Content $content -Header '[mcp_servers.fastctx]'
  Assert-TomlValue -Body $server -Key 'command' -Expected (ConvertTo-TomlBasicString $Binary)
  Assert-TomlValue -Body $server -Key 'args' -Expected '["serve", "--enable-shell"]'
  Assert-TomlValue -Body $server -Key 'startup_timeout_sec' -Expected '120'
  Assert-TomlValue -Body $server -Key 'tool_timeout_sec' -Expected '300'

  $environment = Get-TomlSectionBody -Content $content -Header '[mcp_servers.fastctx.env]'
  Assert-TomlValue -Body $environment -Key 'FASTCTX_BASH' -Expected (ConvertTo-TomlBasicString $Bash)
  Assert-TomlValue -Body $environment -Key 'HOME' -Expected (ConvertTo-TomlBasicString $NativeHome)
  Assert-TomlValue -Body $environment -Key 'USERPROFILE' -Expected (ConvertTo-TomlBasicString $NativeHome)
  Assert-TomlValue -Body $environment -Key 'CODEX_HOME' -Expected (ConvertTo-TomlBasicString $Profile)
  foreach ($budget in @(
    'FASTCTX_TOKEN_BUDGET',
    'FASTCTX_GREP_TOKEN_BUDGET',
    'FASTCTX_GLOB_TOKEN_BUDGET',
    'FASTCTX_RUN_TOKEN_BUDGET',
    'FASTCTX_JOB_OUTPUT_TOKEN_BUDGET'
  )) {
    if (-not [regex]::IsMatch($environment, '(?m)^\s*' + [regex]::Escape($budget) + '\s*=\s*"[1-9][0-9]*"\s*(?:#.*)?$')) {
      throw "missing or invalid FastCtx token budget: $budget"
    }
  }
  Write-Log 'FastCtx MCP tables and stable paths are valid'
}

function Write-MinimalFastCtxConfig {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    return
  }
  $content = @"
schema_version = 1
last_seen_version = "0.2.4"
tool_budget_epoch = 2
language = "zh-CN"
tier = "standard"

[fastshell]
enabled = true
job_storage_limit_mib = 1024
max_running_jobs = 128
job_list_limit = 20

[update]
auto_check = false
source = "auto"
"@
  Write-Utf8NoBomAtomic -Path $Path -Content ($content.TrimStart() + "`r`n")
  Write-Log "created minimal FastCtx config: $Path"
}

function Get-GitBashPath {
  param([string]$Override)
  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($Override)) { $candidates.Add($Override) }
  if (-not [string]::IsNullOrWhiteSpace($env:FASTCTX_BASH)) { $candidates.Add($env:FASTCTX_BASH) }

  $git = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($git) {
    $gitBin = Split-Path -Parent $git.Source
    $gitRoot = Split-Path -Parent $gitBin
    $candidates.Add((Join-Path $gitRoot 'bin\bash.exe'))
    $candidates.Add((Join-Path $gitRoot 'usr\bin\bash.exe'))
  }
  foreach ($programRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not [string]::IsNullOrWhiteSpace($programRoot)) {
      $candidates.Add((Join-Path $programRoot 'Git\bin\bash.exe'))
    }
  }

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return (Resolve-FullPath $candidate)
    }
  }
  throw 'Git Bash was not found. Install Git for Windows or pass -GitBash <path>.'
}

function Get-FastCtxBinaryCandidates {
  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($FastCtxBinary)) { $candidates.Add($FastCtxBinary) }

  $target = Join-Path $FastCtxHome 'bin\fastctx.exe'
  $candidates.Add($target)

  $git = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($git) {
    $gitBin = Split-Path -Parent $git.Source
    $gitRoot = Split-Path -Parent $gitBin
    $customRoot = Join-Path $gitRoot '.fastctx\custom'
    if (Test-Path -LiteralPath $customRoot -PathType Container) {
      foreach ($item in (Get-ChildItem -LiteralPath $customRoot -Recurse -Filter 'fastctx.exe' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $candidates.Add($item.FullName)
      }
    }
  }

  $node = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($node) {
    $nodeRoot = Split-Path -Parent $node.Source
    $candidates.Add((Join-Path $nodeRoot 'node_modules\fastctx\node_modules\@fastctx\win32-x64\bin\fastctx.exe'))
    $candidates.Add((Join-Path $nodeRoot 'node_global\node_modules\fastctx\node_modules\@fastctx\win32-x64\bin\fastctx.exe'))
  }

  foreach ($root in @($env:APPDATA, $env:LOCALAPPDATA, $env:USERPROFILE)) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }
    $candidateRoot = Join-Path $root 'npm\node_modules\fastctx\node_modules\@fastctx\win32-x64\bin\fastctx.exe'
    $candidates.Add($candidateRoot)
  }
  return $candidates | Select-Object -Unique
}

function Resolve-FastCtxBinary {
  foreach ($candidate in (Get-FastCtxBinaryCandidates)) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return (Resolve-FullPath $candidate)
    }
  }
  throw 'FastCtx binary was not found. Install fastctx or pass -FastCtxBinary <path>.'
}

function Install-FastCtxBinary {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )
  if ($Source -ieq $Destination) { return }
  if ((Test-Path -LiteralPath $Destination -PathType Leaf) -and -not $ForceBinary) {
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Source).Hash
    $destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash
    if ($sourceHash -eq $destinationHash) {
      Write-Log "stable FastCtx binary already matches source SHA-256: $sourceHash"
      return
    }
    Write-Log "updating stable FastCtx binary because SHA-256 changed: $destinationHash -> $sourceHash"
  }
  $parent = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  $temporary = Join-Path $parent ('.fastctx-binary-' + [guid]::NewGuid().ToString('N') + '.tmp')
  try {
    Copy-Item -LiteralPath $Source -Destination $temporary -Force
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
      try {
        [System.IO.File]::Replace($temporary, $Destination, $null)
      } catch {
        Copy-Item -LiteralPath $temporary -Destination $Destination -Force
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
      }
    } else {
      Move-Item -LiteralPath $temporary -Destination $Destination -Force
    }
    Write-Log "installed stable FastCtx binary: $Destination"
  } finally {
    if (Test-Path -LiteralPath $temporary) {
      Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-FastCtxVersion {
  param([Parameter(Mandatory = $true)][string]$Binary)
  $output = (& $Binary --version 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $output -notmatch '^fastctx\s+(\d+\.\d+\.\d+)') {
    throw "FastCtx version check failed for $($Binary): $output"
  }
  Write-Log "binary: $output"
  return $Matches[1]
}

function Invoke-FastCtxStatus {
  param(
    [Parameter(Mandatory = $true)][string]$Binary,
    [Parameter(Mandatory = $true)][string]$NativeHome,
    [Parameter(Mandatory = $true)][string]$Profile,
    [Parameter(Mandatory = $true)][string]$Bash
  )
  $old = @{}
  foreach ($name in @('HOME', 'USERPROFILE', 'CODEX_HOME', 'FASTCTX_BASH', 'FASTCTX_DISABLE_UPDATE_CHECK')) {
    $old[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
  }
  try {
    [Environment]::SetEnvironmentVariable('HOME', $NativeHome, 'Process')
    [Environment]::SetEnvironmentVariable('USERPROFILE', $NativeHome, 'Process')
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $Profile, 'Process')
    [Environment]::SetEnvironmentVariable('FASTCTX_BASH', $Bash, 'Process')
    [Environment]::SetEnvironmentVariable('FASTCTX_DISABLE_UPDATE_CHECK', '1', 'Process')
    $output = (& $Binary status --codex-home $Profile 2>&1 | Out-String).TrimEnd()
    if ($LASTEXITCODE -ne 0) {
      throw "FastCtx status failed (exit code $LASTEXITCODE): $output"
    }
    Write-Log "status passed: $($output -split "`r?`n" | Select-Object -First 1)"
  } finally {
    foreach ($name in $old.Keys) {
      [Environment]::SetEnvironmentVariable($name, $old[$name], 'Process')
    }
  }
}

function Invoke-FastCtxToolsList {
  param(
    [Parameter(Mandatory = $true)][string]$Binary,
    [Parameter(Mandatory = $true)][string]$NativeHome,
    [Parameter(Mandatory = $true)][string]$Profile,
    [Parameter(Mandatory = $true)][string]$Bash
  )

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $Binary
  $startInfo.Arguments = 'serve --enable-shell'
  $startInfo.WorkingDirectory = $Profile
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $utf8 = [System.Text.UTF8Encoding]::new($false)
  $startInfo.StandardOutputEncoding = $utf8
  $startInfo.StandardErrorEncoding = $utf8
  $startInfo.EnvironmentVariables['HOME'] = $NativeHome
  $startInfo.EnvironmentVariables['USERPROFILE'] = $NativeHome
  $startInfo.EnvironmentVariables['CODEX_HOME'] = $Profile
  $startInfo.EnvironmentVariables['FASTCTX_BASH'] = $Bash
  $startInfo.EnvironmentVariables['FASTCTX_DISABLE_UPDATE_CHECK'] = '1'

  $requests = @(
    (@{
      jsonrpc = '2.0'
      id = 1
      method = 'initialize'
      params = @{
        protocolVersion = '2025-03-26'
        capabilities = @{}
        clientInfo = @{ name = 'configure-fastctx'; version = '1.0' }
      }
    } | ConvertTo-Json -Compress -Depth 10),
    (@{
      jsonrpc = '2.0'
      method = 'notifications/initialized'
      params = @{}
    } | ConvertTo-Json -Compress -Depth 10),
    (@{
      jsonrpc = '2.0'
      id = 2
      method = 'tools/list'
      params = @{}
    } | ConvertTo-Json -Compress -Depth 10)
  )

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $started = $false
  try {
    $started = $process.Start()
    if (-not $started) {
      throw 'FastCtx MCP handshake process did not start.'
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    foreach ($request in $requests) {
      $process.StandardInput.WriteLine($request)
    }
    $process.StandardInput.Close()

    if (-not $process.WaitForExit(30000)) {
      try { $process.Kill() } catch {}
      throw 'FastCtx MCP handshake timed out after 30 seconds.'
    }
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
      throw "FastCtx MCP handshake failed (exit code $($process.ExitCode)): $stderr"
    }

    $responses = @()
    foreach ($line in ($stdout -split "`r?`n")) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try {
        $responses += ($line | ConvertFrom-Json -ErrorAction Stop)
      } catch {
        throw "FastCtx MCP handshake returned non-JSON output: $line"
      }
    }
    $initializeResponse = @($responses | Where-Object { $_.id -eq 1 }) | Select-Object -First 1
    $toolsResponse = @($responses | Where-Object { $_.id -eq 2 }) | Select-Object -First 1
    if (-not $initializeResponse -or $initializeResponse.error) {
      throw 'FastCtx MCP initialize response is missing or contains an error.'
    }
    if (-not $toolsResponse -or $toolsResponse.error) {
      throw 'FastCtx MCP tools/list response is missing or contains an error.'
    }

    $expected = @('glob', 'grep', 'job_kill', 'job_list', 'job_output', 'read', 'replace', 'run', 'run_background') | Sort-Object
    $actual = @($toolsResponse.result.tools | ForEach-Object { [string]$_.name }) | Sort-Object
    $difference = @(Compare-Object -ReferenceObject $expected -DifferenceObject $actual)
    if ($actual.Count -ne $expected.Count -or $difference.Count -gt 0) {
      throw "FastCtx MCP tools/list mismatch. Expected: $($expected -join ', '); actual: $($actual -join ', ')"
    }
    Write-Log "MCP initialize/tools-list passed: $($actual -join ', ')"
  } finally {
    if ($started -and -not $process.HasExited) {
      try { $process.Kill() } catch {}
    }
    $process.Dispose()
  }
}

function Invoke-TomlValidation {
  param([Parameter(Mandatory = $true)][string]$Path)
  $python = Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $python) {
    Write-Log 'warning: python.exe not found; skipped tomllib validation'
    return
  }
  & $python.Source -c 'import sys,tomllib,pathlib; tomllib.loads(pathlib.Path(sys.argv[1]).read_bytes().decode())' $Path
  if ($LASTEXITCODE -ne 0) {
    throw "tomllib validation failed: $Path"
  }
  Write-Log "TOML valid: $Path"
}

function Set-FastCtxMcpConfig {
  param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$Binary,
    [Parameter(Mandatory = $true)][string]$NativeHome,
    [Parameter(Mandatory = $true)][string]$Profile,
    [Parameter(Mandatory = $true)][string]$Bash
  )
  $before = if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) { Read-Utf8NoBom $ConfigPath } else { '' }
  $after = Update-TomlSection $before '[mcp_servers.fastctx]' @{
    args = '["serve", "--enable-shell"]'
    command = ConvertTo-TomlBasicString $Binary
    startup_timeout_sec = '120'
    tool_timeout_sec = '300'
  }
  $after = Update-TomlSection $after '[mcp_servers.fastctx.env]' @{
    CODEX_HOME = ConvertTo-TomlBasicString $Profile
    FASTCTX_BASH = ConvertTo-TomlBasicString $Bash
    FASTCTX_GLOB_TOKEN_BUDGET = '"5400"'
    FASTCTX_GREP_TOKEN_BUDGET = '"10800"'
    FASTCTX_JOB_OUTPUT_TOKEN_BUDGET = '"5400"'
    FASTCTX_RUN_TOKEN_BUDGET = '"10800"'
    FASTCTX_TOKEN_BUDGET = '"54000"'
    HOME = ConvertTo-TomlBasicString $NativeHome
    USERPROFILE = ConvertTo-TomlBasicString $NativeHome
  } -PreserveExistingKeys @(
    'FASTCTX_GLOB_TOKEN_BUDGET',
    'FASTCTX_GREP_TOKEN_BUDGET',
    'FASTCTX_JOB_OUTPUT_TOKEN_BUDGET',
    'FASTCTX_RUN_TOKEN_BUDGET',
    'FASTCTX_TOKEN_BUDGET'
  )
  if ($after -eq $before) {
    Write-Log 'Codex FastCtx MCP config already matches the requested chain'
    return
  }
  Backup-CodexConfig $ConfigPath
  Write-Utf8NoBomAtomic -Path $ConfigPath -Content $after
  Write-Log "updated only FastCtx MCP tables: $ConfigPath"
}

if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
  throw 'USERPROFILE is required for a stable Windows FastCtx installation.'
}
  $nativeHome = Resolve-FullPath $env:USERPROFILE
  $CodexHome = Resolve-FullPath $CodexHome
  $FastCtxHome = Resolve-FullPath $FastCtxHome
  $configPath = Join-Path $CodexHome 'config.toml'
  $fastctxConfigPath = Join-Path $FastCtxHome 'config.toml'
  $targetBinary = Join-Path $FastCtxHome 'bin\fastctx.exe'
  $bash = Get-GitBashPath $GitBash
  if ($VerifyOnly) {
    if (-not (Test-Path -LiteralPath $targetBinary -PathType Leaf)) {
      throw "stable FastCtx binary does not exist: $targetBinary"
    }
  } else {
    New-Item -ItemType Directory -Force -Path $CodexHome, $FastCtxHome | Out-Null
    $source = Resolve-FastCtxBinary
    Install-FastCtxBinary -Source $source -Destination $targetBinary
  }
  $binary = $targetBinary
  [void](Invoke-FastCtxVersion $binary)

  if ($VerifyOnly) {
    if (-not (Test-Path -LiteralPath $fastctxConfigPath -PathType Leaf)) {
      throw "FastCtx config does not exist: $fastctxConfigPath"
    }
  } else {
    Write-MinimalFastCtxConfig $fastctxConfigPath
  }
  Invoke-TomlValidation $fastctxConfigPath
  if (-not $VerifyOnly) {
    Set-FastCtxMcpConfig -ConfigPath $configPath -Binary $targetBinary -NativeHome $nativeHome -Profile $CodexHome -Bash $bash
    Invoke-TomlValidation $configPath
  } else {
    Invoke-TomlValidation $configPath
  }
  Assert-FastCtxMcpConfig -ConfigPath $configPath -Binary $targetBinary -NativeHome $nativeHome -Profile $CodexHome -Bash $bash
  Invoke-FastCtxStatus -Binary $binary -NativeHome $nativeHome -Profile $CodexHome -Bash $bash
  Invoke-FastCtxToolsList -Binary $binary -NativeHome $nativeHome -Profile $CodexHome -Bash $bash

Write-Log 'FastCtx chain is ready; restart Codex Desktop once to reload MCP configuration.'
