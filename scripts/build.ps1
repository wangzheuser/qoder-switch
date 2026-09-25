# Qoder Switch 的一键构建（Windows 原生入口，PowerShell 5.1 / 7 都能跑）。
#
# 与 scripts/build.sh 的 Windows 分支同义：同一批子命令、同一份环境变量约定、
# 同一把构建锁、同一套磁盘护栏。**锁文件格式必须逐字节对齐**（目录 target/.qs-build-lock，
# 内含 ASCII 的 `pid` 文件），否则 Git-Bash 里跑的 build.sh 与本脚本互相看不见对方，
# clean 与构建交叠那类 ENOENT 事故会回来。
#
# 为什么在已有 build.sh 的情况下还要这一份：build.sh 在 Windows 上依赖 Git-Bash
# （uname/cygpath/taskkill// 转义），CI 的 windows-latest runner 与只想用
# PowerShell 的同事都不该被要求先装 Git-Bash。
#
# 工具链与产物位置钉在 E:（C: 盘装不下一次 release target，实测约 7GB），
# 与 build.sh 取同一组默认值；已有环境变量一律优先。
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'all'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# StrictMode 下 $LASTEXITCODE 在第一条原生命令之前是未定义的，先落地再比较。
$LASTEXITCODE = 0

# ── 输出与外部命令 ────────────────────────────────────────────────────────────
# 人类可读的说明走 stdout，告警与错误走 stderr —— 与 build.sh 的分流一致，
# 便于 `2>&1` 重定向后仍看得清哪几条是失败原因。
function Say { param([string]$Text) [Console]::Out.WriteLine($Text) }
function Warn { param([string]$Text) [Console]::Error.WriteLine($Text) }

function Resolve-Tool {
    # 显式优先 .cmd：Node 会同时留下 npm.ps1 与 npm.cmd 两个 shim，而 PowerShell 的
    # 命令解析先命中 .ps1 —— 那受执行策略约束，且 shim 里的退出码回传不如直接跑 .cmd 可靠。
    param([string]$Name)
    $cmd = Get-Command "$Name.cmd" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $plain = Get-Command $Name -ErrorAction SilentlyContinue
    if ($plain) { return $plain.Source }
    return $null
}

function Invoke-Step {
    # $ErrorActionPreference 管不到原生命令的退出码：不逐条查就会一路跑到最后才炸，
    # 而且看不出是哪一步失败。每个外部命令都必须过这里。
    param([string]$Exe, [string[]]$Arguments = @())
    if (-not $Exe) { throw '找不到所需命令，无法继续。' }
    Say("  > $(Split-Path -Leaf $Exe) $($Arguments -join ' ')")
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "命令失败（退出码 $LASTEXITCODE）：$(Split-Path -Leaf $Exe) $($Arguments -join ' ')"
    }
}

# ── 仓库根与环境变量 ──────────────────────────────────────────────────────────
# 先切根再推导任何相对路径：CARGO_TARGET_DIR 的默认值与 clean 的 TARGET_DIR 都依赖它，
# 求值顺序错了 target 会落到调用者目录，锁与清理护栏随之错位（build.sh 踩过）。
Set-Location (Split-Path -Parent $PSScriptRoot)
$Root = (Get-Location).Path

if (-not $env:RUSTUP_HOME) { $env:RUSTUP_HOME = 'E:\rustup' }
if (-not $env:CARGO_HOME) { $env:CARGO_HOME = 'E:\cargo' }
if (-not $env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR = 'E:\qs-target' }

# 绝对化，后面与 $Root 比较时才有同一形状。
$env:CARGO_TARGET_DIR = [System.IO.Path]::GetFullPath($env:CARGO_TARGET_DIR)
$CargoBin = Join-Path $env:CARGO_HOME 'bin'
if (-not (($env:Path -split ';') -contains $CargoBin)) {
    $env:Path = "$CargoBin;$env:Path"
}

