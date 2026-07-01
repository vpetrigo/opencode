$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Sanitize-Tag([string]$value) {
  $sanitized = $value -replace '[^A-Za-z0-9._-]', '-'
  $sanitized = $sanitized -replace '-+', '-'
  $sanitized = $sanitized.Trim('-')
  if ([string]::IsNullOrWhiteSpace($sanitized)) {
    return 'ref'
  }
  return $sanitized
}

$releaseName = if (-not [string]::IsNullOrWhiteSpace($env:RELEASE_NAME_INPUT)) {
  $env:RELEASE_NAME_INPUT
} elseif (-not [string]::IsNullOrWhiteSpace($env:OPENCODE_VERSION)) {
  "pr-7380-replay-$($env:OPENCODE_VERSION)"
} elseif (-not [string]::IsNullOrWhiteSpace($env:UPSTREAM_TAG)) {
  "pr-7380-replay-$(Sanitize-Tag $env:UPSTREAM_TAG)"
} else {
  "pr-7380-replay-$($env:GITHUB_RUN_NUMBER)"
}
$tagName = Sanitize-Tag $releaseName
if (-not $tagName.StartsWith('pr-7380-')) {
  $tagName = "pr-7380-replay-$tagName"
}

$artifactRoot = Join-Path $env:RUNNER_TEMP 'opencode-verification-artifacts'
$zips = @(Get-ChildItem -Path $artifactRoot -Filter '*.zip' -File | Sort-Object Name)
if ($zips.Count -eq 0) {
  throw "No zip artifacts found under $artifactRoot."
}

$shaPath = Join-Path $artifactRoot 'SHA256SUMS.txt'
Get-ChildItem -Path $artifactRoot -Filter '*.sha256' -File | Sort-Object Name | ForEach-Object {
  Get-Content -LiteralPath $_.FullName
} | Set-Content -LiteralPath $shaPath

$buildInfo = (Get-ChildItem -Path $artifactRoot -Filter '*.build-info.md' -File | Sort-Object Name | ForEach-Object {
  Get-Content -LiteralPath $_.FullName -Raw
}) -join "`n`n"

$releaseNotes = @"
# Unofficial PR #7380 verification build for OpenCode $($env:UPSTREAM_TAG)

This is an unofficial verification build based on OpenCode '$($env:UPSTREAM_TAG)'.

It replays '$($env:BASE_BRANCH)' and '$($env:PATCH_BRANCH)' on top of that tag.

Replay strategy: cherry-pick -X theirs.

Source SHA: $($env:SOURCE_SHA)

This is not an official OpenCode release.

Please test:
- scrolling near the top loads older messages
- scrolling near the bottom loads newer messages
- old messages no longer disappear during long sessions
- Timeline dialog loads the complete session
- the session switcher loads older sessions without duplicates

Please report:
- OS
- terminal
- artifact used
- whether the issue is fixed
- any regressions noticed

The Windows zip has the same root layout as the official CLI zip: extract it and run opencode.exe from the extracted directory. See [INSTALL_NOTES.md](https://github.com/$($env:GITHUB_REPOSITORY)/blob/$($env:GITHUB_REF_NAME)/INSTALL_NOTES.md) for commands, including how to copy opencode.db and test with existing sessions safely.

$buildInfo
"@

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

git fetch origin "+refs/heads/$($env:SOURCE_REF):refs/remotes/origin/$($env:SOURCE_REF)" --force
git checkout --detach $env:SOURCE_SHA
$sourceRefCommit = git rev-parse --verify "refs/remotes/origin/$($env:SOURCE_REF)"
if ($sourceRefCommit -ne $env:SOURCE_SHA) {
  throw "Expected $($env:SOURCE_REF) $($env:SOURCE_SHA), got $sourceRefCommit."
}
$headCommit = git rev-parse HEAD
if ($headCommit -ne $env:SOURCE_SHA) {
  throw "Expected HEAD $($env:SOURCE_SHA), got $headCommit."
}

git tag -f $tagName $env:SOURCE_SHA
git push origin $tagName --force

$releaseArgs = @(
  'release', 'create', $tagName
) + $zips.FullName + @(
  $shaPath,
  '--repo', $env:GITHUB_REPOSITORY,
  '--title', $releaseName,
  '--notes', $releaseNotes
)
if ($env:PRERELEASE -eq 'true') {
  $releaseArgs += '--prerelease'
}

& gh @releaseArgs
