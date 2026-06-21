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

$safeRef = Sanitize-Tag $env:UPSTREAM_REF
$releaseName = if (-not [string]::IsNullOrWhiteSpace($env:RELEASE_NAME_INPUT)) {
  $env:RELEASE_NAME_INPUT
} elseif ($env:UPSTREAM_REF -eq 'dev') {
  "pr-7380-dev-$($env:GITHUB_RUN_NUMBER)"
} else {
  "pr-7380-$safeRef"
}
$tagName = Sanitize-Tag $releaseName
if (-not $tagName.StartsWith('pr-7380-')) {
  $tagName = "pr-7380-$safeRef"
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
# Unofficial PR #26861 verification build for OpenCode $($env:UPSTREAM_REF)

This is an unofficial verification build for testing PR #26861.

It is based on official OpenCode '$($env:UPSTREAM_REF)' plus the lazy-scroll message loading changes from '$($env:PATCH_BRANCH)'.

This is not an official OpenCode release.

Please test:
- scrolling near the top loads older messages
- scrolling near the bottom loads newer messages
- old messages no longer disappear during long sessions
- Timeline dialog loads the complete session

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
git remote add upstream $env:UPSTREAM_REPO 2>$null
git fetch upstream '+refs/heads/*:refs/remotes/upstream/*' '+refs/tags/*:refs/tags/*' --force
git fetch origin "+refs/heads/$($env:PATCH_BRANCH):refs/remotes/origin/$($env:PATCH_BRANCH)" --force

$baseRef = if ($env:UPSTREAM_REF -eq 'dev') { 'refs/remotes/upstream/dev' } else { "refs/tags/$($env:UPSTREAM_REF)" }
git checkout -b "release-$tagName" $baseRef
git merge --no-edit "refs/remotes/origin/$($env:PATCH_BRANCH)"

git tag -f $tagName
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
