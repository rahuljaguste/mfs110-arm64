@echo off
setlocal
REM ============================================================================
REM  Test-MFS110.bat
REM
REM  End-to-end check: does the MFS110 actually read a fingerprint?
REM
REM  Run this AFTER Setup-MFS110.bat. It walks each layer and then performs a
REM  real capture - you will be prompted to place a finger on the scanner.
REM
REM  Setup only proves the service is LISTENING. This proves it can CAPTURE.
REM
REM  Self-elevates (needed to query some device state).
REM
REM  USAGE
REM      Test-MFS110.bat                    1 capture
REM      Test-MFS110.bat -Runs 5            5 consecutive captures, with a
REM                                         success/time summary - useful for
REM                                         checking reliability
REM ============================================================================

net session >nul 2>&1
if %errorLevel% neq 0 goto :elevate
goto :run

:elevate
echo.
echo   Requesting administrator privileges...
powershell -NoProfile -Command "$a = '%*'; if ([string]::IsNullOrWhiteSpace($a)) { Start-Process -FilePath '%~f0' -Verb RunAs } else { Start-Process -FilePath '%~f0' -ArgumentList $a -Verb RunAs }"
exit /b

:run
cd /d "%~dp0"
set "PSBOOT=$ErrorActionPreference='Continue'; $s=Get-Content -Raw -LiteralPath '%~f0'; $m=[regex]::Match($s,'(?m)^#PSSTART#\r?\n(.*?)^#PSEND#','Singleline'); if(-not $m.Success){Write-Host 'ERROR: embedded script not found' -ForegroundColor Red; exit 1}; $sb=[scriptblock]::Create($m.Groups[1].Value); & $sb %*"

powershell -NoProfile -ExecutionPolicy Bypass -Command "%PSBOOT%"

set RC=%errorlevel%
echo.
if %RC%==0 (
  echo   All captures succeeded.
) else (
  echo   One or more captures FAILED ^(exit %RC%^).
)
echo.
pause
exit /b %RC%

#PSSTART#
param([int]$Runs = 1)

