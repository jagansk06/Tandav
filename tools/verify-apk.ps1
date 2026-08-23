# verify-apk.ps1 - is this APK safe to install over the one on the phone?
#
# Run this EVERY time before you copy an APK to a phone. It needs no device and
# no cable.
#
#   .\tools\verify-apk.ps1                 # checks the arm64 release APK
#   .\tools\verify-apk.ps1 -Apk <path>     # checks a specific file
#
# ## Why this exists
#
# Android cannot update an installed app with an APK signed by a different key.
# The only way through is to uninstall, and uninstalling ERASES the app's
# database - which on Tandav is the studio's only copy of its data. Backups live
# under app storage too, so they are destroyed by the same uninstall.
#
# The trap is that the wrong signature is SILENT. If android\key.properties or
# the keystore is missing, Gradle falls back to DEBUG signing and the build still
# reports success. The APK installs fine on a clean phone, cannot update an
# existing install, and cannot sign in to Google Drive either (the OAuth client
# is bound to the release SHA-1).
#
# So the signature must be checked against a known-good value, every time, by a
# machine. That is all this script does.

[CmdletBinding()]
param(
    [string] $Apk
)

$ErrorActionPreference = 'Stop'

$Repo = Split-Path -Parent $PSScriptRoot
if (-not $Apk) {
    $Apk = Join-Path $Repo 'mobile\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
}

$Java      = 'D:\Projects\jdk21\bin\java.exe'
$ApkSigner = 'D:\Projects\android-sdk\build-tools\36.0.0\lib\apksigner.jar'

# The release keystore's fingerprint. Kept in step with ship.ps1 on purpose:
# both scripts are gates on the same one fact.
$ExpectedSha1 = '509fe4a2a52c8081a2f3f9bbf498350bcb981a70'

function Ok   { param($m) Write-Host "  + $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  ! $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host "`n  X $m" -ForegroundColor Red; exit 1 }

foreach ($tool in @($Java, $ApkSigner)) {
    if (-not (Test-Path $tool)) { Die "Not found: $tool" }
}
if (-not (Test-Path $Apk)) {
    Die ("APK missing: $Apk`n    Build it first: cd mobile; flutter build apk --release --split-per-abi")
}

Write-Host "`n=== Checking $(Split-Path -Leaf $Apk)" -ForegroundColor Cyan

$built = (Get-Item $Apk).LastWriteTime
$ageHours = [math]::Round(((Get-Date) - $built).TotalHours, 1)
Write-Host "  built $built ($ageHours h ago)"

$certs = & $Java -jar $ApkSigner verify --print-certs $Apk
$line  = $certs | Select-String -Pattern 'SHA-1 digest' | Select-Object -First 1
if (-not $line) { Die 'apksigner printed no SHA-1. Is the APK signed at all?' }

$sha1 = ([regex]::Match($line.ToString(), '([0-9a-fA-F]{40})')).Groups[1].Value.ToLower()

if ($sha1 -eq $ExpectedSha1) {
    Ok "Release key confirmed ($sha1)."
    Write-Host ''
    Write-Host '  SAFE TO INSTALL OVER THE TOP.' -ForegroundColor Green
    Write-Host '  Copy it to the phone and tap it. Do NOT uninstall first.' -ForegroundColor Green
    Write-Host ''
    exit 0
}

Warn "SHA-1 is $sha1"
Warn "expected  $ExpectedSha1"
Write-Host ''
Write-Host '  DO NOT INSTALL THIS ON A PHONE THAT HAS TANDAV ON IT.' -ForegroundColor Red
Write-Host ''
Write-Host '  This APK is signed with the wrong key - almost certainly the debug' -ForegroundColor Yellow
Write-Host '  fallback, because mobile\android\key.properties or the keystore at' -ForegroundColor Yellow
Write-Host '  D:\Projects\tandav-signing\ was not found at build time. Android will' -ForegroundColor Yellow
Write-Host '  refuse to update with it, and uninstalling to force it through ERASES' -ForegroundColor Yellow
Write-Host "  the studio's database and its backups." -ForegroundColor Yellow
Write-Host ''
Write-Host '  Fix the signing, rebuild, and run this again.' -ForegroundColor Yellow
Write-Host ''
exit 1
