@echo off
title Laptop Fix
rem Single-file Laptop Fix: the PowerShell part below the marker is copied to %TEMP% and run.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText('%~f0',[Text.Encoding]::UTF8); $i=$s.IndexOf('#LAPTOPFIX'+'START'); $t=Join-Path $env:TEMP 'LaptopFix.ps1'; [IO.File]::WriteAllText($t,$s.Substring($i),(New-Object Text.UTF8Encoding $true)); & $t"
echo.
echo   You can close this window now.
pause
exit /b
#LAPTOPFIXSTART
<#
    LaptopFix.ps1  -  applies the fixes from the Laptop Check report (Windows 10/11).

    What it does : asks before every step, then
                   1) shows which programs run the many "node" processes (read-only)
                   2) keeps one browser and closes the other
                   3) closes the ChatGPT / Notion desktop apps and opens them as browser tabs
                   4) turns off auto-start for Teams, Edge auto-launch, Grammarly, ChatGPT, Notion
                   5) restarts the laptop (60-second warning, can be cancelled)
                   and writes an Arabic summary (what changed + how to undo) to the Desktop.
    What it does NOT do : delete or uninstall anything, close the Claude app, touch OneDrive
                   or Windows Security, need admin rights, or send anything over the internet.

    Run it with "Run-LaptopFix.bat" (double-click).
#>

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms

# ------------------------------------------------------------------ helpers
function Say([string]$Text, [string]$Color = 'Cyan') { Write-Host $Text -ForegroundColor $Color }

function Ask([string]$Text, [string]$Buttons = 'YesNo', [string]$Icon = 'Question') {
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    $opts  = [System.Windows.Forms.MessageBoxOptions]::RtlReading -bor [System.Windows.Forms.MessageBoxOptions]::RightAlign
    $r = [System.Windows.Forms.MessageBox]::Show($owner, $Text, 'Laptop Fix',
        [System.Windows.Forms.MessageBoxButtons]$Buttons, [System.Windows.Forms.MessageBoxIcon]$Icon,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button1, [System.Windows.Forms.MessageBoxOptions]$opts)
    $owner.Dispose()
    return [string]$r
}

function RamPct {
    $os = Get-CimInstance Win32_OperatingSystem
    if (-not $os -or -not $os.TotalVisibleMemorySize) { return $null }
    return [math]::Round(100 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100))
}

function Get-AppExe([string]$Exe) {
    foreach ($root in 'HKCU:', 'HKLM:') {
        $p = (Get-ItemProperty -LiteralPath "$root\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$Exe").'(default)'
        if ($p) { $p = $p.Trim('"'); if (Test-Path -LiteralPath $p) { return $p } }
    }
    return $null
}

function Open-Url([string]$Exe, [string]$Url) {
    if ($Exe) { Start-Process -FilePath $Exe -ArgumentList $Url } else { Start-Process $Url }
}

function Stop-App([string]$Name) {
    $p = @(Get-Process -Name $Name)
    if ($p.Count -eq 0) { return $false }
    $p | Stop-Process -Force
    Start-Sleep -Milliseconds 800
    return $true
}

$Done = New-Object System.Collections.ArrayList   # what was changed
$Todo = New-Object System.Collections.ArrayList   # what is left for the user
$Info = New-Object System.Collections.ArrayList   # read-only findings
$Undo = New-Object System.Collections.ArrayList   # how to reverse each change

try { Clear-Host } catch {}
Say '=================================================================='
Say '  Laptop Fix  -  asks before every change. Deletes nothing.'
Say '  The Claude app stays open.'
Say '=================================================================='
Say ''

