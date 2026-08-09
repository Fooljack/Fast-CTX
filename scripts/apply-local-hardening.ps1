[CmdletBinding()]
param(
  [string]$SkillDir
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-local-hardening]'

function Write-Log {
  param([string]$Message)
  Write-Host "$LogPrefix $Message"
}

function Resolve-SkillRoot {
  if (-not [string]::IsNullOrWhiteSpace($SkillDir)) {
    return (Resolve-Path -LiteralPath $SkillDir -ErrorAction Stop).ProviderPath
  }
  if ($PSScriptRoot) {
    return (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot) -ErrorAction Stop).ProviderPath
  }
  return (Resolve-Path -LiteralPath (Join-Path $env:USERPROFILE '.codex\skills\codex-windows-fast-patch') -ErrorAction Stop).ProviderPath
}

function Read-Utf8 {
  param([string]$Path)
  return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )
  [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Repair-LocalSkillWorkflow {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = ConvertTo-Lf (Read-Utf8 $Path)
  $original = $content
  $block = @'
<!-- fooljack-verified-chain:start -->
## Fooljack Verified Chain

For the ordinary combined Fast Mode, Chinese/i18n, plugin UI, bundled marketplace, browser/Chrome, and Windows Computer Use repair, use the repository wrapper when it is present:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\codex-windows-fast-patch\scripts\run-latest-fast-patch.ps1"
```

From a cloned checkout, pass the checkout explicitly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-latest-fast-patch.ps1" -SkillDir (Get-Location).ProviderPath -ReportCheckout (Get-Location).ProviderPath
```

The wrapper force-refreshes the upstream allowlist before repair, reapplies the local compatibility overlay, and publishes to `Fooljack/Fast-CTX` only after the full validation gate passes. A publishable run requires FastCtx read-only verification, the Developer-signed package, Fast wire `service_tier=priority`, final `already-patched` markers for Fast/UI/i18n/browser/Computer Use/bundled marketplace targets, `browser`, `chrome`, and `computer-use` installed and enabled, every plugin shipped in the bundled marketplace available without changing unrelated optional install state, Computer Use client/helper verification, stable Chrome native messaging paths, `[windows] sandbox = "unelevated"`, the sandbox smoke test, and a live Desktop process. Update failures, `-DryRunOnly`, `-NoLaunch`, skipped Fast verification, or any unresolved validation failure must remain local and must not be pushed.

Keep the targeted upstream workflows below for phone remote control, dynamicTools/inputSchema, provider-history/cwd repair, and optional model instructions. The wrapper does not run those symptom-specific paths by default.

## FastCtx Windows Integration

For local file reads, search, glob, mechanical replacement, shell commands, and background jobs, use `mcp__fastctx__*` first. Keep using FastCtx while the matching tool succeeds; retry one transient failure once, then fall back only when FastCtx is unavailable, still failing, or a Windows-only API is required. Do not run `fastctx apply` or `fastctx unapply` in this profile. On a new machine, run `scripts\\configure-fastctx.ps1` once, then restart Codex Desktop. Read `references\\fastctx-windows-integration.md` for the fixed HOME/CODEX_HOME path policy and cleanup boundary.
<!-- fooljack-verified-chain:end -->
'@
  $block = ConvertTo-Lf $block

  $markerPattern = '(?ms)<!-- fooljack-verified-chain:start -->.*?<!-- fooljack-verified-chain:end -->'
  if ([regex]::IsMatch($content, $markerPattern)) {
    $content = [regex]::Replace(
      $content,
      $markerPattern,
      { param($match) $block },
      1
    )
    $content = [regex]::Replace(
      $content,
      '(?ms)# Codex Windows Fast Patch\s*(?=<!-- fooljack-verified-chain:start -->)',
      { param($match) "# Codex Windows Fast Patch`n`n" },
      1
    )
    $content = [regex]::Replace(
      $content,
      '(?ms)<!-- fooljack-verified-chain:end -->\s*(?=Use this skill)',
      { param($match) "<!-- fooljack-verified-chain:end -->`n`n" },
      1
    )
  } else {
    $heading = '# Codex Windows Fast Patch'
    if (-not $content.Contains($heading)) {
      throw "could not find Codex skill heading in $Path"
    }
    $content = $content.Replace($heading, "$heading`n`n$block")
  }

  if ($content -ne $original) {
    Write-Utf8NoBom -Path $Path -Content $content
    Write-Log "repaired Fooljack verified workflow overlay: $Path"
  }
}

function Repair-RestrictionDebugCases {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = ConvertTo-Lf (Read-Utf8 $Path)
  $original = $content
  $oldGuidance = @'
- Never execute the protected WindowsApps `node.exe` or `node_repl.exe` as a fallback. If no matching user-local runtime exists, launch Codex Desktop once to let it extract the runtime and retry; otherwise stop without changing MCP configuration.
'@
  $newGuidance = @'
- Never execute the protected WindowsApps `node.exe` or `node_repl.exe` as a fallback. Current Desktop builds may use package runtimes directly and never extract matching user-local copies. Run the normal `install-computer-use-local.ps1` repair so it copies the current package CLI/CUA by data stream into hash-named, ownership-marked user-local directories; `-StrictVerifyOnly` remains read-only and must fail when those copies are absent. Do not use `File.Copy` for the package CLI because Store EFS metadata can produce "The specified file could not be encrypted" at the destination.
'@
  $content = Update-KnownBlock -Content $content -OldBlock $oldGuidance -NewBlock $newGuidance -Name 'current package runtime recovery guidance' -Path $Path

  if ($content -ne $original) {
    Write-Utf8NoBom -Path $Path -Content $content
    Write-Log "repaired current package runtime recovery guidance: $Path"
  }
}

function Repair-TomllibProbe {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $lines = [System.Collections.Generic.List[string]]::new()
  $sourceLines = [System.IO.File]::ReadAllLines($Path)
  $changed = $false

  for ($i = 0; $i -lt $sourceLines.Count; $i++) {
    $line = $sourceLines[$i]
    if ($line -match "^(?<indent>\s*)& \$python\.Source -c 'import tomllib' \*> \$null\s*$") {
      $indent = $Matches['indent']
      $lines.Add($indent + '& $env:ComSpec /d /c "`"$($python.Source)`" -c `"import tomllib`" >NUL 2>NUL" | Out-Null')
      $lines.Add($indent + '$importExit = $LASTEXITCODE')
      if (($i + 1) -lt $sourceLines.Count -and $sourceLines[$i + 1] -match "^\s*if \(\$LASTEXITCODE -ne 0\) \{\s*$") {
        $lines.Add($indent + 'if ($importExit -ne 0) {')
        $i++
      }
      $changed = $true
      continue
    }
    $lines.Add($line)
  }

  if ($changed) {
    Write-Utf8NoBom -Path $Path -Content (($lines -join "`r`n") + "`r`n")
    Write-Log "repaired tomllib probe: $Path"
  }
}

function Repair-TomllibPythonUsage {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = ConvertTo-Lf (Read-Utf8 $Path)
  if ($content -notmatch 'import tomllib') {
    return
  }

  $original = $content
  $helper = @'
function Get-TomllibPython {
  $python = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $python) {
    return $null
  }

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $env:ComSpec /d /c "`"$($python.Source)`" -c `"import tomllib`" >NUL 2>NUL" | Out-Null
    $importExit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  if ($importExit -ne 0) {
    Write-Log "warning: python lacks tomllib; skipping Python TOML validation: $($python.Source)"
    return $null
  }

  return $python
}

'@
  $helper = ConvertTo-Lf $helper

  $content = [regex]::Replace(
    $content,
    '(?ms)^function Get-TomllibPython\s*\{.*?return \$python\s*\r?\n\}\r?\n',
    ''
  )
  $content = $content -replace '\$python = Get-Command python -ErrorAction SilentlyContinue \| Select-Object -First 1', '$python = Get-TomllibPython'

  $insertPattern = '(?m)^function (Export-McpServers|Test-TomlSyntax)\s*\{'
  if ([regex]::IsMatch($content, $insertPattern)) {
    $content = [regex]::Replace($content, $insertPattern, { param($match) $helper + $match.Value }, 1)
  }

  if ($content -ne $original) {
    Write-Utf8NoBom -Path $Path -Content $content
    Write-Log "repaired tomllib Python selection: $Path"
  }
}

function Repair-DirectCodexLaunch {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = Read-Utf8 $Path
  $original = $content
  $newBlock = @'
      $appId = "$($installed.PackageFamilyName)!App"
      Write-Log "launching Codex app: shell:AppsFolder\$appId"
      Start-Process explorer.exe "shell:AppsFolder\$appId"
'@

  $oldLaunchPattern = '(?ms)^[ \t]+\$exe = Join-Path \$installed\.InstallLocation ''app\\Codex\.exe''\r?\n[ \t]+Write-Log "launching Codex: \$exe"\r?\n[ \t]+Start-Process\s+-FilePath\s+\$exe[^\r\n]*(?:\r?\n)?'
  $content = [regex]::Replace($content, $oldLaunchPattern, $newBlock + "`r`n")
  if ($content -ne $original) {
    Write-Utf8NoBom -Path $Path -Content $content
    Write-Log "repaired WindowsApps direct launch: $Path"
  }
}

function Repair-CodeSigningCertParameter {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = Read-Utf8 $Path
  $updated = $content -replace 'Get-ChildItem\s+Cert:\\CurrentUser\\My\s+-CodeSigningCert', 'Get-ChildItem Cert:\CurrentUser\My'
  if ($updated -ne $content) {
    Write-Utf8NoBom -Path $Path -Content $updated
    Write-Log "removed unsupported certificate provider parameter: $Path"
  }
}

function ConvertTo-Lf {
  param([string]$Content)
  return (($Content -replace "`r`n", "`n") -replace "`r", "`n")
}

