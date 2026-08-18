<#
.SYNOPSIS
    Collect the PDBs for a published build into a symbols ZIP.

.DESCRIPTION
    KD-12: a user's portable build double-freed and died, Windows kept a full
    dump, and the three frames that mattered could not be named - the release
    ships no PDBs, and nothing on any developer machine matches a binary built
    by CI. The dump was reduced to "somewhere in libghostty".

    So every release now carries its own symbols, and they are matched to the
    binaries the way a debugger matches them: by the CodeView record in the
    image, not by filename. A PDB with the right name and the wrong GUID
    resolves addresses to confidently wrong functions, which is worse than no
    symbols at all - so the GUID and age of every pairing go into SYMBOLS.txt,
    where a future triage can check them against the dump's own module record
    (`lmvm <module>`).

    Binaries whose PDB is not on this machine - Microsoft.UI.Xaml.dll and the
    rest of the redistributed WinUI set - are listed as missing rather than
    silently dropped. Their absence is a fact about the build, not an error.

.PARAMETER Zip
    The portable ZIP to collect symbols for. Defaults to the newest
    *-portable.zip in dist/. Its binaries are the definition of "published".

.PARAMETER Layout
    A loose directory of binaries instead of a ZIP. For exercising the
    collector against a local build; CI always passes a ZIP.

.EXAMPLE
    .\scripts\package-symbols.ps1
    .\scripts\package-symbols.ps1 -Layout terminal\bin\x64\Release\CascadiaPackage
#>
[CmdletBinding()]
param(
    [string] $Zip,
    [string] $Layout,
    [string] $DistDir,

    # Binaries this project owns and must be able to debug. If one of these
    # yields no PDB the ZIP is not written at all, because a symbols ZIP that
    # silently omits the engine is worse than none: it looks like coverage.
    #
    # v0.2.6 shipped exactly that. ghostty-internal.dll came out with *no
    # CodeView record*, because -Dstrip defaults to true for ReleaseFast - and
    # the same flag sets unwind_tables to .none, so the engine could not be
    # symbolized *or* stack-walked. Nothing failed; the manifest just said
    # "no codeview record" in a list of successes.
    [string[]] $Require = @(
        'ghostty-internal.dll',
        'WindowsTerminal.exe',
        'Microsoft.Terminal.Control.dll',
        'TerminalApp.dll'
    )
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $DistDir) { $DistDir = Join-Path $RepoRoot 'dist' }

