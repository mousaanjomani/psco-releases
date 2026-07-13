# آپدیت‌کنندهٔ PSCO از GitHub Releases (اینترنت لازم است).
# کارها: پیدا کردنِ آخرین Release در GitHub → مقایسه با نسخهٔ نصب‌شده → دانلودِ بستهٔ
# آپدیت → استخراج → اجرای update.ps1 (لایسنس و همهٔ داده حفظ می‌شوند) → باز کردنِ برنامه.
#
# دو حالت:
#  • ریپوی عمومی (Public):  فقط $Repo کافی است، توکن نمی‌خواهد (ساده‌تر و امن‌تر).
#  • ریپوی خصوصی (Private): $Token را با یک PATِ «read-only» پر کن (fine-grained،
#    فقط Contents: Read روی همین ریپو). توجه: توکن روی دستگاه مشتری قرار می‌گیرد.
#
# اجرا: روی PSCO-Update.cmd دوبار کلیک کن.

param(
    [string]$Repo       = "mousaanjomani/psco-releases",
    [string]$Token      = "",
    [string]$InstallDir = "C:\PSCO",
    [switch]$NoBrowser   # از داخلِ نصب‌کننده صدا زده می‌شود تا مرورگر را دوبار باز نکند
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# توکنِ خالی/فاصله/نقل‌قولِ به‌جامانده از cmd (مثل -Token "") نباید هدر Authorization بسازد.
$Token = "$Token".Trim().Trim('"')

function Start-Chrome($url) {
    $paths = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
               "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
               "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
    $c = $paths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($c) { Start-Process $c $url } else { Start-Process $url }
}

# دانلودِ استریمی با نوارِ پیشرفت (بستهٔ آپدیت ~۵۰۰MB است؛ Invoke-WebRequest برای این
# حجم کند و بی‌بازخورد است).
function Download-WithProgress($url, $out, $label) {
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.UserAgent = "PSCO-Updater"; $req.Timeout = 60000
    $resp = $req.GetResponse(); $total = $resp.ContentLength
    $in = $resp.GetResponseStream(); $fs = [IO.File]::Create($out)
    try {
        $buf = New-Object byte[] (1MB); $sum = 0; $last = 0
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $fs.Write($buf, 0, $n); $sum += $n
            if ($total -gt 0 -and ($sum - $last) -gt 25MB) {
                $last = $sum
                Write-Progress -Activity $label -Status ("{0:N0} / {1:N0} MB" -f ($sum/1MB), ($total/1MB)) -PercentComplete ([int](100 * $sum / $total))
            }
        }
    } finally { $fs.Close(); $in.Close(); $resp.Close(); Write-Progress -Activity $label -Completed }
}

# استخراجِ سریع (Expand-Archive روی صدها مگابایت بسیار کند است).
function Extract-Zip($zip, $dest) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
}

Write-Host "==== PSCO Update check ($Repo) ===="
$api = @{ "User-Agent" = "PSCO-Updater"; "Accept" = "application/vnd.github+json" }
if ($Token) { $api["Authorization"] = "Bearer $Token" }

# آخرین Release
try { $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers $api }
catch { Write-Warning "No release found yet. Skipping."; exit 0 }

$tag = $rel.tag_name
$cur = ""
$verFile = Join-Path $InstallDir "VERSION"
if (Test-Path $verFile) { $cur = (Get-Content $verFile -Raw).Trim() }
Write-Host "Installed: '$cur'  |  Latest: '$tag'"
if ($cur -and ($tag.TrimStart('v') -eq $cur.TrimStart('v'))) {
    Write-Host "Already up to date."
    if (-not $NoBrowser) { Start-Chrome "http://localhost" }
    exit 0
}

# assetِ آپدیت
$asset = $rel.assets | Where-Object { $_.name -like "psco-update*.zip" } | Select-Object -First 1
if (-not $asset) { throw "This release has no psco-update*.zip asset." }
$zip = Join-Path $env:TEMP $asset.name
Write-Host "Downloading update ($($asset.name))..."

if ($Token) {
    # ریپوی خصوصی: asset.url با Accept octet-stream → 302 به S3؛ هدرِ Authorization
    # نباید به S3 برود، پس دستی ریدایرکت را می‌گیریم.
    $req = [System.Net.HttpWebRequest]::Create($asset.url)
    $req.UserAgent = "PSCO-Updater"; $req.Accept = "application/octet-stream"
    $req.Headers.Add("Authorization", "Bearer $Token"); $req.AllowAutoRedirect = $false
    try { $resp = $req.GetResponse() } catch [System.Net.WebException] { $resp = $_.Exception.Response }
    $loc = $resp.Headers["Location"]; $resp.Close()
    Download-WithProgress $loc $zip "Downloading update"
} else {
    # ریپوی عمومی: لینکِ مستقیم، بدون توکن.
    Download-WithProgress $asset.browser_download_url $zip "Downloading update"
}

# استخراج + اجرای update.ps1
$work = Join-Path $env:TEMP "psco-update-extract"
Extract-Zip $zip $work
Remove-Item $zip -Force -ErrorAction SilentlyContinue
$up = Get-ChildItem $work -Recurse -Filter update.ps1 | Select-Object -First 1
if (-not $up) { throw "update.ps1 not found inside the update package." }
Write-Host "==== Applying update ===="
& powershell -NoProfile -ExecutionPolicy Bypass -File $up.FullName -InstallDir $InstallDir
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

if (-not $NoBrowser) { Start-Sleep -Seconds 3; Start-Chrome "http://localhost" }
Write-Host "Update complete."
exit 0