function Update-KnownBlock {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$OldBlock,
    [Parameter(Mandatory = $true)][string]$NewBlock,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $normalizedContent = ConvertTo-Lf $Content
  $normalizedOld = ConvertTo-Lf $OldBlock
  $normalizedNew = ConvertTo-Lf $NewBlock
  $oldCount = [regex]::Matches($normalizedContent, [regex]::Escape($normalizedOld)).Count
  $newCount = [regex]::Matches($normalizedContent, [regex]::Escape($normalizedNew)).Count

  if ($newCount -eq 1) {
    $withoutNew = $normalizedContent.Replace($normalizedNew, '')
    $independentOldCount = [regex]::Matches($withoutNew, [regex]::Escape($normalizedOld)).Count
    if ($independentOldCount -eq 0) {
      return $normalizedContent
    }
    throw "ambiguous $Name shape in $Path (new=1 independent-old=$independentOldCount)"
  }
  if ($newCount -eq 0 -and $oldCount -eq 1) {
    return $normalizedContent.Replace($normalizedOld, $normalizedNew)
  }
  throw "unknown or ambiguous $Name shape in $Path (old=$oldCount new=$newCount)"
}

function Repair-FastPatcherVerifiedWindowsLoop {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = ConvertTo-Lf (Read-Utf8 $Path)
  $original = $content

  if ($content -notmatch '(?m)^function Convert-ToLongPath\s*\{') {
    $helperBlock = @'
function Convert-ToLongPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path.StartsWith('\\?\')) {
    return $Path
  }
  if ($Path.StartsWith('\\')) {
    return '\\?\UNC\' + $Path.Substring(2)
  }
  return '\\?\' + $Path
}

function Quote-ProcessArgument {
  param([Parameter(Mandatory = $true)][string]$Value)
  return '"' + ($Value -replace '"', '\"') + '"'
}

'@
    $content = $content.Replace("function Test-IsAdministrator {", $helperBlock + "function Test-IsAdministrator {")
  }

  $oldCopyFile = @'
function Copy-FileDataOnly {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
  $inputStream = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
  try {
    $outputStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
      $inputStream.CopyTo($outputStream)
    } finally {
      $outputStream.Dispose()
    }
  } finally {
    $inputStream.Dispose()
  }
  try {
    $sourceItem = Get-Item -LiteralPath $Source -Force
    [System.IO.File]::SetLastWriteTimeUtc($Destination, $sourceItem.LastWriteTimeUtc)
  } catch {
    Write-Log "warning: could not preserve timestamp for $Destination`: $($_.Exception.Message)"
  }
}
'@
  $newCopyFile = @'
function Copy-FileDataOnly {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )
  [System.IO.Directory]::CreateDirectory((Convert-ToLongPath (Split-Path -Parent $Destination))) | Out-Null
  $longSource = Convert-ToLongPath $Source
  $longDestination = Convert-ToLongPath $Destination
  $inputStream = [System.IO.File]::Open($longSource, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
  try {
    $outputStream = [System.IO.File]::Open($longDestination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
      $inputStream.CopyTo($outputStream)
    } finally {
      $outputStream.Dispose()
    }
  } finally {
    $inputStream.Dispose()
  }
  try {
    $sourceItem = [System.IO.FileInfo]::new($longSource)
    [System.IO.File]::SetLastWriteTimeUtc($longDestination, $sourceItem.LastWriteTimeUtc)
  } catch {
    Write-Log "warning: could not preserve timestamp for $Destination`: $($_.Exception.Message)"
  }
}
'@
  $content = Update-KnownBlock -Content $content -OldBlock $oldCopyFile -NewBlock $newCopyFile -Name 'Fast patcher Copy-FileDataOnly' -Path $Path

  $oldCopyDirectory = @'
function Copy-DirectoryDataOnly {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )
  if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    Fail "source directory not found: $Source"
  }
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
    $target = Join-Path $Destination $item.Name
    if ($item.PSIsContainer -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)) {
      Copy-DirectoryDataOnly -Source $item.FullName -Destination $target
    } elseif ($item.PSIsContainer) {
      Write-Log "warning: copying reparse directory as an empty directory: $($item.FullName)"
      New-Item -ItemType Directory -Force -Path $target | Out-Null
    } else {
      Copy-FileDataOnly -Source $item.FullName -Destination $target
    }
  }
}
'@
  $newCopyDirectory = @'
function Copy-DirectoryDataOnly {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )
  $longSource = Convert-ToLongPath $Source
  $longDestination = Convert-ToLongPath $Destination
  if (-not [System.IO.Directory]::Exists($longSource)) {
    Fail "source directory not found: $Source"
  }
  [System.IO.Directory]::CreateDirectory($longDestination) | Out-Null
  $sourceInfo = [System.IO.DirectoryInfo]::new($longSource)
  foreach ($item in $sourceInfo.EnumerateFileSystemInfos()) {
    $target = [System.IO.Path]::Combine($Destination, $item.Name)
    $isDirectory = (($item.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
    $isReparsePoint = (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    if ($isDirectory -and -not $isReparsePoint) {
      Copy-DirectoryDataOnly -Source $item.FullName -Destination $target
    } elseif ($isDirectory) {
      Write-Log "warning: copying reparse directory as an empty directory: $($item.FullName)"
      [System.IO.Directory]::CreateDirectory((Convert-ToLongPath $target)) | Out-Null
    } else {
      Copy-FileDataOnly -Source $item.FullName -Destination $target
    }
  }
}
'@
  $content = Update-KnownBlock -Content $content -OldBlock $oldCopyDirectory -NewBlock $newCopyDirectory -Name 'Fast patcher Copy-DirectoryDataOnly' -Path $Path

  $oldServerStart = '  $server = Start-Process -FilePath $node -ArgumentList @($serverPath, [string]$port, $logPath) -PassThru -WindowStyle Hidden'
  $newServerStart = @'
  $serverArgs = @($serverPath, [string]$port, $logPath) | ForEach-Object { Quote-ProcessArgument $_ }
  $server = Start-Process -FilePath $node -ArgumentList $serverArgs -PassThru -WindowStyle Hidden
'@
  $newServerStart = $newServerStart.TrimEnd()
  $content = Update-KnownBlock -Content $content -OldBlock $oldServerStart -NewBlock $newServerStart -Name 'Fast patcher verifier launch' -Path $Path

  if ($content -ne $original) {
    Write-Utf8NoBom -Path $Path -Content $content
    Write-Log "repaired Fast patcher long-path copy and verifier quoting: $Path"
  }
}

function Repair-RepatchMsixFinalizerCrashGuard {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = Read-Utf8 $Path
  $original = $content
  if ($content.Contains('function Test-CompletedMsixFinalizerCrash')) {
    return
  }

  $oldInvokeChecked = @'
function Invoke-Checked {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$ErrorMessage
  )

  Write-Log "$FilePath $($Arguments -join ' ')"
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$ErrorMessage (exit code $LASTEXITCODE)"
  }
}
'@
  $newInvokeChecked = @'
function Invoke-Checked {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$ErrorMessage,
    [switch]$AllowCompletedMsixFinalizerCrash
  )

  Write-Log "$FilePath $($Arguments -join ' ')"
  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $capturedOutput = @(& $FilePath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  $capturedOutput | ForEach-Object { Write-Output $_ }
  if ($exitCode -ne 0) {
    if ($AllowCompletedMsixFinalizerCrash -and (Test-CompletedMsixFinalizerCrash -ExitCode $exitCode -Output $capturedOutput)) {
      Write-Log 'accepted known WinRT finalizer crash after verified Developer install and Fast wire capture'
      return
    }
    throw "$ErrorMessage (exit code $exitCode)"
  }
}
'@
  $content = Update-KnownBlock -Content $content -OldBlock $oldInvokeChecked -NewBlock $newInvokeChecked -Name 'MSIX finalizer Invoke-Checked guard' -Path $Path

  $oldPackageFunction = @'
function Get-InstalledCodexPackage {
  $package = Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
  return $package
}
'@
  $newPackageFunction = $oldPackageFunction + @'

function Test-CompletedMsixFinalizerCrash {
  param(
    [int]$ExitCode,
    [object[]]$Output
  )

  if ($ExitCode -ne -1073741819) {
    return $false
  }
  $text = ($Output | ForEach-Object { [string]$_ }) -join "`n"
  if ($text -notmatch '(?m)^\[codex-msix-patch-win\] done$') {
    return $false
  }
  if ($text -notmatch '(?i)request wire service_tier=priority') {
    return $false
  }
  $package = Get-InstalledCodexPackage
  return ($package -and [string]$package.SignatureKind -eq 'Developer')
}
'@
  $content = Update-KnownBlock -Content $content -OldBlock $oldPackageFunction -NewBlock $newPackageFunction -Name 'MSIX finalizer package-status guard' -Path $Path

  $oldPatchInvocation = @'
    Invoke-Checked 'powershell' (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PatchScript) + $patchArgs) 'Codex MSIX patch failed'
'@
  $patchInvocationLineEnding = if ($oldPatchInvocation.EndsWith("`r`n")) { "`r`n" } else { "`n" }
  $newPatchInvocation = $oldPatchInvocation.TrimEnd("`r", "`n") + ' -AllowCompletedMsixFinalizerCrash' + $patchInvocationLineEnding
  $content = Update-KnownBlock -Content $content -OldBlock $oldPatchInvocation -NewBlock $newPatchInvocation -Name 'MSIX finalizer patch invocation guard' -Path $Path

  Write-Utf8NoBom -Path $Path -Content $content
  Write-Log "repaired verified MSIX finalizer crash handling: $Path"
}