$Cargo = Resolve-Tool 'cargo'
if (-not $Cargo) {
    Warn("找不到 cargo（CARGO_HOME=$env:CARGO_HOME → $CargoBin）")
    Warn('装好 Rust 工具链或导出 CARGO_HOME 再重跑。')
    exit 1
}

$Npm = Resolve-Tool 'npm'
$Npx = Resolve-Tool 'npx'

# ── 磁盘空间护栏 ──────────────────────────────────────────────────────────────
# 空间不足时 cargo 在编译中途失败，报错常常**不是**"磁盘已满"：rustc 建临时目录用
# create_dir 而非 create_dir_all，父目录写不进去（或被别的进程删掉）都表现为 ENOENT，
# 现场看起来像"target 被谁删了"。这里把"跑到一半炸"提前成"一开始就说清楚"。
# 阈值取实测需求的两倍，另留系统 swap / 索引 / 更新的空间。
function Require-DiskSpace {
    param([double]$NeedGb)
    $qualifier = $null
    try { $qualifier = Split-Path -Qualifier $Root } catch { $qualifier = $null }
    if (-not $qualifier) { return }   # UNC 或异常路径：取不到可用空间就不拦，避免误伤
    $drive = New-Object System.IO.DriveInfo($qualifier)
    if (-not $drive.IsReady) { return }
    $avail = [math]::Floor($drive.AvailableFreeSpace / 1GB)
    $floor = $NeedGb * 2
    if ($avail -ge $floor) { return }
    Warn("磁盘可用空间不足：约 ${avail}G；本次构建实测需要约 ${NeedGb}G，留一倍余量需 ${floor}G。")
    Warn('现在继续大概率会在编译中途失败，且报错多为 ENOENT 而非磁盘已满，很难排查。')
    Warn('先释放空间再重跑。常见可回收项（体积请自行确认）：')
    Warn('  npm cache clean --force          # 见 npm config get cache')
    Warn('  微信 → 设置 → 通用 → 存储空间管理')
    Warn('  Docker Desktop → Troubleshoot → 清理不用的镜像与卷')
    Warn("  当前构建目录：$env:CARGO_TARGET_DIR")
    exit 1
}

# ── 构建互斥锁 ────────────────────────────────────────────────────────────────
# clean 会 `rm -rf` 掉几 GB 的 target（数十秒）。与构建交叠时 cargo 已建好的
# target/debug/deps 被抽走，rustc 随即报迷惑性的 ENOENT —— 本仓库真实踩过一次。
# 锁目录放在 target 里，clean 侧删之前先查它。PID 已不存在视为陈旧锁，直接接管。
#
# 锁目录里写两个文件，规则与 scripts/qs-lock.sh（build.sh / clean.sh 共用）对齐：
#   pid     持锁进程在自己那套编号里的 PID
#   winpid  Windows 内核 PID —— Git-Bash 的 kill -0 认不出它，但 tasklist 认得，
#           所以 .sh 侧只按 winpid 判活，才能让两种入口互相锁住。
$LockDir = Join-Path $env:CARGO_TARGET_DIR '.qs-build-lock'
$LockPidFile = Join-Path $LockDir 'pid'
$LockWinPidFile = Join-Path $LockDir 'winpid'

function Read-LockPid {
    # 只认正整数，否则返回 0。文件可能是上一次异常退出留下的半截内容、被手工写坏的
    # 非数字，或 UTF-16 乱码。不用 $null 表达"没有"：PowerShell 5.1 里
    # `0 -eq $null` 为真，用 $null 做哨兵会让调用方的判空语句反过来。
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $raw = ([System.IO.File]::ReadAllText($Path) -replace '\s', '')
    $num = 0
    if (-not [int]::TryParse($raw, [ref] $num)) { return 0 }
    if ($num -lt 1) { return 0 }
    return $num
}

function Get-LockHolder {
    # winpid 优先：build.sh 写的 pid 是 MSYS 编号，Get-Process 按它查只会撞上无关进程，
    # 判活结果不可信；winpid 才是两种入口能对得上号的那个。
    foreach ($f in @($LockWinPidFile, $LockPidFile)) {
        $num = Read-LockPid $f
        if ($num -gt 0 -and (Get-Process -Id $num -ErrorAction SilentlyContinue)) { return $num }
    }
    return 0
}

