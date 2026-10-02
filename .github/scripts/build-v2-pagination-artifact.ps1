$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$required = @(
  "UPSTREAM_TAG", "UPSTREAM_SHA", "PICKER_SHA", "FIXTURE_SHA", "PREPARED_SHA",
  "PREPARED_REF", "V2_VERSION", "RUNNER_TEMP", "GITHUB_SHA", "RUNNER_OS", "RUNNER_ARCH"
)
foreach ($name in $required) {
  if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
    throw "Required environment variable is missing: $name"
  }
}

if ($env:RUNNER_OS -notin @("Windows", "Linux") -or $env:RUNNER_ARCH -ne "X64") {
  throw "Only Windows and Linux x64 runners are supported."
}
$platform = if ($env:RUNNER_OS -eq "Windows") { "windows" } else { "linux" }
$source = Join-Path (Get-Location) "source-v2"
if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "source-v2 checkout is missing." }
$head = (& git -C $source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -ne $env:PREPARED_SHA) { throw "source-v2 HEAD does not match PREPARED_SHA." }

$env:OPENCODE_VERSION = $env:V2_VERSION
$env:OPENCODE_CHANNEL = "dev"
Remove-Item Env:OPENCODE_RELEASE -ErrorAction SilentlyContinue
$bunBin = if ($env:RUNNER_OS -eq "Windows") { Join-Path $env:USERPROFILE ".bun\bin" } else { Join-Path $HOME ".bun\bin" }
$env:PATH = "$bunBin$([IO.Path]::PathSeparator)$env:PATH"
$bunVersion = (& bun --version).Trim()
if ($LASTEXITCODE -ne 0 -or $bunVersion -ne "1.4.2") { throw "Bun 1.4.2 is required; found '$bunVersion'." }

$env:CI = "true"
Push-Location $source
try {
  & bun install
  if ($LASTEXITCODE -ne 0) { throw "bun install failed." }
} finally { Pop-Location }

$tui = Join-Path $source "packages/tui"
$core = Join-Path $source "packages/core"
Push-Location $tui
try {
  & bun test test/cli/tui/dialog-session-list.test.tsx
  if ($LASTEXITCODE -ne 0) { throw "Focused TUI picker tests failed." }
  & bun test test/cli/tui/session-history.test.ts
  if ($LASTEXITCODE -ne 0) { throw "Focused TUI history tests failed." }
  & bun typecheck
  if ($LASTEXITCODE -ne 0) { throw "TUI typecheck failed." }
} finally { Pop-Location }
Push-Location $core
try {
  & bun test test/fixture-v2-pagination.test.ts
  if ($LASTEXITCODE -ne 0) { throw "Core fixture test failed." }
  & bun typecheck
  if ($LASTEXITCODE -ne 0) { throw "Core typecheck failed." }
} finally { Pop-Location }

Push-Location $source
try {
  & bun ./packages/cli/script/build.ts --single
  if ($LASTEXITCODE -ne 0) { throw "CLI build failed." }
} finally { Pop-Location }

$binaryName = if ($platform -eq "windows") { "opencode.exe" } else { "opencode" }
$binary = Join-Path $source "packages/cli/dist/cli-$platform-x64/bin/$binaryName"
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw "Expected native binary missing: $binary" }
if ($platform -eq "linux") {
  $mode = (& stat -c %a -- $binary).Trim()
  if ($LASTEXITCODE -ne 0 -or (([Convert]::ToInt32($mode, 8) -band 73) -ne 73)) {
    throw "Linux binary is not executable; refusing to publish an unexecutable archive."
  }
}
$versionOutput = (& $binary --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $versionOutput -notlike "*$($env:V2_VERSION)*") {
  throw "Built binary version does not include V2_VERSION '$($env:V2_VERSION)'. Output: $versionOutput"
}
$release = Join-Path $env:RUNNER_TEMP "opencode-v2-verification-release"
New-Item -ItemType Directory -Path $release -Force | Out-Null
$base = "opencode-v2-$platform-x64"
$zip = Join-Path $release "$base.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
if ($platform -eq "linux" -and (Get-Command zip -ErrorAction SilentlyContinue)) {
  & zip -j $zip $binary
  if ($LASTEXITCODE -ne 0) { throw "ZIP creation failed." }
} else {
  Compress-Archive -LiteralPath $binary -DestinationPath $zip
}
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($platform -eq "linux") {
  $extract = Join-Path $release "verify-extract"
  if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
  New-Item -ItemType Directory -Path $extract | Out-Null
  if (Get-Command unzip -ErrorAction SilentlyContinue) {
    & unzip -q $zip -d $extract
    if ($LASTEXITCODE -ne 0) { throw "Could not verify Linux ZIP executable mode." }
  } else {
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
  }
  $extracted = Join-Path $extract $binaryName
  if (-not (Test-Path -LiteralPath $extracted -PathType Leaf)) { throw "Linux ZIP does not contain binary at archive root." }
  $mode = (& stat -c %a -- $extracted).Trim()
  if ($LASTEXITCODE -ne 0 -or (([Convert]::ToInt32($mode, 8) -band 73) -ne 73)) {
    throw "Linux ZIP extraction does not preserve executable mode; refusing to publish."
  }
  $extractedVersion = (& $extracted --version 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $extractedVersion -notlike "*$($env:V2_VERSION)*") {
    throw "Extracted Linux binary version does not match V2_VERSION '$($env:V2_VERSION)': $extractedVersion"
  }
  Remove-Item -LiteralPath $extract -Recurse -Force
}
Set-Content -LiteralPath (Join-Path $release "$base.sha256") -Value "$hash  $base.zip" -NoNewline
$linuxNote = if ($platform -eq "linux") { "Executable mode verified after ZIP extraction." } else { "Not applicable." }
$metadata = @"
# OpenCode V2 pagination verification build

- Platform: $platform-x64
- Source commit: $env:PREPARED_SHA
- UPSTREAM_SHA: $env:UPSTREAM_SHA
- PICKER_SHA: $env:PICKER_SHA
- FIXTURE_SHA: $env:FIXTURE_SHA
- V2_VERSION: $env:V2_VERSION
- Upstream tag: $env:UPSTREAM_TAG
- Upstream SHA: $env:UPSTREAM_SHA
- Picker SHA: $env:PICKER_SHA
- Fixture SHA: $env:FIXTURE_SHA
- Prepared source SHA: $env:PREPARED_SHA
- Bundle-local prepared source ref: $env:PREPARED_REF
- Automation revision (GITHUB_SHA): $env:GITHUB_SHA
- Version: $env:V2_VERSION
- ZIP SHA-256: $hash
- Archive: $base.zip (binary at archive root)
- Linux extraction note: $linuxNote
"@
Set-Content -LiteralPath (Join-Path $release "$base.build-info.md") -Value $metadata -NoNewline