$ramStart = RamPct
$onAC = ([System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq 'Online')

$intro = "هذي الأداة تطبّق خطوات تسريع اللابتوب، وتسألك قبل كل خطوة.`n`n" +
         "• ما تحذف ولا تلغي تثبيت أي برنامج.`n" +
         "• ما تقفل تطبيق Claude.`n" +
         "• كل شي تغيّره ينرجع، والطريقة مكتوبة في الملخص.`n`n" +
         "الذاكرة الحين: $ramStart%`n`n" +
         "احفظ أي شغل مفتوح، وبعدها اضغط OK."
if ((Ask $intro 'OKCancel' 'Information') -ne 'OK') { Say 'Cancelled. Nothing was changed.' 'Yellow'; exit 0 }

# ------------------------------------------------------------------ 1. who runs "node" (read-only)
Say '[1/5] Finding which programs run the "node" processes...'
$all  = @(Get-CimInstance Win32_Process)
$byId = @{}
foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
$passThrough = @('node.exe', 'cmd.exe', 'conhost.exe', 'npx.exe', 'npm.exe', 'powershell.exe', 'pwsh.exe', 'uv.exe', 'uvx.exe', 'bun.exe')

function Owner-Label($proc) {
    $cur = $proc
    for ($i = 0; $i -lt 12; $i++) {
        $parent = $byId[[int]$cur.ParentProcessId]
        # a parent that started after the child is a reused process ID: the real parent is gone
        if (-not $parent -or $parent.ProcessId -eq $cur.ProcessId -or
            ($parent.CreationDate -and $cur.CreationDate -and $parent.CreationDate -gt $cur.CreationDate)) {
            return 'unknown (its parent already closed)'
        }
        $n = ([string]$parent.Name).ToLower()
        if ($passThrough -notcontains $n) {
            $path = [string]$parent.ExecutablePath
            if ($n -eq 'claude.exe' -and $path -match '\\\.local\\bin\\') { return 'Claude Code (terminal window)' }
            if ($n -eq 'claude.exe') { return 'Claude app' }
            if ($n -eq 'windowsterminal.exe' -or $n -eq 'explorer.exe') { return 'Terminal window (often Claude Code)' }
            return [string]$parent.Name
        }
        $cur = $parent
    }
    return 'unknown'
}

$nodes = @($all | Where-Object { $_.Name -ieq 'node.exe' })
$nodeGroups = @($nodes | ForEach-Object {
    [pscustomobject]@{ Owner = (Owner-Label $_); MB = [math]::Round($_.WorkingSetSize / 1MB) }
} | Group-Object Owner | ForEach-Object {
    [pscustomobject]@{ Owner = $_.Name; Count = $_.Count; MB = [int](($_.Group | Measure-Object MB -Sum).Sum) }
} | Sort-Object Count -Descending)

if ($nodes.Count -eq 0) {
    [void]$Info.Add('node: ما فيه ولا نسخة شغالة الحين.')
} else {
    [void]$Info.Add("node: $($nodes.Count) نسخة شغالة. مين مشغّلها:")
    foreach ($g in $nodeGroups) {
        [void]$Info.Add("   - $($g.Owner): $($g.Count) نسخة، حوالي $($g.MB) MB")
        Say ("      {0,-40} {1,3} x node  {2,5} MB" -f $g.Owner, $g.Count, $g.MB) 'Gray'
    }
    $top = $nodeGroups[0].Owner
    if ($top -like 'Claude Code*' -or $top -like 'Terminal*') {
        [void]$Todo.Add('نوافذ Claude Code المفتوحة في التيرمنال هي اللي مشغّلة أغلب نسخ node. كل نافذة تشغّل نسخها الخاصة. سكّر النوافذ اللي خلصت منها: اكتب /exit واضغط Enter. إعادة التشغيل تسكّرها كلها بعد، فبعدها لا تفتح إلا اللي تحتاجه.')
    } elseif ($top -eq 'Claude app') {
        [void]$Todo.Add('تطبيق Claude هو اللي مشغّل أغلب نسخ node، عن طريق الإضافات (Extensions/Connectors). من إعدادات Claude عطّل الإضافات اللي ما تستخدمها.')
    }
}

$claudeCode = @($all | Where-Object { $_.Name -ieq 'claude.exe' -and ([string]$_.ExecutablePath) -match '\\\.local\\bin\\' -and $byId[[int]$_.ParentProcessId].Name -ine 'claude.exe' })
if ($claudeCode.Count -gt 0) {
    [void]$Info.Add("نوافذ Claude Code مفتوحة في التيرمنال: $($claudeCode.Count)")
}

# ------------------------------------------------------------------ 2. one browser
Say '[2/5] Browsers...'
$chromeExe = Get-AppExe 'chrome.exe'
$edgeExe   = Get-AppExe 'msedge.exe'
$chromeOn  = @(Get-Process -Name chrome).Count -gt 0
$edgeOn    = @(Get-Process -Name msedge).Count -gt 0
$keep = $null

if ($chromeOn -and $edgeOn -and $chromeExe) {
    $q = "Chrome و Edge شغّالين مع بعض، وكل واحد ياكل ذاكرة لحاله.`n`n" +
         "Yes = خلّ Chrome وسكّر Edge (أنصح فيه، لأن لوحة الموسم و Claude in Chrome شغّالين عليه)`n" +
         "No = خلّ Edge وسكّر Chrome`n" +
         "Cancel = لا تغيّر شي`n`n" +
         "التبويبات ما تضيع، المتصفح يرجّعها لما تفتحه."
    switch (Ask $q 'YesNoCancel') {
        'Yes' { $keep = 'chrome' }
        'No'  { $keep = 'edge' }
    }
    if ($keep -eq 'chrome') {
        if (Stop-App 'msedge') {
            [void]$Done.Add('سكّرت Edge، وخلّيت Chrome.')
            [void]$Undo.Add('Edge: افتحه عادي، ويرجّع لك التبويبات.')
        }
    } elseif ($keep -eq 'edge') {
        if (Stop-App 'chrome') {
            [void]$Done.Add('سكّرت Chrome، وخلّيت Edge.')
            [void]$Undo.Add('Chrome: افتحه عادي، ويرجّع لك التبويبات.')
        }
    }
} elseif ($chromeOn -and $chromeExe) { $keep = 'chrome' }
elseif ($edgeOn -and $edgeExe)       { $keep = 'edge' }
elseif ($chromeExe)                  { $keep = 'chrome' }
elseif ($edgeExe)                    { $keep = 'edge' }

$browserExe = $null
if ($keep -eq 'chrome') {
    $browserExe = $chromeExe
    Open-Url $chromeExe 'chrome://settings/performance'
    [void]$Todo.Add('في Chrome فتحت لك صفحة Performance: شغّل Memory Saver. إذا ما انفتحت الصفحة: Settings ثم Performance.')
} elseif ($keep -eq 'edge') {
    $browserExe = $edgeExe
    Open-Url $edgeExe 'edge://settings/system'
    [void]$Todo.Add('في Edge فتحت لك صفحة System and performance: شغّل Sleeping tabs. إذا ما انفتحت الصفحة: Settings ثم System and performance.')
}

# ------------------------------------------------------------------ 3. ChatGPT / Notion desktop apps -> browser tabs
Say '[3/5] ChatGPT and Notion apps...'
$apps = @(
    [pscustomobject]@{ Name = 'ChatGPT'; Proc = 'ChatGPT'; Url = 'https://chatgpt.com' },
    [pscustomobject]@{ Name = 'Notion';  Proc = 'Notion';  Url = 'https://www.notion.so' }
)
$running = @($apps | Where-Object { @(Get-Process -Name $_.Proc).Count -gt 0 })
if ($running.Count -gt 0) {
    $names = ($running | ForEach-Object { $_.Name }) -join ' و '
    $where = 'المتصفح'
    if ($keep -eq 'chrome') { $where = 'Chrome' } elseif ($keep -eq 'edge') { $where = 'Edge' }
    $q = "تطبيق $names شغّال. كل تطبيق منهم متصفح كامل لحاله، وياكل ذاكرة حتى وأنت ما تستخدمه.`n`n" +
         "أسكّره وأفتحه لك كتبويب في $where بدال التطبيق؟`n`n" +
         "حساباتك ومحادثاتك وصفحاتك نفسها. بس تأكد إنك مو في نص كتابة في Notion."
    if ((Ask $q 'YesNo') -eq 'Yes') {
        foreach ($a in $running) {
            if (Stop-App $a.Proc) {
                Open-Url $browserExe $a.Url
                [void]$Done.Add("سكّرت تطبيق $($a.Name)، وفتحته كتبويب ($($a.Url)).")
            }
        }
        [void]$Todo.Add('ثبّت تبويب ChatGPT و Notion: كليك يمين على التبويب ثم Pin. وسجّل دخول إذا طلب منك.')
        [void]$Undo.Add('ChatGPT و Notion: التطبيقات ما انحذفت. افتحها من قائمة Start متى ما بغيت.')
    }
} else {
    [void]$Info.Add('ChatGPT و Notion: التطبيقات مو شغالة الحين.')
}

# ------------------------------------------------------------------ 4. startup apps
Say '[4/5] Startup apps...'
$target   = '(?i)teams|edgeautolaunch|grammarly|chatgpt|notion'
$approved = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

function Is-Approved([string]$Hive, [string]$Sub, [string]$ValueName) {
    $k = Get-Item -LiteralPath "$Hive\$approved\$Sub"
    if (-not $k) { return $true }
    $v = $k.GetValue($ValueName)
    if ($v -is [byte[]] -and $v.Length -gt 0) { return (($v[0] -band 1) -eq 0) }
    return $true
}

$items = New-Object System.Collections.ArrayList
# current-user Run key (no admin needed)
$run = Get-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ($run) {
    foreach ($vn in $run.GetValueNames()) {
        if ($vn -match $target -and (Is-Approved 'HKCU:' 'Run' $vn)) {
            [void]$items.Add([pscustomobject]@{ Kind = 'run'; Name = $vn; Key = 'HKCU:'; Sub = 'Run' })
        }
    }
}
# current-user Startup folder
$sf = [Environment]::GetFolderPath('Startup')
if ($sf -and (Test-Path -LiteralPath $sf)) {
    foreach ($f in Get-ChildItem -LiteralPath $sf -File) {
        if ($f.Name -match $target -and (Is-Approved 'HKCU:' 'StartupFolder' $f.Name)) {
            [void]$items.Add([pscustomobject]@{ Kind = 'run'; Name = $f.Name; Key = 'HKCU:'; Sub = 'StartupFolder' })
        }
    }
}
# Store / packaged apps (new Teams, ChatGPT). State: 0 off, 1 off by user, 2 on, 3/4 set by policy
$sad = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
foreach ($pkg in Get-ChildItem -LiteralPath $sad) {
    if ($pkg.PSChildName -notmatch $target) { continue }
    foreach ($task in Get-ChildItem -LiteralPath $pkg.PSPath) {
        if ($task.GetValue('State') -eq 2) {
            [void]$items.Add([pscustomobject]@{ Kind = 'pkg'; Name = ($pkg.PSChildName -replace '_[a-z0-9]{13}$', ''); Path = $task.PSPath })
        }
    }
}
# all-users entries need admin: report only
$adminOnly = New-Object System.Collections.ArrayList
foreach ($pair in @(@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'Run'),
                    @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'Run32'))) {
    $k = Get-Item -LiteralPath $pair[0]
    if (-not $k) { continue }
    foreach ($vn in $k.GetValueNames()) {
        if ($vn -match $target -and (Is-Approved 'HKLM:' $pair[1] $vn) -and (Is-Approved 'HKCU:' $pair[1] $vn)) { [void]$adminOnly.Add($vn) }
    }
}

