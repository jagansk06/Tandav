# deploy-pwa.ps1 — build the iPhone (web) version and publish it to GitHub Pages.
#
#   .\tools\deploy-pwa.ps1            build, prune, stamp, commit, push
#   .\tools\deploy-pwa.ps1 -NoPush    everything except the push (inspect first)
#   .\tools\deploy-pwa.ps1 -NoBuild   re-publish the existing build\web
#
# Run it from anywhere; it works out its own paths.
#
# ## Two repositories, on purpose
#
# This repo holds the SOURCE and stays private. The built site goes to a SECOND,
# PUBLIC repo containing nothing but build output, because GitHub Pages on the
# free plan will only serve a public repository. The two never mix: this script
# pushes to $SiteRepoUrl and never to 'origin'.
#
# The site repo is machine-generated. Every deploy replaces its single commit with
# a force push, so it never grows and nothing put there by hand survives.
#
# The build flags are not optional. Read PWA.md before changing them: with the
# wrong ones the app looks fine on a desk with wifi and cannot open in a studio.
#
# Note on style: native command output is deliberately NOT piped or redirected
# with 2>&1. PowerShell 5.1 turns any stderr line from a native .exe into a red
# NativeCommandError wall quoting this script, which makes a normal run look
# like a crash.

[CmdletBinding()]
param(
    [switch] $NoPush,
    [switch] $NoBuild
)

$ErrorActionPreference = 'Stop'

$Repo      = Split-Path -Parent $PSScriptRoot
$MobileDir = Join-Path $Repo 'mobile'
$WebSrc    = Join-Path $MobileDir 'web'
$BuildDir  = Join-Path $MobileDir 'build\web'

# ============================= THE TWO THINGS TO SET ===========================
# Everything the customer's browser touches is derived from these two, so the
# served path and --base-href cannot drift apart. A mismatch between them is a
# blank white page with a 404 for every asset, which reads like a broken build
# rather than a wrong string.
$GitHubUser  = 'jagansk06'
$SiteName    = 'tandav-app'      # the PUBLIC, build-output-only repository
# ===============================================================================

$SiteRepoUrl = "https://github.com/$GitHubUser/$SiteName.git"
$SiteBranch  = 'main'
$BaseHref    = "/$SiteName/"
$SiteUrl     = "https://$GitHubUser.github.io/$SiteName/"

# The OAuth "Authorized JavaScript origin". An origin is scheme + host with NO
# path, so it is the same string whatever the repo is called — renaming the site
# repo does not mean another trip to the Google console.
$Origin      = "https://$GitHubUser.github.io"

# Where the site is assembled before it is pushed. Kept OUTSIDE this repository so
# 18 MB of build output per deploy never enters the source history, and sits next
# to tandav-signing\ for the same reason: it is machine state, not source.
# WIPED AND REBUILT on every deploy - never put anything here by hand.
$SiteDir     = Join-Path (Split-Path -Parent $Repo) 'tandav-site'

function Say  { param($m) Write-Host "`n=== $m" -ForegroundColor Cyan }
function Ok   { param($m) Write-Host "  + $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  ! $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host "`n  X $m" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------------- preflight -------
# Each of these has already cost a wasted deploy at least once in this project's
# life, and every one of them fails *silently* in the browser afterwards.
Say 'Preflight'

$indexSrc = Join-Path $WebSrc 'index.html'
if (-not (Test-Path $indexSrc)) { Die "Missing $indexSrc" }
$indexHtml = Get-Content $indexSrc -Raw
if ($indexHtml -match 'REPLACE_WITH_WEB_CLIENT_ID') {
    Die ("mobile\web\index.html still has the REPLACE_WITH_WEB_CLIENT_ID " +
         "placeholder. Put the real OAuth Web client id in the " +
         "google-signin-client_id meta tag first - see OAUTH-SETUP.md section 6. " +
         "Deployed as-is the app runs, and sign-in fails with invalid_client.")
}
# And that what replaced it is actually a client id. The tag sits right next to a
# comment saying the value is public, which is true - but it makes it easy to
# paste the wrong public-looking string, and every wrong one fails identically in
# the browser, long after the deploy.
$idTag = [regex]::Match($indexHtml, 'google-signin-client_id"\s*(?:\r?\n\s*)?content="([^"]*)"')
if (-not $idTag.Success) {
    Die 'Could not find the google-signin-client_id meta tag in mobile\web\index.html.'
}
$clientId = $idTag.Groups[1].Value.Trim()
if ($clientId -notmatch '^\d+-[a-z0-9]+\.apps\.googleusercontent\.com$') {
    Die ("The google-signin-client_id does not look like a client id:`n" +
         "    $clientId`n" +
         "Expected <digits>-<token>.apps.googleusercontent.com - copy the " +
         "Client ID field of the Web client, not the secret and not the project id.")
}
Ok "Google client id is filled in ($clientId)."

