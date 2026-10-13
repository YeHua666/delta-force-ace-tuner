@echo off
setlocal
title Delta Force ACE Tuner - Installer
set "SELF=%~f0"
set "TMPPS=%TEMP%\df_ace_tuner_%RANDOM%%RANDOM%.ps1"

rem ---- extract the embedded PowerShell script (everything after #PS_START) ----
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f = Get-Content -LiteralPath $env:SELF -Encoding UTF8; $i = [array]::IndexOf($f, '#PS_START'); if ($i -lt 0) { exit 9 }; Set-Content -LiteralPath $env:TMPPS -Value ($f[($i + 1)..($f.Count - 1)]) -Encoding UTF8"
if errorlevel 1 (
    echo [ERROR] Failed to extract the embedded script.
    pause
    exit /b 1
)

if /i "%~1"=="/u" goto uninstall
if /i "%~1"=="-u" goto uninstall
if /i "%~1"=="/uninstall" goto uninstall
if /i "%~1"=="uninstall" goto uninstall

powershell -NoProfile -ExecutionPolicy Bypass -File "%TMPPS%" -Menu
set "RC=%ERRORLEVEL%"
goto cleanup

:uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File "%TMPPS%" -Uninstall
set "RC=%ERRORLEVEL%"

:cleanup
del "%TMPPS%" >nul 2>&1
echo.
echo ------------------------------------------------------------
echo Exit code: %RC%   (0 = OK)
echo Uninstall: run this file again and choose 1, or run it with the /u argument
echo ------------------------------------------------------------
pause
exit /b %RC%

#PS_START
<#
    三角洲行动 · ACE 自动调优（SGuard64 / SGuardSvc64）
    ------------------------------------------------------------------
    功能：在《三角洲行动》游戏本体启动之后，自动把 ACE-Guard 的两个进程
            · SGuard64.exe     （ACE-Guard Client）
            · SGuardSvc64.exe  （ACE-Guard Service）
          的“优先级”改成“低”，并把“处理器相关性”改成“仅 CPU23”。

    为什么必须先等游戏启动：ACE 防护在游戏本体起来之前不会生效／会拒绝外部修改，
          所以脚本先等待 DeltaForce*（游戏本体，不含 launcher）进程出现，
          然后才开始设置；如果被拒绝，会自动每隔几秒重试，直到成功。

    运行方式：
      · 双击“三角洲行动”快捷方式（快捷方式已指向本脚本）：
            非管理员 → 先启动游戏启动器，再弹一次 UAC 申请管理员权限，
                       随后进入静默监听；管理员 → 直接进入监听。
      · ACE 的 SGuard64 / SGuardSvc64 往往比游戏本体晚很多才出现，脚本会
        一直等它们（不会超时放弃），一出现立刻设置。
      · 平时脚本处于阻塞等待（订阅“新进程启动”事件 + 内核等待），不轮询、
        CPU 占用为 0；ACE 重启进程或游戏退出时才会被唤醒。
        加上 -ExitAfterApply 可以让它在设置成功后直接退出。
      · 手动检查（只看不改）：以管理员身份运行 PowerShell
            powershell -NoProfile -ExecutionPolicy Bypass -File "本脚本路径" -DryRun
#>
[CmdletBinding()]
param(
    # 只允许运行的 CPU 编号（任务管理器里的 CPU 编号）默认 23
    [int]$CpuIndex = 23,
    # 优先级：Low = 任务管理器里的“低”
    [ValidateSet('Low', 'BelowNormal', 'Normal', 'AboveNormal', 'High')]
    [string]$Priority = 'Low',
    # 检查间隔（秒）：只用在“等待游戏启动 / 还没设置成功”的阶段；
    # 全部设置成功后会改成阻塞式休眠等待，不再轮询、不占 CPU
    [int]$PollSeconds = 3,
    # 检测到游戏本体后再等几秒，尽量避开 ACE 初始化阶段
    [int]$SettleSeconds = 10,
    # 需要设置的进程名（ACE-Guard 的两个进程）
    [string[]]$GuardNames = @('SGuard64', 'SGuardSvc64'),
    # 等待游戏启动的最长时间（分钟），超时后自动退出
    [int]$WaitGameMinutes = 180,
    # 本脚本最长运行时间（小时），防止进程长期驻留
    [int]$MaxRuntimeHours = 12,
    # 游戏退出后，持续观察多久（秒）再结束监听
    [int]$ExitAfterGameGoneSeconds = 60,
    # 休眠等待的最长时间（秒）：期间一旦有新进程启动会立刻唤醒；
    # 超时也只做一次轻量复核，因此 CPU 占用依旧是 0
    [int]$IdleWakeSeconds = 30,
    # 设置失败时“短间隔重试”的窗口（秒）与最大次数，超过后转入休眠等待（不再频繁重试）
    [int]$QuickRetrySeconds = 120,
    [int]$MaxQuickAttempts = 40,
    # 设置完成一次后直接结束脚本（不再监听 ACE 是否重启）
    [switch]$ExitAfterApply,
    # 日志文件路径，默认脚本同目录 ace-tuner.log
    [string]$LogPath = '',
    # 只报告当前状态，不做任何修改、也不启动游戏、不申请 UAC
    [switch]$DryRun,
    # 一键安装：把脚本装到本机、自动识别游戏目录与 CPU 编号、接管现有快捷方式
    [switch]$Install,
    # 卸载：还原快捷方式并删除安装目录
    [switch]$Uninstall,
    # 常驻后台模式（计划任务用）：一直等待游戏启动，游戏退出后继续等下一次
    [switch]$Persistent,
    # 双击入口：已装过就显示“卸载 / 重装 / 退出”菜单
    [switch]$Menu
)

$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $PSScriptRoot 'ace-tuner.log'
}