function Repair-ComputerUseVerifiedWindowsLoop {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = ConvertTo-Lf (Read-Utf8 $Path)
  $original = $content

  if ($content -notmatch '(?m)^function Convert-ToLongPath\s*\{') {
    $helperBlock = @'
function Convert-ToLongPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or $Path.StartsWith('\\?\')) {
    return $Path
  }
  if ($Path.StartsWith('\\')) {
    return '\\?\UNC\' + $Path.Substring(2)
  }
  return '\\?\' + $Path
}

'@
    $content = $content.Replace("function Remove-ReparsePointOrDirectory {", $helperBlock + "function Remove-ReparsePointOrDirectory {")
  }

  $oldCopyDirectory = @'
function Copy-DirectoryDataOnly {
  param(
    [string]$Source,
    [string]$Destination
  )

  if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    throw "copy source directory not found: $Source"
  }

  $maxAttempts = 3
  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
      if (Test-Path -LiteralPath $Destination) {
        Remove-ReparsePointOrDirectory $Destination
      }

      $sourceRoot = (Resolve-Path -LiteralPath $Source).ProviderPath
      Resolve-OrCreateDirectory $Destination | Out-Null

      foreach ($dir in Get-ChildItem -LiteralPath $sourceRoot -Recurse -Directory -Force) {
        $relative = $dir.FullName.Substring($sourceRoot.Length).TrimStart('\')
        Resolve-OrCreateDirectory (Join-Path $Destination $relative) | Out-Null
      }

      foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force) {
        $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart('\')
        $target = Join-Path $Destination $relative
        $targetParent = Split-Path -Parent $target
        Resolve-OrCreateDirectory $targetParent | Out-Null
        [System.IO.Directory]::CreateDirectory($targetParent) | Out-Null
        [System.IO.File]::WriteAllBytes($target, [System.IO.File]::ReadAllBytes($file.FullName))
        [System.IO.File]::SetLastWriteTime($target, $file.LastWriteTime)
      }
      return
    } catch {
      if ($attempt -ge $maxAttempts -or -not (Test-TransientCopyRace $_.Exception)) {
        throw
      }
      Write-Log "warning: source tree changed during copy; retrying $attempt/${maxAttempts}: $Source"
      Start-Sleep -Seconds 1
    }
  }
}
'@
  $newCopyDirectory = @'