if ($items.Count -gt 0) {
    $list = ($items | ForEach-Object { '• ' + ($_.Name -replace '_[0-9A-F]{32}$', '') }) -join "`n"
    $q = "هذي البرامج تشتغل لحالها مع كل تشغيل للجهاز، وتاكل ذاكرة حتى لو ما فتحتها:`n`n$list`n`n" +
         "أوقّف تشغيلها التلقائي؟`n`n" +
         "البرامج تبقى زي ما هي، وتشتغل عادي لما تفتحها بنفسك. OneDrive وحماية ويندوز ما ألمسها."
    if ((Ask $q 'YesNo') -eq 'Yes') {
        foreach ($it in $items) {
            $label = $it.Name -replace '_[0-9A-F]{32}$', ''
            $ok = $false
            if ($it.Kind -eq 'run') {
                $path = "$($it.Key)\$approved\$($it.Sub)"
                if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
                [byte[]]$bytes = @(3, 0, 0, 0) + [BitConverter]::GetBytes([long](Get-Date).ToFileTime())
                New-ItemProperty -LiteralPath $path -Name $it.Name -Value $bytes -PropertyType Binary -Force | Out-Null
                $ok = -not (Is-Approved $it.Key $it.Sub $it.Name)
            } else {
                Set-ItemProperty -LiteralPath $it.Path -Name 'State' -Value 1 -Type DWord
                $ok = ((Get-ItemProperty -LiteralPath $it.Path).State -eq 1)
            }
            if ($ok) { [void]$Done.Add("أوقفت التشغيل التلقائي لـ $label.") }
            else     { [void]$Todo.Add("ما قدرت أوقف التشغيل التلقائي لـ $label. سوّها يدوي: Ctrl + Shift + Esc ثم Startup apps ثم كليك يمين عليه ثم Disable.") }
        }
        [void]$Undo.Add('برامج بدء التشغيل: Ctrl + Shift + Esc ثم Startup apps ثم كليك يمين على البرنامج ثم Enable.')
    }
} else {
    [void]$Info.Add('برامج بدء التشغيل: ما لقيت شي من القائمة (Teams / Edge / Grammarly / ChatGPT / Notion) شغّال تلقائياً.')
}
if ($adminOnly.Count -gt 0) {
    [void]$Todo.Add('هذي مسجّلة لكل المستخدمين وتحتاج صلاحية مدير: ' + ($adminOnly -join '، ') + '. عطّلها من Ctrl + Shift + Esc ثم Startup apps.')
}