# 命令行用 -File 传参数时，-GuardNames "A","B" 会被合并成一个字符串 "A,B"，
# 这里统一按逗号拆开，避免出现“进程名变成 A,B”这种致命错误。
$GuardNames = @(
    $GuardNames |
        ForEach-Object { [string]$_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' }
)
if ($GuardNames.Count -eq 0) { $GuardNames = @('SGuard64', 'SGuardSvc64') }

# ========================================================================
#  一键安装 / 卸载（供 批处理 调用：-Install / -Uninstall）
# ========================================================================

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ShortcutCandidates {
    # 收集桌面 / 公共桌面 / 开始菜单里的“三角洲行动”快捷方式
    $dirs = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('Programs'),
        [Environment]::GetFolderPath('CommonPrograms'),
        (Join-Path $env:USERPROFILE 'OneDrive\Desktop'),
        (Join-Path $env:USERPROFILE 'OneDrive\桌面')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    foreach ($d in $dirs) {
        # 桌面和开始菜单里都可能有子文件夹（例如把快捷方式放进“游戏”文件夹），所以递归两层找
        foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.lnk' -Recurse -Depth 2 -Force -ErrorAction SilentlyContinue)) {
            $sc = $null
            try { $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($f.FullName) } catch { continue }
            if (-not $sc) { continue }
            # 排除“卸载 / 反安装”之类的快捷方式，别把它们也改了
            if (($f.Name -like '*卸载*') -or ($f.Name -like '*uninstall*') -or ($sc.TargetPath -match '(?i)unins')) { continue }
            $isGame = ($f.Name -like '*三角洲*') -or ($sc.TargetPath -like '*delta_force_launcher*')
            if ($isGame) {
                [PSCustomObject]@{ Path = $f.FullName; Target = $sc.TargetPath; Work = $sc.WorkingDirectory; Icon = $sc.IconLocation }
            }
        }
    }
}
function Install-Tuner {
    Disable-ConsoleQuickEdit
    Write-Host ''
    Write-Host '========== 三角洲行动 ACE 自动调优 · 一键安装 ==========' -ForegroundColor Cyan
    Write-Host ''

    # 注册后台任务需要管理员权限
    if (-not (Test-IsAdmin)) {
        Write-Host '安装需要管理员权限，正在弹出 UAC 授权窗口，请在弹窗里点“是”……' -ForegroundColor Yellow
        $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Install' -f $PSCommandPath
        try {
            $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                -ArgumentList $argLine -Verb RunAs -Wait -PassThru
            exit $p.ExitCode
        }
        catch {
            Write-Host '已取消授权，安装没有完成。' -ForegroundColor Red
            exit 1
        }
        return
    }

    # 1) 安装脚本
    $installDir = Join-Path $env:ProgramData 'DeltaForce-ACE-Tuner'
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    try {
        # 让普通用户也能打开日志
        $acl = Get-Acl -LiteralPath $installDir
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('Users', 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $installDir -AclObject $acl
    }
    catch { }
    $installed = Join-Path $installDir 'ace-guard-tuner.ps1'
    if ((Resolve-Path -LiteralPath $PSCommandPath).Path -ne (Resolve-Path -LiteralPath $installed -ErrorAction SilentlyContinue).Path) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $installed -Force
    }
    Write-Host ("1/3 脚本已安装到：{0}" -f $installDir)

    # 2) 按本机 CPU 线程数自动匹配目标 CPU
    $cpu = [int]$env:NUMBER_OF_PROCESSORS - 1
    if ($cpu -lt 0) { $cpu = 0 }
    $text = [System.IO.File]::ReadAllText($installed, [System.Text.Encoding]::UTF8)
    $new = [regex]::Replace($text, '\[int\]\$CpuIndex\s*=\s*\d+', ('[int]$CpuIndex = ' + $cpu))
    if ($new -ne $text) { [System.IO.File]::WriteAllText($installed, $new, (New-Object System.Text.UTF8Encoding($true))) }
    Write-Host ("2/3 本机逻辑处理器 {0} 个，已自动匹配为 CPU {1}" -f $env:NUMBER_OF_PROCESSORS, $cpu)

    # 3) 注册后台常驻任务（用 SYSTEM 运行，不弹窗、不需要每次 UAC，因此 WeGame / 启动器 / 快捷方式启动都生效）
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $logPath = Join-Path $installDir 'ace-tuner.log'
    $taskName = 'DeltaForce-ACE-Tuner'
    $taskOk = $false
    # 一次运行：最多等游戏 20 分钟，设置好之后一直保持到游戏退出
    # -ExitAfterApply：设置成功就立刻结束脚本，不在后台继续挂机
    $taskArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -WaitGameMinutes 20 -ExitAfterApply -LogPath "{1}"' -f $installed, $logPath
    $sub = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Service Control Manager''] and EventID=7045]]</Select></Query></QueryList>'

    # 触发条件：系统日志出现“服务已安装(7045)”事件 —— ACE 每次启动游戏都会装它的驱动，
    # 所以平时机器上没有任何进程，游戏一启动脚本才被唤醒。
    # 方式一：直接写任务 XML（不依赖 TaskScheduler 的 WMI 类）
    try {
        $xml = @"
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>三角洲行动 ACE 自动调优（ACE 启动时触发）</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Service Control Manager'] and EventID=7045]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$psExe</Command>
      <Arguments>$taskArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@
        Register-ScheduledTask -TaskName $taskName -Xml $xml -Force -ErrorAction Stop | Out-Null
        $taskOk = $true
        Write-Host '3/3 已注册后台任务（事件触发）'
    }
    catch { Write-Host ('      方式一（任务 XML）失败：{0}' -f $_.Exception.Message) -ForegroundColor Yellow }

    # 方式二：用 TaskScheduler 的事件触发器对象
    if (-not $taskOk) {
        try {
            $action = New-ScheduledTaskAction -Execute $psExe -Argument $taskArgs
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
                -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
            $settings.Hidden = $true
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $cls = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskEventTrigger'
            $trigger = New-CimInstance -CimClass $cls -ClientOnly
            $trigger.Enabled = $true
            $trigger.Subscription = $sub
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
                -Description '三角洲行动 ACE 自动调优（ACE 启动时触发）' -Force -ErrorAction Stop | Out-Null
            $taskOk = $true
            Write-Host '3/3 已注册后台任务（事件触发）'
        }
        catch {
            Write-Host ('3/3 注册后台任务失败：{0}' -f $_.Exception.Message) -ForegroundColor Red
            Write-Host '      可以试试以管理员身份重新运行本安装程序。' -ForegroundColor Yellow
        }
    }

    if ($taskOk) {
        # 立刻跑一次：如果你现在正好在游戏里就马上生效；不在游戏里的话它等 20 分钟会自己退出
        try { Start-ScheduledTask -TaskName $taskName } catch { }
    }

    # 如果之前用旧版接管过快捷方式，这里顺便还原（后台任务已能覆盖，快捷方式不需要改）
    $restored = 0
    foreach ($c in @(Get-ShortcutCandidates)) {
        $bak = $c.Path + '.bak'
        if (Test-Path -LiteralPath $bak) {
            try {
                Copy-Item -LiteralPath $bak -Destination $c.Path -Force
                Remove-Item -LiteralPath $bak -Force
                $restored++
            }
            catch { }
        }
    }
    if ($restored -gt 0) { Write-Host ("      已还原 {0} 个被旧版改过的快捷方式（现在它们指向游戏启动器，正常使用即可）" -f $restored) }

    Write-Host ''
    if ($taskOk) {
        Write-Host '安装完成，以后正常开游戏就行：' -ForegroundColor Green
        Write-Host '  · WeGame、游戏启动器、桌面快捷方式，哪种方式启动都可以'
        Write-Host '  · 平时不会有脚本进程常驻；游戏启动时系统自动把它叫起来，ACE 的 SGuard64 / SGuardSvc64 一出现就设置'
        Write-Host ('  · 日志：{0}' -f $logPath)
    }
    else {
        Write-Host '后台任务没有装上，可以改用快捷方式方式：' -ForegroundColor Yellow
        Write-Host '  点击本窗口外的快捷方式启动游戏即可（需要每次点一次 UAC）。'
    }
    Write-Host ''
    Write-Host '卸载：再次运行本批处理并加参数 /u'
    Write-Host ''
}