function Copy-DirectoryDataOnly {
  param(
    [string]$Source,
    [string]$Destination
  )

  $longSource = Convert-ToLongPath $Source
  $longDestination = Convert-ToLongPath $Destination
  if (-not [System.IO.Directory]::Exists($longSource)) {
    throw "copy source directory not found: $Source"
  }

  $maxAttempts = 3
  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
      if (Test-Path -LiteralPath $Destination) {
        Remove-ReparsePointOrDirectory $Destination
      }

      [System.IO.Directory]::CreateDirectory($longDestination) | Out-Null
      $sourceInfo = [System.IO.DirectoryInfo]::new($longSource)
      foreach ($item in $sourceInfo.EnumerateFileSystemInfos()) {
        $target = [System.IO.Path]::Combine($Destination, $item.Name)
        $isDirectory = (($item.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
        $isReparsePoint = (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        if ($isDirectory -and -not $isReparsePoint) {
          Copy-DirectoryDataOnly -Source $item.FullName -Destination $target
        } elseif ($isDirectory) {
          [System.IO.Directory]::CreateDirectory((Convert-ToLongPath $target)) | Out-Null
        } else {
          $longSourceFile = Convert-ToLongPath $item.FullName
          $longTarget = Convert-ToLongPath $target
          [System.IO.Directory]::CreateDirectory((Convert-ToLongPath (Split-Path -Parent $target))) | Out-Null
          $inputStream = [System.IO.File]::Open($longSourceFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
          try {
            $outputStream = [System.IO.File]::Open($longTarget, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
              $inputStream.CopyTo($outputStream)
            } finally {
              $outputStream.Dispose()
            }
          } finally {
            $inputStream.Dispose()
          }
          [System.IO.File]::SetLastWriteTime($longTarget, $item.LastWriteTime)
        }
      }
      return
    } catch {
      if ($attempt -ge $maxAttempts -or -not (Test-TransientCopyRace $_.Exception)) {
        throw
      }
      Write-Log "warning: source tree changed during copy; retrying $attempt/${maxAttempts}: $Source"
      Start-Sleep -Seconds 1
    }
  }
}
'@
  $content = Update-KnownBlock -Content $content -OldBlock $oldCopyDirectory -NewBlock $newCopyDirectory -Name 'Computer Use Copy-DirectoryDataOnly' -Path $Path

  $oldMarketplaceCheck = @'
  $localEntries = @{}
  foreach ($entry in @($localManifest.plugins)) {
    $localEntries[[string]$entry.name] = $entry
  }
'@
  $newMarketplaceCheck = @'
  $localEntries = @{}
  foreach ($entry in @($localManifest.plugins)) {
    $localEntries[[string]$entry.name] = $entry
  }

  foreach ($requiredName in @('computer-use', 'browser', 'chrome')) {
    if (-not $localEntries.ContainsKey($requiredName)) {
      throw "local openai-bundled marketplace is missing required plugin entry: $requiredName"
    }
  }
'@
  $content = Update-KnownBlock -Content $content -OldBlock $oldMarketplaceCheck -NewBlock $newMarketplaceCheck -Name 'Computer Use bundled marketplace validation' -Path $Path

  if ($content -ne $original) {
    Write-Utf8NoBom -Path $Path -Content $content
    Write-Log "repaired Computer Use local long-path copy and bundled marketplace verification: $Path"
  }
}

function Repair-CurrentPackageRuntimeCopies {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = ConvertTo-Lf (Read-Utf8 $Path)
  $original = $content

  if ($content -notmatch '(?m)^function Install-CurrentPackageRuntimeCopies\s*\{') {
    $helper = @'
function Install-CurrentPackageRuntimeCopies {
  param(
    [Parameter(Mandatory = $true)][string]$PackageResourcesRoot,
    [Parameter(Mandatory = $true)][string]$LocalCodexRoot
  )

  $packageCodex = Join-Path $PackageResourcesRoot 'codex.exe'
  $packageCuaRoot = Join-Path $PackageResourcesRoot 'cua_node'
  $packageNode = Join-Path $packageCuaRoot 'bin\node.exe'
  $packageNodeRepl = Join-Path $packageCuaRoot 'bin\node_repl.exe'
  $codexHash = (Get-FileHash -LiteralPath $packageCodex -Algorithm SHA256).Hash
  $runtimeId = 'package-' + $codexHash.Substring(0, 16).ToLowerInvariant()
  $markerName = '.fooljack-managed-runtime'
  $markerContent = "source_codex_sha256=$codexHash`n"

  $localBinRoot = Join-Path $LocalCodexRoot 'bin'
  $localCuaRoot = Join-Path $LocalCodexRoot 'runtimes\cua_node'
  $codexRoot = Join-Path $localBinRoot $runtimeId
  $codexDestination = Join-Path $codexRoot 'codex.exe'
  $codexMarker = Join-Path $codexRoot $markerName
  $cuaRoot = Join-Path $localCuaRoot $runtimeId
  $cuaNode = Join-Path $cuaRoot 'bin\node.exe'
  $cuaNodeRepl = Join-Path $cuaRoot 'bin\node_repl.exe'
  $cuaMarker = Join-Path $cuaRoot $markerName

  if (-not (Test-FilesMatchByContent $codexDestination $packageCodex) -or
      -not (Test-Path -LiteralPath $codexMarker -PathType Leaf)) {
    if (Test-Path -LiteralPath $codexRoot) {
      Remove-ReparsePointOrDirectory $codexRoot
    }
    try {
      [System.IO.Directory]::CreateDirectory((Convert-ToLongPath $codexRoot)) | Out-Null
      $inputStream = [System.IO.File]::Open(
        (Convert-ToLongPath $packageCodex),
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
      )
      try {
        $outputStream = [System.IO.File]::Open(
          (Convert-ToLongPath $codexDestination),
          [System.IO.FileMode]::Create,
          [System.IO.FileAccess]::Write,
          [System.IO.FileShare]::None
        )
        try {
          $inputStream.CopyTo($outputStream)
        } finally {
          $outputStream.Dispose()
        }
      } finally {
        $inputStream.Dispose()
      }
      [System.IO.File]::SetLastWriteTimeUtc(
        (Convert-ToLongPath $codexDestination),
        (Get-Item -LiteralPath $packageCodex).LastWriteTimeUtc
      )
      Write-Utf8NoBom $codexMarker $markerContent
    } catch {
      if (Test-Path -LiteralPath $codexRoot) {
        Remove-ReparsePointOrDirectory $codexRoot
      }
      throw
    }
  }

  if (-not (Test-FilesMatchByContent $cuaNode $packageNode) -or
      -not (Test-FilesMatchByContent $cuaNodeRepl $packageNodeRepl) -or
      -not (Test-Path -LiteralPath $cuaMarker -PathType Leaf)) {
    try {
      Copy-DirectoryDataOnly -Source $packageCuaRoot -Destination $cuaRoot
      Write-Utf8NoBom $cuaMarker $markerContent
    } catch {
      if (Test-Path -LiteralPath $cuaRoot) {
        Remove-ReparsePointOrDirectory $cuaRoot
      }
      throw
    }
  }

  foreach ($managedRoot in @($localBinRoot, $localCuaRoot)) {
    if (-not (Test-Path -LiteralPath $managedRoot -PathType Container)) { continue }
    foreach ($directory in @(Get-ChildItem -LiteralPath $managedRoot -Directory -ErrorAction SilentlyContinue)) {
      $marker = Join-Path $directory.FullName $markerName
      if ($directory.Name -ne $runtimeId -and (Test-Path -LiteralPath $marker -PathType Leaf)) {
        Assert-UnderPath $directory.FullName $managedRoot
        Remove-ReparsePointOrDirectory $directory.FullName
        Write-Log "removed stale Fooljack-managed runtime: $($directory.FullName)"
      }
    }
  }

  Write-Log "current package runtime copied to user-local paths: $runtimeId"
}

'@
    $target = 'function Get-CurrentCodexAppServerRuntimeInventory {'
    if (-not $content.Contains($target)) {
      throw "could not find current runtime inventory insertion target in $Path"
    }
    $content = $content.Replace($target, (ConvertTo-Lf $helper) + $target)
  }

  $oldCodexCopy = @'
      [System.IO.File]::Copy(
        (Convert-ToLongPath $packageCodex),
        (Convert-ToLongPath $codexDestination),
        $true
      )
'@
  $newCodexCopy = @'
      $inputStream = [System.IO.File]::Open(
        (Convert-ToLongPath $packageCodex),
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
      )
      try {
        $outputStream = [System.IO.File]::Open(
          (Convert-ToLongPath $codexDestination),
          [System.IO.FileMode]::Create,
          [System.IO.FileAccess]::Write,
          [System.IO.FileShare]::None
        )
        try {
          $inputStream.CopyTo($outputStream)
        } finally {
          $outputStream.Dispose()
        }
      } finally {
        $inputStream.Dispose()
      }
'@
  $content = Update-KnownBlock -Content $content -OldBlock $oldCodexCopy -NewBlock $newCodexCopy -Name 'current package Codex data-only copy' -Path $Path

  $oldParameters = @'
function Get-CurrentCodexAppServerRuntimeInventory {
  param(
    [string]$PackageResourcesRoot,
    [string]$LocalCodexRoot = (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex')
  )
'@
  $newParameters = @'
function Get-CurrentCodexAppServerRuntimeInventory {
  param(
    [string]$PackageResourcesRoot,
    [string]$LocalCodexRoot = (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'),
    [switch]$AllowRepair
  )
'@
  $content = Update-KnownBlock -Content $content -OldBlock $oldParameters -NewBlock $newParameters -Name 'current runtime inventory parameters' -Path $Path

  $oldInventoryStart = @'
  foreach ($requiredPath in @($packageCodex, $packageNode, $packageNodeRepl)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
      throw "current Codex package runtime is incomplete: $requiredPath"
    }
  }

  $codexCandidates = @()
'@
  $newInventoryStart = @'
  foreach ($requiredPath in @($packageCodex, $packageNode, $packageNodeRepl)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
      throw "current Codex package runtime is incomplete: $requiredPath"
    }
  }

  if ($AllowRepair) {
    Install-CurrentPackageRuntimeCopies -PackageResourcesRoot $PackageResourcesRoot -LocalCodexRoot $LocalCodexRoot
  }

  $codexCandidates = @()
'@
  $content = Update-KnownBlock -Content $content -OldBlock $oldInventoryStart -NewBlock $newInventoryStart -Name 'current runtime repair gate' -Path $Path

  $oldInstallCall = @'
  $runtimeInventory = Get-CurrentCodexAppServerRuntimeInventory
  Invoke-ChromeOfficialManifestInstall $chromeCacheRoot $runtimeInventory
'@
  $newInstallCall = @'
  $runtimeInventory = Get-CurrentCodexAppServerRuntimeInventory -AllowRepair
  Invoke-ChromeOfficialManifestInstall $chromeCacheRoot $runtimeInventory
'@
  $content = Update-KnownBlock -Content $content -OldBlock $oldInstallCall -NewBlock $newInstallCall -Name 'Computer Use runtime repair call' -Path $Path

  $oldStrictRuntimeCheck = @'
  $runtimeInventory = Get-CurrentCodexAppServerRuntimeInventory
  Test-ChromeNativeMessagingManifest $installedChromeCacheRoot
'@
  $newStrictRuntimeCheck = @'
  $runtimeInventory = Get-CurrentCodexAppServerRuntimeInventory
  foreach ($requiredInstalledPlugin in @('computer-use', 'browser', 'chrome')) {
    if (-not (Test-BundledMarketplacePluginInstalledWithCodexCli $requiredInstalledPlugin)) {
      throw "required bundled plugin is not installed and enabled: $requiredInstalledPlugin@openai-bundled"
    }
  }
  Test-ChromeNativeMessagingManifest $installedChromeCacheRoot
'@
  $content = Update-KnownBlock -Content $content -OldBlock $oldStrictRuntimeCheck -NewBlock $newStrictRuntimeCheck -Name 'strict bundled plugin installation validation' -Path $Path

  $content = $content.Replace(
    'no current user-local Codex CLI matches the installed package under $localBinRoot; launch Codex Desktop once so it can extract the current runtime',
    'no current user-local Codex CLI matches the installed package under $localBinRoot; run the normal Computer Use repair before strict verification'
  )
  $content = $content.Replace(
    'no current user-local CUA Node runtime matches the installed package under $localCuaRoot; launch Codex Desktop once so it can extract the current runtime',
    'no current user-local CUA Node runtime matches the installed package under $localCuaRoot; run the normal Computer Use repair before strict verification'
  )

  if ($content -ne $original) {
    Write-Utf8NoBom -Path $Path -Content $content
    Write-Log "repaired current package user-local runtime extraction: $Path"
  }
}

function Repair-ChromeNativeHostV2PowerShell7Json {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = ConvertTo-Lf (Read-Utf8 $Path)
  $original = $content

  $oldHelperTarget = @'
function Test-ChromeNativeHostV2JsonObject {
'@
  $newHelperTarget = @'
function ConvertFrom-ChromeNativeHostV2Json {
  param([Parameter(Mandatory = $true)][string]$Json)

  $convertFromJson = Get-Command ConvertFrom-Json -ErrorAction Stop
  if ($convertFromJson.Parameters.ContainsKey('DateKind')) {
    return ConvertFrom-Json -InputObject $Json -DateKind String
  }
  return ConvertFrom-Json -InputObject $Json
}

function Test-ChromeNativeHostV2JsonObject {
'@
  $content = Update-KnownBlock -Content $content -OldBlock $oldHelperTarget -NewBlock $newHelperTarget -Name 'Chrome native-host v2 JSON parser helper' -Path $Path

  $oldStateRead = @'
      $document = $raw | ConvertFrom-Json
'@
  $newStateRead = @'
      $document = ConvertFrom-ChromeNativeHostV2Json $raw
'@
  $content = Update-KnownBlock -Content $content -OldBlock $oldStateRead -NewBlock $newStateRead -Name 'Chrome native-host v2 state read' -Path $Path

  $oldVerifyRead = @'
      $document = Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath | ConvertFrom-Json
'@
  $newVerifyRead = @'
      $document = ConvertFrom-ChromeNativeHostV2Json (Get-Content -Raw -Encoding UTF8 -LiteralPath $statePath)
'@
  $content = Update-KnownBlock -Content $content -OldBlock $oldVerifyRead -NewBlock $newVerifyRead -Name 'Chrome native-host v2 verification read' -Path $Path

  if ($content -ne $original) {
    Write-Utf8NoBom -Path $Path -Content $content
    Write-Log "repaired PowerShell 7 Chrome native-host v2 JSON parsing: $Path"
  }
}

function Repair-DesktopExecutableCompatibility {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = ConvertTo-Lf (Read-Utf8 $Path)
  $original = $content

  if ($content -notmatch 'function Get-AppExecutablePath') {
    $helper = @'
function Get-AppExecutableRelativePath {
  param([string]$PackageRoot)
  if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    return $null
  }
  $manifestPath = Join-Path $PackageRoot 'AppxManifest.xml'
  if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try {
      [xml]$manifest = Get-Content -Raw -LiteralPath $manifestPath
      foreach ($application in @($manifest.Package.Applications.Application)) {
        $exe = [string]$application.Executable
        if (-not [string]::IsNullOrWhiteSpace($exe)) {
          return ($exe -replace '/', '\')
        }
      }
    } catch {
      Write-Log "warning: could not read AppxManifest executable: $($_.Exception.Message)"
    }
  }
  return $null
}

function Get-AppExecutablePath {
  param([string]$PackageRoot)
  $relative = Get-AppExecutableRelativePath $PackageRoot
  if (-not [string]::IsNullOrWhiteSpace($relative)) {
    $candidate = Join-Path $PackageRoot $relative
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }
  foreach ($fallback in @('app\ChatGPT.exe', 'app\Codex.exe')) {
    $candidate = Join-Path $PackageRoot $fallback
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }
  return $null
}

function Test-CodexDesktopProcessPath {
  param(
    [string]$Path,
    [string]$InstallLocation
  )
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $false
  }
  $leaf = Split-Path -Leaf $Path
  if ($leaf -notin @('ChatGPT.exe', 'Codex.exe')) {
    return $false
  }
  $targetRoot = if ($InstallLocation) { $InstallLocation.TrimEnd('\') } else { $null }
  return (
    ($targetRoot -and $Path.StartsWith($targetRoot, [StringComparison]::OrdinalIgnoreCase)) -or
    $Path -like '*\WindowsApps\OpenAI.Codex_*\app\*.exe'
  )
}

'@
    $target = 'function Test-CodexAppPath {'
    if (-not $content.Contains($target)) {
      throw "could not find Test-CodexAppPath insertion target in $Path"
    }
    $content = $content.Replace($target, $helper + $target)
  }

  $oldAppCheck = '    (Test-Path -LiteralPath (Join-Path $app ''Codex.exe'') -PathType Leaf) -and'
  $newAppCheck = '    (-not [string]::IsNullOrWhiteSpace((Get-AppExecutablePath (Split-Path -Parent $app)))) -and'
  $content = Update-KnownBlock -Content $content -OldBlock $oldAppCheck -NewBlock $newAppCheck -Name 'Desktop executable app-path validation' -Path $Path

  $oldProcessLookup = "Get-Process -Name 'Codex' -ErrorAction SilentlyContinue"
  $newProcessLookup = "Get-Process -Name 'Codex', 'ChatGPT' -ErrorAction SilentlyContinue"
  if ($content.Contains($oldProcessLookup)) {
    $content = $content.Replace($oldProcessLookup, $newProcessLookup)
  }
  if (-not [regex]::IsMatch($content, "Get-Process -Name 'Codex'\s*,\s*'ChatGPT' -ErrorAction SilentlyContinue")) {
    throw "unknown Desktop process lookup shape in $Path"
  }

  $oldWorkExecutable = '  $exe = Join-Path $workApp ''Codex.exe'''
  $newWorkExecutable = @'
  $exe = Get-AppExecutablePath $workPackageRoot
  if ([string]::IsNullOrWhiteSpace($exe)) {
    Fail "could not find app executable in work package: $workPackageRoot"
  }
'@
  $content = Update-KnownBlock -Content $content -OldBlock $oldWorkExecutable -NewBlock $newWorkExecutable -Name 'Desktop work-package executable lookup' -Path $Path

  $stopOld = @'
function Stop-CodexDesktopProcesses {
  param([string]$InstallLocation)
  $targetRoot = if ($InstallLocation) { $InstallLocation.TrimEnd('\') } else { $null }
  $processes = Get-Process -Name 'Codex', 'ChatGPT' -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and (
      ($targetRoot -and $_.Path.StartsWith($targetRoot, [StringComparison]::OrdinalIgnoreCase)) -or
      $_.Path -like '*\WindowsApps\OpenAI.Codex_*\app\Codex.exe' -or
      $_.Path -like '*\WindowsApps\OpenAI.Codex_*\app\ChatGPT.exe'
    )
  }
  foreach ($p in $processes) {
    Write-Log "stopping Codex package process name=$($p.ProcessName) pid=$($p.Id)"
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  }
}
'@
  $stopNew = @'
function Stop-CodexDesktopProcesses {
  param([string]$InstallLocation)
  $processes = Get-Process -Name 'Codex','ChatGPT' -ErrorAction SilentlyContinue |
    Where-Object { Test-CodexDesktopProcessPath -Path $_.Path -InstallLocation $InstallLocation }
  foreach ($p in $processes) {
    Write-Log "stopping Codex package process name=$($p.ProcessName) pid=$($p.Id)"
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  }
}
'@
  $content = Update-KnownBlock -Content $content -OldBlock $stopOld -NewBlock $stopNew -Name 'Desktop process stop filter' -Path $Path

  if ($content -ne $original) {
    Write-Utf8NoBom -Path $Path -Content $content
    Write-Log "repaired Codex/ChatGPT desktop executable handling: $Path"
  }
}

function Repair-Gpt56ModelUiPatch {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = Read-Utf8 $Path
  $original = $content

  if ($content -notmatch 'PatchGpt56ModelUi\.cjs') {
    $content = $content -replace "(\s+\`$bundledMarketplaceCopyPatcherPath = Join-Path \`$WorkDir 'PatchBundledMarketplaceCopy\.cjs'\r?\n)", "`$1  `$gpt56ModelUiPatcherPath = Join-Path `$WorkDir 'PatchGpt56ModelUi.cjs'`r`n"
  }

  if ($content -notmatch 'gpt56-model-ui-target-not-found') {
    $patcherBlock = @'

  Set-Content -LiteralPath $gpt56ModelUiPatcherPath -Encoding UTF8 -Value @'
const fs = require('node:fs');
const file = process.argv[2];
let text = fs.readFileSync(file, 'utf8');

if (!text.includes('hasModelSupportingUltraReasoningEffort') || !text.includes('models:c,defaultModel:l')) {
  process.stderr.write('gpt56-model-ui-target-not-found\n');
  process.exit(2);
}

const helperName = '__codexGpt56ModelUiPatch';
const helper = 'function __codexGpt56ModelUiPatch(models,enabled,includeUltra){const effort=(reasoningEffort,description)=>({reasoningEffort,description});const definitions=[{model:`gpt-5.6-sol`,displayName:`GPT-5.6 Sol`,defaultReasoningEffort:`medium`,isDefault:!1,hidden:!1,supportedReasoningEfforts:[effort(`low`,`Low reasoning`),effort(`medium`,`Standard reasoning`),effort(`high`,`Extended reasoning`),effort(`xhigh`,`Deep reasoning`),effort(`ultra`,`Ultra reasoning`)]},{model:`gpt-5.6-terra`,displayName:`GPT-5.6 Terra`,defaultReasoningEffort:`medium`,isDefault:!1,hidden:!1,supportedReasoningEfforts:[effort(`low`,`Low reasoning`),effort(`medium`,`Standard reasoning`),effort(`high`,`Extended reasoning`),effort(`xhigh`,`Deep reasoning`)]},{model:`gpt-5.6-luna`,displayName:`GPT-5.6 Luna`,defaultReasoningEffort:`medium`,isDefault:!1,hidden:!1,supportedReasoningEfforts:[effort(`low`,`Low reasoning`),effort(`medium`,`Standard reasoning`),effort(`high`,`Extended reasoning`),effort(`xhigh`,`Deep reasoning`)]}];for(const model of definitions){if(models.some((item)=>item.model===model.model))continue;let efforts=model.supportedReasoningEfforts.filter(({reasoningEffort})=>reasoningEffort!==`ultra`||includeUltra).filter(({reasoningEffort})=>enabled.has(reasoningEffort));if(efforts.length===0)efforts=[effort(`medium`,`Standard reasoning`)];models.push({...model,supportedReasoningEfforts:efforts});}}';

let changed = false;
if (!text.includes(`function ${helperName}(`)) {
  text = text.replace('function r({authMethod:', `${helper}function r({authMethod:`);
  changed = true;
}

if (!text.includes(`${helperName}(c,i,a),l??=c.find`)) {
  const next = text.replace('}),l??=c.find', `}),${helperName}(c,i,a),l??=c.find`);
  if (next === text) {
    process.stderr.write('gpt56-model-ui-insert-target-not-found\n');
    process.exit(2);
  }
  text = next;
  changed = true;
}

const ultraNext = text.replace('hasModelSupportingUltraReasoningEffort:f}', 'hasModelSupportingUltraReasoningEffort:f||a}');
if (ultraNext !== text) {
  text = ultraNext;
  changed = true;
}

if (!text.includes('gpt-5.6-luna')) {
  process.stderr.write('gpt56-model-ui-patch-incomplete\n');
  process.exit(2);
}

if (!changed) {
  process.stdout.write('already-patched');
  process.exit(0);
}

fs.writeFileSync(file, text);
process.stdout.write('patched');
__CODEX_SINGLE_QUOTED_HERE_STRING_END__
'@.Replace('__CODEX_SINGLE_QUOTED_HERE_STRING_END__', "'@")
    $content = $content -replace "(\r?\n\s+Set-Content -LiteralPath \`$pluginsPatcherPath -Encoding UTF8 -Value @')", ($patcherBlock + '$1')
  }

  if ($content -notmatch 'Gpt56ModelUi = \$gpt56ModelUiPatcherPath') {
    $content = $content -replace "(\s+BundledMarketplaceCopy = \`$bundledMarketplaceCopyPatcherPath\r?\n)", "`$1    Gpt56ModelUi = `$gpt56ModelUiPatcherPath`r`n"
  }

  if ($content -notmatch '\$gpt56ModelUiTarget = \$null') {
    $content = $content -replace "(\s+\`$browserUseFeatureHookTarget = \`$null\r?\n)", @'
  $gpt56ModelUiTarget = $null
  foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'model-list-filter-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ($text.Contains('hasModelSupportingUltraReasoningEffort') -and
        $text.Contains('models:c,defaultModel:l')) {
      $gpt56ModelUiTarget = $candidate
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($gpt56ModelUiTarget)) {
    foreach ($candidate in (Invoke-RgList $RgPath 'hasModelSupportingUltraReasoningEffort' $assetsDir)) {
      $text = Get-Content -Raw -LiteralPath $candidate
      if ($text.Contains('supportedReasoningEfforts') -and
          $text.Contains('defaultModel')) {
        $gpt56ModelUiTarget = $candidate
        break
      }
    }
  }
$1
'@
  }

  if ($content -notmatch 'could not find GPT-5\.6 model UI patch target') {
    $content = $content -replace "(\s+if \(\[string\]::IsNullOrWhiteSpace\(\`$browserUseFeatureHookTarget\)\) \{)", "  if ([string]::IsNullOrWhiteSpace(`$gpt56ModelUiTarget)) {`r`n    Fail 'could not find GPT-5.6 model UI patch target in extracted assets'`r`n  }`r`n`$1"
  }
  if ($content -notmatch 'Write-Log "GPT-5\.6 model UI patch target') {
    $content = $content -replace "(\s+Write-Log `"locale i18n patch target: \`$localeI18nTarget`"\r?\n)", "`$1  Write-Log `"GPT-5.6 model UI patch target: `$gpt56ModelUiTarget`"`r`n"
  }
  if ($content -notmatch 'Gpt56ModelUi = \$gpt56ModelUiTarget') {
    $content = $content -replace "(\s+LocaleI18n = \`$localeI18nTarget\r?\n)", "`$1    Gpt56ModelUi = `$gpt56ModelUiTarget`r`n"
  }
  if ($content -notmatch 'GPT-5\.6 model UI patch result') {
    $content = $content -replace "(\s+\`$localeI18n = Invoke-NodePatcher \`$nodePath \`$patchers\.LocaleI18n @\(\`$targets\.LocaleI18n\)\r?\n\s+Write-Log `"locale i18n patch result: \`$localeI18n`"\r?\n)", "`$1  `$gpt56ModelUi = Invoke-NodePatcher `$nodePath `$patchers.Gpt56ModelUi @(`$targets.Gpt56ModelUi)`r`n  Write-Log `"GPT-5.6 model UI patch result: `$gpt56ModelUi`"`r`n"
  }
  if ($content -notmatch '\$gpt56ModelUi -eq ''already-patched''') {
    $content = $content -replace "(\s+\`$localeI18n -eq 'already-patched' -and\r?\n)", "`$1      `$gpt56ModelUi -eq 'already-patched' -and`r`n"
  }

  if ($content -ne $original) {
    Write-Utf8NoBom -Path $Path -Content $content
    Write-Log "repaired GPT-5.6 model UI patch chain: $Path"
  }
}

function Repair-BrowserFeatureSenderShape {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = ConvertTo-Lf (Read-Utf8 $Path)
  $original = $content

  $featureNormalizerFinder = '           ($text -match ''function [A-Za-z_$][\w$]*\(e,\{buildFlavor:[^}]+,env:[^}]+,platform:[^}]+\}=\{\}\)\{let [A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*===`win32`&&e\.computerUse===!0\?'') -or'
  $duplicateFinderPattern = '(?m)^' + [regex]::Escape($featureNormalizerFinder) + '(?:\n' + [regex]::Escape($featureNormalizerFinder) + ')+'
  $content = [regex]::Replace($content, $duplicateFinderPattern, { param($match) $featureNormalizerFinder })

  $content = $content.Replace(
    'const patchedSenderPattern = /inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,(defaultLinkOpenTargetPreference:[^,}]+,)?(linksDefaultInAppBrowser:[^,}]+,)?(localBackend:[^,}]+,)?browserPane:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0,computerUse:/;',
    'const patchedSenderPattern = /inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,(?:(?!browserPane:)[A-Za-z_$][\w$]*:[^,}]+,)*browserPane:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0,(?:(?!computerUse:)[A-Za-z_$][\w$]*:[^,}]+,)*computerUse:/;'
  )

  $oldSenderReplace = @'
  let after = before.replace(
    /inAppBrowserUse:[^,}]+,inAppBrowserUseAllowed:[^,}]+,(defaultLinkOpenTargetPreference:[^,}]+,)?(linksDefaultInAppBrowser:[^,}]+,)?(localBackend:[^,}]+,)?browserPane:[^,}]+,externalBrowserUse:[^,}]+,externalBrowserUseAllowed:[^,}]+,computerUse:/,
    'inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,$1$2$3browserPane:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0,computerUse:'
  );
