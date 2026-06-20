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

git remote add upstream $env:UPSTREAM_REPO 2>$null
git fetch upstream '+refs/heads/*:refs/remotes/upstream/*' '+refs/tags/*:refs/tags/*' --force
git fetch origin "+refs/heads/$($env:PATCH_BRANCH):refs/remotes/origin/$($env:PATCH_BRANCH)" --force

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

$baseRef = if ($env:UPSTREAM_REF -eq 'dev') { 'refs/remotes/upstream/dev' } else { "refs/tags/$($env:UPSTREAM_REF)" }
git rev-parse --verify $baseRef
git rev-parse --verify "refs/remotes/origin/$($env:PATCH_BRANCH)"

$baseCommit = git rev-parse $baseRef
$patchCommit = git rev-parse "refs/remotes/origin/$($env:PATCH_BRANCH)"
$workBranch = "generated-$tagName"
git checkout -b $workBranch $baseRef
git merge --no-edit "refs/remotes/origin/$($env:PATCH_BRANCH)"
$mergeCommit = git rev-parse HEAD

& bun --version
& bun install
& bun ./packages/opencode/script/build.ts --single

$releaseRoot = Join-Path $env:RUNNER_TEMP $tagName
New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null
$buildOutput = Get-ChildItem -Path 'packages/opencode/dist' -Directory -Filter 'opencode-windows-*' | Sort-Object Name | Select-Object -First 1
if (-not $buildOutput) {
  throw 'No packages/opencode/dist/opencode-windows-* build output found.'
}
$binaryRoot = Join-Path $buildOutput.FullName 'bin'
if (-not (Test-Path -LiteralPath (Join-Path $binaryRoot 'opencode.exe'))) {
  throw "Expected opencode.exe under $binaryRoot."
}

$buildInfo = @"
# Unofficial OpenCode PR #26861 verification build

This is not an official OpenCode release.

Purpose:
Test lazy-scroll loading for old/new TUI messages.

Official upstream ref: $env:UPSTREAM_REF
Source repository: $env:UPSTREAM_REPO
Official base commit: $baseCommit

Patch branch: $env:PATCH_BRANCH
Patch commit: $patchCommit

Generated merge commit: $mergeCommit
Built at: $(Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')
Runner: windows-latest
Build command: bun ./packages/opencode/script/build.ts --single

Please verify:
- scrolling near the top loads older messages
- scrolling near the bottom loads newer messages
- old messages no longer disappear during long sessions
- Timeline dialog loads the complete session
"@
$buildInfoPath = Join-Path $releaseRoot 'BUILD_INFO.md'
Set-Content -LiteralPath $buildInfoPath -Value $buildInfo -NoNewline

$installNotes = @'
# Testing this unofficial Windows build

This is not an official OpenCode release. It is intended only for verifying PR #26861.

## Running the binary

The zip layout matches the official Windows CLI zip: the bin contents are at the archive root.

1. Extract the zip into a temporary directory, for example:

   ```powershell
   Expand-Archive .\{{TAG_NAME}}.zip -DestinationPath "$env:TEMP\opencode-pr-7380"
   ```

2. Run the test build directly:

   ```powershell
   & "$env:TEMP\opencode-pr-7380\opencode.exe" --version
   & "$env:TEMP\opencode-pr-7380\opencode.exe" <your-project-directory>
   ```

3. Or put the extracted directory on PATH temporarily for the current shell:

   ```powershell
   $env:PATH = "$env:TEMP\opencode-pr-7380;$env:PATH"
   opencode <your-project-directory>
   ```

## Reusing existing sessions

OpenCode stores sessions in the local SQLite database under the OpenCode data directory. On Windows this is usually:

```text
%LOCALAPPDATA%\opencode\opencode.db
```

If your installed version uses channel-specific databases, the file can instead be named like:

```text
%LOCALAPPDATA%\opencode\opencode-<channel>.db
```

To test against your existing sessions without risking your live database, copy the database while OpenCode is closed. The wildcard also copies SQLite WAL sidecar files if present:

```powershell
Stop-Process -Name opencode -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$env:TEMP\opencode-pr-7380-data" | Out-Null
Copy-Item "$env:LOCALAPPDATA\opencode\opencode.db*" "$env:TEMP\opencode-pr-7380-data\"
```

Then run the test build against the copied database:

```powershell
$env:OPENCODE_DB = "$env:TEMP\opencode-pr-7380-data\opencode.db"
& "$env:TEMP\opencode-pr-7380\opencode.exe" <your-project-directory>
```

If your source database is channel-specific, replace opencode.db in the Copy-Item command with the actual file name.

Unset OPENCODE_DB or open a new terminal to return to the normal database.
'@.Replace('{{TAG_NAME}}', $tagName)
$installNotesPath = Join-Path $releaseRoot 'INSTALL_NOTES.md'
Set-Content -LiteralPath $installNotesPath -Value $installNotes -NoNewline

$releaseNotes = @'
# Unofficial PR #26861 verification build for OpenCode {{UPSTREAM_REF}}

This is an unofficial verification build for testing PR #26861.

It is based on official OpenCode '{{UPSTREAM_REF}}' plus the lazy-scroll message loading changes from '{{PATCH_BRANCH}}'.

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

The Windows zip has the same root layout as the official CLI zip: extract it and run opencode.exe from the extracted directory. See INSTALL_NOTES.md for commands, including how to copy opencode.db and test with existing sessions safely.
'@.Replace('{{UPSTREAM_REF}}', $env:UPSTREAM_REF).Replace('{{PATCH_BRANCH}}', $env:PATCH_BRANCH)

$zipPath = Join-Path $releaseRoot "$tagName.zip"
Compress-Archive -Path (Join-Path $binaryRoot '*') -DestinationPath $zipPath -Force

@($zipPath, $buildInfoPath, $installNotesPath) | ForEach-Object {
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash.ToLowerInvariant()
  "$hash  $(Split-Path -Leaf $_)"
} | Set-Content -LiteralPath (Join-Path $releaseRoot 'SHA256SUMS.txt')

git tag -f $tagName
git push origin $tagName --force

$releaseArgs = @(
  'release', 'create', $tagName,
  $zipPath,
  $buildInfoPath,
  $installNotesPath,
  (Join-Path $releaseRoot 'SHA256SUMS.txt'),
  '--title', $releaseName,
  '--notes', $releaseNotes
)
if ($env:PRERELEASE -eq 'true') {
  $releaseArgs += '--prerelease'
}

& gh @releaseArgs