function Uninstall-Tuner {
    Disable-ConsoleQuickEdit
    Write-Host ''
    Write-Host '========== 三角洲行动 ACE 自动调优 · 卸载 ==========' -ForegroundColor Cyan

    if (-not (Test-IsAdmin)) {
        Write-Host '卸载需要管理员权限，正在弹出 UAC 授权窗口，请在弹窗里点“是”……' -ForegroundColor Yellow
        $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Uninstall' -f $PSCommandPath
        try {
            $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                -ArgumentList $argLine -Verb RunAs -Wait -PassThru
            exit $p.ExitCode
        }
        catch {
            Write-Host '已取消授权，卸载没有完成。' -ForegroundColor Red
            exit 1
        }
        return
    }

    $taskName = 'DeltaForce-ACE-Tuner'
    try {
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Host '      已删除后台任务'
        }
    }
    catch { Write-Host ('      删除后台任务失败：' + $_.Exception.Message) -ForegroundColor Yellow }

    $restored = 0
    foreach ($c in @(Get-ShortcutCandidates)) {
        $bak = $c.Path + '.bak'
        if (Test-Path -LiteralPath $bak) {
            try { Copy-Item -LiteralPath $bak -Destination $c.Path -Force; Remove-Item -LiteralPath $bak -Force; $restored++ }
            catch { }
        }
    }

    $installDir = Join-Path $env:ProgramData 'DeltaForce-ACE-Tuner'
    if (Test-Path -LiteralPath $installDir) {
        try { Remove-Item -LiteralPath $installDir -Recurse -Force; Write-Host ("      已删除安装目录：{0}" -f $installDir) }
        catch { Write-Host ('      删除安装目录失败：' + $_.Exception.Message) -ForegroundColor Yellow }
    }
    Write-Host ("卸载完成（还原了 {0} 个快捷方式）。" -f $restored)
    Write-Host ''
}