'@
  $newSenderReplace = @'
  let after = before.replace(
    /inAppBrowserUse:[^,}]+,inAppBrowserUseAllowed:[^,}]+,((?:(?!browserPane:)[A-Za-z_$][\w$]*:[^,}]+,)*)browserPane:[^,}]+,externalBrowserUse:[^,}]+,externalBrowserUseAllowed:[^,}]+,((?:(?!computerUse:)[A-Za-z_$][\w$]*:[^,}]+,)*)computerUse:/,
    'inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,$1browserPane:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0,$2computerUse:'
  );
'@
  $content = $content.Replace($oldSenderReplace, $newSenderReplace)

  $oldFinder = @'
    if ($text.Contains('electron-desktop-features-changed') -and
        (($text -match 'inAppBrowserUse:[^,}]+,inAppBrowserUseAllowed:[^,}]+,(defaultLinkOpenTargetPreference:[^,}]+,)?(linksDefaultInAppBrowser:[^,}]+,)?(localBackend:[^,}]+,)?browserPane:[^,}]+,externalBrowserUse:[^,}]+,externalBrowserUseAllowed:[^,}]+,computerUse:[^,}]+') -or
         ($text -match 'inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,(defaultLinkOpenTargetPreference:[^,}]+,)?(linksDefaultInAppBrowser:[^,}]+,)?(localBackend:[^,}]+,)?browserPane:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0'))) {
'@
  $newFinder = @'
    if ($text.Contains('electron-desktop-features-changed') -and
        $text.Contains('browser_use_availability_resolved') -and
        (($text -match 'inAppBrowserUse:[^,}]+,inAppBrowserUseAllowed:[^,}]+,.*browserPane:[^,}]+,externalBrowserUse:[^,}]+,externalBrowserUseAllowed:[^,}]+,.*computerUse:[^,}]+') -or
         ($text -match 'inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,.*browserPane:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0'))) {
'@
  $content = $content.Replace($oldFinder, $newFinder)

  if ($content -notmatch 'featureNormalizerPattern' -and -not $content.Contains($featureNormalizerFinder)) {
    $content = $content.Replace(
      '  const envGatePattern = /[A-Za-z_$][\w$]*=i===`win32`&&[A-Za-z_$][\w$]*\.CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE===`1`\?\{\.\.\.[A-Za-z_$][\w$]*,computerUse:!0,computerUseNodeRepl:!0\}:[A-Za-z_$][\w$]*/;',
      @'
  const envGatePattern = /[A-Za-z_$][\w$]*=i===`win32`&&[A-Za-z_$][\w$]*\.CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE===`1`\?\{\.\.\.[A-Za-z_$][\w$]*,computerUse:!0,computerUseNodeRepl:!0\}:[A-Za-z_$][\w$]*/;
  const featureNormalizerPattern = /function [A-Za-z_$][\w$]*\(e,\{buildFlavor:[^}]+,env:[^}]+,platform:[^}]+\}=\{\}\)\{let [A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*===`win32`&&e\.computerUse===!0\?/;
'@
    )
    $content = $content.Replace(
      '        (!envGatePattern.test(before) &&',
      '        (!envGatePattern.test(before) &&' + "`r`n" + '        !featureNormalizerPattern.test(before) &&'
    )
    $content = $content.Replace(
      @'
  after = after.replace(
    /inAppBrowserUse:[A-Za-z_$][\w$]*\.inAppBrowserUse,inAppBrowserUseAllowed:[A-Za-z_$][\w$]*\.inAppBrowserUseAllowed,browserPane:[A-Za-z_$][\w$]*\.browserPane,externalBrowserUse:[A-Za-z_$][\w$]*\.externalBrowserUse,externalBrowserUseAllowed:[A-Za-z_$][\w$]*\.externalBrowserUseAllowed,computerUse:/,
    'inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,browserPane:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0,computerUse:'
  );
'@,
      @'
  after = after.replace(
    /inAppBrowserUse:[A-Za-z_$][\w$]*\.inAppBrowserUse,inAppBrowserUseAllowed:[A-Za-z_$][\w$]*\.inAppBrowserUseAllowed,browserPane:[A-Za-z_$][\w$]*\.browserPane,externalBrowserUse:[A-Za-z_$][\w$]*\.externalBrowserUse,externalBrowserUseAllowed:[A-Za-z_$][\w$]*\.externalBrowserUseAllowed,computerUse:/,
    'inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,browserPane:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0,computerUse:'
  );
  after = after.replace(
    /function ([A-Za-z_$][\w$]*)\(e,\{buildFlavor:([^,]+),env:([^,]+),platform:([^}]+)\}=\{\}\)\{let ([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)===`win32`&&e\.computerUse===!0\?/,
    'function $1(e,{buildFlavor:$2,env:$3,platform:$4}={}){e={...e,browserPane:!0,inAppBrowserUse:!0,inAppBrowserUseAllowed:!0,externalBrowserUse:!0,externalBrowserUseAllowed:!0};let $5=$6===`win32`&&e.computerUse===!0?'
  );
'@
    )
    $content = $content.Replace(
      '           ($text -match ''inAppBrowserUse:[A-Za-z_$][\w$]*\.inAppBrowserUse,inAppBrowserUseAllowed:[A-Za-z_$][\w$]*\.inAppBrowserUseAllowed,browserPane:[A-Za-z_$][\w$]*\.browserPane,externalBrowserUse:[A-Za-z_$][\w$]*\.externalBrowserUse,externalBrowserUseAllowed:[A-Za-z_$][\w$]*\.externalBrowserUseAllowed'') -or',
      '           ($text -match ''function [A-Za-z_$][\w$]*\(e,\{buildFlavor:[^}]+,env:[^}]+,platform:[^}]+\}=\{\}\)\{let [A-Za-z_$][\w$]*=[A-Za-z_$][\w$]*===`win32`&&e\.computerUse===!0\?'') -or' + "`r`n" + '           ($text -match ''inAppBrowserUse:[A-Za-z_$][\w$]*\.inAppBrowserUse,inAppBrowserUseAllowed:[A-Za-z_$][\w$]*\.inAppBrowserUseAllowed,browserPane:[A-Za-z_$][\w$]*\.browserPane,externalBrowserUse:[A-Za-z_$][\w$]*\.externalBrowserUse,externalBrowserUseAllowed:[A-Za-z_$][\w$]*\.externalBrowserUseAllowed'') -or'
    )
  }

  if ($content -ne $original) {
    Write-Utf8NoBom -Path $Path -Content $content
    Write-Log "repaired browser-use desktop feature sender matching: $Path"
  }
}

function Repair-PluginAuthMigratedHandling {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = Read-Utf8 $Path
  $original = $content

  $content = $content.Replace(
    @'
if (oldFileCount === 0 && !hasFile(pageAuthFile)) {
  process.stderr.write('plugin-gate-targets-not-found\n');
  process.exit(2);
}
'@,
    @'
if (oldFileCount === 0 && !hasFile(pageAuthFile)) {
  process.stdout.write('already-patched');
  process.exit(0);
}
'@
  )

  if ($content -notmatch 'pluginAuthMigratedOpen') {
    $content = $content.Replace(
      @'
  }

  if ([string]::IsNullOrWhiteSpace($fastModeTarget)) {
'@,
      @'
  }
  $pluginEnabledDefaultTarget = $null
  foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'use-is-plugins-enabled-*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
    $text = Get-Content -Raw -LiteralPath $candidate
    if ($text.Contains('enabled??!0')) {
      $pluginEnabledDefaultTarget = $candidate
      break
    }
  }
  $pluginInstallFlowTarget = Get-ChildItem -LiteralPath $assetsDir -Filter 'plugin-install-modal-*.js' -File -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName -First 1
  if ([string]::IsNullOrWhiteSpace($pluginInstallFlowTarget)) {
    $pluginInstallFlowTarget = Get-ChildItem -LiteralPath $assetsDir -Filter 'plugin-detail-page-*.js' -File -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty FullName -First 1
  }
  $pluginAuthMigratedOpen = -not [string]::IsNullOrWhiteSpace($pluginEnabledDefaultTarget) -and
                            -not [string]::IsNullOrWhiteSpace($pluginInstallFlowTarget)

  if ([string]::IsNullOrWhiteSpace($fastModeTarget)) {
'@
    )

    $content = $content.Replace(
      @'
  if (-not $oldPluginTargetsFound -and [string]::IsNullOrWhiteSpace($pluginPageAuthTarget)) {
    Fail 'could not find plugin auth patch target in extracted assets'
  }
'@,
      @'
  if (-not $oldPluginTargetsFound -and [string]::IsNullOrWhiteSpace($pluginPageAuthTarget)) {
    if ($pluginAuthMigratedOpen) {
      Write-Log "plugin auth patch target not found; current plugin flow appears migrated/default-open: $pluginEnabledDefaultTarget"
    } else {
      Fail 'could not find plugin auth patch target in extracted assets'
    }
  }
'@
    )
  }

  if ($content -ne $original) {
    Write-Utf8NoBom -Path $Path -Content $content
    Write-Log "repaired migrated plugin auth handling: $Path"
  }
}

