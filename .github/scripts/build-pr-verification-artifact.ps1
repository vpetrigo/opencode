$ErrorActionPreference = 'Stop'

function Sanitize-Tag([string]$value) {
  $sanitized = $value -replace '[^A-Za-z0-9._-]', '-'
  $sanitized = $sanitized -replace '-+', '-'
  $sanitized = $sanitized.Trim('-')
  if ([string]::IsNullOrWhiteSpace($sanitized)) {
    return 'ref'
  }
  return $sanitized
}

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

git fetch origin "+refs/heads/$($env:BASE_BRANCH):refs/remotes/origin/$($env:BASE_BRANCH)" --force
git fetch origin "+refs/heads/$($env:PATCH_BRANCH):refs/remotes/origin/$($env:PATCH_BRANCH)" --force

$safeRef = Sanitize-Tag $env:BASE_BRANCH
$releaseName = if (-not [string]::IsNullOrWhiteSpace($env:RELEASE_NAME_INPUT)) {
  $env:RELEASE_NAME_INPUT
} else {
  "pr-7380-$safeRef-$($env:GITHUB_RUN_NUMBER)"
}
$tagName = Sanitize-Tag $releaseName
if (-not $tagName.StartsWith('pr-7380-')) {
  $tagName = "pr-7380-$safeRef"
}

$baseRef = "refs/remotes/origin/$($env:BASE_BRANCH)"
git rev-parse --verify $baseRef
git rev-parse --verify "refs/remotes/origin/$($env:PATCH_BRANCH)"

$baseCommit = git rev-parse $baseRef
$patchCommit = git rev-parse "refs/remotes/origin/$($env:PATCH_BRANCH)"
git checkout -b "generated-$tagName" $baseRef
git merge --ff-only "refs/remotes/origin/$($env:PATCH_BRANCH)"
$mergeCommit = git rev-parse HEAD

# TODO: remove that once opentui-spinner is fixed
(Get-Content package.json) -replace '("opentui-spinner":\s*)"[^"]+"', '$1"0.0.6"' | Set-Content package.json

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
- Base commit: $baseCommit
- Patch branch: $env:PATCH_BRANCH
- Patch commit: $patchCommit
- Rebased commit: $mergeCommit
- Built at: $(Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')
- Runner: $env:RUNNER_OS
- Build command: bun ./packages/opencode/script/build.ts --single
"@
Set-Content -LiteralPath (Join-Path $releaseRoot "$($buildOutput.Name).build-info.md") -Value $buildInfo -NoNewline

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
Set-Content -LiteralPath (Join-Path $releaseRoot "$($buildOutput.Name).sha256") -Value "$hash  $($buildOutput.Name).zip" -NoNewline
