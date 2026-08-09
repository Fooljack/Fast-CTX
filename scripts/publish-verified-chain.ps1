[CmdletBinding()]
param(
  [string]$SkillDir,
  [string]$ReportCheckout,
  [string]$ReportRemoteUrl = 'https://github.com/Fooljack/Fast-CTX.git',
  [string]$ReportBranch = 'main',
  [string]$RunRecordPath,
  [string]$CommitMessage,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[codex-chain-archive]'

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

function Resolve-ReportCheckout {
  if (-not [string]::IsNullOrWhiteSpace($ReportCheckout)) {
    New-Item -ItemType Directory -Force -Path $ReportCheckout | Out-Null
    return (Resolve-Path -LiteralPath $ReportCheckout -ErrorAction Stop).ProviderPath
  }
  if (-not [string]::IsNullOrWhiteSpace($env:CODEX_FAST_PATCH_REPORT_CHECKOUT)) {
    New-Item -ItemType Directory -Force -Path $env:CODEX_FAST_PATCH_REPORT_CHECKOUT | Out-Null
    return (Resolve-Path -LiteralPath $env:CODEX_FAST_PATCH_REPORT_CHECKOUT -ErrorAction Stop).ProviderPath
  }
  $desktopCheckout = Join-Path $env:USERPROFILE 'Desktop\codex-windows-fast-patch-skill-main'
  New-Item -ItemType Directory -Force -Path $desktopCheckout | Out-Null
  return (Resolve-Path -LiteralPath $desktopCheckout -ErrorAction Stop).ProviderPath
}

function Get-GitCommand {
  $git = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $git) {
    throw 'git.exe not found'
  }
  return $git.Source
}

function Test-GitHubProxyFailure {
  param([string]$Output)
  return ($Output -match '127\.0\.0\.1' -or
    $Output -match 'Could not connect to server' -or
    $Output -match 'Failed to connect to github\.com' -or
    $Output -match '(?i)socks|proxy')
}

function Invoke-Git {
  param(
    [string]$RepoRoot,
    [string[]]$Arguments,
    [switch]$RetryWithoutDeadProxy,
    [switch]$AllowFailure
  )

  $git = Get-GitCommand
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = (& $git -C $RepoRoot @Arguments 2>&1 | Out-String).TrimEnd()
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  if ($exitCode -ne 0 -and $RetryWithoutDeadProxy -and (Test-GitHubProxyFailure $output)) {
    Write-Log 'git command hit a dead GitHub proxy; retrying this command without GitHub proxy'
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      $output = (& $git -C $RepoRoot -c 'http.https://github.com.proxy=' -c 'https.https://github.com.proxy=' @Arguments 2>&1 | Out-String).TrimEnd()
      $exitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $oldErrorActionPreference
    }
  }

  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw "git $($Arguments -join ' ') failed with exit code $exitCode`n$output"
  }

  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = $output
  }
}

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
  [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function ConvertTo-SafeReportText {
  param([string]$Text)
  $safe = $Text
  if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $safe = $safe -replace [regex]::Escape($env:USERPROFILE), '$env:USERPROFILE'
  }
  $safe = $safe -replace '(?i)(api[_-]?key|token|secret|password|credential)(\s*[:=]\s*)([^\s,;]+)', '$1$2***'
  $safe = $safe -replace 'github[_]pat[_][A-Za-z0-9_]+', ('github' + '_pat_***')
  $safe = $safe -replace 'gh[pousr]_[A-Za-z0-9_]{20,}', 'gh_***'
  $safe = $safe -replace 'sk[-][A-Za-z0-9_-]{20,}', ('sk' + '-***')
  $safe = $safe -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]{20,}', '$1***'
  $safe = (($safe -split "\r?\n") | ForEach-Object { $_ -replace '\s+$', '' }) -join "`r`n"
  return $safe
}

function Copy-SkillIntoReportCheckout {
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot
  )

  if ($SourceRoot -ieq $DestinationRoot) {
    Write-Log 'active skill root is the report checkout; no file copy needed'
    return
  }

  foreach ($file in @('README.md', 'SKILL.md', '.gitignore')) {
    $sourceFile = Join-Path $SourceRoot $file
    if (Test-Path -LiteralPath $sourceFile -PathType Leaf) {
      Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $DestinationRoot $file) -Force
    }
  }

  foreach ($dir in @('agents', 'assets', 'references', 'scripts')) {
    $sourceDir = Join-Path $SourceRoot $dir
    if (Test-Path -LiteralPath $sourceDir -PathType Container) {
      $destDir = Join-Path $DestinationRoot $dir
      New-Item -ItemType Directory -Force -Path $destDir | Out-Null
      & robocopy.exe $sourceDir $destDir /E /NFL /NDL /NJH /NJS /NP | Out-Null
      if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed while copying $dir to report checkout (exit code $LASTEXITCODE)"
      }
    }
  }
}

