# 清理 scripts/build.ps1 / build.sh（以及 pack-npm）留下的构建缓存与构建产物（Windows 原生入口）。
#
# 与 clean.sh 同一张落点表：构建侧会往 cargo 的 target、vite 的 dist、tauri-build 生成的
# src-tauri/gen/schemas、tauri icon 的备份目录，以及 pack-npm 暂存的 npm/webui_dist 与
# npm/platform/*/bin 里写。只删 target 会留下陈旧 dist 或旧二进制，下次构建可能被拿去打包。
#
# 用法（与 clean.sh 的旗标逐一对应）:
#   powershell -File scripts/clean.ps1              # 列出清单，确认后清理（保留 node_modules）
#   powershell -File scripts/clean.ps1 -n           # 只列出将删除的路径与体积，不动任何文件
#   powershell -File scripts/clean.ps1 -y           # 免确认（非交互环境必须显式带）
#   powershell -File scripts/clean.ps1 -a           # 连 node_modules 一起删
#
# 之所以单独有一份 .ps1：CI 的 windows runner 上没有 tty，也不能假设装了 Git-Bash。
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CliArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LASTEXITCODE = 0

function Say { param([string]$Text) [Console]::Out.WriteLine($Text) }
function Warn { param([string]$Text) [Console]::Error.WriteLine($Text) }

$UsageText = @'
用法: powershell -NoProfile -ExecutionPolicy Bypass -File scripts/clean.ps1 [选项]

  -n, --dry-run   只列出待清理清单与体积，不删除任何文件
  -y, --yes       跳过确认（stdin 非交互时必须带，否则脚本拒绝删除）
  -a, --all       连同 node_modules 一起清理（之后需要重新 npm install）
  -h, --help      显示本帮助

默认清理 cargo/tauri 构建目录、dist、tauri 生成 schema、pack-npm 暂存产物、
vite 预构建缓存与 TypeScript 增量编译信息；保留 node_modules。
'@

$DryRun = $false
$AssumeYes = $false
$WithNodeModules = $false

foreach ($a in $CliArgs) {
    if ($a -in @('-n', '--dry-run')) { $DryRun = $true; continue }
    if ($a -in @('-y', '--yes')) { $AssumeYes = $true; continue }
    if ($a -in @('-a', '--all')) { $WithNodeModules = $true; continue }
    if ($a -in @('-h', '--help')) { Say $UsageText; exit 0 }
    Warn "未知参数: $a"
    Warn $UsageText
    exit 2
}

Set-Location (Split-Path -Parent $PSScriptRoot)
$Root = (Get-Location).Path
$HomeDir = $env:USERPROFILE

# 必须是仓库根：防呆，避免在别处误删同名目录。
foreach ($f in @('Cargo.toml', 'package.json', 'scripts/build.sh')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $f))) {
        Warn "当前目录不像 qoder-switch 仓库根（缺 $f）: $Root"
        exit 1
    }
}

# cargo target 目录的推导必须与构建脚本同源，否则清了半天没清到真正的构建目录，
# 而下面按 $TargetDir 定位的构建锁也会查错路径 —— "边构建边清理"那道保护整个失效。
# 缺省值三端都是仓库内的 target\（cargo 自己的缺省，也是 CI runner 拿到的那个）。
# 曾有一段时间 Windows 侧钉在 E:\qs-target（C: 盘装不下）；现在构建与清理都收到这一条
# 规则上，那个旧落点不再被扫描 —— 老机器上若还留着它，手动删一次即可。
if ($env:CARGO_TARGET_DIR) {
    $TargetDir = [System.IO.Path]::GetFullPath($env:CARGO_TARGET_DIR)
} else {
    $TargetDir = Join-Path $Root 'target'
}
if (-not [System.IO.Path]::IsPathRooted($TargetDir)) { $TargetDir = Join-Path $Root $TargetDir }
$RepoTarget = Join-Path $Root 'target'

# ── 体积与清单 ────────────────────────────────────────────────────────────────
function Get-SizeKb {
    param([string]$Path)
    # 对应 du -sk：按实际字节 / 1024 向上取整。逐目录容错，权限不足或路径过深的子树跳过
    # 而不是整体失败 —— 清单里少一项体积估算，远好过整个清理脚本跑不起来。
    # 重新分析点（junction / 符号链接）一律不跟随：node_modules 里出现链接时，
    # 跟着走会重复计数甚至成环。
    #
    # 取字节数一律走 FileInfo/DirectoryInfo 的实例属性，不走 [System.IO.File]::Length()：
    # 那个静态重载是 .NET Core 3.0 才有的，Windows PowerShell 5.1 跑在 .NET Framework 上，
    # 调它必抛 MethodNotFound —— 而这里的容错会把异常咽掉，结果是每一项体积都显示 0 KB，
    # "合计可释放多少"整行永远失真（本机实测）。实例属性两个框架都有。
    try {
        $attr = [System.IO.File]::GetAttributes($Path)
    } catch { return [long]0 }
    if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { return [long]1 }
    if (-not ($attr -band [System.IO.FileAttributes]::Directory)) {
        try { return [math]::Ceiling((New-Object System.IO.FileInfo $Path).Length / 1KB) } catch { return [long]0 }
    }
    $total = [long]0
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    try {
        $stack.Push((New-Object System.IO.DirectoryInfo $Path))
    } catch { return [long]0 }
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($f in $dir.EnumerateFiles()) { $total += $f.Length }
            foreach ($sub in $dir.EnumerateDirectories()) {
                if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                $stack.Push($sub)
            }
        } catch { }
    }
    return [math]::Ceiling($total / 1KB)
}

