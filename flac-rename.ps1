<#
.SYNOPSIS
    Enables an efficient music library by removing repeated information.
    Watches requested folder(s) for new .flac files, strips the "Artist - Album - "
    prefix from their filenames. Marks those [sub]folders using Explorer's Music template
    to standardize the columns visible when browsing them in Explorer.

.DESCRIPTION
    - IMPORTANT: requires one-time manual action for full functionality (see ONE TIME ACTION below)
    - IMPORTANT: written for win10. not yet tested on win11 (i'll upgrade one of these days)

    -------------------------
    - MISSION STATEMENT

    I like my music library to be structured as such:

    tunes/
    ├─ artist/
    │  ├─ [year] album/
    │  │  ├─ 00 track name

    Nice and clean, no repeated information. However:
        1 --> Depending on where you found them, tracks might come with the artist and/or album names 
              embedded in the song titles, and
        2 --> By default, Windows' Music folder template repeats basically every piece of information
              gleaned by this structure. 

    So this script aims to:
        1 --> Standardize track filenames 
        2 --> Enforce a Music folder template with no repeated information

    tldr: "Artist Name - Album Name - 01 Track Name.flac"  -->  "01 Track Name.flac"

    -------------------------
    - ONE TIME ACTION

    The script marks any folder directly containing at least one .flac is marked in Explorer using the Music folder 
    template via desktop.ini. However, template column layouts are stored in an undocumented binary blob in registry,
    so column layout must be set manually in one applicable Music folder:

        1 --> In Explorer, browse directly to any folder this script has tagged
              (not via Library/This PC: this prevents Apply to Folders [deeply unserious operating system])
        2 --> Ribbon > View tab > Details
        3 --> Right-click column header row > More... and check your desired fields
              (default: Name, Length, Type, Size)
        4 --> Ribbon > View tab > Options > Change folder and search options
        5 --> In Folder Options dialog: View tab > Apply to Folders > Yes

    Windows will then apply this layout to every folder marked as Music by this script. 

    -------------------------
    - FEATURES

    Designed for continuous operation via Task Scheduler:
      --> Mutex prevents overlapping task starts
      --> FileSystemWatcher reacts to new downloads
      --> Periodic full sweep acts as safety net for disconnected drives, etc.
      --> Independent FileSystemWatcher per root prevents offline drive from crashing task
      --> File idle/unlocked threshold (default: 15s) to avoid renaming in-progress downloads
      --> Self-healing: recreates watcher if drive drops or watcher errors
      --> Log rotation (default: 15MB)

    Idempotence: once renamed, files no longer matches the trigger pattern.

    Preserves number-leading titles (e.g. "99 Red Balloons"):
        --> First tries to match track # at position 0
        --> If that fails, consumes a prefix 
    
        e.g. for "Artist - Album - 01 - 99 Red Balloons" the leading text forces the prefix 
        branch and the track is 01, while in an already-renamed "01 Live - Tokyo - 12 Bar Blues",
        the no-prefix branch wins, and the name is left alone instead of being re-cut at "12".#

        Track number and title are captured separately so whatever separator sits between
        them (" - ", ".", "_", "-") is discarded and replaced with a single space. Hyphens
        inside the title itself are untouched.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "E:\scripts\flac-rename.ps1"

.EXAMPLE
    # dry run against current contents, then exit
    .\flac-rename.ps1 -RunOnce -WhatIfMode
#>

[CmdletBinding()]
param(
    # folder trees to monitor, each watched + swept independently
    [string[]]$Roots = @('E:\downloads\complete', 'E:\music\tunes'),

    [string]$LogPath = 'E:\log\flac-rename.log',

    # full sweep interval, in seconds
    [int]$SweepSeconds = 300,

    # file must be idle (unmodified+unlocked) for this long before renaming
    [int]$FileIdleSeconds = 15,

    # watcher event (scan) interval
    [int]$DebounceSeconds = 5,

    # log rotation threshold
    [int]$LogMaxMB = 5,

    # explorer folder template applied to folders containing .flac files
    [ValidateSet('Music', 'Generic', 'Documents', 'Pictures', 'Videos')]
    [string]$FolderTemplate = 'Music',

    # skip desktop.ini / folder template work entirely
    [switch]$SkipFolderTemplates,

    # report what would be renamed without renaming anything
    [switch]$WhatIfMode,

    # do a single pass and exit (useful for testing).
    [switch]$RunOnce
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


# "Artist - Album - " prefix is optional AND lazily optional ('??'):
$script:TrackPattern = '^(?:.+?\s-\s.+?\s-\s)??(?<track>\d{1,3})[\s._-]+(?<title>\S.*)$'

#region Helpers ----------------------------------------------------------------

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }

    if (-not $LogPath) { return }

    try {
        if (Test-Path -LiteralPath $LogPath) {
            $log = Get-Item -LiteralPath $LogPath
            if ($log.Length -gt ($LogMaxMB * 1MB)) {
                Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force
            }
        }
        else {
            $dir = Split-Path -Parent $LogPath
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }
    catch {
        # don't let logging kill the daemon
        Write-Host "logging failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Test-FileReady {
    <# Checks if the file is idle (per our threshold) and not held open by another process. #>
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)

    if ((Get-Date) - $File.LastWriteTime -lt [TimeSpan]::FromSeconds($FileIdleSeconds)) {
        return $false
    }

    try {
        $stream = [System.IO.File]::Open(
            $File.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None)
        $stream.Close()
        $stream.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

function Get-StrippedName {
    <#  Returns the new stripped filename, or $null if the name doesn't match the expected pattern. #>
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)

    $base = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $m = [regex]::Match($base, $script:TrackPattern)
    if (-not $m.Success) { return $null }

    $track = $m.Groups['track'].Value
    $title = $m.Groups['title'].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($title)) { return $null }

    return ('{0} {1}{2}' -f $track, $title, $File.Extension)
}

function Set-FolderTemplate {
    <#
        Writes/updates desktop.ini so Explorer treats the folder as $FolderType.
        Returns $true if anything was changed, $false if already correct.

        Per MS docs, the folder must carry the read-only (or system) bit for Explorer
        to honor desktop.ini, and desktop.ini itself must be hidden+system and Unicode.
        Existing desktop.ini content (custom icons, infotips) is preserved.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FolderType
    )

    $ini = Join-Path $Path 'desktop.ini'
    $desired = "FolderType=$FolderType"
    $contentChanged = $false
    $lines = @()

    if (Test-Path -LiteralPath $ini) {
        $lines = @(Get-Content -LiteralPath $ini -Force -ErrorAction Stop)

        $ftIndex = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*FolderType\s*=') { $ftIndex = $i; break }
        }

        if ($ftIndex -ge 0) {
            if ($lines[$ftIndex].Trim() -ne $desired) {
                $lines[$ftIndex] = $desired
                $contentChanged = $true
            }
        }
        else {
            # insert into an existing [ViewState] section or append a new one
            $vsIndex = -1
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*\[ViewState\]\s*$') { $vsIndex = $i; break }
            }
            if ($vsIndex -ge 0) {
                $lines = @($lines[0..$vsIndex]) + @($desired) +
                         @($lines[($vsIndex + 1)..($lines.Count - 1)] | Where-Object { $null -ne $_ })
            }
            else {
                $lines = @($lines) + @('[ViewState]', 'Mode=', 'Vid=', $desired)
            }
            $contentChanged = $true
        }
    }
    else {
        $lines = @('[ViewState]', 'Mode=', 'Vid=', $desired)
        $contentChanged = $true
    }

    # attr are checked even when content is already correct -- Explorer ignores desktop.ini
    # if the folder lost its read-only bit (common after move/copy).
    $dir = Get-Item -LiteralPath $Path -Force
    $dirNeedsFix = -not ($dir.Attributes -band [System.IO.FileAttributes]::ReadOnly)

    $iniNeedsFix = $false
    if (-not $contentChanged -and (Test-Path -LiteralPath $ini)) {
        $iniItem = Get-Item -LiteralPath $ini -Force
        $iniNeedsFix = -not (($iniItem.Attributes -band [System.IO.FileAttributes]::Hidden) -and
                             ($iniItem.Attributes -band [System.IO.FileAttributes]::System))
    }

    if (-not $contentChanged -and -not $dirNeedsFix -and -not $iniNeedsFix) {
        return $false
    }

    if ($WhatIfMode) {
        Write-Log "WOULD TAG: $Path -> $desired"
        return $true
    }

    if ($contentChanged) {
        # Hidden+system files can't be overwritten in place; clear, write, restore.
        if (Test-Path -LiteralPath $ini) {
            (Get-Item -LiteralPath $ini -Force).Attributes = [System.IO.FileAttributes]::Normal
        }
        # Unicode (UTF-16LE) is required by the shell.
        Set-Content -LiteralPath $ini -Value $lines -Encoding Unicode -Force -ErrorAction Stop
    }

    (Get-Item -LiteralPath $ini -Force).Attributes =
        [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System

    if ($dirNeedsFix) {
        $dir.Attributes = $dir.Attributes -bor [System.IO.FileAttributes]::ReadOnly
    }

    return $true
}

