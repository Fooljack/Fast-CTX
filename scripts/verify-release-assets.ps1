param(
    [string]$ReleaseDirectory = "dist/release",
    [string]$NpmDirectory = "dist/npm"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$releasePath = Join-Path $root $ReleaseDirectory
$npmPath = Join-Path $root $NpmDirectory
$version = (Select-String -LiteralPath (Join-Path $root "Cargo.toml") -Pattern '^version = "([^"]+)"$').Matches[0].Groups[1].Value
$archives = [ordered]@{
    "fastctx-x86_64-pc-windows-msvc.zip" = "fastctx.exe"
    "fastctx-x86_64-unknown-linux-gnu.tar.gz" = "fastctx"
    "fastctx-x86_64-apple-darwin.tar.gz" = "fastctx"
    "fastctx-aarch64-apple-darwin.tar.gz" = "fastctx"
}
$releaseFiles = @($archives.Keys) + @("SHA256SUMS")
$licenseFiles = @("LICENSE-APACHE", "NOTICE", "THIRD_PARTY_LICENSES.md")
$windowsInstallerFiles = @(
    "install-fastctx-windows.ps1",
    "configure-fastctx.ps1",
    "configure-ccswitch-fastctx.ps1",
    "configure-agent-integrations.ps1",
    "verify-fastctx-mcp.ps1",
    "fastctx-agent-guidance.md",
    "INSTALL-WINDOWS.md"
)
$tarCommand = if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows
)) {
    Join-Path $env:SystemRoot "System32/tar.exe"
} else {
    "tar"
}

function Get-Sha256([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Assert-ExactFiles([string]$Directory, [string[]]$Expected, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "$Label directory does not exist: $Directory"
    }
    $actual = @(
        Get-ChildItem -LiteralPath $Directory -File |
            ForEach-Object { $_.Name } |
            Sort-Object
    )
    $sortedExpected = @($Expected | Sort-Object)
    if ((Compare-Object -ReferenceObject $sortedExpected -DifferenceObject $actual).Count -ne 0) {
        throw "$Label file set mismatch. Expected [$($sortedExpected -join ', ')]; got [$($actual -join ', ')]."
    }
}

function Read-ChecksumManifest([string]$Path, [string[]]$ExpectedNames, [string]$Label) {
    $checksums = @{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -notmatch '^([0-9a-f]{64})  ([^/\\]+)$') {
            throw "Invalid $Label checksum line: $line"
        }
        if ($checksums.ContainsKey($Matches[2])) {
            throw "Duplicate $Label checksum entry: $($Matches[2])"
        }
        $checksums[$Matches[2]] = $Matches[1]
    }
    if ((Compare-Object -ReferenceObject @($ExpectedNames | Sort-Object) -DifferenceObject @($checksums.Keys | Sort-Object)).Count -ne 0) {
        throw "$Label checksum set mismatch"
    }
    return $checksums
}

