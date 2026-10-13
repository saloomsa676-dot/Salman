<#
    LaptopCheck.ps1  -  read-only laptop performance check for Windows 10/11.

    What it does : reads system settings + measures activity for ~1 minute,
                   then writes an Arabic HTML report and a plain-text report
                   into a new folder on the Desktop and opens the HTML report.
    What it does NOT do : change any setting, delete any file, install anything,
                   or send anything over the internet.

    Run it with "Run-LaptopCheck.bat" (double-click). No admin rights needed.
#>

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$TestSeconds = 20

# ------------------------------------------------------------------ helpers
function Say([string]$Text, [string]$Color = 'Cyan') { Write-Host $Text -ForegroundColor $Color }
function Enc($s) { if ($null -eq $s) { return '' }; return [System.Net.WebUtility]::HtmlEncode([string]$s) }
function B($s)   { return '<bdi>' + (Enc $s) + '</bdi>' }
function Round1($n) { return [math]::Round([double]$n, 1) }
function Avg($arr) {
    $a = @($arr | Where-Object { $null -ne $_ })
    if ($a.Count -eq 0) { return $null }
    return [math]::Round(($a | Measure-Object -Average).Average, 0)
}
function HideUser($s) {
    if (-not $s) { return $s }
    $s = [string]$s
    if ($env:USERPROFILE) { $s = $s -ireplace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%' }
    return $s
}
function Steps([string[]]$Items) {
    if (-not $Items -or $Items.Count -eq 0) { return '' }
    return '<ol>' + (($Items | ForEach-Object { "<li>$_</li>" }) -join '') + '</ol>'
}

$Findings = New-Object System.Collections.ArrayList
function Add-Finding([string]$Level, [string]$Code, [string]$Title, [string]$Evidence, [string]$Fix) {
    [void]$Findings.Add([pscustomobject]@{
        Index = $Findings.Count; Level = $Level; Code = $Code
        Title = $Title; Evidence = $Evidence; Fix = $Fix
    })
}

try { Clear-Host } catch {}
Say '=================================================================='
Say '  Laptop Check  -  READ-ONLY: it changes nothing on your laptop'
Say '  Takes about 1 minute. Keep the charger plugged in.'
Say '  Leave your usual apps open (the ones open when it feels slow).'
Say '=================================================================='
Say ''

# ------------------------------------------------------------------ 1. system info
Say '[1/7] Reading system info...'
$cs   = Get-CimInstance Win32_ComputerSystem
$csp  = Get-CimInstance Win32_ComputerSystemProduct
$os   = Get-CimInstance Win32_OperatingSystem
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
$bios = Get-CimInstance Win32_BIOS | Select-Object -First 1
$gpus = @(Get-CimInstance Win32_VideoController)
$cv   = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

$mfr   = ([string]$cs.Manufacturer).Trim()
$model = ([string]$cs.Model).Trim()
$ver   = ([string]$csp.Version).Trim()
if ($ver -and $ver -notmatch 'System Version|To be filled|Default string|^None$' -and $model -notlike "*$ver*") {
    $model = "$model ($ver)"
}
$cpuName = ([string]$cpu.Name).Trim()
$logical = [Environment]::ProcessorCount
$osName  = ('{0} {1} (build {2})' -f $os.Caption, $cv.DisplayVersion, $os.BuildNumber).Trim()
$biosText = [string]$bios.SMBIOSBIOSVersion
if ($bios.ReleaseDate) { $biosText += ' (' + $bios.ReleaseDate.ToString('yyyy-MM-dd') + ')' }

$vendor = switch -Regex ($mfr) {
    'ASUS'            { @{ App = 'Armoury Crate';                       Key = 'Fn + F5'; Mode = 'Performance أو Turbo' }; break }
    'LENOVO'          { @{ App = 'Lenovo Vantage أو Legion Space';      Key = 'Fn + Q';  Mode = 'Performance' }; break }
    'Micro-Star|MSI'  { @{ App = 'MSI Center';                          Key = '';        Mode = 'Extreme Performance أو Balanced' }; break }
    '^HP|Hewlett'     { @{ App = 'OMEN Gaming Hub';                     Key = '';        Mode = 'Performance' }; break }
    'Acer'            { @{ App = 'NitroSense أو PredatorSense';         Key = '';        Mode = 'Performance' }; break }
    'Dell|Alienware'  { @{ App = 'Alienware Command Center';            Key = '';        Mode = 'Performance' }; break }
    'GIGABYTE|AORUS'  { @{ App = 'Gigabyte Control Center';             Key = '';        Mode = 'Performance' }; break }
    default           { @{ App = 'برنامج التحكم الخاص بالشركة المصنعة'; Key = '';        Mode = 'Performance' } }
}
$vendorTip = 'افتح برنامج <b>' + (Enc $vendor.App) + '</b> واختر وضع <b>' + (Enc $vendor.Mode) + '</b>'
if ($vendor.Key) { $vendorTip += ' (أو اضغط ' + (B $vendor.Key) + ' أكثر من مرة حتى يظهر وضع الأداء)' }

# ------------------------------------------------------------------ 2. power
Say '[2/7] Checking power settings...'
$onAC = $null; $batPct = $null; $hasBattery = $false
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $pwrStat    = [System.Windows.Forms.SystemInformation]::PowerStatus
    $hasBattery = ($pwrStat.BatteryChargeStatus.ToString() -notmatch 'NoSystemBattery|Unknown')
    $onAC       = ($pwrStat.PowerLineStatus.ToString() -eq 'Online')
    if ($hasBattery) { $batPct = [int][math]::Round($pwrStat.BatteryLifePercent * 100) }
} catch {}
if ($null -eq $onAC) {
    $bat = Get-CimInstance Win32_Battery | Select-Object -First 1
    if ($bat) {
        $hasBattery = $true
        $batPct = $bat.EstimatedChargeRemaining
        $onAC = ($bat.BatteryStatus -notin @(1, 4, 5))
    } else { $onAC = $true }
}

$guidRx   = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$planOut  = (& powercfg.exe /getactivescheme 2>$null) | Out-String
$planGuid = ([regex]::Match($planOut, $guidRx)).Value.ToLower()
$planMap  = @{
    '381b4222-f694-450c-a1a3-0c5ea08c2e7c' = 'Balanced'
    '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'High performance'
    'a1841308-3d3c-4aa2-ad1d-9ae4ed1e8c8f' = 'Power saver'
    'e9a42b02-d5df-448d-aa00-03f14749eb61' = 'Ultimate Performance'
}
$planName = $planMap[$planGuid]
if (-not $planName) {
    $planName = ([regex]::Match($planOut, '\(([^)]+)\)')).Groups[1].Value
    if (-not $planName) { $planName = 'Unknown' }
}

