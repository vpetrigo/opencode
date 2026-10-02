$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Sanitize-Tag([string]$value) {
  $sanitized = $value -replace '[^A-Za-z0-9._-]', '-'
  $sanitized = $sanitized -replace '-+', '-'
  $sanitized = $sanitized.Trim('-')
  if ([string]::IsNullOrWhiteSpace($sanitized)) {
    throw 'Cannot derive a release tag from an empty value.'
  }
  return $sanitized
}

$requiredEnvironment = @(
  'UPSTREAM_TAG', 'UPSTREAM_SHA', 'PICKER_SHA', 'FIXTURE_SHA', 'PREPARED_SHA',
  'PREPARED_REF', 'V2_VERSION', 'RUNNER_TEMP', 'GH_TOKEN', 'GITHUB_REPOSITORY',
  'GITHUB_RUN_NUMBER', 'GITHUB_SHA'
)
foreach ($name in $requiredEnvironment) {
  if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
    throw "Required environment variable $name is missing."
  }
}
if ($env:PREPARED_REF -notmatch '^verification-v2-source-[0-9]+-[0-9]+$') {
  throw 'PREPARED_REF must be a verification-v2-source run ref.'
}
foreach ($name in @('UPSTREAM_SHA', 'PICKER_SHA', 'FIXTURE_SHA', 'PREPARED_SHA', 'GITHUB_SHA')) {
  if ([Environment]::GetEnvironmentVariable($name) -notmatch '^(?i)[0-9a-f]{40}$') {
    throw "Environment variable $name must be a full 40-character commit SHA."
  }
}

$artifactRoot = Join-Path $env:RUNNER_TEMP 'opencode-v2-verification-artifacts'
if (-not (Test-Path -LiteralPath $artifactRoot -PathType Container)) {
  throw "Artifact directory does not exist: $artifactRoot"
}
$expectedZipNames = @('opencode-v2-windows-x64.zip', 'opencode-v2-linux-x64.zip')
$expectedAssetNames = @($expectedZipNames | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) })
$expectedChecksumNames = @($expectedAssetNames | ForEach-Object { "$_ .sha256".Replace(' ', '') })
$expectedBuildInfoNames = @($expectedAssetNames | ForEach-Object { "$_ .build-info.md".Replace(' ', '') })
$allFiles = @(Get-ChildItem -LiteralPath $artifactRoot -File | Sort-Object Name)
$expectedNames = @($expectedZipNames + $expectedChecksumNames + $expectedBuildInfoNames | Sort-Object)
$actualNames = @($allFiles | ForEach-Object { $_.Name } | Sort-Object)
if (($actualNames -join "`n") -cne ($expectedNames -join "`n")) {
  throw "Expected exactly [$($expectedNames -join ', ')] in $artifactRoot; found [$($actualNames -join ', ')]."
}
if (@($expectedNames | Group-Object -CaseSensitive | Where-Object Count -gt 1).Count -gt 0) {
  throw 'Duplicate release asset names detected.'
}