function Format-Size {
    param([long]$Kb)
    if ($Kb -ge 1048576) { return ('{0:N2} GB' -f ($Kb / 1048576)) }
    if ($Kb -ge 1024)    { return ('{0:N1} MB' -f ($Kb / 1024)) }
    return "$Kb KB"
}

$Entries = New-Object System.Collections.Generic.List[object]
$script:TotalKb = [long]0

function Add-Entry {
    param([string]$Desc, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $kb = Get-SizeKb -Path $Path
    # 函数内对累加变量必须显式 $script: —— 直接 `$TotalKb += x` 只会改到函数的同名副本，
    # 合计行会永远显示 0 KB（本机实测）。
    $Entries.Add([pscustomobject]@{ Desc = $Desc; Path = $Path; Kb = $kb }) | Out-Null
    $script:TotalKb += $kb
}

# ── cargo / tauri 构建目录 ────────────────────────────────────────────────────
Add-Entry 'cargo/tauri 构建目录（含 release bundle、增量与依赖缓存）' $TargetDir
if ($TargetDir -ne $RepoTarget) {
    Add-Entry 'cargo 构建目录（仓库内默认位置，构建目录指向了别处）' $RepoTarget
}
Add-Entry 'tauri 旧布局构建目录' (Join-Path $Root 'src-tauri\target')

# ── 前端与 tauri 生成物 ──────────────────────────────────────────────────────
Add-Entry '前端构建产物（vite build 的 outDir）' (Join-Path $Root 'dist')
Add-Entry 'tauri-build 生成的 ACL 与能力 schema' (Join-Path $Root 'src-tauri\gen\schemas')
Add-Entry 'tauri icon 的备份目录' (Join-Path $Root 'src-tauri\icons-backup')

# ── pack-npm 的暂存产物 ──────────────────────────────────────────────────────
Add-Entry 'pack-npm 暂存的前端资源' (Join-Path $Root 'npm\webui_dist')
$PlatformRoot = Join-Path $Root 'npm\platform'
if (Test-Path -LiteralPath $PlatformRoot) {
    Get-ChildItem -LiteralPath $PlatformRoot -Directory | ForEach-Object {
        Add-Entry 'pack-npm 暂存的平台二进制' (Join-Path $_.FullName 'bin')
    }
}
Add-Entry 'pack-npm 旧布局的服务端二进制' (Join-Path $Root 'npm\bin\qs-switch-server')
Add-Entry 'pack-npm 旧布局的服务端二进制（.exe）' (Join-Path $Root 'npm\bin\qs-switch-server.exe')

# ── 各类缓存 ─────────────────────────────────────────────────────────────────
Add-Entry 'vite 依赖预构建缓存' (Join-Path $Root 'node_modules\.vite')
Add-Entry 'vite 依赖预构建缓存（临时）' (Join-Path $Root 'node_modules\.vite-temp')
Add-Entry 'node 工具链缓存' (Join-Path $Root 'node_modules\.cache')

# TypeScript 增量编译信息：tsc --noEmit 一般不产生，但一旦开了 incremental 会散落在各处。
# 自己走一层目录而不是 Get-ChildItem -Recurse：要能在进 node_modules / target 之前就剪枝，
# 那两处有几十万文件，全量递归的耗时在本机能到分钟级（结果两边是一样的，那些不是我们的产物）。
function Find-TsBuildInfo {
    param([string]$Dir)
    $skip = @('node_modules', '.git', 'target')
    $queue = New-Object System.Collections.Generic.Queue[string]
    $queue.Enqueue($Dir)
    while ($queue.Count -gt 0) {
        $d = $queue.Dequeue()
        try {
            foreach ($f in [System.IO.Directory]::GetFiles($d, '*.tsbuildinfo')) { $f }
            foreach ($sub in [System.IO.Directory]::GetDirectories($d)) {
                $name = Split-Path -Leaf $sub
                if ($name -in $skip) { continue }
                try {
                    $a = [System.IO.Directory]::GetAttributes($sub)
                } catch { continue }
                if ($a -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                $queue.Enqueue($sub)
            }
        } catch { }
    }
}
foreach ($hit in Find-TsBuildInfo -Dir $Root) {
    Add-Entry 'TypeScript 增量编译信息' $hit
}

if ($WithNodeModules) {
    Add-Entry '前端依赖目录（清理后需重新 npm install）' (Join-Path $Root 'node_modules')
}

if ($Entries.Count -eq 0) {
    Say '没有发现需要清理的构建产物 —— 工作区已经是干净的。'
    exit 0
}

Say "== 待清理清单（仓库根: $Root）=="
foreach ($e in $Entries) {
    $tag = ''
    if (-not $e.Path.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $tag = '  ⚠ 位于仓库外'
    }
    Say ('  {0,-9} {1}{2}' -f (Format-Size $e.Kb), $e.Path, $tag)
    Say ('            └ {0}' -f $e.Desc)
}
Say "  合计可释放: $(Format-Size $script:TotalKb)，共 $($Entries.Count) 项"

if ($DryRun) {
    Say '== --dry-run：以上内容均未删除 =='
    exit 0
}

if (-not $AssumeYes) {
    # stdin 不是终端时 Read-Host 会直接抛异常而不是等人 —— 先判重定向，走与 clean.sh
    # 相同的第三条路：明确要求 --yes，什么都不删。
    if ([Console]::IsInputRedirected) {
        Warn '非交互环境：请显式加 --yes 确认删除，或先用 --dry-run 预览。未删除任何文件。'
        exit 1
    }
    $ans = Read-Host "确认删除以上 $($Entries.Count) 项？[y/N]"
    if ($ans -notin @('y', 'Y', 'yes', 'YES')) {
        Say '已取消，未删除任何文件。'
        exit 0
    }
}

# 有构建正在进行时拒绝删除。
#
# 为什么需要：删掉几 GB 的 target 要数十秒，而 cargo 会在编译中途创建
# target/debug/deps/rmetaXXXX。目录被抽走后 rustc 报 ENOENT（它建临时目录用 create_dir
# 而非 create_dir_all），现场看起来像"target 凭空消失"。本仓库真实踩过一次。
#
# 判据用构建脚本留下的锁而不是扫进程名：进程名分不清是哪个仓库，且 cargo 的命令行不含
# 仓库路径（cwd 不在 argv 里），按路径扫必然漏检。PID 已不存在视为陈旧锁，放行。
#
# winpid 优先于 pid，规则与 scripts/qs-lock.sh（build.sh / clean.sh 共用）一致：build.sh
# 写的 pid 是 Git-Bash 的 MSYS 编号，本机 Get-Process 按它查会撞上无关进程或查不到，
# 判活结果不可信；winpid 才是两种入口共同对得上号的那个内核 PID。
$LockDir = Join-Path $TargetDir '.qs-build-lock'
$LockWinPidFile = Join-Path $LockDir 'winpid'
$LockPidFile = Join-Path $LockDir 'pid'
$holder = 0
foreach ($p in @($LockWinPidFile, $LockPidFile)) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $raw = ([System.IO.File]::ReadAllText($p) -replace '\s', '')
    $num = 0
    if (-not [int]::TryParse($raw, [ref] $num)) { continue }
    if ($num -gt 0 -and (Get-Process -Id $num -ErrorAction SilentlyContinue)) { $holder = $num; break }
}
if ($holder -gt 0) {
    Warn "检测到构建正在进行（PID $holder），拒绝清理。"
    Warn '边构建边清理会把 target/debug/deps 抽走，让 cargo 报出迷惑性的 ENOENT。'
    Warn "等它结束再重跑本脚本。锁文件：$LockDir"
    exit 1
}

function Test-Blocked {
    # 硬保护：绝不动空路径、文件系统根、家目录、仓库根，以及仓库根的任一祖先目录。
    param([string]$Path)
    if ($Path -eq '' -or $Path -eq '\' -or $Path -eq '/' -or
        $Path -eq $HomeDir -or $Path -eq $Root) {
        Warn "拒绝删除受保护路径: $Path"
        return $true
    }
    # 祖先判定必须补上分隔符再比：否则 "E:\proj" 会误伤 "E:\project-x"。
    $asDir = $Path.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($asDir.Length -gt 3 -and $Root.StartsWith($asDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        Warn "拒绝删除仓库根的祖先目录: $Path"
        return $true
    }
    return $false
}

$Removed = 0
foreach ($e in $Entries) {
    if (Test-Blocked $e.Path) { exit 1 }
    Remove-Item -LiteralPath $e.Path -Recurse -Force
    $Removed++
}

# 复核：删完再确认一遍，避免出现"报成功但其实还在"。
$Leftover = 0
foreach ($e in $Entries) {
    if (Test-Path -LiteralPath $e.Path) {
        Warn "⚠ 未能删除: $($e.Path)"
        $Leftover++
    }
}

if ($Leftover -gt 0) {
    Warn "== 清理未完全成功：仍有 $Leftover 项残留（可能被进程占用或权限不足）=="
    exit 1
}

Say "== 清理完成：删除 $Removed 项，释放约 $(Format-Size $script:TotalKb) =="
Say '   保留项: src-tauri/icons/（已入库的源图标）、Cargo.lock、package-lock.json 等版本控制文件'
if ($WithNodeModules) {
    Say '   提示: node_modules 已删除，下次构建前先跑 scripts/build.ps1 deps（或 npm install）'
} else {
    Say '   提示: 想连 node_modules 一起清，加 --all'
}