# Windows 11 "Power mode" (Best power efficiency / Balanced / Best performance)
$overlayMap = @{
    '961cc777-2547-4f9d-8174-7d86181b8a7a' = 'Best power efficiency'
    '00000000-0000-0000-0000-000000000000' = 'Balanced'
    '3af9b8d9-7c97-431d-ad78-34a8bfea439f' = 'Better performance'
    'ded574b5-45a0-4f42-8737-46345c09c238' = 'Best performance'
}
$overlayGuid = $null
try {
    Add-Type -Namespace LaptopCheck -Name Power -ErrorAction Stop -MemberDefinition @'
[DllImport("powrprof.dll")]
public static extern uint PowerGetEffectiveOverlayScheme(out Guid overlay);
'@
    $g = [Guid]::Empty
    if ([LaptopCheck.Power]::PowerGetEffectiveOverlayScheme([ref]$g) -eq 0) { $overlayGuid = $g.ToString().ToLower() }
} catch {}
if (-not $overlayGuid) {
    $pk = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
    if ($onAC) { $overlayGuid = [string]$pk.ActiveOverlayAcPowerScheme } else { $overlayGuid = [string]$pk.ActiveOverlayDcPowerScheme }
    if ($overlayGuid) { $overlayGuid = $overlayGuid.ToLower() }
}
$overlayName = $overlayMap[[string]$overlayGuid]
if (-not $overlayName) { $overlayName = 'Unknown' }

$uptimeDays = $null
if ($os.LastBootUpTime) { $uptimeDays = Round1 ((Get-Date) - $os.LastBootUpTime).TotalDays }
$rebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                 (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')

# ------------------------------------------------------------------ 3. memory + storage
Say '[3/7] Checking memory and storage...'
$ramTotalGB = $null; $ramFreeGB = $null; $ramUsedPct = $null
if ($os.TotalVisibleMemorySize) {
    $ramTotalGB = Round1 ($os.TotalVisibleMemorySize / 1MB)
    $ramFreeGB  = Round1 ($os.FreePhysicalMemory / 1MB)
    $ramUsedPct = [int][math]::Round(100 * (1 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)))
}
$perfMem   = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
$commitPct = $null
if ($perfMem) { $commitPct = [int]$perfMem.PercentCommittedBytesInUse }
$dimms     = @(Get-CimInstance Win32_PhysicalMemory)
$dimmCount = $dimms.Count
$dimmText  = ($dimms | ForEach-Object {
    $spd = $_.ConfiguredClockSpeed; if (-not $spd) { $spd = $_.Speed }
    '{0} GB @ {1} MT/s' -f [math]::Round($_.Capacity / 1GB), $spd
}) -join ' + '

$sysDrive = $env:SystemDrive
$vols     = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')
$cVol     = $vols | Where-Object { $_.DeviceID -eq $sysDrive } | Select-Object -First 1
$cSizeGB = $null; $cFreeGB = $null; $cFreePct = $null
if ($cVol -and $cVol.Size) {
    $cSizeGB  = Round1 ($cVol.Size / 1GB)
    $cFreeGB  = Round1 ($cVol.FreeSpace / 1GB)
    $cFreePct = [int][math]::Round(100 * $cVol.FreeSpace / $cVol.Size)
}
# Get-PhysicalDisk may return names (SSD) or raw numbers (4) depending on the system
function MapEnum($Value, $Map) { $s = [string]$Value; if ($Map.ContainsKey($s)) { return $Map[$s] }; return $s }
$mediaMap  = @{ '0' = 'Unspecified'; '3' = 'HDD'; '4' = 'SSD'; '5' = 'SCM' }
$busMap    = @{ '3' = 'ATA'; '7' = 'USB'; '8' = 'RAID'; '10' = 'SAS'; '11' = 'SATA'; '17' = 'NVMe' }
$healthMap = @{ '0' = 'Healthy'; '1' = 'Warning'; '2' = 'Unhealthy'; '5' = 'Unknown' }
$pdisks = @(Get-PhysicalDisk | ForEach-Object {
    [pscustomobject]@{
        Name   = [string]$_.FriendlyName
        Type   = MapEnum $_.MediaType $mediaMap
        Bus    = MapEnum $_.BusType $busMap
        Health = MapEnum $_.HealthStatus $healthMap
        SizeGB = [math]::Round($_.Size / 1GB)
    }
})

# ------------------------------------------------------------------ 4. live activity
Say '[4/7] Watching what is running (about 12 seconds) - please do not touch the laptop...'
# WmiPrvSE / powershell / conhost are this check itself, so they are left out.
$skipProc = @('_Total', 'Idle', 'WmiPrvSE', 'wmiapsrv', 'powershell', 'conhost')
$null = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
$null = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
$null = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process
Start-Sleep -Seconds 2

$cpuSamples = @(); $diskSamples = @(); $procCpu = @{}; $rounds = 4
for ($i = 0; $i -lt $rounds; $i++) {
    $c = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
    if ($c) { $cpuSamples += [double]$c.PercentProcessorTime }
    $d = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
    if ($d) { $diskSamples += (100 - [math]::Min(100, [double]$d.PercentIdleTime)) }
    foreach ($p in @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process)) {
        $n = $p.Name -replace '#\d+$', ''
        if ($skipProc -contains $n) { continue }
        $procCpu[$n] = [double]$procCpu[$n] + [double]$p.PercentProcessorTime
    }
    Start-Sleep -Milliseconds 1500
}
$cpuIdleAvg  = Avg $cpuSamples
$diskBusyAvg = Avg $diskSamples

