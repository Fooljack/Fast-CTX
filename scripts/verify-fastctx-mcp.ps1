[CmdletBinding()]
param(
  [string]$FastCtxBinary = (Join-Path $env:USERPROFILE '.fastctx\bin\fastctx.exe'),
  [string]$GitBash,
  [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[fastctx-mcp-smoke]'

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Resolve-GitBash {
  param([string]$Override)
  $candidates = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($Override)) { $candidates.Add($Override) }
  if (-not [string]::IsNullOrWhiteSpace($env:FASTCTX_BASH)) { $candidates.Add($env:FASTCTX_BASH) }

  $git = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($git) {
    $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
    $candidates.Add((Join-Path $gitRoot 'bin\bash.exe'))
    $candidates.Add((Join-Path $gitRoot 'usr\bin\bash.exe'))
  }
  foreach ($registryPath in @(
    'HKCU:\SOFTWARE\GitForWindows',
    'HKLM:\SOFTWARE\GitForWindows',
    'HKLM:\SOFTWARE\WOW6432Node\GitForWindows'
  )) {
    $installPath = (Get-ItemProperty -LiteralPath $registryPath -Name InstallPath -ErrorAction SilentlyContinue).InstallPath
    if (-not [string]::IsNullOrWhiteSpace($installPath)) {
      $candidates.Add((Join-Path $installPath 'bin\bash.exe'))
      $candidates.Add((Join-Path $installPath 'usr\bin\bash.exe'))
    }
  }
  foreach ($programRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
    if (-not [string]::IsNullOrWhiteSpace($programRoot)) {
      $candidates.Add((Join-Path $programRoot 'Git\bin\bash.exe'))
      $candidates.Add((Join-Path $programRoot 'Programs\Git\bin\bash.exe'))
    }
  }

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      continue
    }
    $resolved = [System.IO.Path]::GetFullPath($candidate)
    $version = (& $resolved --version 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0 -and $version -match 'GNU bash') {
      return $resolved
    }
  }
  throw 'Git Bash was not found. Install Git for Windows or pass -GitBash <path>.'
}

function Read-McpResponse {
  param(
    [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
    [Parameter(Mandatory = $true)][int]$Id,
    [Parameter(Mandatory = $true)][int]$TimeoutMs
  )
  while ($true) {
    $task = $Process.StandardOutput.ReadLineAsync()
    if (-not $task.Wait($TimeoutMs)) {
      throw "MCP response $Id timed out after $TimeoutMs ms"
    }
    $line = $task.Result
    if ($null -eq $line) {
      throw "MCP server closed stdout before response $Id"
    }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $response = $line | ConvertFrom-Json -ErrorAction Stop
    } catch {
      throw "MCP server returned non-JSON output: $line"
    }
    if ($null -ne $response.id -and [int]$response.id -eq $Id) {
      return $response
    }
  }
}

function Invoke-McpCall {
  param(
    [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
    [Parameter(Mandatory = $true)][int]$Id,
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)]$Params,
    [Parameter(Mandatory = $true)][int]$TimeoutMs
  )
  $request = @{
    jsonrpc = '2.0'
    id = $Id
    method = $Method
    params = $Params
  } | ConvertTo-Json -Compress -Depth 20
  $Process.StandardInput.WriteLine($request)
  $response = Read-McpResponse -Process $Process -Id $Id -TimeoutMs $TimeoutMs
  if ($response.error) {
    throw "MCP $Method failed: $($response.error | ConvertTo-Json -Compress -Depth 10)"
  }
  return $response
}

function Get-ToolText {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][string]$Tool
  )
  $text = (@($Response.result.content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { [string]$_.text }) -join "`n"
  if ($Response.result.isError) {
    throw "FastCtx tool $Tool returned an error: $text"
  }
  return $text
}

if (-not (Test-Path -LiteralPath $FastCtxBinary -PathType Leaf)) {
  throw "FastCtx binary does not exist: $FastCtxBinary"
}
if ($TimeoutSeconds -lt 5 -or $TimeoutSeconds -gt 240) {
  throw 'TimeoutSeconds must be between 5 and 240.'
}

$binary = [System.IO.Path]::GetFullPath($FastCtxBinary)
$bash = Resolve-GitBash $GitBash
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('fastctx-mcp-smoke-' + [guid]::NewGuid().ToString('N'))
$smokeHome = Join-Path $temporaryRoot 'home'
$codexHome = Join-Path $smokeHome '.codex'
$work = Join-Path $temporaryRoot 'work'
$sample = Join-Path $work 'sample.txt'
$process = $null
$stderrTask = $null
$killJobId = $null
$requestId = 0
$timeoutMs = $TimeoutSeconds * 1000

