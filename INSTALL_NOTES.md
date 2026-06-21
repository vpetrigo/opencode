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