function Save-RunRecordIntoReportCheckout {
  param(
    [string]$RecordPath,
    [string]$DestinationRoot
  )

  if ([string]::IsNullOrWhiteSpace($RecordPath) -or -not (Test-Path -LiteralPath $RecordPath -PathType Leaf)) {
    return
  }

  $safeText = ConvertTo-SafeReportText ([System.IO.File]::ReadAllText($RecordPath, [System.Text.UTF8Encoding]::new($false)))
  $name = [System.IO.Path]::GetFileName($RecordPath)
  Write-Utf8NoBom -Path (Join-Path $DestinationRoot "reports\runs\$name") -Content $safeText
  Write-Utf8NoBom -Path (Join-Path $DestinationRoot 'reports\latest.md') -Content $safeText
  Write-Log "saved sanitized run record into report checkout: $name"
}

function Test-StaleRunReport {
  param([string]$Text)

  if ($Text -match 'codex sandbox windows "C:\\Windows\\System32\\cmd\.exe" /c echo OK') {
    return $true
  }
  if ($Text -match '(?m)^``text$|^``$') {
    return $true
  }

  $problemSection = [regex]::Match($Text, '(?ms)^## Problems And Resolutions\s*(?<body>.*?)(?:^## |\z)')
  if ($problemSection.Success) {
    $body = $problemSection.Groups['body'].Value
    if ($body -notmatch '(?m)^\s*-\s*None\s*$') {
      return $true
    }
  }

  return $false
}

function Remove-StaleRunReports {
  param(
    [string]$DestinationRoot,
    [string]$CurrentRecordName
  )

  $runsRoot = Join-Path $DestinationRoot 'reports\runs'
  if (-not (Test-Path -LiteralPath $runsRoot -PathType Container)) {
    return
  }

  foreach ($file in Get-ChildItem -LiteralPath $runsRoot -Filter '*.md' -File) {
    if ($file.Name -eq $CurrentRecordName) {
      continue
    }
    $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.UTF8Encoding]::new($false))
    if (Test-StaleRunReport -Text $text) {
      Remove-Item -LiteralPath $file.FullName -Force
      Write-Log "removed stale or failed run report: $($file.Name)"
    }
  }
}

$SkillRoot = Resolve-SkillRoot
$CheckoutRoot = Resolve-ReportCheckout
Write-Log "skill root: $SkillRoot"
Write-Log "report checkout: $CheckoutRoot"

Copy-SkillIntoReportCheckout -SourceRoot $SkillRoot -DestinationRoot $CheckoutRoot
Save-RunRecordIntoReportCheckout -RecordPath $RunRecordPath -DestinationRoot $CheckoutRoot
if (-not [string]::IsNullOrWhiteSpace($RunRecordPath)) {
  Remove-StaleRunReports -DestinationRoot $CheckoutRoot -CurrentRecordName ([System.IO.Path]::GetFileName($RunRecordPath))
}

if (-not (Test-Path -LiteralPath (Join-Path $CheckoutRoot '.git') -PathType Container)) {
  Invoke-Git -RepoRoot $CheckoutRoot -Arguments @('init') | Out-Null
}

Invoke-Git -RepoRoot $CheckoutRoot -Arguments @('branch', '-M', $ReportBranch) -AllowFailure | Out-Null
$origin = Invoke-Git -RepoRoot $CheckoutRoot -Arguments @('remote', 'get-url', 'origin') -AllowFailure
if ($origin.ExitCode -ne 0) {
  Invoke-Git -RepoRoot $CheckoutRoot -Arguments @('remote', 'add', 'origin', $ReportRemoteUrl) | Out-Null
} elseif ($origin.Output.Trim() -ne $ReportRemoteUrl) {
  Invoke-Git -RepoRoot $CheckoutRoot -Arguments @('remote', 'set-url', 'origin', $ReportRemoteUrl) | Out-Null
}

Invoke-Git -RepoRoot $CheckoutRoot -Arguments @('add', '-A') | Out-Null
$status = (Invoke-Git -RepoRoot $CheckoutRoot -Arguments @('status', '--porcelain')).Output
if ([string]::IsNullOrWhiteSpace($status)) {
  Write-Log 'no report checkout changes to archive'
  exit 0
}

if ($DryRun) {
  Write-Log "dry run; pending changes:`n$status"
  exit 0
}

if ([string]::IsNullOrWhiteSpace($CommitMessage)) {
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $CommitMessage = "Archive verified Codex fast patch run $stamp"
}

Invoke-Git -RepoRoot $CheckoutRoot -Arguments @('commit', '-m', $CommitMessage) | Out-Null
Invoke-Git -RepoRoot $CheckoutRoot -Arguments @('push', '-u', 'origin', $ReportBranch) -RetryWithoutDeadProxy | Out-Null
Write-Log "archived verified chain to $ReportRemoteUrl@$ReportBranch"
