<#
.SYNOPSIS
    Build, sign and stage a sideloadable MSIX of the ghostty-engine fork.

.DESCRIPTION
    Produces the two files a release needs: the signed .msix and the .cer that
    lets a machine trust it. Everything lands in dist/.

    Three things about this package are deliberate and are set in the fork's
    Package-Dev.appxmanifest, not here:

      Identity Name   WintermGhostty          not WindowsTerminalDev - same Name
                                              means same package family, so
                                              installing would replace a real
                                              Windows Terminal Dev install
      Publisher       CN=Darren Shepherd      an MSIX signature is only valid if
                                              the signing certificate's subject
                                              matches this string exactly
      Alias           wtg.exe                 an execution alias is machine-wide;
                                              claiming wtd.exe would take it from
                                              a real Dev install

    The certificate is self-signed and lives in CurrentUser\My. That is fine for
    sideloading - it is what "trust this .cer" means on the installing end - but
    it is NOT a trusted publisher identity, and the .cer must be published with
    the .msix or the package cannot be installed at all.

.EXAMPLE
    .\scripts\package.ps1                  # build, sign, stage into dist\
    .\scripts\package.ps1 -SkipBuild       # re-sign whatever msbuild last produced
#>
[CmdletBinding()]
param(
    # Subject of the signing certificate. Must equal the manifest's Publisher.
    [string] $Subject = 'CN=Darren Shepherd',

    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    # Reuse the last msbuild output instead of rebuilding. The build is the slow
    # part and signing is the part worth iterating on.
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PkgProj  = Join-Path $RepoRoot 'terminal\src\cascadia\CascadiaPackage'
$DistDir  = Join-Path $RepoRoot 'dist'

# --- Tools --------------------------------------------------------------------
# Pick the highest-numbered SDK rather than a pinned one: signtool is
# backward-compatible and pinning it only breaks when the machine updates.
$sdkBin = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Directory -ErrorAction SilentlyContinue |
    Where-Object Name -match '^10\.' | Sort-Object Name -Descending | Select-Object -First 1
if (-not $sdkBin) { throw 'Windows SDK not found under C:\Program Files (x86)\Windows Kits\10\bin' }
$signtool = Join-Path $sdkBin.FullName 'x64\signtool.exe'
if (-not (Test-Path $signtool)) { throw "signtool.exe not found at $signtool" }

# --- Certificate --------------------------------------------------------------
# Looked up by subject, not by thumbprint, so this survives regenerating the
# cert. The EKU filter matters: a plain self-signed cert without the code
# signing EKU will sign successfully and then fail to validate at install.
$cert = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object {
    $_.Subject -eq $Subject -and $_.HasPrivateKey -and
    $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.3'
}) | Sort-Object NotAfter -Descending | Select-Object -First 1

if (-not $cert) {
    throw @"
No code-signing certificate with subject '$Subject' in CurrentUser\My.
Create one with:

  New-SelfSignedCertificate -Type CodeSigningCert -Subject '$Subject' ``
      -CertStoreLocation Cert:\CurrentUser\My -KeyUsage DigitalSignature ``
      -NotAfter (Get-Date).AddYears(5) ``
      -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3','2.5.29.19={text}')

The subject must match the manifest Publisher exactly or the signature is
rejected at install time with 0x800B0100 / "publisher does not match".
"@
}
Write-Host "certificate  $($cert.Subject)  $($cert.Thumbprint)  expires $($cert.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor Cyan

# --- Build --------------------------------------------------------------------
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build-terminal.ps1') -Project package -Configuration $Configuration
    if ($LASTEXITCODE -ne 0) { throw "package build failed ($LASTEXITCODE)" }
}

# --- Locate the package -------------------------------------------------------
# msbuild writes AppPackages\CascadiaPackage_<version>_x64[_Debug]_Test\*.msix.
# Newest wins; the version in the folder name comes from the manifest.
$msix = Get-ChildItem (Join-Path $PkgProj 'AppPackages') -Recurse -Filter *.msix -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $msix) { throw "no .msix under $PkgProj\AppPackages - did the package project build?" }

# Read identity back out of the package itself rather than trusting the folder
# name. This is the artifact being shipped; what it *says* is what matters.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($msix.FullName)
try {
    $entry = $zip.Entries | Where-Object Name -eq 'AppxManifest.xml' | Select-Object -First 1
    $reader = New-Object System.IO.StreamReader($entry.Open())
    $manifest = [xml]$reader.ReadToEnd()
    $reader.Close()
}
finally { $zip.Dispose() }