function Disable-ConsoleQuickEdit {
    # 关掉控制台的“快速编辑”模式：否则用户在窗口里点一下就会暂停输出，看起来像卡死
    try {
        if (-not ('AceTunerConsole.Api' -as [type])) {
            Add-Type -Namespace AceTunerConsole -Name Api -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction Stop
        }
        $h = [AceTunerConsole.Api]::GetStdHandle(-10)      # STD_INPUT_HANDLE
        [uint32]$mode = 0
        if ([AceTunerConsole.Api]::GetConsoleMode($h, [ref]$mode)) {
            $keep = [uint32]0xFFFFFFBF                     # 清掉 ENABLE_QUICK_EDIT_MODE (0x0040)
            $flags = [uint32]0x0020                        # ENABLE_EXTENDED_FLAGS
            [void][AceTunerConsole.Api]::SetConsoleMode($h, [uint32](($mode -band $keep) -bor $flags))
        }
    }
    catch { }
}

function Test-TunerInstalled {
    # 安装目录在 / 或后台任务在，就认为已经装过（非管理员读不到任务信息时靠目录判断）
    if (Test-Path -LiteralPath (Join-Path $env:ProgramData 'DeltaForce-ACE-Tuner')) { return $true }
    try {
        if (Get-ScheduledTask -TaskName 'DeltaForce-ACE-Tuner' -ErrorAction SilentlyContinue) { return $true }
    }
    catch { }
    return $false
}

function Show-TunerMenu {
    Disable-ConsoleQuickEdit
    Write-Host ''
    Write-Host '========== 三角洲行动 ACE 自动调优 ==========' -ForegroundColor Cyan
    Write-Host ''
    if (-not (Test-TunerInstalled)) {
        Write-Host '本机还没装过，直接开始安装。'
        Install-Tuner
        return
    }
    Write-Host '检测到本机已经装过这个脚本，你想做什么？' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '   1 = 卸载（删除后台任务和脚本）'
    Write-Host '   2 = 重新安装 / 修复'
    Write-Host '   3 = 什么都不做，退出'
    Write-Host ''
    $ans = Read-Host '请输入 1 / 2 / 3（直接回车＝退出）'
    if ($null -eq $ans) { $ans = '' } else { $ans = $ans.Trim() }
    switch ($ans) {
        '1' { Uninstall-Tuner }
        '2' { Install-Tuner }
        default { Write-Host '已取消，什么都没有改动。' }
    }
}

if ($Menu) { Show-TunerMenu; return }
if ($Install) { Install-Tuner; return }
if ($Uninstall) { Uninstall-Tuner; return }
$ScriptPath = $PSCommandPath
$GameDir = Split-Path -Parent $PSScriptRoot                 # 例如 D:\E\Delta Force
$GameLauncher = Join-Path $GameDir 'launcher\delta_force_launcher.exe'
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$PriorityClassMap = @{
    'Low'         = [uint32]0x00000040   # 低（Idle）
    'BelowNormal' = [uint32]0x00004000   # 低于正常
    'Normal'      = [uint32]0x00000020   # 正常
    'AboveNormal' = [uint32]0x00008000   # 高于正常
    'High'        = [uint32]0x00000080   # 高
}
$PriorityClassValue = $PriorityClassMap[$Priority]
$AffinityMask = [uint64]1 -shl $CpuIndex
$GuardNames = @($GuardNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 2MB)) {
            Move-Item -LiteralPath $LogPath -Destination ($LogPath + '.old') -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop }
    catch { }
    Write-Host $line
}

function Get-GameProcess {
    # 游戏本体：DeltaForceClient-Win64-Shipping 之类；排除启动器
    Get-Process -Name 'DeltaForce*' -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -notmatch '(?i)launcher' }
}

# ---------- 原生 API（需要打开 SYSTEM 进程并修改其亲和性/优先级） ----------
if (-not ('AceTuner.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace AceTuner
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID Luid; public uint Attributes; }

    public static class Native
    {
        public const uint PROCESS_SET_INFORMATION = 0x0200;
        public const uint PROCESS_QUERY_INFORMATION = 0x0400;
        public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        public const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
        public const uint TOKEN_QUERY = 0x0008;
        public const uint SE_PRIVILEGE_ENABLED = 0x00000002;

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetProcessAffinityMask(IntPtr hProcess, out UIntPtr lpProcessAffinityMask, out UIntPtr lpSystemAffinityMask);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetProcessAffinityMask(IntPtr hProcess, UIntPtr dwProcessAffinityMask);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint GetPriorityClass(IntPtr hProcess);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetPriorityClass(IntPtr hProcess, uint dwPriorityClass);
        public const uint SYNCHRONIZE = 0x00100000;

        // 内核级阻塞等待：等待期间本进程不占用 CPU
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint WaitForMultipleObjects(uint nCount, IntPtr[] lpHandles, bool bWaitAll, uint dwMilliseconds);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out LUID lpLuid);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, int BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

        // 启用 SeDebugPrivilege：管理员令牌里默认是关闭的，操作 SYSTEM 进程必须打开它
        public static string EnableDebugPrivilege()
        {
            IntPtr token;
            if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out token))
                return "OpenProcessToken 失败，Win32 错误 " + Marshal.GetLastWin32Error();

            LUID luid;
            if (!LookupPrivilegeValue(null, "SeDebugPrivilege", out luid))
                return "LookupPrivilegeValue 失败，Win32 错误 " + Marshal.GetLastWin32Error();

            TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
            tp.PrivilegeCount = 1;
            tp.Luid = luid;
            tp.Attributes = SE_PRIVILEGE_ENABLED;

            if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero))
                return "AdjustTokenPrivileges 失败，Win32 错误 " + Marshal.GetLastWin32Error();

            int err = Marshal.GetLastWin32Error();
            CloseHandle(token);
            // ERROR_NOT_ALL_ASSIGNED = 1300
            if (err == 1300) return "SeDebugPrivilege 未授予（Win32 错误 1300）";
            return null;
        }
    }
}
'@
}