$allProcs = @(Get-Process)
$known = @{
    'MsMpEng'               = 'Microsoft Defender (antivirus)'
    'MpDefenderCoreService' = 'Microsoft Defender (antivirus)'
    'NisSrv'                = 'Microsoft Defender (network)'
    'SearchIndexer'         = 'Windows Search (indexing files)'
    'TiWorker'              = 'Windows Update (installing)'
    'TrustedInstaller'      = 'Windows Update (installing)'
    'MoUsoCoreWorker'       = 'Windows Update'
    'svchost'               = 'Windows services'
    'dwm'                   = 'Windows display (Desktop Window Manager)'
    'explorer'              = 'Windows Explorer'
    'System'                = 'Windows kernel / drivers'
    'Memory Compression'    = 'Windows memory compression'
    'msedge'                = 'Microsoft Edge'
    'msedgewebview2'        = 'Edge WebView2 (used inside other apps)'
    'chrome'                = 'Google Chrome'
    'firefox'               = 'Firefox'
    'OneDrive'              = 'OneDrive (cloud sync)'
    'ms-teams'              = 'Microsoft Teams'
    'Teams'                 = 'Microsoft Teams'
}
function Friendly([string]$Name) {
    if ($known.ContainsKey($Name)) { return $known[$Name] }
    $p = $allProcs | Where-Object { $_.ProcessName -eq $Name } | Select-Object -First 1
    if ($p -and $p.Description) { return [string]$p.Description }
    return ''
}

$cpuTop = @($procCpu.GetEnumerator() | ForEach-Object {
    [pscustomobject]@{ Name = $_.Key; Pct = [math]::Round($_.Value / $rounds / $logical, 1) }
} | Where-Object { $_.Pct -ge 0.5 } | Sort-Object Pct -Descending | Select-Object -First 8)
foreach ($t in $cpuTop) { $t | Add-Member -NotePropertyName Desc -NotePropertyValue (Friendly $t.Name) }

$memTop = @($allProcs | Group-Object ProcessName | ForEach-Object {
    [pscustomobject]@{
        Name  = $_.Name
        Count = $_.Count
        MB    = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB)
    }
} | Sort-Object MB -Descending | Select-Object -First 10)
foreach ($t in $memTop) { $t | Add-Member -NotePropertyName Desc -NotePropertyValue (Friendly $t.Name) }

# ------------------------------------------------------------------ 5. startup, antivirus, drivers
Say '[5/7] Checking startup apps, antivirus and drivers...'
$disabled = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($root in 'HKCU:', 'HKLM:') {
    foreach ($sub in 'Run', 'Run32', 'StartupFolder') {
        $key = Get-Item -LiteralPath "$root\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$sub"
        if (-not $key) { continue }
        foreach ($vn in $key.GetValueNames()) {
            $v = $key.GetValue($vn)
            # first byte odd (0x03) = disabled in Task Manager, even (0x02) = enabled
            if ($v -is [byte[]] -and $v.Length -gt 0 -and (($v[0] -band 1) -eq 1)) {
                [void]$disabled.Add($vn)
                [void]$disabled.Add(($vn -replace '\.lnk$', ''))
            }
        }
    }
}
$startup = @(Get-CimInstance Win32_StartupCommand | ForEach-Object {
    $cmd = [string]$_.Command
    $isOff = $disabled.Contains([string]$_.Name) -or $disabled.Contains($cmd) -or $disabled.Contains(($cmd -replace '\.lnk$', ''))
    [pscustomobject]@{ Name = [string]$_.Name; Command = (HideUser $cmd); Enabled = (-not $isOff) }
})
$startupOn = @($startup | Where-Object { $_.Enabled })