function Invoke-Scan {
    <#  One full pass over the tree. Idempotent. #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "root not available: $Path" 'WARN'
        return
    }

    $renamed = 0
    $deferred = 0
    $tagged = 0

    # case-insensitive set of directories that directly contain at least one .flac.
    $flacDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    $files = @(Get-ChildItem -LiteralPath $Path -Filter '*.flac' -File -Recurse -Force -ErrorAction SilentlyContinue)

    foreach ($file in $files) {
        try {
            [void]$flacDirs.Add($file.DirectoryName)

            $newName = Get-StrippedName -File $file
            if (-not $newName) { continue }
            if ($newName -eq $file.Name) { continue }

            if (-not (Test-FileReady -File $file)) {
                $deferred++
                continue
            }

            $target = Join-Path $file.DirectoryName $newName
            if (Test-Path -LiteralPath $target) {
                Write-Log "SKIP (target exists): $($file.FullName) -> $newName" 'WARN'
                continue
            }

            if ($WhatIfMode) {
                Write-Log "WOULD RENAME: $($file.FullName) -> $newName"
            }
            else {
                Rename-Item -LiteralPath $file.FullName -NewName $newName -ErrorAction Stop
                Write-Log "RENAMED: $($file.FullName) -> $newName"
            }
            $renamed++
        }
        catch {
            Write-Log "FAILED on $($file.FullName): $($_.Exception.Message)" 'ERROR'
        }
    }

    if (-not $SkipFolderTemplates) {
        foreach ($dir in $flacDirs) {
            try {
                if (Set-FolderTemplate -Path $dir -FolderType $FolderTemplate) {
                    $tagged++
                    if (-not $WhatIfMode) {
                        Write-Log "TAGGED: $dir -> FolderType=$FolderTemplate"
                    }
                }
            }
            catch {
                Write-Log "TAG FAILED on ${dir}: $($_.Exception.Message)" 'ERROR'
            }
        }
    }

    Write-Log ("scan complete [{0}]. files seen: {1}. renamed: {2}. deferred (still writing/locked): {3}. folders tagged: {4} of {5}." -f `
        $Path, $files.Count, $renamed, $deferred, $tagged, $flacDirs.Count)
}

function New-Watcher {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$State,
        # unique per-root suffix to prevent event source identifiers collision
        [Parameter(Mandatory)][int]$Index
    )

    $fsw = New-Object System.IO.FileSystemWatcher
    $fsw.Path = $Path
    $fsw.Filter = '*.*'
    $fsw.IncludeSubdirectories = $true
    $fsw.InternalBufferSize = 65536   # max; reduces missed-event overflows
    $fsw.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor
                        [System.IO.NotifyFilters]::DirectoryName -bor
                        [System.IO.NotifyFilters]::LastWrite

    $action = {
        $s = $Event.MessageData
        $s.Dirty = $true
        $s.LastEvent = Get-Date
    }

    foreach ($evt in 'Created', 'Renamed', 'Changed') {
        Register-ObjectEvent -InputObject $fsw -EventName $evt `
            -SourceIdentifier "FlacWatch_${Index}_$evt" -MessageData $State -Action $action | Out-Null
    }

    Register-ObjectEvent -InputObject $fsw -EventName 'Error' `
        -SourceIdentifier "FlacWatch_${Index}_Error" -MessageData $State -Action {
            $s = $Event.MessageData
            $s.Dirty = $true
            $s.Broken = $true
            $s.LastEvent = Get-Date
        } | Out-Null

    $fsw.EnableRaisingEvents = $true
    return $fsw
}

function Remove-Watchers {
    param([hashtable]$Watchers)

    Get-EventSubscriber -SourceIdentifier 'FlacWatch_*' -ErrorAction SilentlyContinue |
        Unregister-Event -Force -ErrorAction SilentlyContinue
    Get-Job -Name 'FlacWatch_*' -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue

    if ($Watchers) {
        foreach ($w in $Watchers.Values) {
            if ($w) {
                try {
                    $w.EnableRaisingEvents = $false
                    $w.Dispose()
                } catch { }
            }
        }
        $Watchers.Clear()
    }
}

#endregion ---------------------------------------------------------------------

#region Main -------------------------------------------------------------------

# single-instance guard. Global\ so it holds across sessions/users.
$mutex = New-Object System.Threading.Mutex($false, 'Global\Watch-FlacRename')
if (-not $mutex.WaitOne(0)) {
    Write-Log 'EXIT: another instance is already running' 'WARN'
    exit 0
}

$state = [hashtable]::Synchronized(@{
    Dirty     = $true
    Broken    = $false
    LastEvent = Get-Date
})

# root path -> live FileSystemWatcher. root with no entry is currently unwatched
# (missing drive, failed rebuild) and gets retried on the next loop pass.
$watchers = @{}

try {
    Write-Log ("starting. pid=$PID roots='$($Roots -join "', '")' sweep=${SweepSeconds}s settle=${FileIdleSeconds}s " +
               "template=$(if ($SkipFolderTemplates) { 'disabled' } else { $FolderTemplate }) WhatIf=$($WhatIfMode.IsPresent)")

    if ($RunOnce) {
        foreach ($root in $Roots) { Invoke-Scan -Path $root }
        Write-Log 'EXIT: RunOnce complete'
        exit 0
    }

    $lastSweep = Get-Date

    while ($true) {
        # (re)build missing/dead watchers 
        # $state.Broken is set by error event handler and can't identify which watcher failed, so rebuild all.
        if ($state.Broken) {
            Write-Log 'watcher error reported; rebuilding all watchers.' 'WARN'
            Remove-Watchers -Watchers $watchers
            $state.Broken = $false
            $state.Dirty = $true
        }

        for ($i = 0; $i -lt $Roots.Count; $i++) {
            $root = $Roots[$i]
            $live = $watchers.ContainsKey($root) -and $watchers[$root] -and $watchers[$root].EnableRaisingEvents
            if ($live) { continue }
            if (-not (Test-Path -LiteralPath $root)) { continue }

            try {
                $watchers[$root] = New-Watcher -Path $root -State $state -Index $i
                $state.Dirty = $true
                Write-Log "watching: $root"
            }
            catch {
                Write-Log "watcher setup failed for ${root}: $($_.Exception.Message)" 'ERROR'
            }
        }

        Start-Sleep -Seconds 2

        $now = Get-Date
        $debounced = $state.Dirty -and (($now - $state.LastEvent).TotalSeconds -ge $DebounceSeconds)
        $sweepDue  = ($now - $lastSweep).TotalSeconds -ge $SweepSeconds

        if ($debounced -or $sweepDue) {
            $state.Dirty = $false
            $lastSweep = $now
            foreach ($root in $Roots) {
                try {
                    Invoke-Scan -Path $root
                }
                catch {
                    Write-Log "scan error on ${root}: $($_.Exception.Message)" 'ERROR'
                }
            }
        }
    }
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    exit 1
}
finally {
    Remove-Watchers -Watchers $watchers
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
    Write-Log 'stopped.'
}

#endregion
