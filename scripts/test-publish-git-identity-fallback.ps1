[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptRoot
$publisher = Join-Path $scriptRoot 'publish-verified-chain.ps1'
$git = Get-Command git.exe -ErrorAction Stop | Select-Object -First 1
$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('publish-git-identity-' + [guid]::NewGuid().ToString('N'))
$checkout = Join-Path $fixtureRoot 'checkout'
$record = Join-Path $fixtureRoot 'record.md'
$isolatedGlobalConfig = Join-Path $fixtureRoot 'isolated-global.gitconfig'

try {
  New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
  [System.IO.File]::WriteAllText($record, "# Verified run`r`n`r`n## Problems And Resolutions`r`n`r`n- None`r`n", [System.Text.UTF8Encoding]::new($false))

  $previousGlobalConfig = $env:GIT_CONFIG_GLOBAL
  $previousNoSystemConfig = $env:GIT_CONFIG_NOSYSTEM
  try {
    $env:GIT_CONFIG_GLOBAL = $isolatedGlobalConfig
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $output = @(
      & powershell -NoProfile -ExecutionPolicy Bypass -File $publisher `
        -SkillDir $skillRoot `
        -ReportCheckout $checkout `
        -ReportRemoteUrl 'https://github.com/Fooljack/Fast-CTX.git' `
        -ReportBranch main `
        -RunRecordPath $record `
        -DryRun 2>&1
    )
    if ($LASTEXITCODE -ne 0) {
      throw "publish identity dry-run fixture failed: $($output -join [Environment]::NewLine)"
    }
  } finally {
    $env:GIT_CONFIG_GLOBAL = $previousGlobalConfig
    $env:GIT_CONFIG_NOSYSTEM = $previousNoSystemConfig
  }

  $name = (& $git.Source -C $checkout config --local --get user.name).Trim()
  if ($LASTEXITCODE -ne 0 -or $name -cne 'Fooljack') {
    throw "fallback Git author name was not configured locally: $name"
  }
  $email = (& $git.Source -C $checkout config --local --get user.email).Trim()
  if ($LASTEXITCODE -ne 0 -or $email -cne 'Fooljack@users.noreply.github.com') {
    throw "fallback Git author email was not configured locally: $email"
  }

  Write-Output 'Publish Git identity fallback regression passed'
} finally {
  if (Test-Path -LiteralPath $fixtureRoot) {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