$avList = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct | ForEach-Object {
    $hex = '{0:x6}' -f [int]$_.productState
    [pscustomobject]@{ Name = [string]$_.displayName; Enabled = ($hex.Substring(2, 2) -in @('10', '11')) }
})
$avOn         = @($avList | Where-Object { $_.Enabled })
$thirdPartyAV = @($avOn | Where-Object { $_.Name -notmatch 'Windows Defender|Microsoft Defender' })
$defenderRTP  = $null
try { $defenderRTP = (Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled } catch {}

$gpuInfo = @($gpus | ForEach-Object {
    $dd = $_.DriverDate
    $age = $null; $dateText = ''
    if ($dd) { $age = [int]((Get-Date) - $dd).TotalDays; $dateText = $dd.ToString('yyyy-MM-dd') }
    [pscustomobject]@{ Name = [string]$_.Name; Driver = [string]$_.DriverVersion; Date = $dateText; AgeDays = $age }
})
$nvGpu = $gpuInfo | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1

# ------------------------------------------------------------------ 6. CPU performance test
Say "[6/7] Performance test ($TestSeconds seconds) - the fans may get louder, that is normal..." 'Yellow'
$perfSamples = @(); $utilSamples = @(); $nominalMHz = $null
$pool = $null; $workers = @()
try {
    $pool = [runspacefactory]::CreateRunspacePool(1, $logical)
    $pool.Open()
    $burn = {
        param($sec)
        $end = [DateTime]::UtcNow.AddSeconds($sec)
        $x = 0.0
        while ([DateTime]::UtcNow -lt $end) {
            for ($k = 0; $k -lt 20000; $k++) { $x = [Math]::Sqrt($k * 1.0001) }
        }
    }
    for ($i = 0; $i -lt $logical; $i++) {
        $w = [powershell]::Create()
        $w.RunspacePool = $pool
        [void]$w.AddScript($burn).AddArgument($TestSeconds)
        $workers += [pscustomobject]@{ PS = $w; Handle = $w.BeginInvoke() }
    }
    $null = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'"
    Start-Sleep -Seconds 3
    $deadline = (Get-Date).AddSeconds($TestSeconds - 4)
    while ((Get-Date) -lt $deadline) {
        $pi = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'"
        if ($pi) {
            if ($pi.ProcessorFrequency) { $nominalMHz = [double]$pi.ProcessorFrequency }
            $perfSamples += [double]$pi.PercentProcessorPerformance
            $utilSamples += [double]$pi.PercentProcessorTime
        }
        Start-Sleep -Milliseconds 1000
    }
} catch {
} finally {
    foreach ($w in $workers) { try { [void]$w.PS.EndInvoke($w.Handle) } catch {}; $w.PS.Dispose() }
    if ($pool) { $pool.Close(); $pool.Dispose() }
}
$validPerf = @()
for ($i = 0; $i -lt $perfSamples.Count; $i++) {
    if ($utilSamples[$i] -ge 70 -and $perfSamples[$i] -gt 0) { $validPerf += $perfSamples[$i] }
}
$loadUtil = Avg $utilSamples
$perfAvg  = Avg $validPerf
$perfMin  = $null
if ($validPerf.Count) { $perfMin = [math]::Round(($validPerf | Measure-Object -Minimum).Minimum) }
if (-not $nominalMHz) { $nominalMHz = [double]$cpu.MaxClockSpeed }
$baseGHz = $null; $effGHz = $null
if ($nominalMHz) { $baseGHz = [math]::Round($nominalMHz / 1000, 2) }
if ($perfAvg -and $nominalMHz) { $effGHz = [math]::Round($nominalMHz * $perfAvg / 100 / 1000, 2) }
$testValid = ($perfAvg -and $loadUtil -ge 70)

# ------------------------------------------------------------------ 7. findings
Say '[7/7] Building your report...'

# --- power source
if ($hasBattery -and -not $onAC) {
    Add-Finding 'red' 'ON_BATTERY' 'اللابتوب شغّال على البطارية' ('نسبة الشحن: ' + (B "$batPct%")) (Steps @(
        'وصّل الشاحن الأصلي. لابتوبات الألعاب (مثل جهازك بكرت RTX) تخفّض سرعة المعالج والكرت بشكل كبير على البطارية لتوفير الشحن — هذا سلوك متوقع وليس عطل.',
        'بعد توصيل الشاحن شغّل الفحص مرة ثانية — نتيجة اختبار الأداء على البطارية غير دقيقة.'))
} elseif ($hasBattery) {
    Add-Finding 'green' 'ON_AC' 'الجهاز موصول بالشاحن' ('نسبة الشحن: ' + (B "$batPct%")) ''
}

# --- Windows power plan / power mode
$planIsPerf = $planName -in @('High performance', 'Ultimate Performance')
$powerEv = 'خطة الطاقة: ' + (B $planName) + ' — وضع الطاقة (Power mode): ' + (B $overlayName)
$powerFix = Steps @(
    'اضغط زر Start ثم <b>Settings</b> ← <b>System</b> ← <b>Power &amp; battery</b> (بالعربي: الإعدادات ← النظام ← الطاقة والبطارية).',
    'من خانة <b>Power mode</b> (وضع الطاقة) اختر <b>Best performance</b> (أفضل أداء) — خصوصاً وقت ما يكون الشاحن موصول.',
    'إذا كان <b>Energy saver</b> / <b>Battery saver</b> (موفّر الطاقة) شغّال، أطفئه.')
if ($planName -eq 'Power saver' -or $overlayName -eq 'Best power efficiency') {
    Add-Finding 'red' 'POWER_MODE_SAVER' 'وضع الطاقة في ويندوز على "توفير الطاقة" — هذا أبطأ وضع' $powerEv $powerFix
} elseif ($overlayName -eq 'Best performance' -or $planIsPerf) {
    Add-Finding 'green' 'POWER_MODE_OK' 'وضع الطاقة في ويندوز على أعلى أداء' $powerEv ''
} else {
    Add-Finding 'info' 'POWER_MODE_BALANCED' 'وضع الطاقة في ويندوز: متوازن' $powerEv $powerFix
}

# --- CPU performance under load
if (-not $testValid) {
    Add-Finding 'info' 'CPU_TEST_NA' 'اختبار سرعة المعالج ما اكتمل' 'ما قدرت أقيس سرعة المعالج تحت الضغط على هذا الجهاز. باقي النتائج صحيحة.' ''
} else {
    $cpuEv = 'سرعة المعالج تحت الضغط تقريباً ' + (B "$effGHz GHz") + ' مقابل السرعة الأساسية ' + (B "$baseGHz GHz") +
             ' — يعني ' + (B "$perfAvg%") + ' من الأساسية (أقل قراءة ' + (B "$perfMin%") + ').'
    if (-not $onAC) { $cpuEv += ' <b>تنبيه: القياس تم على البطارية.</b>' }
    if ($perfAvg -lt 75) {
        Add-Finding 'red' 'CPU_THROTTLED' 'المعالج ما يشتغل بسرعته الطبيعية — مخنوق (طاقة أو حرارة)' $cpuEv (Steps @(
            'وصّل الشاحن الأصلي للجهاز (مو شاحن جوال أو شاحن USB-C ضعيف).',
            "وضع الأداء من الشركة المصنعة: $vendorTip.",
            'وضع الطاقة في ويندوز: <b>Best performance</b> (الخطوات في البند الخاص فيه).',
            'الحرارة: شغّل الجهاز على طاولة صلبة، مو على السرير أو المخدة — فتحات التهوية تحت الجهاز وعلى جوانبه.',
            'إذا عمر الجهاز أكثر من سنة أو المراوح صوتها عالي باستمرار: تنظيف المراوح من الغبار عند فني (مع تغيير المعجون الحراري إذا احتاج).',
            ('للتأكد من الحرارة: برنامج <b>HWiNFO</b> المجاني من الموقع الرسمي hwinfo.com — إذا حرارة المعالج تثبت عند ' + (B '95–100°C') + ' وقت الشغل، المشكلة حرارة.')))
    } elseif ($perfAvg -lt 110) {
        Add-Finding 'yellow' 'CPU_LIMITED' 'المعالج يشتغل، لكن أقل من قدرته' $cpuEv (Steps @(
            "وضع الأداء من الشركة المصنعة: $vendorTip.",
            'وضع الطاقة في ويندوز: <b>Best performance</b> وقت ما يكون الشاحن موصول.',
            'الحرارة: سطح صلب، وفتحات التهوية مفتوحة ونظيفة.'))
    } else {
        Add-Finding 'green' 'CPU_OK' 'المعالج يوصل لسرعته العالية — قوة المعالج سليمة' $cpuEv ''
    }
}

# --- vendor performance mode (cannot be read by Windows, so it is a manual check)
$vendorLevel = 'info'
if (-not $testValid -or $perfAvg -lt 110) { $vendorLevel = 'yellow' }
Add-Finding $vendorLevel 'VENDOR_MODE' ('تأكد بنفسك من وضع الأداء في برنامج ' + (Enc $vendor.App)) `
    ('الشركة المصنعة: ' + (B $mfr) + '. هذا الإعداد ما يقدر الفحص يقرأه. الوضع الصامت (Silent / Quiet / Eco) يخفّض أداء المعالج والكرت بشكل كبير.') `
    (Steps @("$vendorTip.", 'إذا البرنامج مو مثبت، نزّله من متجر Microsoft Store أو من موقع الشركة الرسمي.'))

# --- restart / pending updates
if ($null -ne $uptimeDays -and $uptimeDays -gt 7) {
    Add-Finding 'yellow' 'LONG_UPTIME' ('الجهاز ما انعمل له إعادة تشغيل من ' + (B $uptimeDays) + ' يوم') `
        'إغلاق الجهاز العادي (Shut down) في ويندوز ما يصفّر النظام بالكامل بسبب خاصية Fast Startup — فقط Restart يسويها.' `
        (Steps @('احفظ شغلك، ثم Start ← زر الطاقة ← <b>Restart</b> (إعادة التشغيل) — مو Shut down.', 'عوّد نفسك تسوي Restart مرة بالأسبوع على الأقل.'))
}
if ($rebootPending) {
    Add-Finding 'yellow' 'REBOOT_PENDING' 'فيه تحديثات ويندوز تنتظر إعادة تشغيل' 'التحديثات المعلّقة تخلي ويندوز يشتغل بالخلفية.' `
        (Steps @('Start ← زر الطاقة ← <b>Update and restart</b> أو <b>Restart</b>. خلّ الجهاز على الشاحن لين يخلص.'))
}

# --- RAM
if ($null -ne $ramUsedPct) {
    $topMemNames = ($memTop | Select-Object -First 3 | ForEach-Object { (B $_.Name) + ' (' + (B "$($_.MB) MB") + ')' }) -join '، '
    $ramEv = 'المستخدم ' + (B "$ramUsedPct%") + ' من ' + (B "$ramTotalGB GB") + ' (المتاح ' + (B "$ramFreeGB GB") + '). أكثر البرامج استهلاكاً: ' + $topMemNames
    $ramFix = Steps @(
        'سكّر البرامج اللي ما تستخدمها، وخصوصاً تبويبات المتصفح الكثيرة — كل تبويب يأكل ذاكرة.',
        'في Chrome: Settings ← <b>Performance</b> ← شغّل <b>Memory Saver</b>. في Edge: Settings ← System and performance ← شغّل <b>Sleeping tabs</b>.',
        'إذا الاستهلاك عالي دائماً حتى بعد التنظيف وأنت تشتغل مونتاج أو أدوات ذكاء اصطناعي ثقيلة: ترقية الذاكرة إلى 32 GB حل حقيقي — اسألني وأحدد لك النوع المناسب لجهازك وأتحقق من السعر.')
    if ($ramUsedPct -ge 85 -or ($commitPct -ge 90)) {
        Add-Finding 'red' 'RAM_FULL' 'الذاكرة (RAM) شبه ممتلئة — هذا يسبب بطء واضح' $ramEv $ramFix
    } elseif ($ramUsedPct -ge 70) {
        Add-Finding 'yellow' 'RAM_HIGH' 'استهلاك الذاكرة (RAM) مرتفع' $ramEv $ramFix
    } else {
        Add-Finding 'green' 'RAM_OK' 'الذاكرة (RAM) فيها مساحة كافية' $ramEv ''
    }
}
if ($dimmCount -eq 1) {
    Add-Finding 'yellow' 'RAM_SINGLE_CHANNEL' 'الذاكرة شريحة وحدة (Single-channel)' `
        ('الموجود: ' + (B $dimmText) + '. شريحة وحدة تعطي نصف عرض نطاق الذاكرة مقارنة بشريحتين. التأثير يختلف حسب الاستخدام — أوضح في الألعاب والمونتاج.') `
        (Steps @('هذا مو أول حل — صلّح البنود الحمراء أولاً.', 'إذا قررت تطوّر: شريحة ثانية مطابقة (نفس الحجم والسرعة) — أرسل لي التقرير وأحدد لك المواصفات بالضبط.'))
} elseif ($dimmCount -ge 2) {
    Add-Finding 'green' 'RAM_DUAL_CHANNEL' 'الذاكرة شريحتين (Dual-channel)' ('الموجود: ' + (B $dimmText)) ''
}

# --- storage
if ($null -ne $cFreePct) {
    $diskEv = 'المساحة الفاضية في القرص ' + (B $sysDrive) + ' ' + (B "$cFreeGB GB") + ' من ' + (B "$cSizeGB GB") + ' (' + (B "$cFreePct%") + ')'
    $diskFix = Steps @(
        'Start ← Settings ← System ← <b>Storage</b> ← <b>Temporary files</b> ← حدد الملفات المؤقتة واحذفها. <b>انتبه:</b> لا تحدد خانة <b>Downloads</b> إذا فيها ملفات تبيها.',
        'في نفس الصفحة شغّل <b>Storage Sense</b> عشان ينظف تلقائياً.',
        'Settings ← Apps ← Installed apps ← رتّب حسب الحجم واحذف البرامج والألعاب اللي ما تستخدمها.',
        'انقل الفيديوهات والملفات الكبيرة لهارد خارجي أو تخزين سحابي.')
    if ($cFreePct -lt 10 -or $cFreeGB -lt 15) {
        Add-Finding 'red' 'DISK_FULL' 'القرص الأساسي شبه ممتلئ' $diskEv $diskFix
    } elseif ($cFreePct -lt 20 -or $cFreeGB -lt 30) {
        Add-Finding 'yellow' 'DISK_LOW' 'المساحة الفاضية في القرص قليلة' $diskEv $diskFix
    } else {
        Add-Finding 'green' 'DISK_SPACE_OK' 'مساحة القرص كافية' $diskEv ''
    }
}
$badDisks = @($pdisks | Where-Object { $_.Health -in @('Warning', 'Unhealthy') })
if ($badDisks.Count) {
    Add-Finding 'red' 'DISK_HEALTH' 'القرص يبلّغ عن مشكلة صحية' (($badDisks | ForEach-Object { (B $_.Name) + ': ' + (B $_.Health) }) -join '، ') `
        (Steps @('<b>خذ نسخة احتياطية من ملفاتك المهمة اليوم</b> (هارد خارجي أو OneDrive / Google Drive).', 'أرسل لي التقرير — ممكن القرص يحتاج تبديل.'))
}
$hdd = @($pdisks | Where-Object { $_.Type -eq 'HDD' })
if ($hdd.Count) {
    Add-Finding 'info' 'HDD_PRESENT' 'فيه قرص من النوع القديم (HDD)' (($hdd | ForEach-Object { B $_.Name }) -join '، ') `
        'إذا ويندوز مثبت عليه، هذا سبب رئيسي للبطء — النقل لقرص SSD يفرق بشكل كبير.'
}

# --- background CPU
$topCpuText = ($cpuTop | Select-Object -First 3 | ForEach-Object { (B $_.Name) + ' (' + (B "$($_.Pct)%") + ')' }) -join '، '
if ($null -ne $cpuIdleAvg) {
    $idleEv = 'استهلاك المعالج بدون ما تسوي شي: ' + (B "$cpuIdleAvg%") + '.'
    if ($topCpuText) { $idleEv += ' أكثر البرامج: ' + $topCpuText }
    $idleFix = Steps @(
        ('افتح Task Manager بالضغط على ' + (B 'Ctrl + Shift + Esc') + ' ← تبويب <b>Processes</b> ← رتّب حسب <b>CPU</b>.'),
        'إذا كان البرنامج اللي فوق هو Microsoft Defender أو Windows Update: هذا مؤقت — خلّ الجهاز على الشاحن ساعة لين يخلص.',
        'إذا برنامج تعرفه وما تحتاجه: سكّره. إذا ما تعرفه: أرسل لي اسمه قبل ما تحذف أي شي.')
    if ($cpuIdleAvg -ge 30) {
        Add-Finding 'red' 'CPU_BUSY_IDLE' 'المعالج مشغول بالخلفية بدون ما تستخدمه' $idleEv $idleFix
    } elseif ($cpuIdleAvg -ge 15) {
        Add-Finding 'yellow' 'CPU_SOME_BG' 'فيه نشاط ملحوظ بالخلفية' $idleEv $idleFix
    } else {
        Add-Finding 'green' 'CPU_IDLE_OK' 'ما فيه برامج تستهلك المعالج بالخلفية' $idleEv ''
    }
}

# --- background disk
if ($null -ne $diskBusyAvg -and $diskBusyAvg -ge 40) {
    $lvl = 'yellow'; if ($diskBusyAvg -ge 70) { $lvl = 'red' }
    Add-Finding $lvl 'DISK_BUSY' 'القرص مشغول بالخلفية' ('القرص مشغول ' + (B "$diskBusyAvg%") + ' من الوقت وأنت ما تسوي شي.') `
        (Steps @('Task Manager ← تبويب Processes ← رتّب حسب <b>Disk</b> وشوف مين فوق.', 'الأسباب الشائعة: Windows Update، فحص Defender، مزامنة OneDrive — غالباً مؤقتة.', 'إذا استمر على طول: أرسل لي التقرير.'))
}

# --- startup apps
$startupNames = ($startupOn | ForEach-Object { B $_.Name }) -join '، '
$startupFix = Steps @(
    ('اضغط ' + (B 'Ctrl + Shift + Esc') + ' لفتح Task Manager ← من القائمة الجانبية <b>Startup apps</b> (برامج بدء التشغيل).'),
    'اضغط كليك يمين على أي برنامج ما تحتاجه أول ما يفتح الجهاز ← <b>Disable</b>. (هذا ما يحذف البرنامج — تقدر ترجعه بنفس الطريقة).',
    ('خلّ شغّال: برامج الحماية، تعريفات الصوت والتاتش باد، وبرنامج ' + (Enc $vendor.App) + '. عطّل الباقي مثل: Spotify، Discord، Steam، Epic، Teams، WhatsApp إذا ما تحتاجها فور التشغيل.'))
if ($startupOn.Count -gt 15) {
    Add-Finding 'red' 'STARTUP_HEAVY' ('برامج كثيرة تشتغل مع بداية الجهاز (' + (B $startupOn.Count) + ')') $startupNames $startupFix
} elseif ($startupOn.Count -gt 8) {
    Add-Finding 'yellow' 'STARTUP_MANY' ('عدد البرامج اللي تشتغل مع بداية الجهاز مرتفع (' + (B $startupOn.Count) + ')') $startupNames $startupFix
} else {
    Add-Finding 'green' 'STARTUP_OK' ('برامج بدء التشغيل معقولة (' + (B $startupOn.Count) + ')') $startupNames ''
}

# --- antivirus
$avText = ($avList | ForEach-Object { (B $_.Name) + ' (' + $(if ($_.Enabled) { 'شغّال' } else { 'مطفي' }) + ')' }) -join '، '
if ($avOn.Count -ge 2) {
    Add-Finding 'red' 'AV_MULTIPLE' 'أكثر من برنامج حماية شغّال بنفس الوقت' $avText `
        (Steps @('برنامجين حماية مع بعض يتعاركون على نفس الملفات ويثقلون الجهاز.', 'خلّ واحد بس. رأيي: Microsoft Defender المدمج في ويندوز كافي لأغلب المستخدمين ومجاني. احذف الثاني من Settings ← Apps ← Installed apps.'))
} elseif ($thirdPartyAV.Count -ge 1) {
    Add-Finding 'yellow' 'AV_THIRD_PARTY' ('برنامج حماية خارجي: ' + (($thirdPartyAV | ForEach-Object { Enc $_.Name }) -join '، ')) $avText `
        (Steps @('برامج مثل McAfee و Norton غالباً تجي مثبتة كنسخة تجريبية من المصنع وتثقل الجهاز.', 'رأيي: إذا ما دفعت اشتراك وما تحتاج مزايا خاصة، احذفه من Settings ← Apps ← Installed apps — ويندوز يشغّل Microsoft Defender تلقائياً بعدها.'))
} elseif ($avOn.Count -eq 0 -and $avList.Count -gt 0 -and $defenderRTP -ne $true) {
    Add-Finding 'red' 'AV_NONE' 'ما فيه حماية فيروسات شغّالة' $avText `
        (Steps @('Start ← اكتب <b>Windows Security</b> ← Virus &amp; threat protection ← شغّل الحماية.'))
} elseif ($avList.Count -gt 0) {
    Add-Finding 'green' 'AV_OK' 'برنامج الحماية سليم (واحد فقط شغّال)' $avText ''
}

# --- GPU driver
if ($nvGpu -and $null -ne $nvGpu.AgeDays) {
    $gEv = (B $nvGpu.Name) + ' — تعريف بتاريخ ' + (B $nvGpu.Date) + ' (' + (B $nvGpu.AgeDays) + ' يوم)'
    if ($nvGpu.AgeDays -gt 365) {
        Add-Finding 'yellow' 'GPU_DRIVER_OLD' 'تعريف كرت الشاشة NVIDIA قديم (أكثر من سنة)' $gEv `
            (Steps @('نزّل برنامج <b>NVIDIA App</b> من الموقع الرسمي nvidia.com ← تبويب Drivers ← حدّث التعريف.', ('أو حدّث من برنامج الشركة المصنعة (' + (Enc $vendor.App) + ').')))
    } else {
        Add-Finding 'green' 'GPU_DRIVER_OK' 'تعريف كرت الشاشة NVIDIA حديث' $gEv ''
    }
}