# The SQLite engine. Only the .wasm - the app uses the worker-free factory, so
# sqflite_sw.js is not served at all (lib\platform\app_files_web.dart explains
# why). If setup ever puts one back, the prune step below removes it, because a
# worker built against a different sqlite3 version than the .wasm is exactly the
# bug that cost a day.
if (-not (Test-Path (Join-Path $WebSrc 'sqlite3.wasm'))) {
    Die ("mobile\web\sqlite3.wasm is missing. Run this once, from mobile\:`n" +
         "    dart run sqflite_common_ffi_web:setup`n" +
         "Without it the app loads and then has no database, which looks " +
         "like a database bug rather than a missing file.")
}
Ok 'Database engine present.'

if (-not (Test-Path (Join-Path $WebSrc 'tandav_sw.js'))) {
    Die 'mobile\web\tandav_sw.js is missing - that file IS the offline support.'
}
Ok 'Service worker present.'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die 'git is not on PATH, so the site cannot be published.'
}
Ok 'git available.'

# ----------------------------------------------------------------- build -------
if (-not $NoBuild) {
    Say 'Building the web release'
    Push-Location $MobileDir
    try {
        flutter build web --release `
            --pwa-strategy=none `
            --no-web-resources-cdn `
            --base-href $BaseHref
        if ($LASTEXITCODE -ne 0) { Die "flutter build web failed (exit $LASTEXITCODE)." }
    } finally { Pop-Location }
    Ok 'Build finished.'
}

if (-not (Test-Path (Join-Path $BuildDir 'main.dart.js'))) {
    Die "No build in $BuildDir. Run without -NoBuild."
}

# Cheap proof the flags actually took effect, because a build made with the
# defaults produces a directory that looks identical at a glance.
$bootstrap = Get-Content (Join-Path $BuildDir 'flutter_bootstrap.js') -Raw
if ($bootstrap -match 'serviceWorkerVersion') {
    Die ("This build registers Flutter's own service worker, so it was NOT " +
         "built with --pwa-strategy=none. Two workers fighting over one scope " +
         "is exactly the bug that flag prevents.")
}
if (-not (Test-Path (Join-Path $BuildDir 'canvaskit\canvaskit.wasm'))) {
    Die ("canvaskit is missing from the build, so it would be fetched from " +
         "gstatic.com - cross-origin, therefore uncacheable, therefore no " +
         "offline app. Build with --no-web-resources-cdn.")
}
Ok 'Flags verified in the output.'

# ----------------------------------------------------------------- prune -------
# 42 MB on disk, of which 37 MB is CanvasKit. buildConfig in this build says
# {"compileTarget":"dart2js","renderer":"canvaskit"} and nothing else, so:
#
#   *.symbols          debug symbol maps. Never requested at runtime.
#   skwasm*, wimp*     only loaded when renderer === "skwasm", i.e. a --wasm
#                      build. Unreachable here.
#   webparagraph\      only chosen when flutterConfiguration.preferWebParagraph
#                      is set, which the app never sets.
#
# What stays is both reachable CanvasKit variants: canvaskit\ for Safari and
# Firefox - which is the iPhone, the whole point - and canvaskit\chromium\ for
# Chrome and Edge. Deleting either would break one of the two browsers that
# matter, so this list is deliberately conservative.
Say 'Pruning files the browser will never ask for'

$before = (Get-ChildItem $BuildDir -Recurse -File | Measure-Object -Property Length -Sum).Sum

$doomed = @()
$doomed += Get-ChildItem $BuildDir -Recurse -File -Filter '*.symbols'
$doomed += Get-ChildItem (Join-Path $BuildDir 'canvaskit') -File |
           Where-Object { $_.Name -like 'skwasm*' -or $_.Name -like 'wimp*' }
foreach ($f in $doomed) { Remove-Item $f.FullName -Force }

$wp = Join-Path $BuildDir 'canvaskit\webparagraph'
if (Test-Path $wp) { Remove-Item $wp -Recurse -Force }

# The 815-byte tombstone. --pwa-strategy=none should mean it was never written,
# but if a stale one survives from an earlier build it would be published and
# could unregister our worker.
$tomb = Join-Path $BuildDir 'flutter_service_worker.js'
if (Test-Path $tomb) { Remove-Item $tomb -Force; Warn 'Removed a stale flutter_service_worker.js.' }

# 263 KB of SQLite web worker the app never loads, and worse than dead weight:
# it is compiled against whatever sqlite3 version its own build resolved, which
# is not necessarily the one sqlite3.wasm was built from.
$swWorker = Join-Path $BuildDir 'sqflite_sw.js'
if (Test-Path $swWorker) { Remove-Item $swWorker -Force; Warn 'Removed an unused sqflite_sw.js.' }

$after = (Get-ChildItem $BuildDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
Ok ("{0:N1} MB -> {1:N1} MB" -f ($before / 1MB), ($after / 1MB))

# ----------------------------------------------------------------- stamp -------
# The service worker's cache is named after this version. Without a real value
# every deploy would reuse one cache name and returning customers would keep
# being served the old app out of it - the classic PWA "I pushed a fix and
# nobody got it" failure. Content-derived, so an identical build redeploys to the
# same cache and does not force a pointless 12 MB re-download.
Say 'Stamping the service worker version'

$swPath = Join-Path $BuildDir 'tandav_sw.js'
if (-not (Test-Path $swPath)) { Die "tandav_sw.js is not in the build output." }

$manifest = New-Object System.Text.StringBuilder
Get-ChildItem $BuildDir -Recurse -File |
    Where-Object { $_.FullName -ne $swPath } |
    Sort-Object FullName |
    ForEach-Object {
        $rel = $_.FullName.Substring($BuildDir.Length).TrimStart('\')
        [void]$manifest.AppendLine("$rel " + (Get-FileHash $_.FullName -Algorithm SHA256).Hash)
    }
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($manifest.ToString())
    $version = ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 12).ToLower()
} finally { $sha.Dispose() }

$sw = Get-Content $swPath -Raw
if ($sw -notmatch '__TANDAV_SW_VERSION__') {
    Die "tandav_sw.js has no __TANDAV_SW_VERSION__ placeholder left to stamp."
}
# -NoNewline: a trailing newline added on every deploy would change the file and
# so change the next version hash for no reason.
[System.IO.File]::WriteAllText($swPath, ($sw -replace '__TANDAV_SW_VERSION__', $version))
Ok "Cache version: $version"

# GitHub Pages runs Jekyll unless told not to, and Jekyll silently drops files
# and folders whose names begin with an underscore. Flutter does not emit any
# today, but a missing asset in production is not worth the risk of finding out.
Set-Content (Join-Path $BuildDir '.nojekyll') '' -NoNewline
Ok 'Added .nojekyll.'

# --------------------------------------------------------------- publish -------
# The site repo holds ONE commit, always. Each deploy rebuilds it from scratch and
# force-pushes, which is why there is no fetch, no merge and no orphan-branch
# dance here: there is no history to preserve, and a build-output repo that
# accumulates 18 MB per deploy would eventually stop being clonable.
#
# The "nothing changed, skipping" check that a normal deploy script wants is
# deliberately absent. The service worker's cache name is derived from the build's
# content, so redeploying an identical build lands on the same cache version and
# customers re-download nothing. A redundant deploy costs upload time and nothing
# else, which is not worth code to avoid.
Say "Publishing to $GitHubUser/$SiteName ($SiteBranch)"

if ($SiteDir -eq $Repo -or
    $SiteDir.StartsWith($Repo.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    Die ("`$SiteDir would sit inside the source repo ($SiteDir). It is wiped on " +
         "every deploy - point it somewhere outside.")
}