function Repair-ComputerUseInstallFlowMigratedHandling {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = Read-Utf8 $Path
  $original = $content

  $computerUsePatcherHasFile = '(?ms)const \[availabilityFile, installFlowFile, setupFile\] = process\.argv\.slice\(2\);\s*let changed = false;\s*function read\(file\) \{\s*return fs\.readFileSync\(file, ''utf8''\);\s*\}\s*function hasFile\(file\) \{'
  if (-not [regex]::IsMatch($content, $computerUsePatcherHasFile)) {
    $beforeHelperRepair = $content
    $content = [regex]::Replace(
      $content,
      '(?ms)(const \[availabilityFile, installFlowFile, setupFile\] = process\.argv\.slice\(2\);\s*let changed = false;\s*function read\(file\) \{\s*return fs\.readFileSync\(file, ''utf8''\);\s*\}\s*)',
      {
        param($match)
        return $match.Groups[1].Value + "function hasFile(file) {`n  return typeof file === 'string' && file.length > 0 && file !== '__none__' && fs.existsSync(file);`n}`n`n"
      },
      1
    )
    if ($content -eq $beforeHelperRepair) {
      Fail "could not add safe hasFile helper to generated Computer Use patcher: $Path"
    }
  }

  $content = [regex]::Replace(
    $content,
    '(?m)^patchComputerUseInstallFlow\(installFlowFile\);$',
    'if (hasFile(installFlowFile)) patchComputerUseInstallFlow(installFlowFile);'
  )

  $content = $content.Replace(
    @'
  if ([string]::IsNullOrWhiteSpace($computerUseAvailabilityTarget)) {
    Fail 'could not find Computer Use availability gate in extracted assets'
  }
  if ([string]::IsNullOrWhiteSpace($computerUseInstallFlowTarget)) {
    Fail 'could not find Computer Use install-flow gate in extracted assets'
  }
'@,
    @'
  $computerUseInstallFlowMigrated = $false
  if ([string]::IsNullOrWhiteSpace($computerUseInstallFlowTarget)) {
    $computerUseSettingsTarget = Get-ChildItem -LiteralPath $assetsDir -Filter 'computer-use-settings-*.js' -File -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty FullName -First 1
    $computerUseNativeAppsTarget = $null
    foreach ($candidate in (Get-ChildItem -LiteralPath $assetsDir -Filter 'use-native-apps*.js' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)) {
      $text = Get-Content -Raw -LiteralPath $candidate
      if ($text.Contains('plugin.name===`computer-use`') -or $text.Contains('plugin.name===`computer_use`')) {
        $computerUseNativeAppsTarget = $candidate
        break
      }
    }
    $computerUseInstallModalTarget = Get-ChildItem -LiteralPath $assetsDir -Filter 'plugin-install-modal-*.js' -File -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty FullName -First 1
    $computerUseInstallFlowMigrated = -not [string]::IsNullOrWhiteSpace($computerUseSettingsTarget) -and
                                      -not [string]::IsNullOrWhiteSpace($computerUseNativeAppsTarget) -and
                                      -not [string]::IsNullOrWhiteSpace($computerUseInstallModalTarget)
  }
  if ([string]::IsNullOrWhiteSpace($computerUseAvailabilityTarget)) {
    Fail 'could not find Computer Use availability gate in extracted assets'
  }
  if ([string]::IsNullOrWhiteSpace($computerUseInstallFlowTarget)) {
    if ($computerUseInstallFlowMigrated) {
      Write-Log 'Computer Use install-flow gate not found; current plugin install flow appears migrated'
    } else {
      Fail 'could not find Computer Use install-flow gate in extracted assets'
    }
  }
'@
  )

  $content = $content.Replace(
    @'
  $computerUseArgs = @(
    [string]$targets.ComputerUseAvailability
    [string]$targets.ComputerUseInstallFlow
    [string]$targets.ComputerUseSetup
  )
'@,
    @'
  $computerUseArgs = @(
    [string]$targets.ComputerUseAvailability
    $(if ([string]::IsNullOrWhiteSpace($targets.ComputerUseInstallFlow)) { '__none__' } else { [string]$targets.ComputerUseInstallFlow })
    [string]$targets.ComputerUseSetup
  )
'@
  )

  if ($content -ne $original) {
    Write-Utf8NoBom -Path $Path -Content $content
    Write-Log "repaired migrated Computer Use install-flow handling: $Path"
  }
}

