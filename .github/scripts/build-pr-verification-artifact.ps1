$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

git fetch origin "+refs/heads/$($env:SOURCE_REF):refs/remotes/origin/$($env:SOURCE_REF)" --force
git checkout --detach $env:SOURCE_SHA
git rev-parse --verify $env:SOURCE_SHA
$sourceRefCommit = git rev-parse --verify "refs/remotes/origin/$($env:SOURCE_REF)"
if ($sourceRefCommit -ne $env:SOURCE_SHA) {
  throw "Expected $($env:SOURCE_REF) $($env:SOURCE_SHA), got $sourceRefCommit."
}

$headCommit = git rev-parse HEAD
if ($headCommit -ne $env:SOURCE_SHA) {
  throw "Expected HEAD $($env:SOURCE_SHA), got $headCommit."
}

& bun --version
& bun install
& bun ./packages/opencode/script/build.ts --single

$releaseRoot = Join-Path $env:RUNNER_TEMP 'opencode-verification-release'
New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null
$buildOutputs = @(Get-ChildItem -Path 'packages/opencode/dist' -Directory -Filter 'opencode-*')
if ($buildOutputs.Count -ne 1) {
  throw "Expected exactly one packages/opencode/dist/opencode-* build output, found $($buildOutputs.Count)."
}
$buildOutput = $buildOutputs[0]
$binaryRoot = Join-Path $buildOutput.FullName 'bin'
$binaryName = if ($IsWindows) { 'opencode.exe' } else { 'opencode' }
if (-not (Test-Path -LiteralPath (Join-Path $binaryRoot $binaryName))) {
  throw "Expected $binaryName under $binaryRoot."
}

$zipPath = Join-Path $releaseRoot "$($buildOutput.Name).zip"
Compress-Archive -Path (Join-Path $binaryRoot '*') -DestinationPath $zipPath -Force

$buildInfo = @"
## Build info for $($buildOutput.Name)

- Base branch: $env:BASE_BRANCH
- Base commit: $env:BASE_SHA
- Patch branch: $env:PATCH_BRANCH
- Patch commit: $env:PATCH_SHA
- Upstream tag: $env:UPSTREAM_TAG
- Source ref: $env:SOURCE_REF
- Source commit: $headCommit
- Built at: $(Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')
- Runner: $env:RUNNER_OS
- Build command: bun ./packages/opencode/script/build.ts --single
"@
Set-Content -LiteralPath (Join-Path $releaseRoot "$($buildOutput.Name).build-info.md") -Value $buildInfo -NoNewline

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
Set-Content -LiteralPath (Join-Path $releaseRoot "$($buildOutput.Name).sha256") -Value "$hash  $($buildOutput.Name).zip" -NoNewline

if ($env:INCLUDE_V2 -ceq 'true') {
  $v2BuildCommand = 'bun ./packages/cli/script/build.ts --single'
  & bun ./packages/cli/script/build.ts --single

  $v2Platform = if ($IsWindows) { 'windows' } else { 'linux' }
  $v2BinaryName = if ($IsWindows) { 'lildax.exe' } else { 'lildax' }
  $v2BuildPath = "packages/cli/dist/cli-$v2Platform-x64"
  $v2BuildOutputs = @(Get-ChildItem -Path $v2BuildPath -File -Recurse -Filter $v2BinaryName | Where-Object { $_.Directory.Name -eq 'bin' })
  if ($v2BuildOutputs.Count -ne 1) {
    throw "Expected exactly one $v2BinaryName under $v2BuildPath/bin, found $($v2BuildOutputs.Count)."
  }
  $v2Binary = $v2BuildOutputs[0]
  if ($v2Binary.Directory.FullName -ne (Join-Path (Join-Path (Get-Location) $v2BuildPath) 'bin')) {
    throw "Expected native output at $v2BuildPath/bin/$v2BinaryName, got $($v2Binary.FullName)."
  }

  $v2AssetName = "lildax-$v2Platform-x64"
  $v2ZipPath = Join-Path $releaseRoot "$v2AssetName.zip"
  Compress-Archive -Path $v2Binary.FullName -DestinationPath $v2ZipPath -Force
  $v2Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $v2ZipPath).Hash.ToLowerInvariant()
  Set-Content -LiteralPath (Join-Path $releaseRoot "$v2AssetName.sha256") -Value "$v2Hash  $v2AssetName.zip" -NoNewline

  $v2BuildInfo = @"
## Build info for $v2AssetName

- Base branch: $env:BASE_BRANCH
- Base commit: $env:BASE_SHA
- Patch branch: $env:PATCH_BRANCH
- Patch commit: $env:PATCH_SHA
- Upstream tag: $env:UPSTREAM_TAG
- Source ref: $env:SOURCE_REF
- Source commit: $headCommit
- V2_SHA: $env:V2_SHA
- Built at: $(Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')
- Runner: $env:RUNNER_OS
- Build command: $v2BuildCommand
"@
  Set-Content -LiteralPath (Join-Path $releaseRoot "$v2AssetName.build-info.md") -Value $v2BuildInfo -NoNewline
}
