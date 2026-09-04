# verify-apk.ps1 - is this APK safe to install, and is it the RIGHT build?
#
# Run this EVERY time before you copy an APK to a phone. It needs no device and
# no cable.
#
#   .\tools\verify-apk.ps1                       # checks the arm64 release APK
#   .\tools\verify-apk.ps1 -Apk <path>           # checks a specific file
#   .\tools\verify-apk.ps1 -Apk <path> -Role attender   # …and insists on a role
#
# ## Two questions, both silent when they go wrong
#
# **1. Is it signed with the release key?**
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
# **2. Is it the owner build or the attender build?**
#
# Two APKs now leave this machine. They share a package name, a version and a
# signing key; the only difference is one `--dart-define=TANDAV_ROLE`. So they
# are indistinguishable by eye, they install over each other, and the mistake
# that matters - the attender's phone receiving the owner's build - hands a
# member of staff the studio's fee records and revenue. A file name cannot be
# trusted for this: names get changed, re-downloaded, and a -SkipBuild run can
# pick up a stale build directory.
#
# So the role is read out of the binary itself. `roleStamp` in
# lib/core/app_role.dart is a compile-time constant containing the raw
# TANDAV_ROLE value, rendered on the Device & Sync screen so the tree shaker
# keeps it; this script unzips the APK and reads it back.
#
# Both checks are gates on facts a machine can settle, so a machine settles
# them. ship.ps1 calls this script rather than repeating it.

[CmdletBinding()]
param(
    [string] $Apk,

    # owner | attender - fail unless the APK really is that build.
    # 'auto' (default) reports whatever it finds without judging it.
    [ValidateSet('auto', 'owner', 'attender')]
    [string] $Role = 'auto'
)

$ErrorActionPreference = 'Stop'

$Repo = Split-Path -Parent $PSScriptRoot
if (-not $Apk) {
    $Apk = Join-Path $Repo 'mobile\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
}

$Java      = 'D:\Projects\jdk21\bin\java.exe'
$ApkSigner = 'D:\Projects\android-sdk\build-tools\36.0.0\lib\apksigner.jar'

# The release keystore's fingerprint. The single fact the whole signing check
# turns on; ship.ps1 no longer keeps its own copy.
$ExpectedSha1 = '509fe4a2a52c8081a2f3f9bbf498350bcb981a70'

# Must match `roleStamp` in mobile\lib\core\app_role.dart.
$StampPattern = 'TANDAV-BUILD-ROLE=\[([^\]]*)\]'

# TANDAV_ROLE value -> what to call it out loud.
$RoleNames = @{
    'full'       = 'OWNER build (full studio app)'
    'attendance' = 'ATTENDER build (attendance and fees only)'
}
# -Role argument -> the TANDAV_ROLE value it demands.
$RoleWanted = @{
    'owner'    = 'full'
    'attender' = 'attendance'
}

function Ok   { param($m) Write-Host "  + $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  ! $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host "`n  X $m" -ForegroundColor Red; exit 1 }

foreach ($tool in @($Java, $ApkSigner)) {
    if (-not (Test-Path $tool)) { Die "Not found: $tool" }
}
if (-not (Test-Path $Apk)) {
    Die ("APK missing: $Apk`n    Build it first: .\ship.ps1 -BuildOnly")
}
$Apk = (Resolve-Path $Apk).Path

Write-Host "`n=== Checking $(Split-Path -Leaf $Apk)" -ForegroundColor Cyan

$built = (Get-Item $Apk).LastWriteTime
$ageHours = [math]::Round(((Get-Date) - $built).TotalHours, 1)
$sizeMb = [math]::Round((Get-Item $Apk).Length / 1MB, 1)
Write-Host "  built $built ($ageHours h ago, $sizeMb MB)"

# ------------------------------------------------------------ the role ---------
# Read the compiled-in stamp. The APK is a zip, so the bytes have to be
# decompressed by a zip reader before the string is there to find - grepping the
# .apk file directly finds nothing and would look like a missing stamp.
#
# Release builds put the Dart snapshot in lib\<abi>\libapp.so; debug and profile
# builds leave it in assets\flutter_assets\kernel_blob.bin. Both are checked so
# that running this on the wrong build says "that is a debug build" instead of
# failing to find a role.
Add-Type -AssemblyName System.IO.Compression.FileSystem