function Repair-FastModeServiceTierShape {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = Read-Utf8 $Path
  $original = $content

  if ($content -notmatch 'currentProfileAsyncOriginalRe') {
    $content = $content.Replace(
      @'
const currentAsyncOriginalRe = /async function (\w+)\((\w+),(\w+)\)\{let (\w+)=await ([A-Za-z_$][\w$]*)\(\2,\3\);return \4===`chatgpt`\?\(await \2\.query\.fetch\(([A-Za-z_$][\w$]*),\{authMethod:\4,hostId:\3\}\)\)\.requirements\?\.featureRequirements\?\.fast_mode!==!1:!1\}/;
const currentSplitConditionRe = /if\((\w+)\?\.authMethod!==`chatgpt`\|\|(\w+)\)\{/;
'@,
      @'
const currentAsyncOriginalRe = /async function (\w+)\((\w+),(\w+)\)\{let (\w+)=await ([A-Za-z_$][\w$]*)\(\2,\3\);return \4===`chatgpt`\?\(await \2\.query\.fetch\(([A-Za-z_$][\w$]*),\{authMethod:\4,hostId:\3\}\)\)\.requirements\?\.featureRequirements\?\.fast_mode!==!1:!1\}/;
const currentProfileAsyncOriginalRe = /;if\([A-Za-z_$][\w$]*!==`chatgpt`\)return!1;let (?=[A-Za-z_$][\w$]*=await [A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*,\{priority:`critical`\}\);return [A-Za-z_$][\w$]*\.query\.setData\([A-Za-z_$][\w$]*,\{authMethod:[A-Za-z_$][\w$]*,hostId:[A-Za-z_$][\w$]*\},[A-Za-z_$][\w$]*\),[A-Za-z_$][\w$]*\.requirements\?\.featureRequirements\?\.fast_mode!==!1\})/;
const currentProfileAsyncPatchedRe = /async function [A-Za-z_$][\w$]*\([A-Za-z_$][\w$]*,[A-Za-z_$][\w$]*\)\{let [A-Za-z_$][\w$]*=await [^;]+;let [A-Za-z_$][\w$]*=await [^;]+;return [A-Za-z_$][\w$]*\.query\.setData\([A-Za-z_$][\w$]*,\{authMethod:[A-Za-z_$][\w$]*,hostId:[A-Za-z_$][\w$]*\},[A-Za-z_$][\w$]*\),[A-Za-z_$][\w$]*\.requirements\?\.featureRequirements\?\.fast_mode!==!1\}/;
const currentSplitConditionRe = /if\((\w+)\?\.authMethod!==`chatgpt`\|\|(\w+)\)\{/;
'@
    )

    $content = $content.Replace(
      'if (legacyPatchedRe.test(text) || currentAsyncPatchedRe.test(text) || (currentDirectPatchedRe.test(text) && !legacyOriginalRe.test(text) && !currentDirectOriginalRe.test(text) && !currentSplitConditionRe.test(text))) {',
      'if (legacyPatchedRe.test(text) || currentAsyncPatchedRe.test(text) || (currentProfileAsyncPatchedRe.test(text) && !currentProfileAsyncOriginalRe.test(text)) || (currentDirectPatchedRe.test(text) && !legacyOriginalRe.test(text) && !currentDirectOriginalRe.test(text) && !currentSplitConditionRe.test(text))) {'
    )

    $content = $content.Replace(
      @'
    next = next.replace(currentAsyncOriginalRe, `async function ${fn}(${hostManagerVar},${hostIdVar}){let ${authMethodVar}=await ${authMethodFn}(${hostManagerVar},${hostIdVar});return(await ${hostManagerVar}.query.fetch(${queryVar},{authMethod:${authMethodVar},hostId:${hostIdVar}})).requirements?.featureRequirements?.fast_mode!==!1}`);
    patched = true;
  }

  if (/canUseFastMode:!1/.test(next)) {
'@,
      @'
    next = next.replace(currentAsyncOriginalRe, `async function ${fn}(${hostManagerVar},${hostIdVar}){let ${authMethodVar}=await ${authMethodFn}(${hostManagerVar},${hostIdVar});return(await ${hostManagerVar}.query.fetch(${queryVar},{authMethod:${authMethodVar},hostId:${hostIdVar}})).requirements?.featureRequirements?.fast_mode!==!1}`);
    patched = true;
  }

  if (!patched && currentProfileAsyncOriginalRe.test(next)) {
    next = next.replace(currentProfileAsyncOriginalRe, ';let ');
    patched = true;
  }

  if (/canUseFastMode:!1/.test(next)) {
'@
    )
  }

  if ($content -ne $original) {
    Write-Utf8NoBom -Path $Path -Content $content
    Write-Log "repaired Fast Mode service-tier gate matching: $Path"
  }
}

function Repair-BundledMarketplaceCopyMigratedHandling {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return
  }

  $content = Read-Utf8 $Path
  $original = $content

  $hasCurrentOverlayMarker = $content -match 'copyAlreadyPatchedByCurrentBuild'
  $hasMigratedNativeFallback = $content -match 'hasNativeWindowsCopyFallback'

  if (-not $hasCurrentOverlayMarker -and -not $hasMigratedNativeFallback) {
    $oldBlock = @'
let after = text;
let changed = false;

if (!after.includes(copyPatchedMarker)) {
'@
    $newBlock = @'
let after = text;
let changed = false;
const copyAlreadyPatchedByCurrentBuild =
  after.includes('windows-file-copy') &&
  after.includes('copyDirectoryAllowDecryptedDestinationOnEncryptionFailure') &&
  after.includes('verbatimSymlinks:!0');

if (!after.includes(copyPatchedMarker) && !copyAlreadyPatchedByCurrentBuild) {
'@
    if (-not $content.Contains($oldBlock)) {
      throw "could not find bundled marketplace migrated-copy insertion target in $Path"
    }
    $content = $content.Replace($oldBlock, $newBlock)
  }

  if ($content -ne $original) {
    Write-Utf8NoBom -Path $Path -Content $content
    Write-Log "repaired bundled marketplace copy migrated handling: $Path"
  }
}

function Assert-HardeningResult {
  param([string]$Root)

  $skillPath = Join-Path $Root 'SKILL.md'
  $skill = Read-Utf8 $skillPath
  foreach ($requiredSkillMarker in @(
    '<!-- fooljack-verified-chain:start -->',
    '## Platform Compatibility',
    '## Phone Remote Control',
    '## FastCtx Windows Integration',
    'references\\fastctx-windows-integration.md',
    '## Provider History Sync',
    '## Success Criteria'
  )) {
    if (-not $skill.Contains($requiredSkillMarker)) {
      throw "hardened SKILL.md is missing required upstream/local marker: $requiredSkillMarker"
    }
  }

  $patcherPath = Join-Path $Root 'scripts\patch_codex_fast_mode_windows_msix.ps1'
  $patcher = Read-Utf8 $patcherPath
  foreach ($functionName in @(
    'Write-PatcherFiles',
    'Find-PatchTargets',
    'Invoke-PatchAppAsar',
    'Install-PatchedPackage',
    'Invoke-FastModeVerification'
  )) {
    $count = [regex]::Matches($patcher, "(?m)^function $([regex]::Escape($functionName))\s*\{").Count
    if ($count -ne 1) {
      throw "hardened patcher contains $count copies of function $functionName"
    }
  }
  foreach ($requiredPatcherMarker in @(
    'gpt-5.6-sol',
    'GPT-5.6 model UI patch result',
    'codex_windows_sites_bundled_plugin_available',
    'copyDirectoryAllowDecryptedDestinationOnEncryptionFailure',
    'function Get-AppExecutablePath',
    'Get-AppExecutablePath $workPackageRoot',
    'Convert-ToLongPath $Source',
    'Convert-ToLongPath $Destination'
  )) {
    if (-not $patcher.Contains($requiredPatcherMarker)) {
      throw "hardened patcher is missing required marker: $requiredPatcherMarker"
    }
  }
  foreach ($forbiddenPatcherMarker in @(
    "Join-Path `$app 'Codex.exe'",
    "`$exe = Join-Path `$workApp 'Codex.exe'"
  )) {
    if ($patcher.Contains($forbiddenPatcherMarker)) {
      throw "hardened patcher still contains retired executable shape: $forbiddenPatcherMarker"
    }
  }
  if (-not ($patcher.Contains('copyAlreadyPatchedByCurrentBuild') -or
      $patcher.Contains('hasNativeWindowsCopyFallback'))) {
    throw 'hardened patcher is missing both current and migrated bundled marketplace copy guards'
  }
  if (-not [regex]::IsMatch($patcher, '(?ms)const \[availabilityFile, installFlowFile, setupFile\] = process\.argv\.slice\(2\);\s*let changed = false;\s*function read\(file\) \{\s*return fs\.readFileSync\(file, ''utf8''\);\s*\}\s*function hasFile\(file\) \{\s*return typeof file === ''string'' && file\.length > 0 && file !== ''__none__'' && fs\.existsSync\(file\);')) {
    throw 'hardened patcher is missing the safe generated Computer Use hasFile helper'
  }

  $repatch = Read-Utf8 (Join-Path $Root 'scripts\repatch-codex-windows.ps1')
  foreach ($requiredRepatchMarker in @(
    'function Test-CompletedMsixFinalizerCrash',
    'request wire service_tier=priority',
    'accepted known WinRT finalizer crash after verified Developer install and Fast wire capture',
    '-AllowCompletedMsixFinalizerCrash'
  )) {
    if (-not $repatch.Contains($requiredRepatchMarker)) {
      throw "hardened repatch wrapper is missing finalizer crash guard marker: $requiredRepatchMarker"
    }
  }

  $computerUsePath = Join-Path $Root 'scripts\install-computer-use-local.ps1'
  $computerUse = Read-Utf8 $computerUsePath
  foreach ($requiredComputerUseMarker in @(
    'function Install-CurrentPackageRuntimeCopies',
    'function ConvertFrom-ChromeNativeHostV2Json',
    'ConvertFrom-Json -InputObject $Json -DateKind String',
    'Get-CurrentCodexAppServerRuntimeInventory -AllowRepair',
    '.fooljack-managed-runtime',
    'current package runtime copied to user-local paths',
    'required bundled plugin is not installed and enabled'
  )) {
    if (-not $computerUse.Contains($requiredComputerUseMarker)) {
      throw "hardened Computer Use installer is missing required marker: $requiredComputerUseMarker"
    }
  }

  $restrictionCases = Read-Utf8 (Join-Path $Root 'references\restriction-debug-cases.md')
  if (-not $restrictionCases.Contains('copies the current package CLI/CUA by data stream into hash-named, ownership-marked user-local directories')) {
    throw 'restriction debug cases are missing current package runtime recovery guidance'
  }

  foreach ($script in Get-ChildItem -LiteralPath (Join-Path $Root 'scripts') -Filter '*.ps1' -File) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
      $messages = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
      throw "PowerShell parse validation failed for $($script.Name): $messages"
    }
  }
}

