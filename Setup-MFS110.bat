@echo off
setlocal
REM ============================================================================
REM  Setup-MFS110.bat
REM
REM  One-shot setup for the MFS110 on Windows ARM64:
REM    1. points the WDK driver-signing certificate at the bundled driver
REM    2. installs the ARM64 CYUSB3 driver
REM    3. installs or updates Mantra's RD Service
REM    4. starts (or restarts) the service and verifies
REM
REM  Self-elevates via UAC. Handles the PlugPlay dependency problem that
REM  breaks Mantra's own installer on slimmed Windows images.
REM
REM  FILES NEEDED BESIDE THIS SCRIPT:
REM      cyusb3.sys   cyusb3.inf   cyusb3.cat
REM  They are in the repository root.
REM
REM  USAGE
REM      Setup-MFS110.bat                      (default RD Service path)
REM      Setup-MFS110.bat "D:\path\to\L1Device"  (custom path)
REM
REM  DEFAULT RD SERVICE PATH
REM      C:\Program Files (x86)\Mantra\RDService\L1Device
REM  Install the vendor package into C:\Program Files (x86)\Mantra, or pass
REM  the real path as an argument.
REM ============================================================================

set "RDPATH=%~1"
if "%RDPATH%"=="" set "RDPATH=C:\Program Files (x86)\Mantra\RDService\L1Device"

REM --- self-elevate -----------------------------------------------------------
net session >nul 2>&1
if %errorLevel% neq 0 goto :elevate
goto :run

:elevate
echo.
echo   Requesting administrator privileges...
REM Pass the resolved RD path so the elevated instance gets the same one.
powershell -NoProfile -Command "$a = '%*'; if ([string]::IsNullOrWhiteSpace($a)) { Start-Process -FilePath '%~f0' -Verb RunAs } else { Start-Process -FilePath '%~f0' -ArgumentList $a -Verb RunAs }"
exit /b

:run
cd /d "%~dp0"

echo.
echo ============================================================
echo  MFS110 ARM64 setup
echo ============================================================
echo  script dir    : %~dp0
echo  RD Service at : %RDPATH%
echo.

set "PSBOOT=$ErrorActionPreference='Stop'; $rd='%RDPATH%'; $sd='%~dp0'; $s=Get-Content -Raw -LiteralPath '%~f0'; $m=[regex]::Match($s,'(?m)^#PSSTART#\r?\n(.*?)^#PSEND#','Singleline'); if(-not $m.Success){Write-Host 'ERROR: embedded script not found' -ForegroundColor Red; exit 1}; $sb=[scriptblock]::Create($m.Groups[1].Value); & $sb $sd $rd"

powershell -NoProfile -ExecutionPolicy Bypass -Command "%PSBOOT%"

set RC=%errorlevel%
echo.
if %RC%==0 (
  echo   Setup finished successfully.
) else (
  echo   Setup finished with errors ^(exit %RC%^). Scroll up for detail.
)
echo.
pause
exit /b %RC%

#PSSTART#
param([string]$ScriptDir, [string]$RdPath)

$ErrorActionPreference = 'Continue'
$ok = $true

function Head($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Good($t) { Write-Host "   OK   $t" -ForegroundColor Green }
function Warn($t) { Write-Host "   WARN $t" -ForegroundColor Yellow }
function Bad($t)  { Write-Host "   FAIL $t" -ForegroundColor Red; $script:ok = $false }

# ---------------------------------------------------------------- 1. elevation
Head "1. Elevation"
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Bad "not running as Administrator"
    exit 1
}
Good "administrator"

# -------------------------------------------------------------- 2. architecture
Head "2. Architecture"
if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64') {
    Bad "this driver is ARM64 only; machine reports '$env:PROCESSOR_ARCHITECTURE'"
    Write-Host "        For x64 Windows use Mantra's original driver instead." -ForegroundColor Yellow
    exit 1
}
Good "ARM64"

# --------------------------------------------------------------- 3. Secure Boot
Head "3. Secure Boot"
$sb = $null
try { $sb = Confirm-SecureBootUEFI } catch { $sb = $null }
if ($sb -eq $true) {
    Bad "Secure Boot is ENABLED"
    Write-Host "        Test-signing cannot be enabled while Secure Boot is on." -ForegroundColor Yellow
    Write-Host "        Shut down, disable Secure Boot in the firmware settings, boot again." -ForegroundColor Yellow
    exit 1
} elseif ($sb -eq $false) { Good "Secure Boot is off" }
else { Warn "Secure Boot state undetermined (legacy firmware?) - continuing" }

# ----------------------------------------------------- 4. current installation
Head "4. Current state"
$alreadyRunning = $false
$svcName = 'MantraMFS110AVDM'

$svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
if ($svc) {
    Good "service registered ($($svc.Status))"
    if ($svc.Status -eq 'Running') {
        $guidThere = [bool](Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses' -ErrorAction SilentlyContinue |
                            Where-Object { $_.PSChildName -like '*2424460d*' })
        if ($guidThere) {
            $alreadyRunning = $true
            Good "interface GUID registered - a working installation already exists"
        } else {
            Warn "service running but the interface GUID is not registered"
            Write-Host "        The RD Service will not find the device. Reinstalling the driver." -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "        not installed yet" -ForegroundColor Gray
}

$devNow = Get-PnpDevice -ErrorAction SilentlyContinue |
          Where-Object { $_.InstanceId -like 'USB\VID_2C0F&PID_1204*' }
if ($devNow) { Good "device present: $($devNow.Status)" }
else { Warn "MFS110 not attached - the driver will install but the service cannot start" }

if ($alreadyRunning) {
    Write-Host ""
    Write-Host "   Everything is already installed and running." -ForegroundColor Green
    Write-Host "   Run Test-MFS110.bat to check capture, or continue to reinstall." -ForegroundColor Gray
    Write-Host ""
    $ans = Read-Host "   Continue with a reinstall anyway? (y/N)"
    if ($ans -ne 'y' -and $ans -ne 'Y') {
        Write-Host "   Nothing to do." -ForegroundColor Gray
        exit 0
    }
}

# ------------------------------------------------------------------ 5. sources
Head "5. Driver files"
$need = 'cyusb3.sys','cyusb3.inf','cyusb3.cat'
foreach ($f in $need) {
    $p = Join-Path $ScriptDir $f
    if (-not (Test-Path $p)) {
        Bad "missing $f  (expected in $ScriptDir)"
        exit 1
    }
    Good ("{0,-14} {1,8:N0} bytes" -f $f, (Get-Item $p).Length)
}

# ------------------------------------------------------------- 5. test signing
Head "6. Test signing"
$ts = (bcdedit | Select-String 'testsigning').ToString()
if ($ts -match 'Yes') {
    Good "already enabled"
    $needReboot = $false
} else {
    bcdedit /set testsigning on | Out-Null
    Warn "enabled - A REBOOT IS REQUIRED before the driver can load"
    $needReboot = $true
}

# -------------------------------------------------------------- 6. certificate
Head "7. Signing certificate"
$subject = 'CN=MFS110Driver'
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $subject } |
        Sort-Object NotAfter -Descending | Select-Object -First 1

if ($cert) {
    Good "reusing $($cert.Thumbprint)"
} else {
    try {
        $cert = New-SelfSignedCertificate -Subject $subject -Type CodeSigningCert `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3') -ErrorAction Stop
        Good "created $($cert.Thumbprint)"
    } catch {
        Bad "could not create certificate: $($_.Exception.Message)"
        exit 1
    }

    foreach ($store in 'Root','TrustedPublisher') {
        $dest = "Cert:\LocalMachine\$store"
        $have = Get-ChildItem $dest -ErrorAction SilentlyContinue |
                Where-Object Thumbprint -eq $cert.Thumbprint
        if (-not $have) {
            $tmp = Join-Path $env:TEMP "mfs110-$store.cer"
            Export-Certificate -Cert $cert -FilePath $tmp -Type CERT | Out-Null
            Import-Certificate -FilePath $tmp -CertStoreLocation $dest | Out-Null
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
        Good "trusted in LocalMachine\$store"
    }
}

# ----------------------------------------------------------------- 7. staging
Head "8. Staging (INF and catalog must sit together)"
$stage = Join-Path $env:TEMP 'mfs110-driver'
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Get-ChildItem $stage -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

Copy-Item (Join-Path $ScriptDir 'cyusb3.sys') (Join-Path $stage 'cyusb3.sys') -Force
Copy-Item (Join-Path $ScriptDir 'cyusb3.inf') (Join-Path $stage 'cyusb3.inf') -Force
Copy-Item (Join-Path $ScriptDir 'cyusb3.cat') (Join-Path $stage 'cyusb3.cat') -Force
Good "staged in $stage"

# ----------------------------------------------------------------- 8. signing
Head "9. Signing"
$signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter signtool.exe `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like '*\x64\*' } |
            Select-Object -First 1 -ExpandProperty FullName
if (-not $signtool) {
    Bad "signtool.exe not found - install 'Windows SDK Signing Tools for Desktop Apps'"
    exit 1
}
foreach ($f in 'cyusb3.cat','cyusb3.sys') {
    & $signtool sign /q /fd SHA256 /sha1 $cert.Thumbprint (Join-Path $stage $f) | Out-Null
    if ($LASTEXITCODE -ne 0) { Bad "signing failed: $f" } else { Good "signed $f" }
}
if (-not $ok) { exit 1 }

# ---------------------------------------------------------------- 9. reboot gate
if ($needReboot) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host " REBOOT REQUIRED" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host " Test-signing was just enabled. The driver cannot load until" -ForegroundColor Yellow
    Write-Host " the machine restarts. Look for a 'Test Mode' watermark." -ForegroundColor Yellow
    Write-Host ""
    Write-Host " Re-run this script after the reboot to finish." -ForegroundColor Yellow
    exit 2
}

# ----------------------------------------------------------------- 10. driver
Head "10. Installing driver"
$out = & pnputil /add-driver (Join-Path $stage 'cyusb3.inf') /install 2>&1
$out | ForEach-Object { Write-Host "        $_" }
if ($out -match 'successfully|already exists') { Good "driver package installed" }
else { Bad "pnputil reported a problem (see above)" }

# ------------------------------------------------------------- 11. RD Service
Head "11. RD Service"
if (-not (Test-Path $RdPath)) {
    Bad "RD Service folder not found: $RdPath"
    Write-Host "        Install Mantra's RD Service package into:" -ForegroundColor Yellow
    Write-Host "          C:\Program Files (x86)\Mantra" -ForegroundColor Yellow
    Write-Host "        or pass the real path as an argument to this script." -ForegroundColor Yellow
} else {
    Good "found $RdPath"
    $hostExe = Join-Path $RdPath 'MantraMFS110AVDMHost.exe'
    if (-not (Test-Path $hostExe)) {
        Bad "MantraMFS110AVDMHost.exe not in that folder"
    } else {
        $svc = 'MantraMFS110AVDM'
        $existing = Get-Service -Name $svc -ErrorAction SilentlyContinue

        if (-not $existing) {
            Write-Host "        service not registered - creating it" -ForegroundColor Gray
            Write-Host "        (Mantra's installer usually fails on slimmed images because" -ForegroundColor Gray
            Write-Host "         it declares a dependency on PlugPlay, which may not exist)" -ForegroundColor Gray
            New-Service -Name $svc -BinaryPathName $hostExe `
                        -DisplayName 'Mantra L1 AVDM' -StartupType Automatic -ErrorAction SilentlyContinue | Out-Null
            & sc.exe config $svc depend= RpcSs | Out-Null
            & sc.exe description $svc 'Mantra MFS110 Registered Device Service' | Out-Null
            $existing = Get-Service -Name $svc -ErrorAction SilentlyContinue
        }

        if ($existing) {
            Good "service registered"

            # restart it
            $running = (Get-Service $svc).Status -eq 'Running'
            if ($running) {
                Write-Host "        stopping for update..." -ForegroundColor Gray
                Stop-Service $svc -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            }

            $started = $false
            for ($i = 1; $i -le 5; $i++) {
                try {
                    Start-Service $svc -ErrorAction Stop
                    $started = $true
                    Good "started (attempt $i)"
                    break
                } catch {
                    Write-Host "        attempt ${i}: $($_.Exception.Message)" -ForegroundColor Gray
                    Start-Sleep -Seconds 4
                }
            }
            if (-not $started) { Bad "service would not start" }

            Start-Sleep -Seconds 5
            $listen = netstat -an | Select-String '11100.*LISTENING'
            if ($listen) { Good "LISTENING on 127.0.0.1:11100" }
            else { Warn "not listening on 11100 yet - give it a moment, or check the device" }
        } else {
            Bad "could not create the service"
        }

        # clock check - -214 error from the RD Service
        Write-Host ""
        Write-Host "        system time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')" -ForegroundColor Gray
        Write-Host "        if the RD Service reports -214, run: w32tm /resync" -ForegroundColor Gray
    }
}

# ----------------------------------------------------------------- 12. summary
Head "12. Summary"
$inst = Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'USB\VID_2C0F&PID_1204*' }
if ($inst) { Good "device: $($inst.Status) - $($inst.FriendlyName)" }
else { Warn "MFS110 not detected - is it attached to this machine?" }

$guidOk = [bool](Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses' -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -like '*2424460d*' })
if ($guidOk) { Good "interface GUID registered" }
else { Warn "interface GUID NOT registered - the RD Service will not find the device" }

Write-Host ""
if ($ok) { Write-Host " All steps completed." -ForegroundColor Green }
else     { Write-Host " Some steps failed - see FAIL lines above." -ForegroundColor Yellow }
exit ([int](-not $ok))
#PSEND#
