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
$tagName = Sanitize-Tag $releaseName
if (-not $tagName.StartsWith('pr-7380-')) {
  $tagName = "pr-7380-replay-$tagName"
}

$artifactRoot = Join-Path $env:RUNNER_TEMP 'opencode-verification-artifacts'
$zips = @(Get-ChildItem -Path $artifactRoot -Filter '*.zip' -File | Sort-Object Name)
$expectedZipNames = @('opencode-windows-x64.zip', 'opencode-linux-x64.zip')
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
  $expectedSourceSha = $env:SOURCE_SHA
  if ($content -notmatch '(?m)^- Source commit: ([0-9a-fA-F]+)\s*$' -or -not [string]::Equals($Matches[1], $expectedSourceSha, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Build-info $($file.Name) does not record the expected source SHA $expectedSourceSha."
  }
  $buildInfoContents[$file.Name] = $content
}
$buildInfo = ($buildInfoFiles | ForEach-Object { $buildInfoContents[$_.Name] }) -join "`n`n"

$releaseNotes = @"
# Unofficial PR #7380 verification build for OpenCode $($env:UPSTREAM_TAG)

This is an unofficial verification build based on OpenCode '$($env:UPSTREAM_TAG)'.

It replays '$($env:BASE_BRANCH)' and '$($env:PATCH_BRANCH)' on top of that tag.

Replay strategy: ordinary git cherry-pick (without -X theirs).

The GitHub tag and GitHub-generated source archives point to the automation workflow tree at $($env:GITHUB_SHA), not the prepared v1 source. The attached 'prepared-v1.bundle' is the exact prepared source at $($env:SOURCE_SHA); the binaries were built from that SHA.

Prepared v1 source SHA (bundle and binary source): $($env:SOURCE_SHA)
Automation workflow tree SHA (tag and GitHub source archives): $($env:GITHUB_SHA)
Base commit: $($env:BASE_SHA)
Patch commit: $($env:PATCH_SHA)

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

$bundlePath = [IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP 'opencode-v1-source/prepared-v1.bundle'))
if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
  throw "Prepared source bundle does not exist: $bundlePath"
}
git bundle verify $bundlePath
if ($LASTEXITCODE -ne 0) { throw 'Prepared source bundle verification failed.' }
$bundleRef = "refs/heads/$($env:SOURCE_REF)"
$bundleHeads = @(git bundle list-heads $bundlePath)
if ($LASTEXITCODE -ne 0) { throw 'Unable to read prepared source bundle heads.' }
$advertisedHead = @($bundleHeads | ForEach-Object { "$($_)".Trim() } | Where-Object { $_ -match "^[0-9a-fA-F]{40}\s+$([regex]::Escape($bundleRef))$" })
if ($advertisedHead.Count -ne 1 -or -not [string]::Equals(($advertisedHead[0] -split '\s+')[0], $env:SOURCE_SHA, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Bundle ref $bundleRef does not advertise SOURCE_SHA $($env:SOURCE_SHA)."
}
git fetch --no-tags $bundlePath "+${bundleRef}:${bundleRef}"
if ($LASTEXITCODE -ne 0) { throw "Unable to import prepared bundle ref $bundleRef." }
$sourceRefCommit = git rev-parse --verify $bundleRef
if ($LASTEXITCODE -ne 0 -or -not [string]::Equals("$sourceRefCommit".Trim(), $env:SOURCE_SHA, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Prepared ref $($env:SOURCE_REF) does not resolve to SOURCE_SHA $($env:SOURCE_SHA)."
}
$headCommit = git rev-parse --verify HEAD
if ($LASTEXITCODE -ne 0 -or -not [string]::Equals("$headCommit".Trim(), $env:GITHUB_SHA, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Checked-out HEAD is not the automation workflow commit GITHUB_SHA $($env:GITHUB_SHA)."
}

git tag $tagName $env:GITHUB_SHA
if ($LASTEXITCODE -ne 0) { throw "Unable to create local tag $tagName." }
$tagCommit = git rev-parse --verify "$tagName^{commit}"
if ($LASTEXITCODE -ne 0 -or -not [string]::Equals("$tagCommit".Trim(), $env:GITHUB_SHA, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Created tag $tagName does not point to GITHUB_SHA."
}
git push origin $tagName
if ($LASTEXITCODE -ne 0) { throw "Unable to push tag $tagName to origin." }
$pushedTag = git ls-remote --tags origin "refs/tags/$tagName" "refs/tags/$tagName^{}"
if ($LASTEXITCODE -ne 0) { throw "Unable to verify pushed remote tag $tagName." }
$pushedTagLines = @($pushedTag | ForEach-Object { "$($_)".Trim() } | Where-Object { $_ })
$peeledTag = @($pushedTagLines | Where-Object { $_ -match "\srefs/tags/$([regex]::Escape($tagName))\^\{\}$" })
$directTag = @($pushedTagLines | Where-Object { $_ -match "\srefs/tags/$([regex]::Escape($tagName))$" })
$remoteTagCommit = if ($peeledTag.Count -eq 1) { ($peeledTag[0] -split '\s+')[0] } elseif ($directTag.Count -eq 1) { ($directTag[0] -split '\s+')[0] } else { '' }
if (-not [string]::Equals($remoteTagCommit, $env:GITHUB_SHA, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Remote tag $tagName does not resolve to GITHUB_SHA $($env:GITHUB_SHA)."
}

$releaseArgs = @(
  'release', 'create', $tagName
) + $zips.FullName + @(
  $shaPath,
  $bundlePath,
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
