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
$buildOutput = Get-ChildItem -Path 'packages/opencode/dist' -Directory -Filter 'opencode-*' | Sort-Object Name | Select-Object -First 1
if (-not $buildOutput) {
  throw 'No packages/opencode/dist/opencode-* build output found.'
}
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
