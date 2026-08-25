# ship.ps1 — build, verify, name, install and capture device logs for Tandav.
#
# Two APKs come out of this repo now: the studio owner's full app and the
# attender's attendance-and-fees-only app. They are the same package, the same
# version and the same signing key; the only difference is
# `--dart-define=TANDAV_ROLE=attendance`. Everything below exists to make sure
# the right one ends up on the right phone.
#
#   .\ship.ps1                        owner build   -> verify -> dist -> install + log
#   .\ship.ps1 -Role attender         attender build -> verify -> dist -> install + log
#   .\ship.ps1 -Both                  build BOTH, verify both, copy to dist, no device
#   .\ship.ps1 -BuildOnly             build + verify + dist, skip the phone entirely
#   .\ship.ps1 -SkipBuild             install the existing APK + capture (fast loop)
#   .\ship.ps1 -LogOnly               capture only, no build, no install
#
# Finished, named copies land in dist\ — that is the folder to send files from.
# The Gradle output is always called app-arm64-v8a-release.apk whichever role
# built it, so passing THAT file around is how the wrong build reaches a phone.
#
# The second thing this script exists for is the LOG. Debugging Drive sign-in by
# reading error toasts on a phone screen loses the stack trace and the real
# exception type; this pulls the actual Dart error text off the device into a
# file.
#
# Note on style: native command output is deliberately NOT piped or redirected
# with 2>&1. PowerShell 5.1 turns any stderr line from a native .exe into a red
# NativeCommandError wall quoting this script, which makes a normal run look
# like a crash. Letting output go straight to the console avoids that entirely.

[CmdletBinding()]
param(
    [ValidateSet('owner', 'attender')]
    [string] $Role = 'owner',

    [switch] $Both,
    [switch] $BuildOnly,
    [switch] $SkipBuild,
    [switch] $LogOnly
)

$ErrorActionPreference = 'Stop'

$Repo      = 'D:\Projects\Tandav'
$MobileDir = Join-Path $Repo 'mobile'
$DistDir   = Join-Path $Repo 'dist'
$Apk       = Join-Path $MobileDir 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
$Verify    = Join-Path $Repo 'tools\verify-apk.ps1'
$Package   = 'com.tandav.tandav_mobile'
$LogFile   = Join-Path $Repo 'device-log.txt'

$Adb = 'D:\Projects\android-sdk\platform-tools\adb.exe'

# What each role means to the build and to the file name. The dart-define is the
# whole difference between the two apps; see mobile\lib\core\app_role.dart.
$RoleSpec = @{
    'owner'    = @{ Define = 'full';       Label = 'Owner';      Blurb = 'full studio app' }
    'attender' = @{ Define = 'attendance'; Label = 'Attendance'; Blurb = 'attendance and fees only' }
}