# A commit with no identity configured fails with a wall of git advice, which
# reads like the script is broken. Ask first.
$who = git config --get user.email
if (-not $who) {
    Die ("git has no user.email configured, so the commit would fail:`n" +
         "    git config --global user.email you@example.com`n" +
         "    git config --global user.name  ""Your Name""")
}

if (Test-Path $SiteDir) {
    # A locked file here produces a raw .NET exception that reads like a bug in
    # this script, and the cause is almost always mundane.
    try { Remove-Item $SiteDir -Recurse -Force }
    catch {
        Die ("Could not empty $SiteDir - something is holding a file open in " +
             "there, usually an editor or an Explorer window sitting in the " +
             "folder. Close it and run this again.`n    " +
             $_.Exception.Message)
    }
}
New-Item -ItemType Directory -Path $SiteDir -Force | Out-Null

Copy-Item (Join-Path $BuildDir '*') $SiteDir -Recurse -Force
Copy-Item (Join-Path $BuildDir '.nojekyll') $SiteDir -Force
Ok "Staged the site in $SiteDir"

Push-Location $SiteDir
try {
    # Two steps rather than `git init -b`, which does not exist before git 2.28 and
    # fails by writing to stderr - which under $ErrorActionPreference = 'Stop' ends
    # the script in a NativeCommandError wall instead of the fallback path. The -c
    # also silences the "using 'master' as the name for the initial branch" advice,
    # which is stderr too.
    git -c "init.defaultBranch=$SiteBranch" init -q
    if ($LASTEXITCODE -ne 0) { Die 'git init failed.' }
    git symbolic-ref HEAD "refs/heads/$SiteBranch"
    if ($LASTEXITCODE -ne 0) { Die "Could not name the initial branch $SiteBranch." }

    git add -A
    if ($LASTEXITCODE -ne 0) { Die 'git add failed.' }

    $staged = @(git diff --cached --name-only)
    if ($staged.Count -eq 0) { Die 'Nothing was staged - the build directory looks empty.' }

    git commit -q -m "Tandav PWA $version"
    if ($LASTEXITCODE -ne 0) { Die 'git commit failed.' }
    Ok "Committed $($staged.Count) files."

    git remote add origin $SiteRepoUrl
    if ($LASTEXITCODE -ne 0) { Die "Could not set the remote to $SiteRepoUrl." }

    if ($NoPush) {
        Warn "-NoPush: the site is built and committed in $SiteDir but not pushed."
        Warn "  Inspect it, then:  cd $SiteDir; git push --force origin $SiteBranch"
    } else {
        # --force is correct and not a shortcut: this commit intentionally has no
        # ancestor in common with what is on the remote.
        git push --force origin $SiteBranch
        if ($LASTEXITCODE -ne 0) {
            Die ("git push failed.`n" +
                 "    If it says the repository does not exist, create it first:`n" +
                 "      github.com/new -> name it '$SiteName' -> PUBLIC -> no README,`n" +
                 "      no .gitignore, no licence. Leave it completely empty.`n" +
                 "    This repo must hold ONLY build output. Never push source to it.")
        }
        Ok "Pushed to $GitHubUser/$SiteName."
    }
} finally { Pop-Location }