# The CodeView (RSDS) record of a PE image: the path of the PDB it was linked
# against, and the GUID+age that identify that exact PDB. This is the whole
# point of the script, so it reads the image itself rather than trusting a
# same-named file next to it.
function Get-CodeView {
    param([string] $Path)

    $fs = [IO.File]::OpenRead($Path)
    try {
        $br = New-Object IO.BinaryReader($fs)

        $fs.Position = 0x3C
        $fs.Position = $br.ReadInt32()
        if ($br.ReadUInt32() -ne 0x00004550) { return $null }    # 'PE\0\0'

        $null        = $br.ReadUInt16()                          # machine
        $numSections = $br.ReadUInt16()
        $null        = $br.ReadBytes(12)                         # stamp, symtab, nsyms
        $optSize     = $br.ReadUInt16()
        $null        = $br.ReadUInt16()                          # characteristics

        $optStart = $fs.Position
        $magic    = $br.ReadUInt16()
        # DataDirectory starts 96 bytes (PE32) or 112 (PE32+) into the optional
        # header; entry 6 is IMAGE_DIRECTORY_ENTRY_DEBUG.
        $dirStart = if ($magic -eq 0x20B) { 112 } else { 96 }
        $fs.Position = $optStart + $dirStart + (6 * 8)
        $debugRva = $br.ReadUInt32()
        if ($debugRva -eq 0) { return $null }
        $debugSize = $br.ReadUInt32()

        $fs.Position = $optStart + $optSize
        $sections = @()
        for ($i = 0; $i -lt $numSections; $i++) {
            $null    = $br.ReadBytes(8)                          # name
            $null    = $br.ReadUInt32()                          # virtual size
            $va      = $br.ReadUInt32()
            $rawSize = $br.ReadUInt32()
            $raw     = $br.ReadUInt32()
            $null    = $br.ReadBytes(16)                         # relocs, lines, flags
            $sections += [pscustomobject]@{ VA = $va; Raw = $raw; Size = $rawSize }
        }

        $debugOff = 0
        foreach ($s in $sections) {
            if ($debugRva -ge $s.VA -and $debugRva -lt ($s.VA + $s.Size)) {
                $debugOff = $s.Raw + ($debugRva - $s.VA)
                break
            }
        }
        if ($debugOff -eq 0) { return $null }

        for ($e = 0; $e -lt [int]($debugSize / 28); $e++) {
            $fs.Position = $debugOff + ($e * 28)
            $null = $br.ReadBytes(12)                            # flags, stamp, versions
            $type = $br.ReadUInt32()
            $null = $br.ReadUInt32()                             # size of data
            $null = $br.ReadUInt32()                             # rva of data
            $ptr  = $br.ReadUInt32()
            if ($type -ne 2 -or $ptr -eq 0) { continue }         # 2 = CODEVIEW

            $fs.Position = $ptr
            if ([Text.Encoding]::ASCII.GetString($br.ReadBytes(4)) -ne 'RSDS') { continue }
            $guid = New-Object Guid (, $br.ReadBytes(16))
            $age  = $br.ReadUInt32()
            $bytes = New-Object Collections.Generic.List[byte]
            while ($true) {
                $b = $br.ReadByte()
                if ($b -eq 0) { break }
                $bytes.Add($b)
            }
            return [pscustomobject]@{
                PdbPath = [Text.Encoding]::UTF8.GetString($bytes.ToArray())
                Guid    = $guid
                Age     = $age
                # How a debugger names it: the GUID with no punctuation, then
                # the age. This is the string to compare against a dump.
                Sig     = ('{0}{1:X}' -f $guid.ToString('N').ToUpper(), $age)
            }
        }
        return $null
    }
    finally { $fs.Dispose() }
}

# The same identity, read from the other end: a PDB's own GUID and age, out of
# the MSF stream 1 header. Nothing may be published on the strength of a
# filename - zig records a bare `ghostty.pdb` with no directory, so the file has
# to be searched for, and a search without this check is how you ship symbols
# that resolve a crash to the wrong function with total confidence.
function Get-PdbSignature {
    param([string] $Path)

    $fs = [IO.File]::OpenRead($Path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        if ([Text.Encoding]::ASCII.GetString($br.ReadBytes(26)) -ne "Microsoft C/C++ MSF 7.00`r`n") { return $null }

        $fs.Position = 0x20
        $pageSize    = $br.ReadUInt32()
        $null        = $br.ReadUInt32()                 # free page map
        $null        = $br.ReadUInt32()                 # pages in file
        $dirBytes    = $br.ReadUInt32()
        $null        = $br.ReadUInt32()                 # reserved
        $blockMap    = $br.ReadUInt32()

        # The block map is a page of page numbers holding the stream directory.
        $dirPages = [int][Math]::Ceiling($dirBytes / $pageSize)
        $fs.Position = $blockMap * $pageSize
        $dirPageNos = for ($i = 0; $i -lt $dirPages; $i++) { $br.ReadUInt32() }

        $dir = New-Object byte[] ($dirPages * $pageSize)
        for ($i = 0; $i -lt $dirPages; $i++) {
            $fs.Position = $dirPageNos[$i] * $pageSize
            [void]$fs.Read($dir, $i * $pageSize, $pageSize)
        }

        $numStreams = [BitConverter]::ToUInt32($dir, 0)
        if ($numStreams -lt 2) { return $null }
        # sizes[], then the page list of every stream in order; stream 1 is the
        # PDB info stream, so we only need past stream 0's pages.
        $sizes = for ($i = 0; $i -lt $numStreams; $i++) { [BitConverter]::ToUInt32($dir, 4 + ($i * 4)) }
        $cursor = 4 + ($numStreams * 4)
        $pages0 = [int][Math]::Ceiling($sizes[0] / $pageSize)
        $cursor += $pages0 * 4
        if ($sizes[1] -eq 0 -or $sizes[1] -eq 0xFFFFFFFF) { return $null }
        $page1 = [BitConverter]::ToUInt32($dir, $cursor)

        $fs.Position = $page1 * $pageSize
        $null = $br.ReadUInt32()                        # version
        $null = $br.ReadUInt32()                        # signature (time)
        $age  = $br.ReadUInt32()
        $guid = New-Object Guid (, $br.ReadBytes(16))
        return ('{0}{1:X}' -f $guid.ToString('N').ToUpper(), $age)
    }
    catch { return $null }
    finally { $fs.Dispose() }
}

