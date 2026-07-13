# نصب‌کنندهٔ خودکارِ PSCO روی کامپیوترِ مشتری (اینترنت لازم است).
# کارها: پرسیدنِ مسیر نصب → دانلودِ بستهٔ کامل از Google Drive → استخراج → اجرای
# نصب (Rancher/WSL/ایمیج‌ها/استک) → گرفتنِ آخرین آپدیت از GitHub → باز کردنِ Chrome
# روی برنامه.
#
# اجرا: روی PSCO-Install.cmd دوبار کلیک کن (خودش با دسترسی Administrator اجرا می‌شود).

param(
    # لینکِ اشتراکیِ Google Drive بستهٔ کامل (باید «Anyone with the link» باشد).
    [string]$DriveUrl    = "https://drive.google.com/file/d/1AljodRzDBJcQFyJ8bA0psKfE9v3ocywR/view?usp=sharing",
    # مسیر نصب (خالی = از کاربر پرسیده می‌شود)
    [string]$InstallDir  = "",
    # ریپوی عمومیِ آپدیت‌ها (بدون توکن).
    [string]$UpdateRepo  = "mousaanjomani/psco-releases",
    [string]$UpdateToken = ""
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path

# خود-بالابری: نصب به دسترسی Administrator نیاز دارد (Rancher/WSL/msiexec/C:\).
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`""
    exit
}

function Start-Chrome($url) {
    $paths = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
               "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
               "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
    $chrome = $paths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($chrome) { Start-Process $chrome $url } else { Start-Process $url }  # مرورگرِ پیش‌فرض
}

# دانلودِ استریمی با نوارِ پیشرفت — برای فایلِ ۲GB مناسب است (برخلاف Invoke-WebRequest).
function Download-WithProgress($url, $out, $label) {
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.UserAgent = "PSCO-Installer"
    $req.Timeout = 60000
    $resp = $req.GetResponse()
    $total = $resp.ContentLength
    $in = $resp.GetResponseStream()
    $fs = [IO.File]::Create($out)
    try {
        $buf = New-Object byte[] (1MB)
        $sum = 0; $last = 0
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $fs.Write($buf, 0, $n); $sum += $n
            if ($total -gt 0 -and ($sum - $last) -gt 25MB) {
                $last = $sum
                Write-Progress -Activity $label -Status ("{0:N0} / {1:N0} MB" -f ($sum/1MB), ($total/1MB)) -PercentComplete ([int](100 * $sum / $total))
            }
        }
    } finally { $fs.Close(); $in.Close(); $resp.Close(); Write-Progress -Activity $label -Completed }
}

# حجمِ فایلِ راه‌دور (Content-Length) بدونِ دانلودِ کاملِ بدنه — برای بررسیِ کاملیِ کش.
function Get-RemoteSize($url) {
    try {
        $req = [System.Net.HttpWebRequest]::Create($url); $req.UserAgent = "PSCO-Installer"
        $resp = $req.GetResponse(); $len = $resp.ContentLength; $resp.Close(); return $len
    } catch { return -1 }
}

# دانلود از Google Drive (رد کردنِ صفحهٔ هشدارِ اسکنِ ویروسِ فایل‌های بزرگ).
function Download-GDrive($id, $out) {
    $base = "https://drive.usercontent.google.com/download"
    Download-WithProgress "$base`?id=$id&export=download&confirm=t" $out "Downloading PSCO package"
    # اگر به‌جای ZIP یک صفحهٔ HTMLِ تأیید آمد (ZIP با «PK» شروع می‌شود)، فرمش را پارس و دوباره.
    $fs = [IO.File]::OpenRead($out); $b = New-Object byte[] 2; [void]$fs.Read($b, 0, 2); $fs.Close()
    if (-not ($b[0] -eq 0x50 -and $b[1] -eq 0x4B)) {
        $html = Get-Content $out -Raw
        $form = @{}
        foreach ($m in [regex]::Matches($html, 'name="([^"]+)"\s+value="([^"]*)"')) { $form[$m.Groups[1].Value] = $m.Groups[2].Value }
        if ($form.Count -eq 0) { throw "Google Drive download failed - make sure the link is set to Anyone-with-the-link." }
        $qs = ($form.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString($_.Value))" }) -join "&"
        Download-WithProgress "$base`?$qs" $out "Downloading PSCO package"
    }
}

# استخراجِ سریع (ZipFile به‌جای Expand-Archive که روی ۲GB بسیار کند است).
function Extract-Zip($zip, $dest) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
}

Write-Host "==== PSCO Installer ===="