# ------------------------------------------------------------------ build HTML report
$levelOrder = @{ red = 0; yellow = 1; info = 2; green = 3 }
$levelLabel = @{ red = 'مشكلة'; yellow = 'انتبه'; info = 'معلومة'; green = 'سليم' }
$sorted  = @($Findings | Sort-Object @{ Expression = { $levelOrder[$_.Level] } }, Index)
$nRed    = @($Findings | Where-Object { $_.Level -eq 'red' }).Count
$nYellow = @($Findings | Where-Object { $_.Level -eq 'yellow' }).Count

if ($nRed -gt 0) {
    $firstRed = ($sorted | Where-Object { $_.Level -eq 'red' } | Select-Object -First 1).Title
    $verdict = "لقيت <b>$nRed</b> مشكلة واضحة و <b>$nYellow</b> تنبيه. ابدأ بأول بطاقة حمراء: <b>$firstRed</b> — ثم اللي بعدها بالترتيب."
    $verdictClass = 'red'
} elseif ($nYellow -gt 0) {
    $verdict = "ما فيه مشاكل كبيرة، لكن فيه <b>$nYellow</b> تنبيه. نفّذها بالترتيب — كل وحدة تاخذ دقائق."
    $verdictClass = 'yellow'
} else {
    $verdict = 'العتاد والإعدادات سليمة. إذا الجهاز لسه ثقيل، السبب غالباً برنامج معيّن أو الإنترنت — أرسل ملف report-for-claude.txt لـ Claude مع وصف متى تحس بالثقل.'
    $verdictClass = 'green'
}