# Where a PDB might be, given that the image may name it without a directory.
# Ordered cheapest-first; every hit is still signature-checked before use.
function Find-Pdb {
    param([string] $Recorded, [string] $BinaryDir, [string] $Sig, [string[]] $SearchRoots)

    $name = Split-Path -Leaf $Recorded
    $candidates = New-Object Collections.Generic.List[string]
    if ($Recorded -match '^[A-Za-z]:\\' -or $Recorded -match '^\\\\') { $candidates.Add($Recorded) }
    $candidates.Add((Join-Path $BinaryDir $name))
    foreach ($root in $SearchRoots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -Recurse -File -Filter $name -ErrorAction SilentlyContinue |
            ForEach-Object { $candidates.Add($_.FullName) }
    }

    foreach ($c in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path $c)) { continue }
        if ((Get-PdbSignature $c) -eq $Sig) { return $c }
    }
    return $null
}

# --- What are we collecting symbols for? --------------------------------------
$temp = $null
if ($Layout) {
    $root    = (Resolve-Path $Layout).Path
    $version = 'local'
}
else {
    if (-not $Zip) {
        $Zip = Get-ChildItem $DistDir -Filter '*portable.zip' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $Zip -or -not (Test-Path $Zip)) {
        throw "no portable ZIP to collect symbols for (looked in $DistDir). Run package-portable.ps1 first, or pass -Zip / -Layout."
    }
    $Zip     = (Resolve-Path $Zip).Path
    $version = [regex]::Match((Split-Path -Leaf $Zip), '-(\d+\.\d+\.\d+\.\d+)-').Groups[1].Value
    if (-not $version) { $version = 'unknown' }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('wg-symbols-' + [guid]::NewGuid().ToString('N'))
    Expand-Archive -Path $Zip -DestinationPath $temp -Force
    $root = $temp
    Write-Host "collecting for $(Split-Path -Leaf $Zip)" -ForegroundColor Cyan
}

