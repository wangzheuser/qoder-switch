# 打包 npm 多平台形态（Windows 原生入口）：构建 server + 前端，把产物暂存进 npm/ 各平台包目录。
# 之后由维护者手动 npm publish（需要 npm 账号与发布令牌，见 npm/README.md）。
#
# 用法（与 pack-npm.sh 逐一对应）：
#   powershell -File scripts/pack-npm.ps1                                    # 只打宿主这一个平台
#   powershell -File scripts/pack-npm.ps1 x86_64-pc-windows-msvc             # 显式指定 target
#
# 一次跑不了全部平台：Windows 上造不出 darwin 二进制。所以每个平台各跑一次，最后一起 publish。
# 产物不入库（npm/.gitignore 已挡）；发布前用 `npm pack --dry-run` 核对文件清单。
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Targets = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LASTEXITCODE = 0

function Say { param([string]$Text) [Console]::Out.WriteLine($Text) }
function Warn { param([string]$Text) [Console]::Error.WriteLine($Text) }

function Resolve-Tool {
    # 同 build.ps1：优先 .cmd，绕开 npm.ps1 shim 的执行策略与退出码回传问题。
    param([string]$Name)
    $cmd = Get-Command "$Name.cmd" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $plain = Get-Command $Name -ErrorAction SilentlyContinue
    if ($plain) { return $plain.Source }
    return $null
}

function Invoke-Step {
    param([string]$Exe, [string[]]$Arguments = @())
    if (-not $Exe) { throw '找不到所需命令，无法继续。' }
    Say("  > $(Split-Path -Leaf $Exe) $($Arguments -join ' ')")
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "命令失败（退出码 $LASTEXITCODE）：$(Split-Path -Leaf $Exe) $($Arguments -join ' ')"
    }
}

Set-Location (Split-Path -Parent $PSScriptRoot)
$Root = (Get-Location).Path

if (-not $env:RUSTUP_HOME) { $env:RUSTUP_HOME = 'E:\rustup' }
if (-not $env:CARGO_HOME) { $env:CARGO_HOME = 'E:\cargo' }
if (-not $env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR = 'E:\qs-target' }
$env:CARGO_TARGET_DIR = [System.IO.Path]::GetFullPath($env:CARGO_TARGET_DIR)

$CargoBin = Join-Path $env:CARGO_HOME 'bin'
if (-not (($env:Path -split ';') -contains $CargoBin)) { $env:Path = "$CargoBin;$env:Path" }

$Node = Resolve-Tool 'node'
$Cargo = Resolve-Tool 'cargo'
$Rustc = Resolve-Tool 'rustc'
$Npm = Resolve-Tool 'npm'
# rustup 不是硬依赖：只有显式指定非宿主 target 时才用得到，且缺了也只影响 std 安装。
$Rustup = Resolve-Tool 'rustup'
foreach ($t in @(@('node', $Node), @('cargo', $Cargo), @('rustc', $Rustc), @('npm', $Npm))) {
    if (-not $t[1]) { Warn "找不到 $($t[0])（CARGO_HOME=$env:CARGO_HOME → $CargoBin）"; exit 1 }
}

# 平台包目录名与二进制文件名。新增平台只改这张表 —— 与 pack-npm.sh 的 target_key 同源。
function Get-PlatformSpec {
    param([string]$Target)
    switch ($Target) {
        'x86_64-pc-windows-msvc' { return @('qoder-switch-win32-x64', 'qs-switch-server.exe') }
        'aarch64-apple-darwin'   { return @('qoder-switch-darwin-arm64', 'qs-switch-server') }
        'x86_64-apple-darwin'    { return @('qoder-switch-darwin-x64', 'qs-switch-server') }
        default                  { return $null }
    }
}

$Version = (& $Node -p "require('./package.json').version").Trim()
if ($LASTEXITCODE -ne 0 -or -not $Version) { Warn '读不到 package.json 的 version'; exit 1 }
Say "== qoder-switch npm 打包 v$Version（宿主: windows）=="

# 强制核对版本一致性，任一不符直接终止，防止发错版本包。
Invoke-Step $Node @((Join-Path $PSScriptRoot 'check-versions.cjs'))

Say '== 1/3 构建 webui 服务端（release）=='
# 与 pack-npm.sh 一样从 `rustc -vV` 的 host: 行取宿主 target。
$RustcInfo = & $Rustc -vV
if ($LASTEXITCODE -ne 0) { Warn 'rustc -vV 执行失败'; exit 1 }
$HostTarget = ($RustcInfo | Select-String -Pattern '^host: ' | Select-Object -First 1).ToString() -replace '^host:\s*', ''
if (-not $HostTarget) { Warn '无法从 rustc -vV 取 host target'; exit 1 }

if (-not $Targets -or $Targets.Count -eq 0) { $Targets = @($HostTarget) }

$Built = New-Object System.Collections.Generic.List[string]
foreach ($t in $Targets) {
    $spec = Get-PlatformSpec $t
    if (-not $spec) {
        Warn "跳过 ${t}：这张表里没有对应的 npm 平台包"
        continue
    }
    $pkg = $spec[0]
    $bin = $spec[1]
    if ($t -ne $HostTarget) {
        # 交叉编译需要先把 std 装上；装失败不致命（可能已装或离线），交给 cargo 报真实原因。
        # 与 pack-npm.sh 的 `rustup target add ... || true` 同义。stderr 不经 2>&1 丢弃，
        # 理由见 build.ps1 的 Kill-Previous：PS 5.1 会把原生命令的 stderr 行变成终止错误。
        if ($Rustup) {
            $null = & $env:ComSpec /c " `"$Rustup`" target add $t 2>nul"
            $LASTEXITCODE = 0
        }
        Invoke-Step $Cargo @('build', '--release', '-p', 'qs-switch-server', '--target', $t)
        # 显式带 --target 时 cargo 会多插一层 target triple：
        # $CARGO_TARGET_DIR\<triple>\release\，不是 release\<triple>\。
        $src = Join-Path $env:CARGO_TARGET_DIR "$t\release\$bin"
    } else {
        Invoke-Step $Cargo @('build', '--release', '-p', 'qs-switch-server')
        $src = Join-Path $env:CARGO_TARGET_DIR "release\$bin"
    }
    if (-not (Test-Path -LiteralPath $src)) { Warn "构建后找不到产物 $src"; exit 1 }
    $dstDir = Join-Path $Root "npm\platform\$pkg\bin"
    if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination (Join-Path $dstDir $bin) -Force
    # 没有 chmod 那一步：Windows 上可执行位由 .exe 扩展名决定，NTFS ACL 与 0755 不对应。
    $Built.Add($pkg)
    Say "  → npm/platform/$pkg/bin/$bin"
}

Say '== 2/3 构建前端 dist =='
Invoke-Step $Npm @('run', 'build')

Say '== 3/3 暂存主包前端资源 =='
# 主包：前端 dist（npm pack 不看 .gitignore，files 字段会带上 webui_dist）
$staged = Join-Path $Root 'npm\webui_dist'
if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Recurse -Force }
Copy-Item -LiteralPath (Join-Path $Root 'dist') -Destination $staged -Recurse -Force

if ($Built.Count -eq 0) {
    Say '== 完成。已产出平台包：（无）=='
} else {
    Say "== 完成。已产出平台包：$($Built -join ', ') =="
}
foreach ($p in $Built) {
    Say "  (cd npm/platform/$p && npm pack --dry-run)"
}
Say '  (cd npm && npm pack --dry-run)'
Say '其余平台请在对应宿主上再各跑一次本脚本。'