$cards = foreach ($f in $sorted) {
    $fixBlock = ''
    if ($f.Fix) {
        $fixBlock = '<div class="fix"><div class="fix-h">الحل</div>'
        if ($f.Fix -like '<ol>*') { $fixBlock += $f.Fix } else { $fixBlock += "<p>$($f.Fix)</p>" }
        $fixBlock += '</div>'
    }
    "<section class=""card $($f.Level)""><span class=""badge"">$($levelLabel[$f.Level])</span><h3>$($f.Title)</h3><p class=""ev"">$($f.Evidence)</p>$fixBlock</section>"
}

function Rows($items, [scriptblock]$Cells) { return (($items | ForEach-Object { '<tr>' + (& $Cells $_) + '</tr>' }) -join '') }

$sysRows = @(
    @('الجهاز', "$mfr $model"), @('المعالج', $cpuName), @('الذاكرة', "$ramTotalGB GB — $dimmText"),
    @('كرت الشاشة', (($gpuInfo | ForEach-Object { "$($_.Name) (driver $($_.Driver), $($_.Date))" }) -join ' | ')),
    @('ويندوز', $osName), @('BIOS', $biosText),
    @('الأقراص', (($pdisks | ForEach-Object { "$($_.Name) — $($_.Type)/$($_.Bus), $($_.SizeGB) GB, $($_.Health)" }) -join ' | ')),
    @('آخر إعادة تشغيل', "$uptimeDays يوم")
) | ForEach-Object { '<tr><th>' + (Enc $_[0]) + '</th><td dir="auto">' + (Enc $_[1]) + '</td></tr>' }