try {
  New-Item -ItemType Directory -Force -Path $codexHome, $work | Out-Null
  [System.IO.File]::WriteAllText($sample, "first`nneedle second`nthird`n", [System.Text.UTF8Encoding]::new($false))

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $binary
  $startInfo.Arguments = 'serve --enable-shell'
  $startInfo.WorkingDirectory = $work
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $utf8 = [System.Text.UTF8Encoding]::new($false)
  $startInfo.StandardOutputEncoding = $utf8
  $startInfo.StandardErrorEncoding = $utf8
  $startInfo.EnvironmentVariables['HOME'] = $smokeHome
  $startInfo.EnvironmentVariables['USERPROFILE'] = $smokeHome
  $startInfo.EnvironmentVariables['CODEX_HOME'] = $codexHome
  $startInfo.EnvironmentVariables['FASTCTX_BASH'] = $bash
  $startInfo.EnvironmentVariables['FASTCTX_DISABLE_UPDATE_CHECK'] = '1'
  $startInfo.EnvironmentVariables['FASTCTX_TEST_BUILD_ID'] = 'mcp-smoke-' + [guid]::NewGuid().ToString('N')
  $startInfo.EnvironmentVariables['FASTCTX_TEST_RUNTIME_IDLE_MS'] = '300'

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) { throw 'FastCtx MCP smoke process did not start.' }
  $process.StandardInput.AutoFlush = $true
  $stderrTask = $process.StandardError.ReadToEndAsync()

  $requestId++
  $initialize = Invoke-McpCall -Process $process -Id $requestId -Method 'initialize' -Params @{
    protocolVersion = '2025-03-26'
    capabilities = @{}
    clientInfo = @{ name = 'fastctx-mcp-smoke'; version = '1.0' }
  } -TimeoutMs $timeoutMs
  if ($initialize.result.serverInfo.name -ne 'fastctx') { throw 'Unexpected MCP server identity.' }
  $process.StandardInput.WriteLine((@{ jsonrpc = '2.0'; method = 'notifications/initialized'; params = @{} } | ConvertTo-Json -Compress))

  $requestId++
  $tools = Invoke-McpCall -Process $process -Id $requestId -Method 'tools/list' -Params @{} -TimeoutMs $timeoutMs
  $expectedTools = @('glob','grep','job_kill','job_list','job_output','read','replace','run','run_background') | Sort-Object
  $actualTools = @($tools.result.tools | ForEach-Object { [string]$_.name }) | Sort-Object
  if ($actualTools.Count -ne $expectedTools.Count -or @(Compare-Object $expectedTools $actualTools).Count -ne 0) {
    throw "Nine-tool manifest mismatch: $($actualTools -join ', ')"
  }

  $requestId++
  $read = Invoke-McpCall -Process $process -Id $requestId -Method 'tools/call' -Params @{
    name = 'read'
    arguments = @{ files = @(@{ path = $sample; offset = 1; limit = 1 }, @{ path = $sample; offset = 2; limit = 1 }) }
  } -TimeoutMs $timeoutMs
  $readText = Get-ToolText $read 'read'
  if ($readText -notmatch 'first' -or $readText -notmatch 'needle second') { throw 'read smoke output is incomplete.' }

  $requestId++
  $grep = Invoke-McpCall -Process $process -Id $requestId -Method 'tools/call' -Params @{
    name = 'grep'; arguments = @{ pattern = 'needle'; path = $work; output_mode = 'content' }
  } -TimeoutMs $timeoutMs
  if ((Get-ToolText $grep 'grep') -notmatch 'needle second') { throw 'grep smoke did not find the fixture.' }

  $requestId++
  $glob = Invoke-McpCall -Process $process -Id $requestId -Method 'tools/call' -Params @{
    name = 'glob'; arguments = @{ pattern = '*.txt'; path = $work }
  } -TimeoutMs $timeoutMs
  if ((Get-ToolText $glob 'glob') -notmatch 'sample\.txt') { throw 'glob smoke did not find the fixture.' }

  $requestId++
  $replace = Invoke-McpCall -Process $process -Id $requestId -Method 'tools/call' -Params @{
    name = 'replace'; arguments = @{ pattern = 'needle'; replacement = 'changed'; path = $sample; literal = $true }
  } -TimeoutMs $timeoutMs
  [void](Get-ToolText $replace 'replace')
  if (([System.IO.File]::ReadAllText($sample)) -notmatch 'changed second') { throw 'replace smoke did not update the fixture.' }

  $requestId++
  $run = Invoke-McpCall -Process $process -Id $requestId -Method 'tools/call' -Params @{
    name = 'run'; arguments = @{ command = "printf 'fastctx-run-ok\n'"; cwd = $work; login_shell = $false }
  } -TimeoutMs $timeoutMs
  if ((Get-ToolText $run 'run') -notmatch 'fastctx-run-ok') { throw 'run smoke output is missing.' }

  $requestId++
  $background = Invoke-McpCall -Process $process -Id $requestId -Method 'tools/call' -Params @{
    name = 'run_background'; arguments = @{ command = "printf 'fastctx-bg-ok\n'"; cwd = $work; login_shell = $false }
  } -TimeoutMs $timeoutMs
  $backgroundText = Get-ToolText $background 'run_background'
  $backgroundMatch = [regex]::Match($backgroundText, '\bj-[a-z0-9]+\b')
  if (-not $backgroundMatch.Success) { throw "run_background did not return a job id: $backgroundText" }
  $backgroundJobId = $backgroundMatch.Value

  $requestId++
  $jobOutput = Invoke-McpCall -Process $process -Id $requestId -Method 'tools/call' -Params @{
    name = 'job_output'; arguments = @{ job_id = $backgroundJobId; wait_ms = 10000 }
  } -TimeoutMs $timeoutMs
  if ((Get-ToolText $jobOutput 'job_output') -notmatch 'fastctx-bg-ok') { throw 'job_output smoke output is missing.' }

  $requestId++
  $jobList = Invoke-McpCall -Process $process -Id $requestId -Method 'tools/call' -Params @{
    name = 'job_list'; arguments = @{ status = 'all' }
  } -TimeoutMs $timeoutMs
  if ((Get-ToolText $jobList 'job_list') -notmatch [regex]::Escape($backgroundJobId)) { throw 'job_list smoke did not return the completed job.' }

  $requestId++
  $killBackground = Invoke-McpCall -Process $process -Id $requestId -Method 'tools/call' -Params @{
    name = 'run_background'; arguments = @{ command = "printf 'fastctx-kill-started\n'; sleep 15"; cwd = $work; login_shell = $false }
  } -TimeoutMs $timeoutMs
  $killText = Get-ToolText $killBackground 'run_background'
  $killMatch = [regex]::Match($killText, '\bj-[a-z0-9]+\b')
  if (-not $killMatch.Success) { throw "kill fixture did not return a job id: $killText" }
  $killJobId = $killMatch.Value

  $requestId++
  $jobKill = Invoke-McpCall -Process $process -Id $requestId -Method 'tools/call' -Params @{
    name = 'job_kill'; arguments = @{ job_id = $killJobId }
  } -TimeoutMs $timeoutMs
  [void](Get-ToolText $jobKill 'job_kill')
  $killJobId = $null

  Write-Log 'all nine MCP tools passed real smoke calls'
} finally {
  if ($process -and -not $process.HasExited -and $killJobId) {
    try {
      $requestId++
      $cleanupKill = Invoke-McpCall -Process $process -Id $requestId -Method 'tools/call' -Params @{
        name = 'job_kill'; arguments = @{ job_id = $killJobId }
      } -TimeoutMs 5000
      [void](Get-ToolText $cleanupKill 'job_kill')
    } catch {}
  }
  if ($process) {
    if (-not $process.HasExited) {
      try { $process.StandardInput.Close() } catch {}
      if (-not $process.WaitForExit(10000)) {
        try { $process.Kill() } catch {}
      }
    }
    if ($stderrTask) {
      try {
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if (-not [string]::IsNullOrWhiteSpace($stderr)) { Write-Log "server stderr: $($stderr.Trim())" }
      } catch {}
    }
    $process.Dispose()
  }
  Start-Sleep -Milliseconds 1000
  for ($attempt = 1; $attempt -le 20 -and (Test-Path -LiteralPath $temporaryRoot); $attempt++) {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) { Start-Sleep -Milliseconds 250 }
  }
  if (Test-Path -LiteralPath $temporaryRoot) {
    throw "FastCtx MCP smoke temporary directory could not be cleaned: $temporaryRoot"
  }
}
