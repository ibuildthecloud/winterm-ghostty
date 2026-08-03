<#
.SYNOPSIS
    Measure terminal throughput by timing `cat` of a fixed corpus inside it.

.DESCRIPTION
    The child writes to the pty; when the terminal cannot drain it fast enough
    the write blocks. So the wall time `cat` takes, measured by the child
    itself, is a measure of the terminal rather than of the shell. This is the
    usual way terminal throughput is compared, and it is what the Phase 3 plan
    asks for ("measure cat-a-large-file throughput vs wintty and WT").

    The corpus is generated once and is deterministic, so runs are comparable
    across builds and across terminals. It deliberately mixes plain ASCII, SGR
    colour changes and UTF-8: a corpus of only plain ASCII measures the fast
    path and little else.

    IMPORTANT: build ReleaseFast. scripts/build-ghostty.ps1 defaults to Debug,
    which carries full safety checks and is several times slower - a Debug
    number says nothing useful.

    IMPORTANT: run this on a CONNECTED session. When an RDP session is
    detached, DWM stops compositing and presentation behaviour changes, so the
    numbers do not reflect what a user would see.

.EXAMPLE
    .\scripts\bench-throughput.ps1
    .\scripts\bench-throughput.ps1 -SizeMB 32 -Runs 5
#>
[CmdletBinding()]
param(
    # Corpus size. Large enough that startup cost is noise, small enough to
    # iterate on.
    [int] $SizeMB = 16,

    [int] $Runs = 3,

    # Where the harness lives.
    [string] $Harness = (Join-Path $PSScriptRoot '..\harness\hwnd-host\hwnd-host.exe'),

    # Skip the connected-session check. The numbers will be suspect.
    [switch] $AllowDetached
)

$ErrorActionPreference = 'Stop'

$corpusWin = 'C:\temp\ghostty-bench-corpus.txt'
$resultWin = 'C:\temp\ghostty-bench-result.txt'
$corpusWsl = '/mnt/c/temp/ghostty-bench-corpus.txt'
$resultWsl = '/mnt/c/temp/ghostty-bench-result.txt'

New-Item -ItemType Directory -Force C:\temp | Out-Null

# --- session check -------------------------------------------------------
$sessionLine = (query session 2>&1 | Where-Object { $_ -match '^>' })
if ($sessionLine -and $sessionLine -match 'Disc') {
    if (-not $AllowDetached) {
        throw "This RDP session is detached. DWM stops compositing, so throughput numbers are not representative. Reconnect, or pass -AllowDetached to measure anyway."
    }
    Write-Warning "Session is detached; numbers are not representative."
}

# --- corpus --------------------------------------------------------------
$targetBytes = $SizeMB * 1MB
if ((-not (Test-Path $corpusWin)) -or ((Get-Item $corpusWin).Length -lt $targetBytes)) {
    Write-Host "generating ${SizeMB}MB corpus..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $fs = [System.IO.StreamWriter]::new($corpusWin, $false, (New-Object Text.UTF8Encoding $false))
    try {
        # Deterministic: a fixed rotation rather than random, so two runs and
        # two terminals see byte-identical input.
        $plain = 'The quick brown fox jumps over the lazy dog 0123456789 '
        $cjk = [char]::ConvertFromUtf32(0x4E2D) + [char]::ConvertFromUtf32(0x6587)
        $i = 0
        while ($fs.BaseStream.Length -lt $targetBytes) {
            switch ($i % 8) {
                0 { $fs.WriteLine($plain * 2) }
                1 { $fs.WriteLine("`e[31m$plain`e[0m") }
                2 { $fs.WriteLine("`e[1;32m$plain`e[0m") }
                3 { $fs.WriteLine("$plain$cjk$plain") }
                4 { $fs.WriteLine("`e[38;5;208m$plain`e[0m") }
                5 { $fs.WriteLine($plain) }
                6 { $fs.WriteLine("`e[7m$plain`e[0m") }   # reverse video
                7 { $fs.WriteLine("$cjk$cjk$cjk $plain") }
            }
            $i++
        }
    } finally { $fs.Dispose() }
    $sw.Stop()
    Write-Host ("corpus: {0:N0} bytes in {1:N1}s" -f (Get-Item $corpusWin).Length, $sw.Elapsed.TotalSeconds)
}
$corpusBytes = (Get-Item $corpusWin).Length

# --- probe script, run inside the terminal -------------------------------
# The child times itself: date before, cat, date after. Nothing here depends
# on the host being able to see the window.
$probe = @"
#!/bin/sh
s=`$(date +%s%N)
cat $corpusWsl
e=`$(date +%s%N)
echo `$(( (e - s) / 1000000 )) > $resultWsl
"@
$probe = $probe -replace "`r`n", "`n"
[IO.File]::WriteAllText('C:\temp\ghostty-bench.sh', $probe, (New-Object Text.UTF8Encoding $false))
# Everything touching `~` has to stay inside a single-quoted string: PowerShell
# expands a bare `~` to the Windows profile path before wsl.exe ever sees it,
# which silently copies the probe to a nonexistent location.
wsl.exe -- sh -c 'cp /mnt/c/temp/ghostty-bench.sh "$HOME/ghostty-bench.sh" && chmod +x "$HOME/ghostty-bench.sh"'
$probeWsl = (wsl.exe -- sh -c 'echo $HOME/ghostty-bench.sh').Trim()
wsl.exe -- test -x $probeWsl
if ($LASTEXITCODE -ne 0) { throw "probe script not executable at $probeWsl" }

# --- runs ----------------------------------------------------------------
$times = @()
for ($r = 1; $r -le $Runs; $r++) {
    Remove-Item $resultWin -ErrorAction SilentlyContinue
    Get-Process hwnd-host -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 400

    $p = Start-Process $Harness -PassThru -ArgumentList "--command=`"wsl.exe -e $probeWsl`""
    $deadline = (Get-Date).AddSeconds(180)
    while (-not (Test-Path $resultWin) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $resultWin)) {
        Write-Warning "run $r produced no result (timed out)"
        continue
    }
    $ms = [int](Get-Content $resultWin | Select-Object -First 1)
    $mbps = $corpusBytes / 1MB / ($ms / 1000.0)
    $times += [PSCustomObject]@{ Run = $r; Ms = $ms; MBps = [math]::Round($mbps, 1) }
    "run {0}: {1,6} ms  {2,6:N1} MB/s" -f $r, $ms, $mbps
}

if ($times.Count -eq 0) { throw "no successful runs" }

$best = ($times | Measure-Object -Property Ms -Minimum).Minimum
$median = ($times | Sort-Object Ms | Select-Object -Skip ([int]($times.Count / 2)) -First 1).Ms
""
"corpus : {0:N0} bytes ({1} MB)" -f $corpusBytes, $SizeMB
"best   : {0} ms  ({1:N1} MB/s)" -f $best, ($corpusBytes / 1MB / ($best / 1000.0))
"median : {0} ms  ({1:N1} MB/s)" -f $median, ($corpusBytes / 1MB / ($median / 1000.0))
