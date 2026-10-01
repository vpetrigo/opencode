# Testing unofficial PR #26861 builds

These builds are not official OpenCode releases. They are intended only for verifying PR #26861.

## Running a downloaded binary

The Windows zip layout matches the official Windows CLI zip: the `bin` contents are at the archive root.

```powershell
Expand-Archive .\opencode-windows-x64.zip -DestinationPath "$env:TEMP\opencode-pr-7380"
& "$env:TEMP\opencode-pr-7380\opencode.exe" --version
& "$env:TEMP\opencode-pr-7380\opencode.exe" <your-project-directory>
```

To put the extracted directory on `PATH` for the current PowerShell session:

```powershell
$env:PATH = "$env:TEMP\opencode-pr-7380;$env:PATH"
opencode <your-project-directory>
```

## Reusing existing sessions on Windows

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

If your source database is channel-specific, replace `opencode.db` in the `Copy-Item` command with the actual file name.

Unset `OPENCODE_DB` or open a new terminal to return to the normal database.

## Experimental patched OpenCode v2.0.21 fixture testing

The v2 ZIP contains an `opencode`/`opencode.exe` binary built from the official OpenCode v2.0.21 full TUI source with pagination changes; it is an unofficial, experimental patched build, not the v1 build or a pristine v2.0.21 release. Keep it in a separate directory, never overwrite or replace a PATH-installed v1 executable, and use only a disposable fixture database. Set both `OPENCODE_DB` and `XDG_STATE_HOME` to fresh, absolute, fixture-specific paths for every run. Launch with `--standalone` so the private server cannot reuse the normal managed service configuration or override the fixture database; do not stop or modify your live daemon. The fixture contains 60 sessions and 250 messages to exercise pagination across long histories.

Generate a long-session fixture from the v2 source checkout into a new absolute temporary path (do not reuse a live database):

```powershell
$runId = [guid]::NewGuid().ToString('N')
$runRoot = Join-Path $env:TEMP "opencode-v2-fixture-$runId"
$fixture = Join-Path $runRoot 'opencode.db'
$env:XDG_STATE_HOME = Join-Path $runRoot 'state'
New-Item -ItemType Directory -Force $runRoot, $env:XDG_STATE_HOME | Out-Null
bun .\packages\core\script\fixture-v2-pagination.ts $fixture
Expand-Archive .\opencode-v2-windows-x64.zip -DestinationPath (Join-Path $runRoot 'binary')
$env:OPENCODE_DB = $fixture
Set-Location $runRoot
& (Join-Path $runRoot 'binary\opencode.exe') --standalone
```

For Linux, run these from the patched official v2.0.21 v2-pagination source checkout; each run gets its own absolute fixture, state, and binary paths. The fixture script's output path must be absolute. It creates 60 sessions with 250 messages total. Change to the fixture run directory before invoking the binary to select that project location.

```bash
run_root="$(mktemp -d /tmp/opencode-v2-fixture.XXXXXX)"
fixture="$run_root/opencode.db"
export XDG_STATE_HOME="$run_root/state"
mkdir -p "$XDG_STATE_HOME" "$run_root/binary"
bun ./packages/core/script/fixture-v2-pagination.ts "$fixture"
unzip opencode-v2-linux-x64.zip -d "$run_root/binary"
chmod +x "$run_root/binary/opencode"
export OPENCODE_DB="$fixture"
cd "$run_root"
"$run_root/binary/opencode" --standalone
```

Unset `OPENCODE_DB` and `XDG_STATE_HOME` or use a fresh terminal after testing. Keep the unique run directory for each test; `--standalone` keeps its server and credential separate from your managed OpenCode service.

## Linux x64

Extract the Linux archive and run `opencode` from the extracted directory:

```bash
mkdir -p /tmp/opencode-pr-7380
unzip opencode-linux-x64.zip -d /tmp/opencode-pr-7380
/tmp/opencode-pr-7380/opencode --version
/tmp/opencode-pr-7380/opencode <your-project-directory>
```

## Reusing existing sessions on Linux

OpenCode stores sessions in the local SQLite database under the OpenCode data directory. On Linux this is usually:

```text
~/.local/share/opencode/opencode.db
```

If `XDG_DATA_HOME` is set, use this path instead:

```text
$XDG_DATA_HOME/opencode/opencode.db
```

If your installed version uses channel-specific databases, the file can instead be named like:

```text
opencode-<channel>.db
```

To test against your existing sessions without risking your live database, copy the database while OpenCode is closed. The wildcard also copies SQLite WAL sidecar files if present:

```bash
pkill opencode || true
mkdir -p /tmp/opencode-pr-7380-data
cp "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db"* /tmp/opencode-pr-7380-data/
```

Then run the test build against the copied database:

```bash
OPENCODE_DB=/tmp/opencode-pr-7380-data/opencode.db /tmp/opencode-pr-7380/opencode <your-project-directory>
```

If your source database is channel-specific, replace `opencode.db` in the `cp` command with the actual file name.
