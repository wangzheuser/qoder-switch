# shellcheck shell=bash
# 构建锁（target/.qs-build-lock）的判活规则，被 build.sh 与 clean.sh 共用。
#
# 为什么单独一个文件：这道护栏成立的前提是"检查锁的那一方"和"持锁的那一方"用同一套
# 判活规则。Windows 上这条前提天然被打破 —— Git-Bash 的 PID 与 Windows 内核 PID 是两套
# 编号，而 .sh 与 .ps1 两种入口各写各的 PID。判据抄两份迟早只改一边，漏掉的那边表现为
# "锁根本没挡住"，静默删掉正在构建的 target（本机实测：clean.sh 对 build.ps1 写的锁
# 返回成功并把几 GB 的 target 删了）。所以规则集中在这里，两个入口都只调函数。
#
# 锁目录里的两个文件：
#   pid     持锁进程在自己那套编号里的 PID（build.sh 写 MSYS 的 $$，build.ps1 写 $PID）
#   winpid  持锁进程的 Windows 内核 PID（仅 Windows；build.sh 从 ps -W 换算，build.ps1 直接给）
# 读侧一律 winpid 优先：它在 .sh 和 .ps1 眼里是同一个数字，只有它能把两种入口互锁住。

qs_is_windows_host() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# 当前这个 bash 自己的 Windows 内核 PID；拿不到就输出空（老版本 Git-Bash 没有 ps -W）。
qs_self_winpid() {
  qs_is_windows_host || return 0
  ps -W 2>/dev/null | awk -v me="$$" '$1 == me { print $4; exit }'
}

# 判活。$1 = PID，$2 = 编号空间：win 表示 Windows 内核 PID，其它（含留空）按调用方自己的
# 编号处理。
#
# win 那一支不能用 kill -0：Git-Bash 的 kill 只认 MSYS 自己那套 PID，喂给它 Windows PID
# 会恒返回"没有这个进程"（本机实测 kill -0 与 taskkill /PI 都判不出来），正在构建的锁就
# 会被判成陈旧锁。tasklist 是唯一能按内核 PID 查到的入口，且它查不到时退出码仍是 0，
# 所以判据是"过滤掉表头噪声之后还剩不剩行"。
qs_pid_alive() {
  local pid="${1:-}" space="${2:-}"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ "$space" = win ] && qs_is_windows_host; then
    # tasklist 查不到时也返回 0，所以判据是"过滤掉表头与 INFO 之后还剩不剩行"。
    # 显式写成 if/return 而不是裸管道：调用方都在 set -o pipefail 下，一条只为取真假值
    # 的管道不该把信号/提前退出当成结果。
    if tasklist //FI "PID eq $pid" //NH 2>/dev/null \
      | grep -v -e '^[[:space:]]*$' -e '^INFO:' | grep -q .; then
      return 0
    fi
    return 1
  fi
  kill -0 "$pid" 2>/dev/null
}

# $1 = 锁目录。活着的持锁者 PID 打到 stdout 并返回 0；没人持锁（锁不存在或已是陈旧锁）
# 则无输出返回 1 —— 调用方据此决定"拒绝"还是"接管"。
qs_lock_holder() {
  local dir="${1:-}" n
  if [ -f "$dir/winpid" ]; then
    n="$(tr -cd '0-9' < "$dir/winpid" 2>/dev/null)"
    if qs_pid_alive "$n" win; then printf '%s\n' "$n"; return 0; fi
  fi
  if [ -f "$dir/pid" ]; then
    n="$(tr -cd '0-9' < "$dir/pid" 2>/dev/null)"
    if qs_pid_alive "$n" msys; then printf '%s\n' "$n"; return 0; fi
  fi
  return 1
}

# $1 = 锁目录，$2 = 要写进 pid 文件的值。winpid 能算出来才写：没有它时另一侧会退回
# kill -0 判 pid，行为与修复前一致，不会因为多了个文件而变得更糟。
qs_lock_write_pid() {
  local dir="$1" pid="$2" w
  # 必须 ASCII 且不带 UTF-16 BOM：PowerShell 默认的 `>` 写出来是 UTF-16，另一侧 `cat`
  # 得到乱码，判活直接失败 → 陈旧锁被误放行。这里显式用 printf 保证字节可控。
  printf '%s\n' "$pid" > "$dir/pid"
  w="$(qs_self_winpid)"
  [ -n "$w" ] && printf '%s\n' "$w" > "$dir/winpid"
  return 0
}
