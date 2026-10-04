# 3dp-sort-gf.ps1
# watches e:/3dp and auto-sorts gridfinity bins
# renames files to lowercase and replaces spaces with single dashes

$Source = "E:\3dp"
$Target = "E:\3dp\gf\bins"

if (-not (Test-Path $Target)) {
    New-Item -ItemType Directory -Path $Target | Out-Null
}

function Wait-ForFileReady($path, $timeout = 60) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeout) {
        try {
            $fs = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
            $fs.Close()
            return $true
        } catch {
            Start-Sleep -Milliseconds 300
        }
    }
    return $false
}

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $Source
$watcher.Filter = "*"
$watcher.IncludeSubdirectories = $false
$watcher.EnableRaisingEvents = $true

$action = {
    $path = $Event.SourceEventArgs.FullPath
    if (-not (Test-Path $path)) { return }

    $name = [System.IO.Path]::GetFileName($path)

    if ($name -notlike "box-*") { return }

    if (-not (Wait-ForFileReady $path)) { return }

    $dest = Join-Path $Target $name

    # avoid overwrite
    if (Test-Path $dest) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
        $ext  = [System.IO.Path]::GetExtension($name)
        $i = 1
        do {
            $dest = Join-Path $Target ("{0}-{1}{2}" -f $base, $i, $ext)
            $i++
        } while (Test-Path $dest)
    }

    Move-Item -LiteralPath $path -Destination $dest
}

Register-ObjectEvent $watcher Created -Action $action | Out-Null
Register-ObjectEvent $watcher Renamed -Action $action | Out-Null

while ($true) { Start-Sleep 5 }