$found = @()
$scanned = @()
$zip = [System.IO.Compression.ZipFile]::OpenRead($Apk)
try {
    $wanted = $zip.Entries | Where-Object {
        $_.FullName -like 'lib/*/libapp.so' -or
        $_.FullName -eq 'assets/flutter_assets/kernel_blob.bin'
    }
    # ISO-8859-1 maps every byte to exactly one character, so binary data
    # survives the conversion without the mangling or truncation that UTF-8 or
    # a NUL-terminated read would cause.
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    foreach ($entry in $wanted) {
        $scanned += $entry.FullName
        $stream = $entry.Open()
        try {
            $buffer = New-Object System.IO.MemoryStream
            $stream.CopyTo($buffer)
            $text = $latin1.GetString($buffer.ToArray())
            $buffer.Dispose()
        } finally { $stream.Dispose() }
        foreach ($m in [regex]::Matches($text, $StampPattern)) {
            $found += $m.Groups[1].Value
        }
        $text = $null
    }
} finally { $zip.Dispose() }

if ($scanned.Count -eq 0) {
    Die ("No Dart code found in this APK (no lib\<abi>\libapp.so and no " +
         "kernel_blob.bin). Is this a Tandav APK at all?")
}

$roles = @($found | Sort-Object -Unique)

if ($roles.Count -eq 0) {
    Warn "Scanned: $($scanned -join ', ')"
    Die ("The build-role marker is MISSING from this APK, so which build it is " +
         "cannot be proved.`n    Either it predates the marker, or something in " +
         "mobile\lib\core\app_role.dart stopped referencing `$roleStamp and the " +
         "tree shaker dropped it. Do not hand this file to anyone: check that " +
         "the Device & Sync screen still prints the Build line, rebuild, and " +
         "run this again.")
}
if ($roles.Count -gt 1) {
    Die ("This APK contains CONFLICTING build roles: $($roles -join ', ').`n" +
         "    Wipe mobile\build and rebuild - a stale artefact has been mixed " +
         "into it.")
}

$rawRole = $roles[0]
$roleName = $null
if ($RoleNames.ContainsKey($rawRole)) { $roleName = $RoleNames[$rawRole] }

if (-not $roleName) {
    Die ("This APK was built with an unrecognised TANDAV_ROLE (`"$rawRole`").`n" +
         "    It would refuse to start on a phone. Rebuild with " +
         "TANDAV_ROLE=full or TANDAV_ROLE=attendance.")
}
Ok "Role read from the binary: $roleName"

if ($Role -ne 'auto') {
    $expectRaw = $RoleWanted[$Role]
    if ($rawRole -ne $expectRaw) {
        Warn "asked for the $Role build (TANDAV_ROLE=$expectRaw)"
        Warn "this file is  TANDAV_ROLE=$rawRole"
        Write-Host ''
        if ($Role -eq 'attender') {
            Die ("This is the OWNER build. Handing it to the attender gives him " +
                 "every screen in the app - students, events, reports, the " +
                 "month's revenue - and syncs the whole studio onto his phone. " +
                 "Build the right one: .\ship.ps1 -Role attender -BuildOnly")
        }
        Die ("This is the ATTENDER build. Installing it on an owner's phone " +
             "replaces their app with the two-tab one and stops their events " +
             "and progress records syncing. Build the right one: " +
             ".\ship.ps1 -BuildOnly")
    }
}

# ------------------------------------------------------- the signature ---------
$certs = & $Java -jar $ApkSigner verify --print-certs $Apk
$line  = $certs | Select-String -Pattern 'SHA-1 digest' | Select-Object -First 1
if (-not $line) { Die 'apksigner printed no SHA-1. Is the APK signed at all?' }

$sha1 = ([regex]::Match($line.ToString(), '([0-9a-fA-F]{40})')).Groups[1].Value.ToLower()

if ($sha1 -eq $ExpectedSha1) {
    Ok "Release key confirmed ($sha1)."
    Write-Host ''
    Write-Host "  SAFE TO INSTALL OVER THE TOP - $roleName" -ForegroundColor Green
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