function Open-GuardProcess {
    param([int]$ProcessId)
    # 设置亲和性/优先级需要 PROCESS_SET_INFORMATION，读取需要 QUERY_LIMITED_INFORMATION
    $handle = [AceTuner.Native]::OpenProcess(0x1200, $false, $ProcessId)
    if ($handle -eq [IntPtr]::Zero) {
        $handle = [AceTuner.Native]::OpenProcess(0x1600, $false, $ProcessId)
    }
    return $handle
}

function Open-WaitHandle {
    param([int]$ProcessId)
    # 需要 SYNCHRONIZE 才能“阻塞等待该进程退出”，同时尽量保留查询权限
    $handle = [AceTuner.Native]::OpenProcess(0x00101200, $false, $ProcessId)
    if ($handle -eq [IntPtr]::Zero) {
        $handle = [AceTuner.Native]::OpenProcess(0x00100000, $false, $ProcessId)
    }
    return $handle
}

function Get-GuardState {
    param([int]$ProcessId)
    $result = [PSCustomObject]@{ Ok = $false; Affinity = $null; PriorityClass = $null; Error = '' }
    $handle = Open-GuardProcess -ProcessId $ProcessId
    if ($handle -eq [IntPtr]::Zero) {
        $result.Error = 'OpenProcess 失败，Win32 错误 ' + [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        return $result
    }
    try {
        [UIntPtr]$maskPtr = [UIntPtr]::Zero
        [UIntPtr]$sysPtr = [UIntPtr]::Zero
        if ([AceTuner.Native]::GetProcessAffinityMask($handle, [ref]$maskPtr, [ref]$sysPtr)) {
            $result.Affinity = [uint64]$maskPtr
        }
        $pc = [AceTuner.Native]::GetPriorityClass($handle)
        if ($pc -ne 0) { $result.PriorityClass = [uint32]$pc }
        $result.Ok = $true
    }
    finally {
        [void][AceTuner.Native]::CloseHandle($handle)
    }
    return $result
}

function Set-GuardProcess {
    param([string]$Name, [int]$ProcessId)

    $handle = Open-GuardProcess -ProcessId $ProcessId
    if ($handle -eq [IntPtr]::Zero) {
        return [PSCustomObject]@{
            ProcessId = $ProcessId; Name = $Name; Changed = $false; Ok = $false
            Error = 'OpenProcess 失败，Win32 错误 ' + [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            Affinity = $null; PriorityClass = $null
        }
    }

    [UIntPtr]$maskPtr = [UIntPtr]::Zero
    [UIntPtr]$sysPtr = [UIntPtr]::Zero
    $curAffinity = $null
    if ([AceTuner.Native]::GetProcessAffinityMask($handle, [ref]$maskPtr, [ref]$sysPtr)) {
        $curAffinity = [uint64]$maskPtr
    }
    $curPriority = [uint32][AceTuner.Native]::GetPriorityClass($handle)

    $changed = $false
    $errors = New-Object System.Collections.Generic.List[string]

    # 1) 处理器相关性 → 仅 CPUxx
    if ($curAffinity -ne $AffinityMask) {
        [UIntPtr]$newMask = [UIntPtr]$AffinityMask
        if ([AceTuner.Native]::SetProcessAffinityMask($handle, $newMask)) {
            $changed = $true
        }
        else {
            $errors.Add('设置相关性失败，Win32 错误 ' + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
    }

    # 2) 优先级 → 低
    if ($curPriority -ne $PriorityClassValue) {
        if ([AceTuner.Native]::SetPriorityClass($handle, $PriorityClassValue)) {
            $changed = $true
        }
        else {
            $errors.Add('设置优先级失败，Win32 错误 ' + [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
    }

    [void][AceTuner.Native]::CloseHandle($handle)

    # 读取一次最终状态，便于日志核对
    $after = Get-GuardState -ProcessId $ProcessId
    return [PSCustomObject]@{
        ProcessId = $ProcessId; Name = $Name; Changed = $changed; Ok = ($errors.Count -eq 0)
        Error = ($errors -join '; '); Affinity = $after.Affinity; PriorityClass = $after.PriorityClass
    }
}

function Format-Affinity {
    param($Value)
    if ($null -eq $Value) { return '未知' }
    $cpus = @()
    for ($i = 0; $i -lt 64; $i++) {
        if (([uint64]$Value -band ([uint64]1 -shl $i)) -ne 0) { $cpus += "CPU$i" }
    }
    if ($cpus.Count -eq 0) { return "0x$('{0:X}' -f [uint64]$Value)" }
    return ($cpus -join ',')
}

function Format-Priority {
    param($Value)
    if ($null -eq $Value) { return '未知' }
    foreach ($k in $PriorityClassMap.Keys) {
        if ($PriorityClassMap[$k] -eq [uint32]$Value) { return $k }
    }
    return "0x$('{0:X}' -f [uint32]$Value)"
}

function Show-GuardReport {
    $found = $false
    foreach ($name in $GuardNames) {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $found = $true
            $state = Get-GuardState -ProcessId $p.Id
            Write-Host ("{0} (PID {1})  当前相关性={2}  当前优先级={3}  {4}" -f `
                    $name, $p.Id, (Format-Affinity $state.Affinity), (Format-Priority $state.PriorityClass), $state.Error)
        }
    }
    if (-not $found) { Write-Host '未找到 ACE-Guard 进程（SGuard64 / SGuardSvc64）。' }
}

# ============================ DryRun：只看不改 ============================
if ($DryRun) {
    Write-Log ('DryRun：目标 = 相关性仅 CPU{0}，优先级 {1}（0x{2:X}）' -f $CpuIndex, $Priority, $PriorityClassValue)
    Show-GuardReport
    return
}

# ============================ 非管理员：启动器角色 ============================
if (-not (Test-IsAdmin)) {
    Write-Log '当前不是管理员：先启动游戏，再弹 UAC 申请管理员权限用于调优。'

    $alreadyRunning = @(Get-GameProcess)
    if ($alreadyRunning.Count -gt 0) {
        Write-Log ('检测到游戏本体已在运行（{0}），跳过启动。' -f $alreadyRunning[0].ProcessName)
    }
    elseif (Test-Path -LiteralPath $GameLauncher) {
        try {
            Start-Process -FilePath $GameLauncher -WorkingDirectory (Split-Path -Parent $GameLauncher) | Out-Null
            Write-Log "已启动游戏启动器：$GameLauncher"
        }
        catch {
            Write-Log ("启动游戏启动器失败：{0}" -f $_.Exception.Message) 'WARN'
        }
    }
    else {
        Write-Log "未找到游戏启动器：$GameLauncher（跳过启动，仅启动调优监听）" 'WARN'
    }

    $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -CpuIndex {1} -Priority {2} -PollSeconds {3} -SettleSeconds {4} -WaitGameMinutes {5} -MaxRuntimeHours {6} -ExitAfterGameGoneSeconds {7} -LogPath "{8}"' -f `
        $ScriptPath, $CpuIndex, $Priority, $PollSeconds, $SettleSeconds, $WaitGameMinutes, $MaxRuntimeHours, $ExitAfterGameGoneSeconds, $LogPath
    if ($GuardNames.Count -gt 0) {
        # 注意：-File 方式传数组会被合并成一个字符串，所以这里就用逗号串，
        # 脚本内部会再拆开（见文件顶部的 GuardNames 处理）
        $argLine += (' -GuardNames "{0}"' -f ($GuardNames -join ','))
    }

    try {
        Start-Process -FilePath $PsExe -ArgumentList $argLine -Verb RunAs | Out-Null
        Write-Log '已请求管理员权限；请在 UAC 弹窗中点击“是”，否则调优不会生效。'
    }
    catch {
        Write-Log ('申请管理员权限失败或被取消：{0}' -f $_.Exception.Message) 'ERROR'
    }
    return
}

# ============================ 管理员：监听并设置 ============================
$createdNew = $true
try {
    $mutex = New-Object System.Threading.Mutex($true, 'Global\AceGuardTuner', [ref]$createdNew)
}
catch {
    Write-Log ('创建互斥体失败，跳过“重复运行”检查：{0}' -f $_.Exception.Message) 'WARN'
    $createdNew = $true
}
if (-not $createdNew) {
    Write-Log '已有调优进程在运行，本次不再重复启动。'
    return
}

$privError = [AceTuner.Native]::EnableDebugPrivilege()
if ($privError) { Write-Log ("启用 SeDebugPrivilege 失败：{0}" -f $privError) 'WARN' }
else { Write-Log '已启用 SeDebugPrivilege。' }

Write-Log ('调优监听已启动：目标线程相关性仅 CPU{0}（掩码 0x{1:X}），优先级 {2}，监视进程 {3}；检查间隔 {4}s，休眠时最长等待 {5}s（有新进程启动会立刻唤醒）。' -f `
        $CpuIndex, $AffinityMask, $Priority, ($GuardNames -join ' / '), $PollSeconds, $IdleWakeSeconds)

# ---- 启动自检：把“实际要监视的进程名”和当前能找到的进程写进日志 ----
Write-Log ('实际监视的进程名：{0}' -f ($GuardNames -join ' / '))
foreach ($n in $GuardNames) {
    $found = @(Get-Process -Name $n -ErrorAction SilentlyContinue)
    Write-Log ('自检：{0} 当前可见 {1} 个{2}' -f $n, $found.Count, $(if ($found.Count -gt 0) { '（PID ' + (($found | ForEach-Object { $_.Id }) -join ',') + '）' } else { '' }))
}

function Test-Deadline {
    param([datetime]$HardDeadline)
    if ((Get-Date) -gt $HardDeadline) {
        Write-Log '已达到最长运行时间，监听结束。' 'WARN'
        return $false
    }
    return $true
}

if ($Persistent) {
    Write-Log '常驻模式：在后台等待游戏启动（不占 CPU），游戏退出后继续等下一次启动。'
}

:persistLoop while ($true) {
$startedAt = Get-Date
$waitDeadline = $startedAt.AddMinutes($WaitGameMinutes)
$hardDeadline = $startedAt.AddHours($MaxRuntimeHours)

# ---- 第一步：等待游戏本体出现（ACE 在游戏启动前不会生效） ----
Write-Log '等待《三角洲行动》游戏本体启动（DeltaForce*...）。'
$gameSeen = $false
$lastNotice = Get-Date
while ($true) {
    if (@(Get-GameProcess).Count -gt 0) { $gameSeen = $true; break }
    if ($Persistent) {
        # 常驻模式：不限时等待，每 30 分钟记一次日志
        if (((Get-Date) - $lastNotice).TotalSeconds -ge 1800) {
            Write-Log '仍在后台等待游戏启动……'
            $lastNotice = Get-Date
        }
        Start-Sleep -Seconds 15
        continue
    }
    if ((Get-Date) -gt $waitDeadline) { break }
    if (-not (Test-Deadline -HardDeadline $hardDeadline)) { return }
    if (((Get-Date) - $lastNotice).TotalSeconds -ge 60) {
        Write-Log '仍在等待游戏启动……'
        $lastNotice = Get-Date
    }
    Start-Sleep -Seconds ([Math]::Max(2, $PollSeconds))
}
if (-not $gameSeen) {
    Write-Log ('等待游戏启动超时（{0} 分钟），监听结束。' -f $WaitGameMinutes) 'WARN'
    return
}

Write-Log ('检测到游戏本体：{0}；等待 {1} 秒后开始设置 ACE-Guard。' -f (@(Get-GameProcess))[0].ProcessName, $SettleSeconds)
Start-Sleep -Seconds $SettleSeconds

# ---- 第二步：设置 + 休眠等待 ----
# 设置没做完时按 PollSeconds 短间隔重试；一旦全部设置成功，就改用
# 内核级阻塞等待（WaitForMultipleObjects）——等待期间不占 CPU，
# 只在 ACE 进程被重新拉起或游戏退出时才会被唤醒。
$lastErrorLog = @{}         # PID -> 最近一次错误日志时间
$failInfo = @{}             # PID -> @{ First = 首次失败时间; Fails = 失败次数 }
$appliedPids = @{}          # 上一轮已成功设置的 PID
$waitHandles = New-Object System.Collections.Generic.List[IntPtr]
$gameGoneSince = $null
$noTargetSince = $null
$restartWatchUntil = $null  # 刚有 ACE 进程退出时，短暂恢复密集检查的截止时间
$sleeping = $false
$lastHeartbeat = Get-Date

while ($true) {
    if (-not (Test-Deadline -HardDeadline $hardDeadline)) { return }

    # 关闭上一轮的等待句柄
    foreach ($h in $waitHandles) { [void][AceTuner.Native]::CloseHandle($h) }
    $waitHandles.Clear()

    # ---- 游戏本体是否还在运行 ----
    $game = @(Get-GameProcess)
    if ($game.Count -eq 0) {
        if ($null -eq $gameGoneSince) {
            $gameGoneSince = Get-Date
            Write-Log '游戏本体已退出，继续观察一段时间。'
        }
        elseif (((Get-Date) - $gameGoneSince).TotalSeconds -ge $ExitAfterGameGoneSeconds) {
            Write-Log '游戏已退出。'
            if ($Persistent) {
                Write-Log '常驻模式：继续在后台等待下一次启动。'
                continue persistLoop
            }
            Write-Log '监听结束。'
            return
        }
        Start-Sleep -Seconds ([Math]::Max(1, [Math]::Min($PollSeconds, 5)))
        continue
    }
    $gameGoneSince = $null

    # ---- 枚举 ACE-Guard 进程并设置 ----
    $targets = @()
    foreach ($name in $GuardNames) {
        foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) { $targets += $p }
    }
    $targets = @($targets | Sort-Object Id -Unique)

    $now = Get-Date
    $nowApplied = @{}
    foreach ($p in $targets) {
        $targetPid = $p.Id
        $res = Set-GuardProcess -Name $p.ProcessName -ProcessId $targetPid
        if ($res.Ok) {
            if ($res.Changed) {
                Write-Log ('已设置 {0} (PID {1})：相关性={2} 优先级={3}' -f `
                        $p.ProcessName, $targetPid, (Format-Affinity $res.Affinity), (Format-Priority $res.PriorityClass))
            }
            $nowApplied[$targetPid] = $true
            $lastErrorLog.Remove($targetPid)
            $failInfo.Remove($targetPid)
        }
        else {
            $f = $failInfo[$targetPid]
            if ($null -eq $f) { $f = @{ First = $now; Fails = 0 }; $failInfo[$targetPid] = $f }
            $f['Fails'] = [int]$f['Fails'] + 1
            $last = $lastErrorLog[$targetPid]
            if (($null -eq $last) -or ((($now - $last)).TotalSeconds -ge 30)) {
                Write-Log ('设置 {0} (PID {1}) 未成功：{2}（{3} 秒内继续重试）' -f $p.ProcessName, $targetPid, $res.Error, $QuickRetrySeconds) 'WARN'
                $lastErrorLog[$targetPid] = $now
            }
        }
    }

    # ACE 重启进程时，新进程可能晚一点才出现：刚有已设置的进程退出，
    # 就在限定窗口内恢复短间隔检查，避免漏掉重新拉起的进程
    $vanished = @($appliedPids.Keys | Where-Object { -not $nowApplied.ContainsKey($_) })
    if ($vanished.Count -gt 0) {
        $restartWatchUntil = $now.AddSeconds($QuickRetrySeconds)
        Write-Log ('检测到 ACE 进程退出（PID {0}），{1} 秒内保持快速检查，等待它被重新拉起。' -f ($vanished -join ','), $QuickRetrySeconds)
    }
    $appliedPids = $nowApplied

    # ---- 是否还需要“短间隔重试”？否则转入事件驱动的等待（不占 CPU） ----
    $quickRetry = $false
    if ($targets.Count -eq 0) {
        # 游戏在跑但 ACE 还没出现：先用短间隔快速等一会儿（常见情况几秒内就出现），
        # 之后交给“进程启动事件”来唤醒，不会放弃等待
        if ($null -eq $noTargetSince) { $noTargetSince = $now }
        if (($now - $noTargetSince).TotalSeconds -lt $QuickRetrySeconds) { $quickRetry = $true }
    }
    else {
        $noTargetSince = $null
        foreach ($k in @($failInfo.Keys)) {
            $f = $failInfo[$k]
            if ((([int]$f['Fails']) -lt $MaxQuickAttempts) -and ((($now - $f['First']).TotalSeconds -lt $QuickRetrySeconds))) {
                $quickRetry = $true
                break
            }
        }
        if ((-not $quickRetry) -and ($null -ne $restartWatchUntil) -and ($now -lt $restartWatchUntil)) {
            $quickRetry = $true
        }
    }

    if ($quickRetry) {
        if ($sleeping) {
            $sleeping = $false
            Write-Log '需要继续设置，恢复快速检查。'
        }
        Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
        continue
    }

    if ($ExitAfterApply -and $targets.Count -gt 0 -and $failInfo.Count -eq 0) {
        Write-Log '设置完成，按 -ExitAfterApply 参数结束脚本。'
        return
    }

    if (-not $sleeping) {
        $sleeping = $true
        if ($targets.Count -eq 0) {
            Write-Log '游戏已运行，等待 ACE-Guard 进程（SGuard64 / SGuardSvc64）出现：它一启动就会被立刻设置，等待期间不占 CPU。'
        }
        elseif ($failInfo.Count -gt 0) {
            Write-Log ('仍有 {0} 个进程未能设置（可能被 ACE 保护拒绝），已停止频繁重试；有新进程启动或下次唤醒时会再试。' -f $failInfo.Count) 'WARN'
        }
        else {
            Write-Log '设置完成，脚本转入休眠等待：不再轮询，CPU 占用为 0；仅在 ACE 进程启动/重启或游戏退出时被唤醒。'
        }
    }

    # ---- 等待唤醒（内核级阻塞，不占 CPU） ----
    # 等待对象 = 游戏本体 + 已找到的 ACE 进程：任一进程退出会立刻唤醒；
    # 超时时间在“还没找到 ACE 进程”时用短间隔（尽快发现它出现），
    # 全部设置完成后用长间隔（几乎不唤醒）。
    foreach ($p in @($game + $targets)) {
        $h = Open-WaitHandle -ProcessId $p.Id
        if ($h -eq [IntPtr]::Zero) { continue }
        if ($waitHandles.Count -lt 60) { [void]$waitHandles.Add($h) }
        else { [void][AceTuner.Native]::CloseHandle($h) }
    }

    $waitSeconds = if ($targets.Count -eq 0 -or $failInfo.Count -gt 0) { [Math]::Max(5, [Math]::Min($IdleWakeSeconds, 15)) } else { $IdleWakeSeconds }
    if ($waitHandles.Count -gt 0) {
        [void][AceTuner.Native]::WaitForMultipleObjects([uint32]$waitHandles.Count, $waitHandles.ToArray(), $false, [uint32]($waitSeconds * 1000))
    }
    else {
        Start-Sleep -Seconds ([Math]::Max(1, $waitSeconds))
    }

    # 心跳日志：每 2 分钟记一次状态，方便以后排查（占极小开销）
    if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge 120) {
        Write-Log ('心跳：游戏进程 {0} 个，ACE 进程 {1} 个（已成功设置 {2} 个，失败 {3} 个）' -f `
                $game.Count, $targets.Count, $nowApplied.Count, $failInfo.Count)
        $lastHeartbeat = Get-Date
    }
}

}