# ------------------------------------------------------------------ 5. restart + summary
Say '[5/5] Restart and summary...'
Start-Sleep -Seconds 4
$ramNow = RamPct

$os = Get-CimInstance Win32_OperatingSystem
$upDays = $null
if ($os -and $os.LastBootUpTime) { $upDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1) }

$q = "آخر خطوة: إعادة تشغيل الجهاز."
if ($upDays -ne $null) { $q += " آخر Restart كان قبل $upDays يوم." }
$q += "`n`nالذاكرة كانت $ramStart% وصارت $ramNow%. بعد Restart تنزل أكثر.`n`n" +
      "احفظ شغلك أول. الجهاز بيعيد التشغيل بعد دقيقة من ضغطك Yes."
if ($claudeCode.Count -gt 0) {
    $q += "`n`nنوافذ Claude Code المفتوحة بتتسكّر. محادثاتها محفوظة، وترجع لها بالأمر claude --resume."
}
$q += "`n`nإذا غيّرت رأيك خلال الدقيقة: Win + R واكتب shutdown /a واضغط Enter.`n`nإعادة التشغيل الحين؟"
$restart = ((Ask $q 'YesNo' 'Warning') -eq 'Yes')
if ($restart) {
    [void]$Done.Add('جدولت إعادة تشغيل الجهاز بعد دقيقة.')
} else {
    [void]$Todo.Insert(0, 'سوّ Restart لما تخلص شغلك: Start ثم زر الطاقة ثم Restart (مو Shut down).')
}