Assert-ExactFiles $releasePath $releaseFiles "Release"
$checksums = Read-ChecksumManifest `
    -Path (Join-Path $releasePath "SHA256SUMS") `
    -ExpectedNames @($archives.Keys) `
    -Label "release"
foreach ($name in $archives.Keys) {
    if ($checksums[$name] -ne (Get-Sha256 (Join-Path $releasePath $name))) {
        throw "SHA-256 mismatch for $name"
    }
}

$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ("fastctx-release-verify-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $workspace | Out-Null
try {
    foreach ($archive in $archives.GetEnumerator()) {
        $destination = Join-Path $workspace ([System.IO.Path]::GetFileNameWithoutExtension($archive.Key))
        New-Item -ItemType Directory -Path $destination | Out-Null
        $assetPath = Join-Path $releasePath $archive.Key
        if ($archive.Key.EndsWith(".zip")) {
            Expand-Archive -LiteralPath $assetPath -DestinationPath $destination
        } else {
            Push-Location $releasePath
            try {
                & $tarCommand -xzf $archive.Key -C $destination
                if ($LASTEXITCODE -ne 0) {
                    throw "Cannot extract release archive $($archive.Key)"
                }
            } finally {
                Pop-Location
            }
        }

        $expectedContents = @($archive.Value) + $licenseFiles + @("SHA256SUMS")
        if ($archive.Key.EndsWith(".zip")) { $expectedContents += $windowsInstallerFiles }
        $directories = @(Get-ChildItem -LiteralPath $destination -Recurse -Directory)
        if ($directories.Count -ne 0) {
            throw "Release archive $($archive.Key) contains a directory; contents must be flat"
        }
        Assert-ExactFiles $destination $expectedContents "Archive $($archive.Key)"

        $payloadNames = @($expectedContents | Where-Object { $_ -ne "SHA256SUMS" })
        $internalChecksums = Read-ChecksumManifest `
            -Path (Join-Path $destination "SHA256SUMS") `
            -ExpectedNames $payloadNames `
            -Label "archive $($archive.Key)"
        foreach ($name in $payloadNames) {
            if ($internalChecksums[$name] -ne (Get-Sha256 (Join-Path $destination $name))) {
                throw "Internal SHA-256 mismatch for $name in $($archive.Key)"
            }
        }

        if ($archive.Key.EndsWith(".zip")) {
            foreach ($script in @(
                "install-fastctx-windows.ps1",
                "configure-fastctx.ps1",
                "configure-ccswitch-fastctx.ps1",
                "configure-agent-integrations.ps1",
                "verify-fastctx-mcp.ps1"
            )) {
                $tokens = $null
                $errors = $null
                [void][System.Management.Automation.Language.Parser]::ParseFile(
                    (Join-Path $destination $script),
                    [ref]$tokens,
                    [ref]$errors
                )
                if ($errors.Count -ne 0) {
                    throw "PowerShell syntax error in release file ${script}: $($errors[0].Message)"
                }
            }
            $guidance = [System.IO.File]::ReadAllText(
                (Join-Path $destination "fastctx-agent-guidance.md"),
                [System.Text.UTF8Encoding]::new($true)
            )
            foreach ($required in @(
                '<!-- fastctx:begin -->',
                '<!-- fastctx:end -->',
                'three consecutive, reasonable FastCtx attempts',
                'Never repeat an unchanged failing call',
                'Specialized host tools such as `apply_patch` remain exempt'
            )) {
                if (-not $guidance.Contains($required)) {
                    throw "Windows guidance is missing required contract text: $required"
                }
            }
            if ([regex]::Matches($guidance, [regex]::Escape('<!-- fastctx:begin -->')).Count -ne 1 -or
                [regex]::Matches($guidance, [regex]::Escape('<!-- fastctx:end -->')).Count -ne 1) {
                throw 'Windows guidance must contain exactly one managed block'
            }
            $installDocument = [System.IO.File]::ReadAllText(
                (Join-Path $destination "INSTALL-WINDOWS.md"),
                [System.Text.UTF8Encoding]::new($true)
            )
            foreach ($required in @('.\install-fastctx-windows.ps1', '-VerifyOnly', '-ForceMcpRegistration', 'CC Switch', '-NoLaunchCcSwitch')) {
                if (-not $installDocument.Contains($required)) {
                    throw "Windows installation document is missing: $required"
                }
            }
        } elseif (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
            & /usr/bin/test -x (Join-Path $destination $archive.Value)
            if ($LASTEXITCODE -ne 0) {
                throw "Unix executable bit was not preserved in $($archive.Key)"
            }
        }
    }
} finally {
    Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
}

$npmPackages = [ordered]@{
    "fastctx-win32-x64-$version.tgz" = "@fastctx/win32-x64"
    "fastctx-linux-x64-$version.tgz" = "@fastctx/linux-x64"
    "fastctx-darwin-x64-$version.tgz" = "@fastctx/darwin-x64"
    "fastctx-darwin-arm64-$version.tgz" = "@fastctx/darwin-arm64"
    "fastctx-$version.tgz" = "fastctx"
    "codex-fastctx-$version.tgz" = "codex-fastctx"
}
Assert-ExactFiles $npmPath @($npmPackages.Keys) "npm workflow artifact"
foreach ($package in $npmPackages.GetEnumerator()) {
    Push-Location $npmPath
    try {
        $manifestJson = (& $tarCommand -xOf $package.Key "package/package.json" | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "Cannot read package.json from $($package.Key)"
        }
    } finally {
        Pop-Location
    }
    $manifest = $manifestJson | ConvertFrom-Json
    if ($manifest.name -ne $package.Value -or $manifest.version -ne $version) {
        throw "npm tarball identity mismatch for $($package.Key): $($manifest.name)@$($manifest.version)"
    }
}