$staging = Join-Path ([IO.Path]::GetTempPath()) ('wg-symstage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging | Out-Null

try {
    # Where to look when an image names its PDB without a directory. The zig
    # cache is the one that matters: zig records "ghostty.pdb" and nothing else,
    # and the file it means lives under a content hash.
    $searchRoots = @(
        (Join-Path $RepoRoot 'ghostty\zig-out\lib'),
        (Join-Path $RepoRoot 'ghostty\.zig-cache\o'),
        (Join-Path $RepoRoot 'terminal\bin\x64\Release'),
        (Join-Path $RepoRoot 'terminal\bin\x64\Debug')
    )

    $rows = @()
    $seen = @{}
    # The layout carries the same binary in more than one place (the package
    # staging keeps copies), so identity is the CodeView signature, not the path.
    $binaries = Get-ChildItem $root -Recurse -File -Include *.exe, *.dll | Sort-Object Name
    foreach ($bin in $binaries) {
        $cv = $null
        try { $cv = Get-CodeView $bin.FullName } catch { }
        if (-not $cv) {
            if ($seen.ContainsKey($bin.Name)) { continue }
            $seen[$bin.Name] = $true
            $rows += [pscustomobject]@{ Binary = $bin.Name; Pdb = ''; Sig = ''; State = 'no codeview record' }
            continue
        }
        if ($seen.ContainsKey($cv.Sig)) { continue }
        $seen[$cv.Sig] = $true

        $name = Split-Path -Leaf $cv.PdbPath
        $found = Find-Pdb -Recorded $cv.PdbPath -BinaryDir $bin.DirectoryName -Sig $cv.Sig -SearchRoots $searchRoots
        if ($found) {
            # Under the name the image records, flat, because that is the only
            # name a debugger will look for: dbghelp searches each symbol path
            # directory for the recorded basename, not for something helpfully
            # renamed after the binary. (zig's "ghostty.pdb" is why this matters
            # - a ghostty-internal.pdb would never be found.)
            $dest = Join-Path $staging $name
            if (Test-Path $dest) {
                # Two different PDBs claiming one name cannot both be flat.
                # Keep the first, say so, rather than overwrite in silence.
                $rows += [pscustomobject]@{ Binary = $bin.Name; Pdb = $name; Sig = $cv.Sig
                                            State = "name taken by another pdb - not collected" }
                continue
            }
            Copy-Item $found $dest -Force
            $rows += [pscustomobject]@{ Binary = $bin.Name; Pdb = $name; Sig = $cv.Sig; State = 'collected' }
        }
        else {
            $rows += [pscustomobject]@{ Binary = $bin.Name; Pdb = $name; Sig = $cv.Sig; State = 'no matching pdb here' }
        }
    }

    $collected = @($rows | Where-Object State -eq 'collected')
    if ($collected.Count -eq 0) {
        throw 'no PDBs were found for any binary - refusing to publish an empty symbols ZIP'
    }

    $missing = @($Require | Where-Object { $n = $_; -not ($collected | Where-Object Binary -eq $n) })
    if ($missing.Count -gt 0) {
        foreach ($m in $missing) {
            $row = $rows | Where-Object Binary -eq $m | Select-Object -First 1
            $why = if ($row) { $row.State } else { 'not present in the layout at all' }
            Write-Host ("  REQUIRED {0,-38} {1}" -f $m, $why) -ForegroundColor Red
        }
        throw ("no symbols for {0}. A 'no codeview record' here means the binary was built stripped - " +
               "for libghostty that is -Dstrip, which also drops the unwind tables. Build it with " +
               "-Dstrip=false rather than publishing a build nobody can debug.") -f ($missing -join ', ')
    }

    # The manifest is what makes these symbols trustworthy later: the signature
    # here has to equal the one the dump reports for the same module.
    $manifest = @(
        "winterm-ghostty $version - symbols",
        '',
        'PDB signature = CodeView GUID (no punctuation) followed by the age,',
        'exactly as a debugger matches them. Check it against the dump before',
        'believing any symbol it prints:   0:000> lmvm <module>',
        '',
        'To use:   .sympath+ <this folder>   then   .reload /f',
        ''
    )
    $manifest += ($rows | ForEach-Object { '{0,-40} {1,-40} {2,-34} {3}' -f $_.Binary, $_.Pdb, $_.Sig, $_.State })
    Set-Content -Path (Join-Path $staging 'SYMBOLS.txt') -Value ($manifest -join "`r`n") -Encoding utf8

    if (-not (Test-Path $DistDir)) { New-Item -ItemType Directory -Path $DistDir | Out-Null }
    $out = Join-Path $DistDir "winterm-ghostty-$version-x64-symbols.zip"
    if (Test-Path $out) { Remove-Item $out -Force }
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $out -CompressionLevel Optimal

    foreach ($r in $rows) {
        $colour = if ($r.State -eq 'collected') { 'Green' } else { 'DarkGray' }
        Write-Host ('  {0,-38} {1,-34} {2}' -f $r.Binary, $r.Sig, $r.State) -ForegroundColor $colour
    }
    Write-Host ("`n{0}  ({1:N0} bytes, {2} PDBs)" -f $out, (Get-Item $out).Length, $collected.Count) -ForegroundColor Green
    Get-Item $out
}
finally {
    if ($temp -and (Test-Path $temp)) { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue }
}