$HeldLock = $false
if (-not $env:QS_BUILD_LOCKED) {
    if (-not (Test-Path -LiteralPath $env:CARGO_TARGET_DIR)) {
        New-Item -ItemType Directory -Path $env:CARGO_TARGET_DIR -Force | Out-Null
    }
    if (Test-Path -LiteralPath $LockDir) {
        $holder = Get-LockHolder
        if ($holder -gt 0) {
            Warn("已有构建正在进行（PID $holder），拒绝并行启动。")
            Warn('并行构建会互相踩 target 目录，并让 cargo 报出迷惑性的 ENOENT。')
            exit 1
        }
        Remove-Item -LiteralPath $LockDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $LockDir | Out-Null
    # 必须 ASCII：用 PowerShell 默认的 `>` 会写成 UTF-16，Git-Bash 那边 `cat` 出来的
    # 是乱码，判活失败 → 陈旧锁被误放行 → 清理照删不误。
    [System.IO.File]::WriteAllText($LockPidFile, "$PID`n", [System.Text.Encoding]::ASCII)
    # PowerShell 的 $PID 本身就是内核 PID，所以 winpid 与 pid 同值；写它是让 clean.sh
    # 那条路（tasklist 判活）拿得到正确的编号空间。
    [System.IO.File]::WriteAllText($LockWinPidFile, "$PID`n", [System.Text.Encoding]::ASCII)
    $HeldLock = $true
    $env:QS_BUILD_LOCKED = '1'
}

# ── 宿主相关取值 ──────────────────────────────────────────────────────────────
$Bundles = 'nsis'

function Kill-Previous {
    # 构建前先收掉上一次留下的进程，否则链接期因文件占用失败（Windows 是 LNK1104）。
    # taskkill 在"目标进程本来不存在"时返回 128 并往 stderr 写 ERROR —— 那不是错误。
    # 这里绕开 `2>&1 | Out-Null`：PowerShell 5.1 会把原生命令经 2>&1 的 stderr 行转成
    # ErrorRecord，在 $ErrorActionPreference='Stop' 下直接变成终止错误，整个 debug/release
    # 会被"进程不存在"这条无害输出打死（本机实测）。交给 cmd 做丢弃，PS 只看退出码。
    $null = & $env:ComSpec /c 'taskkill /IM qoder-switch.exe /F >nul 2>nul'
    $LASTEXITCODE = 0
}

function Invoke-Self {
    # `all` 依次调用本脚本的其它子命令。用子进程而不是函数内递归，是为了与 build.sh
    # 同构（每步失败即停、每步的 $LASTEXITCODE 干净），也让锁的持有方始终只有最外层。
    param([string]$Sub)
    $hostExe = @((Join-Path $PSHOME 'pwsh.exe'), (Join-Path $PSHOME 'powershell.exe')) |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $hostExe) { throw '找不到宿主 PowerShell，无法执行 all。' }
    Invoke-Step $hostExe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, $Sub)
}

function Write-Usage {
    Warn("用法: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1 [deps|icons|test|web|debug|release|all]（当前宿主: windows，bundles: $Bundles）")
}