$buildInfoContents = @{}
foreach ($zipName in $expectedZipNames) {
  $zipPath = Join-Path $artifactRoot $zipName
  $assetName = [IO.Path]::GetFileNameWithoutExtension($zipName)
  $checksum = (Get-Content -LiteralPath (Join-Path $artifactRoot "$assetName.sha256") -Raw).Trim()
  if ($checksum -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$' -or $Matches[2] -cne $zipName) {
    throw "Invalid checksum record for $zipName."
  }
  $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash
  if (-not [string]::Equals($actualHash, $Matches[1], [StringComparison]::OrdinalIgnoreCase)) {
    throw "SHA-256 mismatch for $zipName."
  }

  $buildInfoPath = Join-Path $artifactRoot "$assetName.build-info.md"
  $content = Get-Content -LiteralPath $buildInfoPath -Raw
  foreach ($entry in @(
    @{ Name = 'Source commit'; Value = $env:PREPARED_SHA },
    @{ Name = 'UPSTREAM_SHA'; Value = $env:UPSTREAM_SHA },
    @{ Name = 'PICKER_SHA'; Value = $env:PICKER_SHA },
    @{ Name = 'FIXTURE_SHA'; Value = $env:FIXTURE_SHA },
    @{ Name = 'V2_VERSION'; Value = $env:V2_VERSION }
  )) {
    if ($content -notmatch "(?m)^- $([regex]::Escape($entry.Name)): (\S+)\s*$" -or
      -not [string]::Equals($Matches[1], $entry.Value, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Build-info $([IO.Path]::GetFileName($buildInfoPath)) does not record the expected $($entry.Name) ($($entry.Value))."
    }
  }
  $buildInfoContents[$([IO.Path]::GetFileName($buildInfoPath))] = $content
}

$tagName = "v2-pagination-$(Sanitize-Tag $env:UPSTREAM_TAG)-$($env:FIXTURE_SHA.Substring(0, 8))"
$releaseNotes = @"
# Unofficial patched OpenCode $($env:V2_VERSION) pagination verification build

This is an unofficial, patched build derived from upstream '$($env:UPSTREAM_TAG)' and is not an official OpenCode release. It contains only the standalone v2 pagination build; it is separate from the v1 verification release and has no v1 assets.

Release tag: $tagName
Prepared v2 source SHA (the tag and source archive target): $($env:PREPARED_SHA)
Upstream source SHA: $($env:UPSTREAM_SHA)
Picker patch SHA: $($env:PICKER_SHA)
Fixture SHA: $($env:FIXTURE_SHA)
Automation workflow SHA: $($env:GITHUB_SHA)
Automation run number: $($env:GITHUB_RUN_NUMBER)

Use a separate extraction directory and an isolated standalone fixture/database. Never point this build at a live OpenCode database. Extract the platform ZIP and run its included `opencode` executable (or `opencode.exe`) from the extracted directory, following the fixture-specific setup supplied with your test environment.

## Build provenance

$($buildInfoContents['opencode-v2-linux-x64.build-info.md'])

$($buildInfoContents['opencode-v2-windows-x64.build-info.md'])
"@

$localTag = git tag --list $tagName
if ($localTag) {
  throw "Local tag $tagName already exists; refusing to move or reuse it."
}
$remoteTag = git ls-remote --tags origin "refs/tags/$tagName" "refs/tags/$tagName^{}"
if ($LASTEXITCODE -ne 0) {
  throw "Unable to check remote tag $tagName."
}
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

$bundlePath = [IO.Path]::GetFullPath((Join-Path $env:RUNNER_TEMP 'opencode-v2-source/prepared-v2.bundle'))
if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
  throw "Prepared source bundle does not exist: $bundlePath"
}
git bundle verify $bundlePath
if ($LASTEXITCODE -ne 0) {
  throw 'Prepared source bundle verification failed.'
}
$bundleHeads = @(git bundle list-heads $bundlePath)
if ($LASTEXITCODE -ne 0) {
  throw 'Unable to read prepared source bundle heads.'
}
$bundleRef = "refs/heads/$($env:PREPARED_REF)"
$advertisedHead = @($bundleHeads | ForEach-Object { "$($_)".Trim() } | Where-Object { $_ -match "^[0-9a-fA-F]{40}\s+$([regex]::Escape($bundleRef))$" })
if ($advertisedHead.Count -ne 1 -or -not [string]::Equals(($advertisedHead[0] -split '\s+')[0], $env:PREPARED_SHA, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Bundle ref $bundleRef does not advertise PREPARED_SHA $($env:PREPARED_SHA)."
}
git fetch --no-tags $bundlePath "+${bundleRef}:${bundleRef}"
if ($LASTEXITCODE -ne 0) {
  throw "Unable to import prepared bundle ref $bundleRef."
}
$preparedRefCommit = git rev-parse --verify $bundleRef
if ($LASTEXITCODE -ne 0 -or -not [string]::Equals("$preparedRefCommit".Trim(), $env:PREPARED_SHA, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Prepared ref $($env:PREPARED_REF) does not resolve to PREPARED_SHA $($env:PREPARED_SHA)."
}
$parentCommit = git rev-parse --verify "$($env:PREPARED_SHA)^"
if ($LASTEXITCODE -ne 0) {
  throw 'Prepared source commit has no first parent.'
}
$upstreamParent = git rev-parse --verify "$($env:PREPARED_SHA)~2"
if ($LASTEXITCODE -ne 0 -or -not [string]::Equals("$upstreamParent".Trim(), $env:UPSTREAM_SHA, [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Prepared source commit must be exactly two commits beyond UPSTREAM_SHA.'
}
$preparedCommits = @(git rev-list --merges "$($env:UPSTREAM_SHA)..$($env:PREPARED_SHA)")
if ($LASTEXITCODE -ne 0 -or $preparedCommits.Count -ne 0) {
  throw 'Prepared source range contains merge commits or could not be verified.'
}

git tag $tagName $env:PREPARED_SHA
if ($LASTEXITCODE -ne 0) {
  throw "Unable to create local tag $tagName."
}
$tagCommit = git rev-parse --verify "$tagName^{commit}"
if ($LASTEXITCODE -ne 0 -or -not [string]::Equals("$tagCommit".Trim(), $env:PREPARED_SHA, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Created tag $tagName does not point to PREPARED_SHA."
}

git push origin $tagName
if ($LASTEXITCODE -ne 0) {
  throw "Unable to push tag $tagName to origin."
}
$pushedTag = git ls-remote --tags origin "refs/tags/$tagName" "refs/tags/$tagName^{}"
if ($LASTEXITCODE -ne 0) {
  throw "Unable to verify pushed remote tag $tagName."
}
$pushedTagLines = @($pushedTag | ForEach-Object { "$($_)".Trim() } | Where-Object { $_ })
$peeledTag = @($pushedTagLines | Where-Object { $_ -match "\srefs/tags/$([regex]::Escape($tagName))\^\{\}$" })
$directTag = @($pushedTagLines | Where-Object { $_ -match "\srefs/tags/$([regex]::Escape($tagName))$" })
$remoteTagCommit = if ($peeledTag.Count -eq 1) { ($peeledTag[0] -split '\s+')[0] } elseif ($directTag.Count -eq 1) { ($directTag[0] -split '\s+')[0] } else { '' }
if (-not [string]::Equals($remoteTagCommit, $env:PREPARED_SHA, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Remote tag $tagName does not resolve to PREPARED_SHA $($env:PREPARED_SHA)."
}

$releaseArgs = @('release', 'create', $tagName) + @(
  (Join-Path $artifactRoot $expectedZipNames[0]),
  (Join-Path $artifactRoot $expectedZipNames[1]),
  (Join-Path $artifactRoot $expectedChecksumNames[0]),
  (Join-Path $artifactRoot $expectedChecksumNames[1]),
  (Join-Path $artifactRoot $expectedBuildInfoNames[0]),
  (Join-Path $artifactRoot $expectedBuildInfoNames[1]),
  '--repo', $env:GITHUB_REPOSITORY,
  '--title', $tagName,
  '--notes', $releaseNotes,
  '--verify-tag',
  '--prerelease',
  '--latest=false'
)
& gh @releaseArgs
if ($LASTEXITCODE -ne 0) {
  throw "GitHub release creation failed for $tagName."
}