# ------------------------------------------------------------------ next -------
Say 'Done'
Write-Host ''
Write-Host "  Send this link to the iPhone user:" -ForegroundColor White
Write-Host "    $SiteUrl" -ForegroundColor Green
Write-Host ''
Write-Host '  One-time settings, if this was the first deploy:' -ForegroundColor White
Write-Host "    1. GitHub -> $GitHubUser/$SiteName -> Settings -> Pages ->"
Write-Host "       Deploy from a branch -> branch $SiteBranch, folder / (root)."
Write-Host "       Give it a couple of minutes. The repo must be PUBLIC."
Write-Host "    2. Google Cloud Console -> Credentials -> the Web client ->"
Write-Host "       Authorized JavaScript origins -> add exactly:"
Write-Host "         $Origin" -ForegroundColor Yellow
Write-Host "       An origin has no path, so it is NOT $SiteUrl"
Write-Host '    3. Same console: enable the People API, and add userinfo.email and'
Write-Host '       userinfo.profile to the consent screen. Without these the app'
Write-Host '       installs and works offline but can never reach Drive.'
Write-Host ''
Write-Host '  Then on the iPhone: open the link in SAFARI - not the WhatsApp' -ForegroundColor White
Write-Host '  in-app browser, which has no Add to Home Screen - then Share ->' -ForegroundColor White
Write-Host '  Add to Home Screen, and launch it from the icon.' -ForegroundColor White
Write-Host ''
