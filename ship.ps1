# ship.ps1 — build, verify, install and capture device logs for Tandav.
#
# The point of this script is the LOG. Debugging Drive sign-in by reading error
# toasts on a phone screen loses the stack trace and the real exception type;
# this pulls the actual Dart error text off the device into a file.
#
#   .\ship.ps1                 build + install + capture
#   .\ship.ps1 -SkipBuild      install the existing APK + capture (fast loop)
#   .\ship.ps1 -LogOnly        capture only, no build, no install
#
# Note on style: native command output is deliberately NOT piped or redirected
# with 2>&1. PowerShell 5.1 turns any stderr line from a native .exe into a red
# NativeCommandError wall quoting this script, which makes a normal run look
# like a crash. Letting output go straight to the console avoids that entirely.

[CmdletBinding()]
param(
    [switch] $SkipBuild,
    [switch] $LogOnly
)

$ErrorActionPreference = 'Stop'

$Repo      = 'D:\Projects\Tandav'
$MobileDir = Join-Path $Repo 'mobile'
$Apk       = Join-Path $MobileDir 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
$Package   = 'com.tandav.tandav_mobile'
$LogFile   = Join-Path $Repo 'device-log.txt'

$Adb       = 'D:\Projects\android-sdk\platform-tools\adb.exe'
$Java      = 'D:\Projects\jdk21\bin\java.exe'
$ApkSigner = 'D:\Projects\android-sdk\build-tools\36.0.0\lib\apksigner.jar'

# The release keystore fingerprint. An APK signed with anything else CANNOT sign
# in to Google Drive, because the Android OAuth client is bound to this SHA-1.
$ExpectedSha1 = '509fe4a2a52c8081a2f3f9bbf498350bcb981a70'

function Say  { param($m) Write-Host "`n=== $m" -ForegroundColor Cyan }
function Ok   { param($m) Write-Host "  + $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  ! $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host "`n  X $m" -ForegroundColor Red; exit 1 }

foreach ($tool in @($Adb, $Java, $ApkSigner)) {
    if (-not (Test-Path $tool)) { Die "Not found: $tool" }
}

# ---------------------------------------------------------------- build --------
if (-not $SkipBuild -and -not $LogOnly) {
    Say 'Building release APKs'
    Push-Location $MobileDir
    try {
        flutter build apk --release --split-per-abi
        if ($LASTEXITCODE -ne 0) { Die "flutter build failed (exit $LASTEXITCODE)." }
    } finally { Pop-Location }
    Ok 'Build finished.'
}

# ------------------------------------------------------ verify the signature ---
if (-not $LogOnly) {
    if (-not (Test-Path $Apk)) { Die "APK missing: $Apk`n    Run without -SkipBuild." }

    Say 'Verifying the APK is signed with the release key'
    $certs = & $Java -jar $ApkSigner verify --print-certs $Apk
    $line  = $certs | Select-String -Pattern 'SHA-1 digest' | Select-Object -First 1
    if (-not $line) { Die "apksigner printed no SHA-1. Is the APK signed at all?" }

    $sha1 = ([regex]::Match($line.ToString(), '([0-9a-fA-F]{40})')).Groups[1].Value.ToLower()
    if ($sha1 -eq $ExpectedSha1) {
        Ok "Release key confirmed ($sha1)."
    } else {
        Warn "SHA-1 is $sha1"
        Warn "expected  $ExpectedSha1"
        Die  ("This APK is signed with the WRONG key - almost certainly the debug " +
              "fallback because android\key.properties or the keystore was not found. " +
              "It will install, but Google Drive sign-in cannot work. Check the build " +
              "log for the 'Falling back to DEBUG signing' warning.")
    }
}

# --------------------------------------------------------------- device --------
Say 'Looking for a connected device'
$devices = & $Adb devices
$attached = $devices | Select-String -Pattern '^\S+\s+device$'
if (-not $attached) {
    Write-Host ($devices -join "`n")
    Die ("No device in 'device' state. On the phone: Settings -> About -> tap Build " +
         "number 7 times, then Developer options -> USB debugging. Reconnect and " +
         "accept the 'Allow USB debugging' prompt.")
}
Ok "Device ready: $($attached[0].ToString().Trim())"

# -------------------------------------------------------------- install --------
if (-not $LogOnly) {
    Say 'Installing (keeping existing data)'
    & $Adb install -r $Apk
    if ($LASTEXITCODE -ne 0) {
        Die ("Install failed. If the reason was INSTALL_FAILED_UPDATE_INCOMPATIBLE the " +
             "installed copy was signed with a different key; uninstalling is the only " +
             "fix and it WILL erase the app's database, so only do that on a test phone.")
    }
    Ok 'Installed.'
}

# ------------------------------------------------------------- capture ---------
Say 'Capturing device log'
& $Adb logcat -c
Ok 'Log cleared.'

if (-not $LogOnly) {
    & $Adb shell monkey -p $Package -c android.intent.category.LAUNCHER 1 | Out-Null
    Ok 'App launched.'
}

Write-Host ''
Write-Host '  Reproduce whatever you are testing on the phone now, then come' -ForegroundColor White
Write-Host '  back here. (Sync test: Settings -> Device & Sync -> Sync now.)' -ForegroundColor White
Write-Host ''
Read-Host '  Press Enter here once you are done on the phone'

& $Adb logcat -d -v time > $LogFile
$size = (Get-Item $LogFile).Length
Ok "Wrote $size bytes to $LogFile"

Say 'Interesting lines'
$hits = Select-String -Path $LogFile -Pattern 'flutter|Exception|Unimplemented|GoogleSign|Drive|Tandav|E/' |
        Select-Object -Last 40
if ($hits) { $hits | ForEach-Object { Write-Host "  $($_.Line)" } }
else { Warn 'Nothing matched. The full log is still in the file.' }

Write-Host ''
Write-Host "  Paste $LogFile into the chat (or just the lines above)." -ForegroundColor Cyan