$SkillRoot = Resolve-SkillRoot
$scriptsRoot = Join-Path $SkillRoot 'scripts'

Repair-LocalSkillWorkflow -Path (Join-Path $SkillRoot 'SKILL.md')
Repair-RestrictionDebugCases -Path (Join-Path $SkillRoot 'references\restriction-debug-cases.md')

foreach ($file in @(
  'install-computer-use-local.ps1',
  'install-model-instructions-file.ps1',
  'manage-codex-backups.ps1',
  'repatch-codex-windows.ps1'
)) {
  Repair-TomllibProbe -Path (Join-Path $scriptsRoot $file)
  Repair-TomllibPythonUsage -Path (Join-Path $scriptsRoot $file)
}

foreach ($file in @(
  'patch-dynamic-tools-windows-msix.ps1',
  'patch-remote-control-windows-msix.ps1',
  'patch_codex_fast_mode_windows_msix.ps1'
)) {
  $path = Join-Path $scriptsRoot $file
  Repair-DirectCodexLaunch -Path $path
  Repair-CodeSigningCertParameter -Path $path
}

Repair-FastPatcherVerifiedWindowsLoop -Path (Join-Path $scriptsRoot 'patch_codex_fast_mode_windows_msix.ps1')
Repair-RepatchMsixFinalizerCrashGuard -Path (Join-Path $scriptsRoot 'repatch-codex-windows.ps1')
Repair-ComputerUseVerifiedWindowsLoop -Path (Join-Path $scriptsRoot 'install-computer-use-local.ps1')
Repair-CurrentPackageRuntimeCopies -Path (Join-Path $scriptsRoot 'install-computer-use-local.ps1')
Repair-ChromeNativeHostV2PowerShell7Json -Path (Join-Path $scriptsRoot 'install-computer-use-local.ps1')
Repair-DesktopExecutableCompatibility -Path (Join-Path $scriptsRoot 'patch_codex_fast_mode_windows_msix.ps1')
Repair-Gpt56ModelUiPatch -Path (Join-Path $scriptsRoot 'patch_codex_fast_mode_windows_msix.ps1')
Repair-BrowserFeatureSenderShape -Path (Join-Path $scriptsRoot 'patch_codex_fast_mode_windows_msix.ps1')
Repair-PluginAuthMigratedHandling -Path (Join-Path $scriptsRoot 'patch_codex_fast_mode_windows_msix.ps1')
Repair-ComputerUseInstallFlowMigratedHandling -Path (Join-Path $scriptsRoot 'patch_codex_fast_mode_windows_msix.ps1')
Repair-FastModeServiceTierShape -Path (Join-Path $scriptsRoot 'patch_codex_fast_mode_windows_msix.ps1')
Repair-BundledMarketplaceCopyMigratedHandling -Path (Join-Path $scriptsRoot 'patch_codex_fast_mode_windows_msix.ps1')

Assert-HardeningResult -Root $SkillRoot

Write-Log 'local hardening overlay complete'