$memRows = Rows $memTop { param($r) '<td dir="ltr">' + (Enc $r.Name) + '</td><td dir="auto">' + (Enc $r.Desc) + '</td><td>' + (Enc $r.Count) + '</td><td dir="ltr">' + (Enc "$($r.MB) MB") + '</td>' }
$cpuRows = Rows $cpuTop { param($r) '<td dir="ltr">' + (Enc $r.Name) + '</td><td dir="auto">' + (Enc $r.Desc) + '</td><td dir="ltr">' + (Enc "$($r.Pct)%") + '</td>' }
$stRows  = Rows $startup { param($r) '<td dir="ltr">' + (Enc $r.Name) + '</td><td>' + $(if ($r.Enabled) { 'شغّال' } else { 'معطّل' }) + '</td><td dir="ltr" class="cmd">' + (Enc $r.Command) + '</td>' }
if (-not $cpuRows) { $cpuRows = '<tr><td colspan="3">ما فيه برنامج يستهلك أكثر من 0.5% بالخلفية.</td></tr>' }

$now = Get-Date -Format 'yyyy-MM-dd HH:mm'
$html = @"
<!doctype html>
<html lang="ar" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>فحص اللابتوب</title>
<style>
:root { --bg:#f6f7f9; --card:#ffffff; --text:#1d2330; --muted:#5d6675; --line:#e3e6eb;
        --red:#d6343f; --red-bg:#fdecee; --yellow:#b7791f; --yellow-bg:#fdf5e6;
        --green:#2f855a; --green-bg:#eaf6ef; --info:#3b6fb6; --info-bg:#ebf2fb; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#14171c; --card:#1d2128; --text:#e8eaee; --muted:#9aa3b2; --line:#2d323b;
          --red:#ff6b74; --red-bg:#3a1d21; --yellow:#f0b955; --yellow-bg:#352a17;
          --green:#5fcf92; --green-bg:#17301f; --info:#7aa7ec; --info-bg:#1a2638; }
}
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--text); font-family:"Segoe UI", Tahoma, Arial, sans-serif; font-size:16px; line-height:1.7; }
.wrap { max-width:860px; margin:0 auto; padding:24px 16px 48px; }
h1 { font-size:26px; margin:0 0 4px; }
.sub { color:var(--muted); margin:0 0 18px; font-size:14px; }
.verdict { border-radius:12px; padding:14px 18px; margin:0 0 22px; font-size:17px; }
.verdict.red { background:var(--red-bg); } .verdict.yellow { background:var(--yellow-bg); } .verdict.green { background:var(--green-bg); }
.card { background:var(--card); border:1px solid var(--line); border-inline-start:6px solid var(--muted); border-radius:12px; padding:14px 18px; margin:0 0 14px; }
.card.red { border-inline-start-color:var(--red); } .card.yellow { border-inline-start-color:var(--yellow); }
.card.green { border-inline-start-color:var(--green); } .card.info { border-inline-start-color:var(--info); }
.card h3 { margin:6px 0 4px; font-size:18px; }
.badge { display:inline-block; font-size:12px; font-weight:700; padding:1px 10px; border-radius:20px; }
.red .badge { background:var(--red-bg); color:var(--red); } .yellow .badge { background:var(--yellow-bg); color:var(--yellow); }
.green .badge { background:var(--green-bg); color:var(--green); } .info .badge { background:var(--info-bg); color:var(--info); }
.ev { color:var(--muted); margin:0 0 6px; }
.fix { border-top:1px dashed var(--line); margin-top:8px; padding-top:6px; }
.fix-h { font-weight:700; font-size:14px; }
.fix ol { margin:4px 0 0; padding-inline-start:22px; } .fix li { margin:3px 0; }
h2 { font-size:20px; margin:30px 0 10px; }
.tbl { overflow-x:auto; background:var(--card); border:1px solid var(--line); border-radius:12px; }
table { border-collapse:collapse; width:100%; font-size:14px; }
th, td { text-align:start; padding:7px 12px; border-bottom:1px solid var(--line); vertical-align:top; }
tr:last-child th, tr:last-child td { border-bottom:none; }
thead th { color:var(--muted); font-weight:600; }
td.cmd { font-size:12px; color:var(--muted); word-break:break-all; }
.note { color:var(--muted); font-size:13px; margin-top:26px; }
.next { background:var(--info-bg); border-radius:12px; padding:12px 18px; margin-top:24px; }
</style>
</head>
<body><div class="wrap">
<h1>فحص اللابتوب</h1>
<p class="sub"><bdi>$(Enc "$mfr $model")</bdi> · <bdi>$now</bdi> · هذا الفحص قرأ الإعدادات فقط — ما غيّر ولا حذف أي شيء في جهازك.</p>
<div class="verdict $verdictClass">$verdict</div>
$($cards -join "`n")
<div class="next"><b>الخطوة التالية:</b> نفّذ البطاقات الحمراء ثم الصفراء، وبعدها سوّ <b>Restart</b> وشغّل الفحص مرة ثانية. إذا تبي حل مفصّل لجهازك، أرسل ملف <bdi>report-for-claude.txt</bdi> (موجود بنفس المجلد) لـ Claude.</div>