$identity  = $manifest.Package.Identity
$version   = $identity.Version
$publisher = $identity.Publisher

Write-Host "package      $($msix.Name)  ($('{0:N1}' -f ($msix.Length/1MB)) MB)" -ForegroundColor Cyan
Write-Host "identity     $($identity.Name) $version $publisher" -ForegroundColor Cyan

if ($publisher -ne $Subject) {
    throw "manifest Publisher '$publisher' does not match certificate subject '$Subject'; the signature would be rejected at install"
}

# --- Stage --------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
$stem    = "winterm-ghostty-$version-x64"
$outMsix = Join-Path $DistDir "$stem.msix"
$outCer  = Join-Path $DistDir "winterm-ghostty-$version.cer"

Copy-Item $msix.FullName $outMsix -Force

# --- Sign ---------------------------------------------------------------------
# Timestamping is attempted but not required: it keeps signatures valid past the
# certificate's expiry, and it is the one step here that needs the network.
$signArgs = @('sign', '/fd', 'SHA256', '/sha1', $cert.Thumbprint, '/tr', 'http://timestamp.digicert.com', '/td', 'SHA256', $outMsix)
& $signtool @signArgs 2>&1 | Where-Object { $_ -notmatch '^\s*$' } | ForEach-Object { "  $_" }
if ($LASTEXITCODE -ne 0) {
    Write-Host "  timestamping failed; signing without a timestamp" -ForegroundColor Yellow
    & $signtool sign /fd SHA256 /sha1 $cert.Thumbprint $outMsix 2>&1 | ForEach-Object { "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "signtool failed ($LASTEXITCODE)" }
}

& $signtool verify /pa $outMsix 2>&1 | ForEach-Object { "  $_" }
if ($LASTEXITCODE -ne 0) {
    # Expected until the .cer is trusted on this machine - the signature is
    # well-formed, the chain just does not terminate in a trusted root yet.
    # Swallow it deliberately: leaving it in $LASTEXITCODE makes a successful
    # packaging run look like a failed one to any caller that checks.
    Write-Host "  verify reports an untrusted chain, which is what a self-signed package looks like before the .cer is installed" -ForegroundColor Yellow
    $global:LASTEXITCODE = 0
}

# --- Certificate for distribution --------------------------------------------
Export-Certificate -Cert $cert -FilePath $outCer -Type CERT | Out-Null

# --- Framework dependency: deliberately NOT shipped ---------------------------
# The package declares a PackageDependency on Microsoft.UI.Xaml.2.8, and it is
# not staged here on purpose.
#
# Anyone installing this already has Windows Terminal, which depends on the same
# framework - and Windows 11 preinstalls it. Measured on the build machine: two
# copies present, both Store-delivered, and both *newer* than the 8.2305.5001.0
# the NuGet package carries. So the asset would be 5 MB of dead weight in the
# normal case.
#
# It is also not ours to hand out casually. WinUI 2 is under Microsoft's own
# licence terms, not MIT like the two upstreams; redistribution is permitted
# (section 2, Distributable Code) but carries obligations, including passing
# terms on to end users. Not shipping it avoids taking that on for a file the
# recipient almost certainly already has.
#
# The cost is one bad error message: a genuinely missing framework fails with a
# bare 0x80073CF3 naming no dependency. docs/install.md decodes it.
$dep = Get-ChildItem (Join-Path $PkgProj 'AppPackages') -Recurse -Filter 'Microsoft.UI.Xaml.2.8.appx' -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -eq 'x64' } | Select-Object -First 1
if ($dep) { Write-Host "  framework dependency available at $($dep.FullName) (not shipped - see comment)" -ForegroundColor DarkGray }

# --- Checksums ----------------------------------------------------------------
$sums = Join-Path $DistDir 'SHA256SUMS.txt'
Get-ChildItem $DistDir -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } |
    ForEach-Object { '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name } |
    Set-Content -Path $sums -Encoding ascii

Write-Host ''
Write-Host "dist/" -ForegroundColor Green
Get-ChildItem $DistDir -File | ForEach-Object { '  {0,-40} {1,10:N0} bytes' -f $_.Name, $_.Length }
Write-Host ''
Write-Host "version $version" -ForegroundColor Green
