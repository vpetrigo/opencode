$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$releaseRoot = Join-Path $env:RUNNER_TEMP 'opencode-verification-release'
New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null
$platform = if ($IsWindows) { 'windows' } else { 'linux' }

$v1Root = Join-Path (Get-Location) $env:V1_ROOT
Push-Location $v1Root
try {
  $v1Head = (git rev-parse HEAD).Trim()
  if ($v1Head -ne $env:SOURCE_SHA) {
    throw "Expected source-v1 HEAD $($env:SOURCE_SHA), got $v1Head."
  }

  $env:OPENCODE_CHANNEL = 'dev'
  Remove-Item Env:OPENCODE_RELEASE -ErrorAction SilentlyContinue
  & bun --version
  & bun install
  & bun ./packages/opencode/script/build.ts --single

  $v1BuildOutputs = @(Get-ChildItem -Path 'packages/opencode/dist' -Directory -Filter 'opencode-*')
  if ($v1BuildOutputs.Count -ne 1) {
    throw "Expected exactly one packages/opencode/dist/opencode-* build output, found $($v1BuildOutputs.Count)."
  }
  $v1BuildOutput = $v1BuildOutputs[0]
  $v1BinaryName = if ($IsWindows) { 'opencode.exe' } else { 'opencode' }
  $v1BinaryRoot = Join-Path $v1BuildOutput.FullName 'bin'
  if (-not (Test-Path -LiteralPath (Join-Path $v1BinaryRoot $v1BinaryName))) {
    throw "Expected $v1BinaryName under $v1BinaryRoot."
  }
  $v1Version = $env:OPENCODE_VERSION
  $v1Channel = $env:OPENCODE_CHANNEL

  $v1AssetName = "opencode-$platform-x64"
  $v1ZipPath = Join-Path $releaseRoot "$v1AssetName.zip"
  Compress-Archive -Path (Join-Path $v1BinaryRoot '*') -DestinationPath $v1ZipPath -Force
  $v1Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $v1ZipPath).Hash.ToLowerInvariant()
  Set-Content -LiteralPath (Join-Path $releaseRoot "$v1AssetName.sha256") -Value "$v1Hash  $v1AssetName.zip" -NoNewline

  $v1BuildInfo = @"
## Build info for $v1AssetName

- Source commit: $v1Head
- Version: $v1Version
- Channel: $v1Channel
- Base branch: $env:BASE_BRANCH
- Base commit: $env:BASE_SHA
- Patch branch: $env:PATCH_BRANCH
- Patch commit: $env:PATCH_SHA
- Upstream tag: $env:UPSTREAM_TAG
- Native binary: $v1BinaryName (present)
- ZIP SHA256: $v1Hash
- Built at: $(Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')
- Runner: $env:RUNNER_OS
- Build command: bun ./packages/opencode/script/build.ts --single
"@
  Set-Content -LiteralPath (Join-Path $releaseRoot "$v1AssetName.build-info.md") -Value $v1BuildInfo -NoNewline
}
finally {
  Pop-Location
}

if ($env:INCLUDE_V2 -ceq 'true') {
  $v2Root = Join-Path (Get-Location) $env:V2_ROOT
  Push-Location $v2Root
  try {
    $v2Head = (git rev-parse HEAD).Trim()
    if ($v2Head -ne $env:V2_SHA) {
      throw "Expected source-v2 HEAD $($env:V2_SHA), got $v2Head."
    }

    $v2ShortSha = $v2Head.Substring(0, 7)
    $env:OPENCODE_VERSION = "0.0.0-v2-prototype-$v2ShortSha"
    $env:OPENCODE_CHANNEL = 'dev'
    Remove-Item Env:OPENCODE_RELEASE -ErrorAction SilentlyContinue
    $v2BuildCommand = 'bun ./packages/cli/script/build.ts --single'
    & bun --version
    & bun install
    & bun ./packages/cli/script/build.ts --single

    $v2BinaryName = if ($IsWindows) { 'lildax.exe' } else { 'lildax' }
    $v2BuildPath = "packages/cli/dist/cli-$platform-x64"
    $v2BinaryPath = Join-Path (Join-Path $v2BuildPath 'bin') $v2BinaryName
    if (-not (Test-Path -LiteralPath $v2BinaryPath -PathType Leaf)) {
      throw "Expected native binary at $v2BinaryPath."
    }
    & $v2BinaryPath --version
    $v2Version = $env:OPENCODE_VERSION
    $v2Channel = $env:OPENCODE_CHANNEL

    $v2AssetName = "lildax-$platform-x64"
    $v2ZipPath = Join-Path $releaseRoot "$v2AssetName.zip"
    Compress-Archive -Path $v2BinaryPath -DestinationPath $v2ZipPath -Force
    $v2Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $v2ZipPath).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $releaseRoot "$v2AssetName.sha256") -Value "$v2Hash  $v2AssetName.zip" -NoNewline

    $v2BuildInfo = @"
## Build info for $v2AssetName

- Source commit: $v2Head
- Version: $v2Version
- Channel: $v2Channel
- V2_SHA: $env:V2_SHA
- Native binary: $v2BinaryName (present)
- ZIP SHA256: $v2Hash
- Built at: $(Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')
- Runner: $env:RUNNER_OS
- Build command: $v2BuildCommand
"@
    Set-Content -LiteralPath (Join-Path $releaseRoot "$v2AssetName.build-info.md") -Value $v2BuildInfo -NoNewline
  }
  finally {
    Pop-Location
  }
}