# ۱) مسیر نصب
if (-not $InstallDir) {
    $InstallDir = Read-Host "Install path (press Enter for C:\PSCO)"
    if (-not $InstallDir) { $InstallDir = "C:\PSCO" }
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Write-Host "Install path: $InstallDir"

# ۲) استخراج شناسهٔ فایل از لینک Drive
if ($DriveUrl -match "/d/([A-Za-z0-9_-]+)") { $fileId = $Matches[1] }
elseif ($DriveUrl -match "[?&]id=([A-Za-z0-9_-]+)") { $fileId = $Matches[1] }
else { throw "Invalid Google Drive link." }

# ۳+۴) دانلود + استخراجِ کش‌شده (روی همان درایو، تا با ری‌استارت دوباره دانلود نشود).
$setup = Join-Path $InstallDir "_setup"
$work  = Join-Path $setup "extract"
$dist  = Join-Path $work "dist"
$zip   = Join-Path $setup "PSCO-full.zip"
$dlUrl = "https://drive.usercontent.google.com/download?id=$fileId&export=download&confirm=t"
New-Item -ItemType Directory -Force -Path $setup | Out-Null

if (Test-Path (Join-Path $dist "scripts\install.ps1")) {
    Write-Host "Package already extracted - skipping download and extract."
} else {
    # از zipِ کش‌شده استفاده کن اگر کامل است (حجمِ راه‌دور برابر، یا اگر آن در دسترس نبود، >1.9GB).
    $haveZip = $false
    if (Test-Path $zip) {
        $sz = (Get-Item $zip).Length
        $expected = Get-RemoteSize $dlUrl
        if (($expected -gt 0 -and $sz -eq $expected) -or ($expected -le 0 -and $sz -gt 1900MB)) { $haveZip = $true }
        elseif ($sz -lt 1900MB) { Write-Host "Cached download incomplete - re-downloading." }
    }
    if ($haveZip) {
        Write-Host "Using cached download - skipping download."
    } else {
        Write-Host "Downloading full package (~2GB)... this takes a few minutes."
        Download-GDrive $fileId $zip
        Write-Host ("Downloaded: {0:N0} MB" -f ((Get-Item $zip).Length / 1MB))
    }
    Write-Host "Extracting..."
    Extract-Zip $zip $work
}
if (-not (Test-Path (Join-Path $dist "scripts\install.ps1"))) { throw "Bad package layout (dist\scripts\install.ps1 not found)." }

# ۴.۵) اگر docker روی PATH هست ولی موتور جواب نمی‌دهد (حالتِ رایجِ بعد از ری‌استارت)،
# اول موتور را روشن کن و صبر کن — وگرنه install.ps1 بلوکِ پیش‌نیازها را رد می‌کند و
# docker load بی‌صدا شکست می‌خورد (روی ماشینِ staging دیده شد).
function Test-Engine { try { docker version *>$null; return ($LASTEXITCODE -eq 0) } catch { return $false } }
if ((Get-Command docker -ErrorAction SilentlyContinue) -and -not (Test-Engine)) {
    Write-Host "Container engine is not running - starting Rancher Desktop..."
    try { & rdctl start 2>$null | Out-Null } catch {
        $rdApp = Join-Path $env:LOCALAPPDATA "Programs\Rancher Desktop\Rancher Desktop.exe"
        if (Test-Path $rdApp) { Start-Process $rdApp }
    }
    $deadline = (Get-Date).AddMinutes(8)
    while (-not (Test-Engine) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }
    if (-not (Test-Engine)) {
        Write-Warning "Engine still not ready. Open Rancher Desktop, wait until it is Running, then run this installer again (downloads are kept)."
        exit 1
    }
}

# ۵) اجرای نصبِ اصلی
Write-Host "==== Running setup (Rancher / WSL / images / stack) ===="
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dist "scripts\install.ps1") -InstallDir $InstallDir

# اگر نصب گفت «ری‌استارت لازم است»، اینجا می‌ایستیم.
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Warning "Windows needs one restart. After restarting, run this installer again to continue."
    exit 0
}

# ۵.۵) راستی‌آزماییِ نصب — install.ps1 ممکن است بی‌صدا شکست بخورد؛ قبل از آپدیت و
# پاک‌سازیِ کشِ چندگیگی مطمئن شو استک واقعاً بالاست، وگرنه کش را نگه دار و خارج شو.
$psco = @(); try { $psco = @(docker ps --filter "name=psco" --format "{{.Names}}") } catch {}
if ($psco.Count -lt 5) {
    Write-Warning "Setup did not complete (PSCO stack is not running - found $($psco.Count) containers)."
    Write-Host "Fix the issue (usually: wait until Rancher Desktop is Running), then run this installer again."
    Write-Host "Downloaded files are kept - no re-download will be needed."
    exit 1
}

# ۶) گرفتنِ آخرین آپدیت (اگر Releaseای نبود بی‌صدا رد می‌شود)
if ($UpdateRepo -and (Test-Path (Join-Path $HERE "PSCO-Update.ps1"))) {
    Write-Host "==== Checking for updates ===="
    # PowerShell 5.1 آرگومانِ رشتهٔ خالی را هنگامِ صدا زدنِ powershell.exe حذف می‌کند؛
    # -Token "" می‌شود «-Token -InstallDir …» و بایندینگ می‌شکند → توکن فقط اگر پُر بود پاس بده.
    $updArgs = @("-NoProfile","-ExecutionPolicy","Bypass",
                 "-File",(Join-Path $HERE "PSCO-Update.ps1"),
                 "-Repo",$UpdateRepo,"-InstallDir",$InstallDir,"-NoBrowser")
    if ($UpdateToken) { $updArgs += @("-Token",$UpdateToken) }
    try { & powershell @updArgs }
    catch { Write-Warning "Update skipped (not fatal): $_" }
}

# ۷) پاک‌سازیِ کشِ نصب (zip + extract، چند GB) و باز کردنِ Chrome روی برنامه
Remove-Item $setup -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "==== Opening the app ===="
Start-Sleep -Seconds 3
Start-Chrome "http://localhost"

Write-Host ""
Write-Host "Install complete. App: http://localhost   |   Demo login: admin / Admin@1234"
exit 0