$ErrorActionPreference = 'Continue'
$svc  = 'MantraMFS110AVDM'
$base = 'http://127.0.0.1:11100/rd'
$tmp  = Join-Path $env:TEMP 'mfs110test'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function Head($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Good($t) { Write-Host "   OK   $t" -ForegroundColor Green }
function Warn($t) { Write-Host "   WARN $t" -ForegroundColor Yellow }
function Bad($t)  { Write-Host "   FAIL $t" -ForegroundColor Red }

# ------------------------------------------------------------------ 1. device
Head "1. Device"
$dev = Get-PnpDevice -ErrorAction SilentlyContinue |
       Where-Object { $_.InstanceId -like 'USB\VID_2C0F&PID_1204*' }
if ($dev) {
    Good "$($dev.Status) - $($dev.FriendlyName)"
    if ($dev.Status -ne 'OK') {
        Bad "device is not in OK state - check Device Manager"
        exit 1
    }
} else {
    Bad "MFS110 not present. Is it attached to this machine?"
    exit 1
}

# ------------------------------------------------------------- 2. interface GUID
Head "2. Interface GUID"
$guidOk = [bool](Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses' -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -like '*2424460d*' })
if ($guidOk) { Good "registered" }
else {
    Bad "NOT registered - the RD Service will not find the device"
    Write-Host "        The driver must register {2424460D-3D9D-45A4-A66A-D9FEF89E490B}." -ForegroundColor Yellow
    exit 1
}

# --------------------------------------------------------------- 3. RD Service
Head "3. RD Service"
$s = Get-Service -Name $svc -ErrorAction SilentlyContinue
if (-not $s) {
    Bad "service '$svc' not found - run Setup-MFS110.bat first"
    exit 1
}
if ($s.Status -ne 'Running') {
    Warn "not running - attempting to start"
    try { Start-Service $svc -ErrorAction Stop; Start-Sleep -Seconds 5 }
    catch { Bad "could not start: $($_.Exception.Message)"; exit 1 }
}
Good "service running"

$listen = $false
for ($i = 1; $i -le 10; $i++) {
    if (netstat -an | Select-String '11100.*LISTENING') { $listen = $true; break }
    Start-Sleep -Seconds 2
}
if ($listen) { Good "listening on 127.0.0.1:11100" }
else { Bad "not listening on 11100"; exit 1 }

# ---------------------------------------------------------------- 4. handshake
Head "4. Service responds"
$req = Join-Path $tmp 'req.xml'
$out = Join-Path $tmp 'resp.xml'

$deviceInfo = '<?xml version="1.0"?><DeviceInfo><Opts fCount="1" fType="0" iCount="0" pCount="0" format="0" /></DeviceInfo>'
Set-Content -LiteralPath $req -Value $deviceInfo -Encoding UTF8 -NoNewline

curl.exe -s -o $out -X RDSERVICE "$base/info" -H "Content-Type: text/xml" --data-binary "@$req" | Out-Null
$body = if (Test-Path $out) { [IO.File]::ReadAllText($out) } else { '' }

if ($body -match 'status="([A-Z]+)"') {
    $status = $Matches[1]
    if ($status -eq 'READY') { Good "status = READY" }
    else {
        Bad "status = $status (expected READY)"
        Write-Host "        NOTREADY usually means the service cannot open the device." -ForegroundColor Yellow
        exit 1
    }
} else {
    Bad "no valid RDSERVICE response"
    Write-Host "        $body" -ForegroundColor Gray
    exit 1
}

# ------------------------------------------------------------ 5. device details
curl.exe -s -o $out -X DEVICEINFO "$base/info" -H "Content-Type: text/xml" --data-binary "@$req" | Out-Null
$info = if (Test-Path $out) { [IO.File]::ReadAllText($out) } else { '' }

$dc = ''; $srno = ''
if ($info -match 'dc="([^"]+)"')      { $dc = $Matches[1] }
if ($info -match 'name="srno"\s+value="([^"]+)"') { $srno = $Matches[1] }

if ($dc)   { Good "device code (dc) = $dc" } else { Warn "no dc in DEVICEINFO response" }
if ($srno) { Good "serial (srno)    = $srno" }
Write-Host "        (the device code is required for the capture request)" -ForegroundColor Gray

# ----------------------------------------------------------------- 6. captures
Head "6. Capture $Runs time(s)"
Write-Host "   A capture blocks until a finger is read, or until it times out." -ForegroundColor Gray
Write-Host ""

$capXml = @(
  '<?xml version="1.0"?>'
  '<Capture>'
  '  <Opts fCount="1" fType="0" iCount="0" pCount="0" format="0" pidVer="2.0" timeout="20000" posh="UNKNOWN" />'
  '  <DeviceInfo>'
  '    <rdsId>RENESAS.MANTRA.001</rdsId>'
  '    <rdsVer>1.5.1</rdsVer>'
  '    <dpId>MANTRA.MSIPL</dpId>'
  "    <dc>$dc</dc>"
  '    <mi>MFS110</mi>'
  '    <mc>MFS110</mc>'
  '  </DeviceInfo>'
  '</Capture>'
) -join "`r`n"
$capFile = Join-Path $tmp 'capture.xml'
Set-Content -LiteralPath $capFile -Value $capXml -Encoding UTF8 -NoNewline

$pass = 0; $fail = 0
$times = @()

for ($n = 1; $n -le $Runs; $n++) {
    Write-Host "   [$n/$Runs] waiting for finger... " -NoNewline
    $t0 = Get-Date
    curl.exe -s -o $out -X CAPTURE "$base/capture" -H "Content-Type: text/xml" --data-binary "@$capFile" | Out-Null
    $elapsed = (Get-Date) - $t0
    $times += $elapsed.TotalMilliseconds

    $r = if (Test-Path $out) { [IO.File]::ReadAllText($out) } else { '' }

    if ($r -match 'errCode="(\d+)"') {
        $code = [int]$Matches[1]
        $q = ''; $nm = ''
        if ($r -match 'qScore="(\d+)"')  { $q  = $Matches[1] }
        if ($r -match 'nmPoints="(\d+)"'){ $nm = $Matches[1] }

        if ($code -eq 0) {
            Write-Host "CAPTURED" -ForegroundColor Green
            Write-Host "        qScore=$q  nmPoints=$nm  time=$([math]::Round($elapsed.TotalSeconds,2))s" -ForegroundColor Gray
            $pass++
        } else {
            $info2 = ''
            if ($r -match 'errInfo="([^"]*)"') { $info2 = $Matches[1] }
            Write-Host "FAILED (errCode=$code)" -ForegroundColor Red
            if ($info2) { Write-Host "        $info2" -ForegroundColor Yellow }
            $fail++
        }
    } else {
        Write-Host "NO RESPONSE" -ForegroundColor Red
        if ($r) { Write-Host "        $($r.Substring(0,[Math]::Min(160,$r.Length)))" -ForegroundColor Gray }
        $fail++
    }
}

# ------------------------------------------------------------------ 7. summary
Head "7. Summary"
$total = $Runs
Write-Host "   captures attempted : $total"
Write-Host "   succeeded          : $pass" -ForegroundColor $(if ($pass -eq $total) { 'Green' } else { 'Yellow' })
Write-Host "   failed             : $fail" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($times.Count -gt 0) {
    $avg = ($times | Measure-Object -Average).Average
    Write-Host ("   average time       : {0:N2}s" -f ($avg / 1000))
}

Write-Host ""
if ($fail -eq 0 -and $pass -gt 0) {
    Write-Host " FINGERPRINT CAPTURE WORKS." -ForegroundColor Green
    exit 0
} else {
    Write-Host " CAPTURE FAILED." -ForegroundColor Red
    Write-Host " See the Troubleshooting table in README.md." -ForegroundColor Yellow
    exit 1
}
#PSEND#
