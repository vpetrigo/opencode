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
} elseif (-not [string]::IsNullOrWhiteSpace($env:UPSTREAM_TAG)) {
  "pr-7380-replay-$(Sanitize-Tag $env:UPSTREAM_TAG)"
} elseif (-not [string]::IsNullOrWhiteSpace($env:OPENCODE_VERSION)) {
  "pr-7380-replay-$($env:OPENCODE_VERSION)"
} else {
  "pr-7380-replay-$($env:GITHUB_RUN_NUMBER)"
}
$includeV2 = $env:INCLUDE_V2 -ceq 'true'
if ($includeV2) {
  if ($env:PRERELEASE -cne 'true') {
    throw "INCLUDE_V2=true requires PRERELEASE=true."
  }
  if (-not $releaseName.EndsWith('-v2', [StringComparison]::OrdinalIgnoreCase)) {
    $releaseName = "$releaseName-v2"
  }
}
$tagName = Sanitize-Tag $releaseName
if (-not $tagName.StartsWith('pr-7380-')) {
  $tagName = "pr-7380-replay-$tagName"
}

$artifactRoot = Join-Path $env:RUNNER_TEMP 'opencode-verification-artifacts'
$zips = @(Get-ChildItem -Path $artifactRoot -Filter '*.zip' -File | Sort-Object Name)
$expectedZipNames = if ($includeV2) {
  @('opencode-windows-x64.zip', 'opencode-linux-x64.zip', 'lildax-windows-x64.zip', 'lildax-linux-x64.zip')
} else {
  @('opencode-windows-x64.zip', 'opencode-linux-x64.zip')
}
$actualZipNames = @($zips | ForEach-Object { $_.Name } | Sort-Object)
$expectedZipNames = @($expectedZipNames | Sort-Object)
if (($actualZipNames -join "`n") -cne ($expectedZipNames -join "`n")) {
  throw "Expected ZIP set [$($expectedZipNames -join ', ')], found [$($zips.Name -join ', ')] under $artifactRoot."
}

$shaPath = Join-Path $artifactRoot 'SHA256SUMS.txt'
$expectedAssetNames = @($expectedZipNames | ForEach-Object { $_ -replace '\.zip$', '' })
$checksumFiles = @(Get-ChildItem -Path $artifactRoot -Filter '*.sha256' -File | Sort-Object Name)
$buildInfoFiles = @(Get-ChildItem -Path $artifactRoot -Filter '*.build-info.md' -File | Sort-Object Name)
$expectedChecksumNames = @($expectedAssetNames | ForEach-Object { "$_ .sha256".Replace(' ', '') } | Sort-Object)
$actualChecksumNames = @($checksumFiles | ForEach-Object { $_.Name } | Sort-Object)
if (($actualChecksumNames -join "`n") -cne ($expectedChecksumNames -join "`n")) {
  throw "Expected SHA-256 files for [$($expectedAssetNames -join ', ')]."
}
$expectedBuildInfoNames = @($expectedAssetNames | ForEach-Object { "$_ .build-info.md".Replace(' ', '') } | Sort-Object)
$actualBuildInfoNames = @($buildInfoFiles | ForEach-Object { $_.Name } | Sort-Object)
if (($actualBuildInfoNames -join "`n") -cne ($expectedBuildInfoNames -join "`n")) {
  throw "Expected build-info files for [$($expectedAssetNames -join ', ')]."
}
if (@($expectedZipNames + $expectedAssetNames + 'SHA256SUMS.txt' | Group-Object -CaseSensitive | Where-Object Count -gt 1).Count -gt 0) {
  throw 'Duplicate zip or release asset names detected.'
}
$checksumLines = @()
foreach ($zip in $zips) {
  $assetName = [IO.Path]::GetFileNameWithoutExtension($zip.Name)
  $line = (Get-Content -LiteralPath (Join-Path $artifactRoot "$assetName.sha256") -Raw).Trim()
  if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') {
    throw "Invalid checksum record for $($zip.Name)."
  }
  $recordedHash = $Matches[1]
  $recordedName = $Matches[2]
  if ($recordedName -cne $zip.Name) {
    throw "Invalid checksum record for $($zip.Name)."
  }
  $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip.FullName).Hash
  if (-not [string]::Equals($actualHash, $recordedHash, [StringComparison]::OrdinalIgnoreCase)) {
    throw "SHA-256 mismatch for $($zip.Name)."
  }
  $checksumLines += $line
}
Set-Content -LiteralPath $shaPath -Value $checksumLines

$buildInfoContents = @{}
foreach ($file in $buildInfoFiles) {
  $content = Get-Content -LiteralPath $file.FullName -Raw
  if ($content -notmatch '(?m)^- Source commit: ([0-9a-fA-F]+)\s*$' -or -not [string]::Equals($Matches[1], $env:SOURCE_SHA, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Build-info $($file.Name) does not record the expected source SHA."
  }
  if ($includeV2 -and $file.Name -like 'lildax-*.build-info.md') {
    if ([string]::IsNullOrWhiteSpace($env:V2_SHA) -or $content -notmatch '(?m)^- V2_SHA: (\S+)\s*$') {
      throw "Build-info $($file.Name) is missing V2_SHA."
    }
    if (-not [string]::Equals($Matches[1], $env:V2_SHA, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Build-info $($file.Name) does not record the expected V2_SHA."
    }
  }
  $buildInfoContents[$file.Name] = $content
}
$buildInfo = ($buildInfoFiles | ForEach-Object { $buildInfoContents[$_.Name] }) -join "`n`n"

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
if ($includeV2) {
  $releaseNotes = @"
# Experimental lildax v2 PR #7380 verification build

This prerelease contains two distinct products: OpenCode v1 builds (`opencode-*`) and experimental lildax v2 builds (`lildax-*`). The v2 builds are experimental and are not OpenCode v1.

**Important:** lildax v2 may use the normal `opencode.db`; its data is not isolated from OpenCode v1. Use with care.

$releaseNotes
"@
}

$localTag = git tag --list $tagName
if ($localTag) {
  throw "Local tag $tagName already exists; refusing to move or reuse it."
}
$remoteTag = git ls-remote --tags origin "refs/tags/$tagName" "refs/tags/$tagName^{}"
if ($remoteTag) {
  throw "Remote tag $tagName already exists; refusing to move or reuse it."
}
$releaseEndpoint = "repos/$($env:GITHUB_REPOSITORY)/releases/tags/$tagName"
$nativeErrorPreference = $PSNativeCommandUseErrorActionPreference
$PSNativeCommandUseErrorActionPreference = $false
$existingRelease = & gh api $releaseEndpoint --jq '.tag_name' 2>&1
$releaseLookupExitCode = $LASTEXITCODE
$PSNativeCommandUseErrorActionPreference = $nativeErrorPreference
if ($releaseLookupExitCode -eq 0) {
  throw "GitHub release $tagName already exists."
}
if ($releaseLookupExitCode -ne 1 -or "$existingRelease" -notmatch '\(HTTP 404\)') {
  throw "Unable to check GitHub release $tagName (gh api exit $releaseLookupExitCode): $existingRelease"
}

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

git tag $tagName $env:SOURCE_SHA
git push origin $tagName

$releaseArgs = @(
  'release', 'create', $tagName
) + $zips.FullName + @(
  $shaPath,
  '--repo', $env:GITHUB_REPOSITORY,
  '--title', $releaseName,
  '--notes', $releaseNotes,
  '--verify-tag',
  '--latest=false'
)
if ($env:PRERELEASE -eq 'true') {
  $releaseArgs += '--prerelease'
}

& gh @releaseArgs