function Say  { param($m) Write-Host "`n=== $m" -ForegroundColor Cyan }
function Ok   { param($m) Write-Host "  + $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  ! $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host "`n  X $m" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $Adb))    { Die "Not found: $Adb" }
if (-not (Test-Path $Verify)) { Die "Not found: $Verify" }

# Both APKs must carry the same version: Android refuses to install an older
# versionCode over a newer one, and these two files replace each other.
$versionLine = Select-String -Path (Join-Path $MobileDir 'pubspec.yaml') `
                             -Pattern '^version:\s*(.+)$' | Select-Object -First 1
if (-not $versionLine) { Die 'Could not read version: from mobile\pubspec.yaml' }
$version = $versionLine.Matches[0].Groups[1].Value.Trim()
# 1.0.0+2 -> 1.0.0-b2, because '+' in a file name survives Windows but not every
# chat app, mail client and download folder it has to pass through.
$versionTag = $version -replace '\+', '-b'

# ---------------------------------------------------------------- helpers ------

# Build one role, prove what came out, and copy it to dist\ under a name that
# says which build it is. The finished path is left in $script:Shipped rather
# than returned: `flutter build` writes to the success stream, so a function that
# returned a value here would hand back the entire build log with the path buried
# at the end of it.
function Build-Role {
    param([string] $Which, [switch] $NoBuild)

    $spec = $RoleSpec[$Which]

    if (-not $NoBuild) {
        Say "Building the $Which APK (TANDAV_ROLE=$($spec.Define))"
        Push-Location $MobileDir
        try {
            flutter build apk --release --split-per-abi `
                --dart-define=TANDAV_ROLE=$($spec.Define)
            if ($LASTEXITCODE -ne 0) { Die "flutter build failed (exit $LASTEXITCODE)." }
        } finally { Pop-Location }
        Ok 'Build finished.'
    }

    if (-not (Test-Path $Apk)) { Die "APK missing: $Apk`n    Run without -SkipBuild." }

    # One gate, one implementation. verify-apk.ps1 checks the release signature
    # AND reads the role back out of the compiled binary, so a stale build
    # directory or a mistyped dart-define is caught here rather than on a phone.
    Say "Verifying the $Which APK"
    & $Verify -Apk $Apk -Role $Which
    if ($LASTEXITCODE -ne 0) { Die "Verification failed for the $Which build. Nothing was copied to dist." }

    if (-not (Test-Path $DistDir)) { New-Item -ItemType Directory -Path $DistDir | Out-Null }
    $name = "Tandav-$($spec.Label)-$versionTag.apk"
    $dest = Join-Path $DistDir $name
    Copy-Item $Apk $dest -Force

    # A sidecar rather than a longer file name: what was built, from what, when.
    # The question it answers is "is the file I am about to send the current one?"
    $sha1 = (Get-FileHash -Path $dest -Algorithm SHA1).Hash.ToLower()
    @(
        "Tandav $($spec.Label) build - $($spec.Blurb)"
        "version      $version"
        "role         TANDAV_ROLE=$($spec.Define)"
        "built        $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        "command      flutter build apk --release --split-per-abi --dart-define=TANDAV_ROLE=$($spec.Define)"
        "file sha1    $sha1   (of the APK file itself, NOT the signing key)"
        ''
        'Verified before this file was written: release signing key + the build'
        'role read back out of the binary. Re-check any copy at any time with:'
        "  .\tools\verify-apk.ps1 -Apk `"$dest`" -Role $Which"
        ''
        'Install by tapping it on the phone. Never uninstall first - uninstalling'
        "erases that phone's database and its backups."
    ) | Set-Content -Path ([System.IO.Path]::ChangeExtension($dest, 'txt')) -Encoding UTF8

    Ok "dist\$name"
    $script:Shipped = $dest
}

# ------------------------------------------------------------------- both ------
if ($Both) {
    if ($LogOnly)   { Die '-Both and -LogOnly do not go together.' }
    if ($SkipBuild) { Die '-Both means building both, so -SkipBuild makes no sense.' }

    Build-Role -Which 'owner'
    $ownerApk = $script:Shipped
    Build-Role -Which 'attender'
    $attenderApk = $script:Shipped

    Say 'Both builds are ready'
    Write-Host "  $ownerApk"    -ForegroundColor White
    Write-Host "  $attenderApk" -ForegroundColor White
    Write-Host ''
    Write-Host '  Send the Owner file to the two owners and the Attendance file to' -ForegroundColor Cyan
    Write-Host '  the attender. They install over each other, so a phone must only' -ForegroundColor Cyan
    Write-Host '  ever be given its own one.' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  No device was touched. Add -Role <owner|attender> without -Both to' -ForegroundColor Cyan
    Write-Host '  install one of them here and capture a log.' -ForegroundColor Cyan
    exit 0
}

# ------------------------------------------------------------ single role ------
if ($LogOnly -and $BuildOnly) { Die '-LogOnly and -BuildOnly do not go together.' }

if (-not $LogOnly) {
    Build-Role -Which $Role -NoBuild:$SkipBuild
    if ($BuildOnly) {
        Say 'Done (no device)'
        Write-Host "  $script:Shipped" -ForegroundColor White
        exit 0
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
    if ($Role -eq 'attender') {
        Warn 'Installing the ATTENDER build. On a phone that holds an owner install'
        Warn 'this REPLACES the full app (nothing is deleted - the app will say so'
        Warn 'and tell you to reinstall the owner APK).'
    }
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