# ── 子命令 ────────────────────────────────────────────────────────────────────
try {
    switch ($Command) {
        'deps' {
            Invoke-Step $Npm @('install', '--no-audit', '--no-fund')
        }
        'icons' {
            # 资源编译要求 src-tauri/icons/ 里的文件真实存在，缺 icon 直接编译失败；
            # Windows 要 .ico（tauri.conf.json 的 bundle.icon 列了）。
            if (-not (Test-Path -LiteralPath (Join-Path $Root 'public\app-icon.png'))) {
                Warn('缺 public/app-icon.png（1024x1024 源图）')
                exit 1
            }
            Invoke-Step $Npx @('tauri', 'icon', 'public/app-icon.png')
            foreach ($d in @('android', 'ios')) {
                $p = Join-Path $Root "src-tauri\icons\$d"
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
            }
        }
        'test' {
            Require-DiskSpace 3
            # cargo test 要编译 src-tauri，而它的 frontendDist（../dist）必须真实存在，
            # 否则 generate_context! 在编译期直接 panic。缺了就补一次前端构建。
            if (-not (Test-Path -LiteralPath (Join-Path $Root 'dist\index.html'))) {
                Invoke-Step $Npm @('run', 'build')
            }
            Invoke-Step $Cargo @('test', '--workspace')
            # 本机再补跑被 #[ignore] 的真机证据测试（绑定本机 Qoder 布局）。
            Invoke-Step $Cargo @('test', '--workspace', '--', '--ignored')
        }
        'web' {
            Invoke-Step $Npm @('run', 'build')
        }
        'debug' {
            Require-DiskSpace 3
            Kill-Previous
            Invoke-Step $Cargo @('build', '-p', 'qoder-switch')
            Say "产物: $(Join-Path $env:CARGO_TARGET_DIR 'debug\qoder-switch.exe')"
        }
        'release' {
            Require-DiskSpace 4
            Kill-Previous
            if (-not $env:TAURI_SIGNING_PRIVATE_KEY) {
                $keyFile = Join-Path $env:USERPROFILE '.tauri\qoder-switch.key'
                if (Test-Path -LiteralPath $keyFile) {
                    $env:TAURI_SIGNING_PRIVATE_KEY = [System.IO.File]::ReadAllText($keyFile).Trim()
                    $env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = ''
                }
            }
            # 没有发布私钥时不能让它炸在最后一步：tauri 会先把 NSIS 全部产出，再在
            # updater 签名那一步以非 0 退出 —— "包做好了、脚本报失败"，而且产物清单
            # 根本不打印。所以按有没有密钥分流。
            if (-not $env:TAURI_SIGNING_PRIVATE_KEY) {
                Warn '提示: 未找到 TAURI_SIGNING_PRIVATE_KEY（也没有 ~/.tauri/qoder-switch.key）。'
                Warn '      本次跳过 updater 签名产物（.sig / .app.tar.gz），安装包本体照常产出。'
                Warn '      正式发版请不要用这条路径 —— 交给 CI（tag 触发，私钥在仓库 Secrets）。'
                # 关掉签名的覆盖配置走临时文件而不是内联 JSON：内联 JSON 里全是双引号，
                # 经 PowerShell → npm.cmd 两层批处理重解析后必被吃掉。文件路径没有引号面。
                $cfg = Join-Path ([System.IO.Path]::GetTempPath()) "qs-switch-updater-off.$PID.json"
                [System.IO.File]::WriteAllText($cfg, '{"bundle":{"createUpdaterArtifacts":false}}', [System.Text.Encoding]::ASCII)
                try {
                    Invoke-Step $Npx @('tauri', 'build', '--bundles', $Bundles, '--config', $cfg)
                } finally {
                    Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
                }
            } else {
                # 会自己跑 beforeBuildCommand（npm run build），不必先 build.ps1 web。
                Invoke-Step $Npx @('tauri', 'build', '--bundles', $Bundles)
            }
            $bundleRoot = Join-Path $env:CARGO_TARGET_DIR 'release\bundle'
            if (Test-Path -LiteralPath $bundleRoot) {
                Get-ChildItem -LiteralPath $bundleRoot -Recurse -File |
                    Where-Object { $_.Extension -in @('.exe', '.msi', '.dmg', '.app') } |
                    ForEach-Object { Say $_.FullName }
            } else {
                Warn("未找到 bundle 目录：$bundleRoot")
            }
        }
        'all' {
            # debug 与 release 两套 target 都要落地，实测合计约 6GB。
            Require-DiskSpace 6
            foreach ($sub in @('deps', 'icons', 'test', 'release')) { Invoke-Self $sub }
        }
        default {
            Write-Usage
            exit 2
        }
    }
} catch {
    Warn($_.Exception.Message)
    exit 1
} finally {
    if ($HeldLock) {
        Remove-Item -LiteralPath $LockDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