<h2>معلومات الجهاز</h2>
<div class="tbl"><table>$($sysRows -join '')</table></div>

<h2>أكثر البرامج استهلاكاً للذاكرة (تقريبي)</h2>
<div class="tbl"><table><thead><tr><th>البرنامج</th><th>الوصف</th><th>عدد النسخ</th><th>الذاكرة</th></tr></thead><tbody>$memRows</tbody></table></div>

<h2>أكثر البرامج استهلاكاً للمعالج بالخلفية</h2>
<div class="tbl"><table><thead><tr><th>البرنامج</th><th>الوصف</th><th>من المعالج</th></tr></thead><tbody>$cpuRows</tbody></table></div>

<h2>برامج بدء التشغيل</h2>
<div class="tbl"><table><thead><tr><th>البرنامج</th><th>الحالة</th><th>المسار</th></tr></thead><tbody>$stRows</tbody></table></div>

<p class="note">الحدود المستخدمة في الحكم (مثل 85% للذاكرة، 75% لسرعة المعالج، 15 برنامج بدء تشغيل) قواعد عامة مبنية على الممارسة الشائعة — وليست أرقام رسمية من Microsoft أو الشركة المصنعة. أرقام الذاكرة لكل برنامج تقريبية.</p>
</div></body></html>
"@

# ------------------------------------------------------------------ build text report (for Claude)
$t = New-Object System.Text.StringBuilder
function L([string]$s) { [void]$t.AppendLine($s) }
L "LAPTOP CHECK REPORT  $now"
L "Model      : $mfr $model"
L "CPU        : $cpuName ($logical threads)"
L "RAM        : $ramTotalGB GB, used $ramUsedPct%, commit $commitPct%, modules: $dimmCount [$dimmText]"
L ("GPU        : " + (($gpuInfo | ForEach-Object { "$($_.Name) drv $($_.Driver) ($($_.Date))" }) -join ' | '))
L "OS         : $osName"
L "BIOS       : $biosText"
L "Power      : onAC=$onAC battery=$batPct% plan=$planName powerMode=$overlayName vendorApp=$($vendor.App)"
L "Uptime     : $uptimeDays days, rebootPending=$rebootPending"
L "System disk: $sysDrive free $cFreeGB GB of $cSizeGB GB ($cFreePct%)"
L ("Disks      : " + (($pdisks | ForEach-Object { "$($_.Name) $($_.Type)/$($_.Bus) $($_.SizeGB)GB $($_.Health)" }) -join ' | '))
L "Idle       : CPU $cpuIdleAvg%, disk busy $diskBusyAvg%"
L ("Top CPU    : " + (($cpuTop | ForEach-Object { "$($_.Name) $($_.Pct)%" }) -join ', '))
L ("Top RAM    : " + (($memTop | ForEach-Object { "$($_.Name) $($_.MB)MB x$($_.Count)" }) -join ', '))
L ("Startup ON : ($($startupOn.Count)) " + (($startupOn | ForEach-Object { $_.Name }) -join ', '))
L ("Antivirus  : " + (($avList | ForEach-Object { "$($_.Name)=$(if ($_.Enabled) { 'on' } else { 'off' })" }) -join ', ') + " defenderRTP=$defenderRTP")
L "CPU test   : load $loadUtil%, perf avg $perfAvg% (min $perfMin%) of base $baseGHz GHz => ~$effGHz GHz, samples $($validPerf.Count)"
L ''
L 'FINDINGS:'
foreach ($f in $sorted) { L ('[{0}] {1}' -f $f.Level.ToUpper(), $f.Code) }

# ------------------------------------------------------------------ save + open
$desk = [Environment]::GetFolderPath('Desktop')
if (-not $desk -or -not (Test-Path $desk)) { $desk = $env:USERPROFILE }
$outDir = Join-Path $desk ('Laptop-Check_' + (Get-Date -Format 'yyyy-MM-dd_HH-mm'))
$utf8 = New-Object System.Text.UTF8Encoding($true)
try {
    New-Item -ItemType Directory -Path $outDir -Force -ErrorAction Stop | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $outDir 'Laptop-Report.html'), $html, $utf8)
} catch {
    $outDir = Join-Path $env:TEMP ('Laptop-Check_' + (Get-Date -Format 'yyyy-MM-dd_HH-mm'))
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $outDir 'Laptop-Report.html'), $html, $utf8)
}
[System.IO.File]::WriteAllText((Join-Path $outDir 'report-for-claude.txt'), $t.ToString(), $utf8)

Say ''
Say '==================================================================' 'Green'
Say "  Done.  Problems: $nRed   Warnings: $nYellow" 'Green'
Say "  Report folder: $outDir" 'Green'
Say '  The report is opening in your browser now.' 'Green'
Say '  For a personalised fix, send report-for-claude.txt to Claude.' 'Green'
Say '==================================================================' 'Green'
Start-Process (Join-Path $outDir 'Laptop-Report.html')
