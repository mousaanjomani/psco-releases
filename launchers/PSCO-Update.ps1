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

# تشخیصِ خودکارِ مسیرِ نصب — نصب لزوماً روی C:\PSCO نیست (staging=D:\PSCO، مشتری=E:\PSCO).
# نصبِ واقعی = compose **و** .env (نسخهٔ قدیمیِ همین اسکریپت compose را به مسیرِ غلط کپی
# می‌کرد؛ نبودِ .env لوش می‌دهد). اگر مسیرِ داده‌شده واقعی نبود، درایوها را می‌گردیم.
if (-not ((Test-Path (Join-Path $InstallDir "docker-compose.psco.yml")) -and (Test-Path (Join-Path $InstallDir ".env")))) {
    $found = Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root "PSCO" } |
             Where-Object { (Test-Path (Join-Path $_ "docker-compose.psco.yml")) -and (Test-Path (Join-Path $_ ".env")) } |
             Select-Object -First 1
    if ($found) { $InstallDir = $found; Write-Host "Detected PSCO install: $InstallDir" }
    else { throw "PSCO installation not found (looked for <drive>:\PSCO). Run with -InstallDir <path>." }
}

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

# فهرست Releaseها — آپدیترِ زنجیره‌ای: همهٔ نسخه‌های جدیدتر از نسخهٔ نصب‌شده را
# به‌ترتیب اعمال می‌کند. بسته‌های «دلتا» (نامِ *-delta.zip) فقط ایمیج‌های تغییرکرده را
# دارند و کوچک‌اند؛ ترتیبِ اعمال برایشان حیاتی است. بستهٔ بدونِ پسوند = کامل.
try { $rels = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases?per_page=100" -Headers $api }
catch { Write-Warning "No releases found yet. Skipping."; exit 0 }

$cur = ""
$verFile = Join-Path $InstallDir "VERSION"
if (Test-Path $verFile) { $cur = (Get-Content $verFile -Raw).Trim() }

$chain = @()
foreach ($r in $rels) {
    if ($r.draft -or $r.prerelease) { continue }
    $v = $null
    if (-not [version]::TryParse("$($r.tag_name)".TrimStart("v"), [ref]$v)) { continue }
    $a = $r.assets | Where-Object { $_.name -like "psco-update*.zip" } | Select-Object -First 1
    if ($a) { $chain += [pscustomobject]@{ Ver = $v; Tag = $r.tag_name; Asset = $a; IsDelta = ($a.name -like "*-delta.zip") } }
}
if (-not $chain.Count) { Write-Warning "No usable update packages. Skipping."; exit 0 }
$chain = @($chain | Sort-Object Ver)

$curV = $null
if ($cur -and [version]::TryParse($cur.TrimStart("v"), [ref]$curV)) {
    $pending = @($chain | Where-Object { $_.Ver -gt $curV })
} else {
    # نصبی که VERSION ندارد (نصبِ تازه از بستهٔ کامل): از آخرین Releaseِ کامل شروع کن
    # و دلتاهای بعد از آن را هم به‌ترتیب بزن — دلتای تنها، نصبِ ناقص می‌سازد.
    $lastFull = @($chain | Where-Object { -not $_.IsDelta }) | Select-Object -Last 1
    if ($lastFull) { $pending = @($chain | Where-Object { $_.Ver -ge $lastFull.Ver }) }
    else { $pending = @($chain | Select-Object -Last 1) }
}

Write-Host "Installed: '$cur'  |  Latest: '$($chain[-1].Tag)'  |  To apply: $($pending.Count) package(s)"
if (-not $pending.Count) {
    Write-Host "Already up to date."
    if (-not $NoBrowser) { Start-Chrome "http://localhost" }
    exit 0
}

foreach ($step in $pending) {
    $asset = $step.Asset
    Write-Host "==== $($step.Tag): downloading $($asset.name) ($([int]($asset.size / 1MB)) MB) ===="
    $zip = Join-Path $env:TEMP $asset.name

    if ($Token) {
        # ریپوی خصوصی: asset.url با Accept octet-stream → 302 به S3؛ هدرِ Authorization
        # نباید به S3 برود، پس دستی ریدایرکت را می‌گیریم.
        $req = [System.Net.HttpWebRequest]::Create($asset.url)
        $req.UserAgent = "PSCO-Updater"; $req.Accept = "application/octet-stream"
        $req.Headers.Add("Authorization", "Bearer $Token"); $req.AllowAutoRedirect = $false
        try { $resp = $req.GetResponse() } catch [System.Net.WebException] { $resp = $_.Exception.Response }
        $loc = $resp.Headers["Location"]; $resp.Close()
        Download-WithProgress $loc $zip "Downloading $($step.Tag)"
    } else {
        # ریپوی عمومی: لینکِ مستقیم، بدون توکن.
        Download-WithProgress $asset.browser_download_url $zip "Downloading $($step.Tag)"
    }

    # دانلودِ ناقص (قطعیِ اتصال) نباید به docker load برسد — حجم باید دقیقاً با حجمِ
    # اعلام‌شدهٔ GitHub یکی باشد (روی staging یک دانلودِ بریده، آپدیتِ خراب ساخته بود).
    $got = (Get-Item $zip).Length
    if ($asset.size -gt 0 -and $got -ne $asset.size) {
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        throw ("Download of $($step.Tag) incomplete ({0:N0} of {1:N0} MB) - check the connection and run the updater again." -f ($got / 1MB), ($asset.size / 1MB))
    }

    # استخراج + اجرای update.ps1 همان بسته
    $work = Join-Path $env:TEMP "psco-update-extract"
    Extract-Zip $zip $work
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    $up = Get-ChildItem $work -Recurse -Filter update.ps1 | Select-Object -First 1
    if (-not $up) { throw "update.ps1 not found inside $($asset.name)." }
    Write-Host "==== $($step.Tag): applying ===="
    & powershell -NoProfile -ExecutionPolicy Bypass -File $up.FullName -InstallDir $InstallDir
    if ($LASTEXITCODE -ne 0) {
        throw "Update $($step.Tag) FAILED (update.ps1 exit $LASTEXITCODE) - nothing was finalized. Fix the issue above and run the updater again."
    }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $NoBrowser) { Start-Sleep -Seconds 3; Start-Chrome "http://localhost" }
Write-Host "Update complete."
exit 0