if (-not $onAC) {
    [void]$Todo.Insert(0, 'وصّل الشاحن. الجهاز يخفّض الأداء وهو على البطارية. ومن برنامج Control Center اختر أعلى وضع أداء.')
}
[void]$Todo.Add('أولوية منخفضة: حدّث تعريف كرت NVIDIA من NVIDIA App. يفرق في المونتاج وأدوات الذكاء الاصطناعي، مو في الثقل العام.')

$sb = New-Object System.Text.StringBuilder
function L([string]$s) { [void]$sb.AppendLine($s) }
L ('ملخص تسريع اللابتوب  -  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
L '=================================================='
L ''
L "الذاكرة قبل: $ramStart%    الذاكرة بعد الخطوات: $ramNow%"
L '(الرقم الحقيقي يبان بعد إعادة التشغيل.)'
L ''
L '--- اللي سويته ---'
if ($Done.Count -eq 0) { L '- ما تغيّر شي.' } else { foreach ($x in $Done) { L ('- ' + $x) } }
L ''
L '--- اللي باقي عليك ---'
$n = 1; foreach ($x in $Todo) { L ("$n. " + $x); $n++ }
L ''
L '--- اللي لقيته (بدون أي تغيير) ---'
foreach ($x in $Info) { L ('- ' + $x) }
L ''
L '--- طريقة الإرجاع ---'
if ($Undo.Count -eq 0) { L '- ما فيه شي يحتاج إرجاع.' } else { foreach ($x in $Undo) { L ('- ' + $x) } }
L ''
L '--- الخطوة الجاية ---'
L 'بعد إعادة التشغيل: وصّل الشاحن، وافتح برامجك المعتادة، وانتظر 10 دقايق.'
L 'بعدها شغّل Run-LaptopCheck مرة ثانية، وأرسل لـ Claude محتوى report-for-claude.txt الجديد.'

$desk = [Environment]::GetFolderPath('Desktop')
if (-not $desk -or -not (Test-Path -LiteralPath $desk)) { $desk = $env:USERPROFILE }
$out = Join-Path $desk ('Laptop-Fix_' + (Get-Date -Format 'yyyy-MM-dd_HH-mm') + '.txt')
[System.IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
Start-Process notepad.exe -ArgumentList ('"' + $out + '"')

Say ''
Say "  RAM: $ramStart% -> $ramNow%" 'Green'
Say "  Summary saved on the Desktop: $(Split-Path -Leaf $out)" 'Green'
if ($restart) {
    & shutdown.exe /r /t 60 /c "Laptop Fix: restarting in 60 seconds. To cancel: Win+R, type shutdown /a"
    Say '  Restarting in 60 seconds. To cancel: Win+R -> shutdown /a' 'Yellow'
} else {
    Say '  No restart now. Restart later: Start -> Power -> Restart.' 'Yellow'
}
Say ''
