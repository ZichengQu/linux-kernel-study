#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# 观测 scx_cpu0 是否已经启用，以及任务是否按 CPU0 调度器的预期运行。
# 脚本会默认创建 2 倍在线 CPU 数量的 CPU-bound 测试负载。

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SHOW_STATE="$SCRIPT_DIR/scx_show_state.py"
SCHED_EXT=/sys/kernel/sched_ext

OBSERVE_INTERVAL=1
OBSERVE_DURATION=600
nr_cpus=
nr_busy_tasks=
pid=
work_pids=()
prev_cpu_stats=()
prev_task_stats=()

# 打印脚本用法，说明当前固定的观测行为和唯一支持的帮助参数。
usage()
{
        cat <<EOF
Usage: $0 [OPTIONS]

通过 sched_ext sysfs 状态、任务 sched 状态、内置事件计数、
scx_show_state.py、CPU-bound 测试负载和每 CPU 利用率来观测 scx_cpu0。

Options:
  -h, --help          显示帮助信息

Examples:
  $0
  sudo $0
EOF
}

# 检查指定命令是否存在；缺失时直接退出，避免后续输出误导。
need_cmd()
{
        if ! command -v "$1" >/dev/null 2>&1; then
                echo "missing command: $1" >&2
                exit 1
        fi
}

# 清理脚本创建的测试负载，保证正常退出或被中断时不留下忙循环进程。
cleanup()
{
        if ((${#work_pids[@]})); then
                kill "${work_pids[@]}" >/dev/null 2>&1 || true
        fi
}

# 运行 scx_show_state.py；如果脚本不可执行，则尝试通过 drgn 解释执行。
run_show_state()
{
        if [[ ! -r "$SHOW_STATE" ]]; then
                echo "<unavailable: $SHOW_STATE>"
                return
        fi

        if [[ -x "$SHOW_STATE" ]]; then
                if ((EUID == 0)); then
                        "$SHOW_STATE" 2>/dev/null || echo "scx_show_state.py failed"
                elif command -v sudo >/dev/null 2>&1; then
                        sudo "$SHOW_STATE" 2>/dev/null || echo "scx_show_state.py failed"
                else
                        echo "sudo unavailable; skip"
                fi
        elif command -v drgn >/dev/null 2>&1; then
                if ((EUID == 0)); then
                        drgn "$SHOW_STATE" 2>/dev/null || echo "scx_show_state.py failed"
                elif command -v sudo >/dev/null 2>&1; then
                        sudo drgn "$SHOW_STATE" 2>/dev/null || echo "scx_show_state.py failed"
                else
                        echo "sudo unavailable; skip"
                fi
        else
                echo "drgn unavailable; skip"
        fi
}

# 读取单个 sysfs/procfs 文件；不可读时输出明确的 unavailable 标记。
read_one()
{
        local path=$1

        if [[ -r "$path" ]]; then
                cat "$path"
        else
                echo "<unavailable: $path>"
        fi
}

# 打印指定任务在 /proc/PID/sched 中暴露的 sched_ext 相关字段。
print_task_ext_state()
{
        local task_pid=$1
        local sched_file="/proc/$task_pid/sched"

        if [[ ! -r "$sched_file" ]]; then
                echo "task[$task_pid]: <cannot read $sched_file>"
                return
        fi

        local ext_line
        ext_line=$(grep -E "ext\.(enabled|slice|dsq_vtime)" "$sched_file" || true)
        if [[ -n "$ext_line" ]]; then
                echo "$ext_line"
        else
                echo "task[$task_pid]: no ext.* fields found"
        fi
}

# 打印 scx_cpu0 的关键 sched_ext 事件计数，聚焦基础诊断项。
print_events()
{
        local events="$SCHED_EXT/cpu0/events"

        if [[ ! -r "$events" ]]; then
                echo "<unavailable: $events>"
                return
        fi

        grep -E "SCX_EV_(REFILL_SLICE_DFL|SELECT_CPU_FALLBACK|DISPATCH_KEEP_LAST|ENQ_SKIP_EXITING|ENQ_SKIP_MIGRATION_DISABLED|REENQ_IMMED|REENQ_LOCAL_REPEAT|BYPASS_DURATION|BYPASS_DISPATCH|BYPASS_ACTIVATE|INSERT_NOT_OWNED|SUB_BYPASS_DISPATCH)" "$events" || true
}

# 获取当前在线逻辑 CPU 数量，用于决定测试负载数量。
get_online_cpu_count()
{
        getconf _NPROCESSORS_ONLN
}

# 创建用于观测 scx_cpu0 行为的测试负载，数量为在线 CPU 数的 2 倍。
launch_workloads()
{
        local idx

        nr_cpus=$(get_online_cpu_count)
        nr_busy_tasks=$((nr_cpus * 2))

        for ((idx = 0; idx < nr_busy_tasks; idx++)); do
                bash -c 'while :; do :; done' &
                work_pids+=("$!")
        done

        echo "online cpus: $nr_cpus"
        echo "busy tasks:  $nr_busy_tasks"
        echo "workload pids: ${work_pids[*]}"
}

# 解析命令行参数；当前只接受 -h/--help，其它参数视为误用。
parse_args()
{
        while (($#)); do
                case "$1" in
                -h|--help)
                        usage
                        exit 0
                        ;;
                *)
                        echo "unknown option: $1" >&2
                        usage >&2
                        exit 1
                        ;;
                esac
                shift
        done
}

# 检查脚本运行所需的基础命令。
check_dependencies()
{
        need_cmd awk
        need_cmd getconf
        need_cmd grep
}

# 启动默认测试负载，并选择第一个 busy 任务作为默认观测 PID。
setup_workloads()
{
        launch_workloads
        if [[ ${#work_pids[@]} -gt 0 ]]; then
                pid=${work_pids[0]}
        fi
        pid=${pid:-$BASHPID}
}

# 打印基础检测项的标题和时间戳。
print_header()
{
        local now

        now=$(date "+%F %T")

        echo "=== scx_cpu0 observation: $now ==="
        echo
}

# 打印 sched_ext 全局状态，确认调度器是否启用以及当前 ops 名称。
print_sched_ext_state()
{
        echo "[1] sched_ext state"
        echo "state:      $(read_one "$SCHED_EXT/state")"
        echo "root/ops:   $(read_one "$SCHED_EXT/root/ops")"
        echo "enable_seq: $(read_one "$SCHED_EXT/enable_seq")"
        echo
}

# 打印默认观测任务的 sched_ext 字段，确认该任务是否进入 ext class。
print_observed_task_state()
{
        echo "[2] task sched_ext state: pid=$pid"
        print_task_ext_state "$pid"
        echo
}

# 打印 scx_show_state.py 输出，提供 sched_ext 当前状态的汇总视图。
print_show_state_section()
{
        echo "[3] scx_show_state.py"
        run_show_state
        echo
}

# 打印 scx_cpu0 对应的 sched_ext 事件计数，用于发现 fallback/refill 等行为。
print_events_section()
{
        echo "[4] sched_ext/cpu0 events"
        print_events
        echo
}

# 提醒用户 scx_cpu0 的 local/cpu0 计数需要在其运行终端观察。
print_scx_cpu0_stdout_hint()
{
        echo "[5] scx_cpu0 stdout"
        echo "本脚本不启动 scx_cpu0；请在运行 scx_cpu0 的终端观察 local/cpu0 计数。"
        echo "预期：大量无绑核 CPU-bound 任务会暴露 scx_cpu0 是否把可运行负载集中到 CPU0。"
        echo
}

# 从 /proc/stat 读取每个 CPU 的 total/idle 计数，用于计算每 CPU 利用率。
read_cpu_stats()
{
        local line cpu user nice system idle iowait irq softirq steal guest guest_nice
        local total idle_all
        local stats=()

        if [[ ! -r /proc/stat ]]; then
                echo "<unavailable: /proc/stat>"
                return 1
        fi

        while read -r line; do
                [[ $line =~ ^cpu[0-9]+[[:space:]] ]] || continue
                read -r cpu user nice system idle iowait irq softirq steal guest guest_nice <<<"$line"
                idle_all=$((idle + iowait))
                total=$((user + nice + system + idle + iowait + irq + softirq + steal))
                stats+=("$cpu:$total:$idle_all")
        done < /proc/stat

        printf '%s\n' "${stats[@]}"
}

# 基于两次 /proc/stat 采样的差值，打印每个 CPU 的 busy 利用率。
print_per_cpu_usage()
{
        local curr_cpu_stats=("$@")
        local idx prev curr cpu total idle prev_cpu prev_total prev_idle
        local total_delta idle_delta busy pct

        if ((${#prev_cpu_stats[@]} == 0 || ${#curr_cpu_stats[@]} == 0)); then
                echo "per-cpu usage: <unavailable>"
                prev_cpu_stats=("${curr_cpu_stats[@]}")
                return
        fi

        echo "per-cpu usage:"
        for idx in "${!curr_cpu_stats[@]}"; do
                prev=${prev_cpu_stats[$idx]:-}
                curr=${curr_cpu_stats[$idx]}
                [[ -n "$prev" ]] || continue

                IFS=: read -r prev_cpu prev_total prev_idle <<<"$prev"
                IFS=: read -r cpu total idle <<<"$curr"
                [[ "$cpu" == "$prev_cpu" ]] || continue

                total_delta=$((total - prev_total))
                idle_delta=$((idle - prev_idle))
                if ((total_delta <= 0)); then
                        pct="0.0"
                else
                        busy=$((total_delta - idle_delta))
                        pct=$(awk -v busy="$busy" -v total="$total_delta" 'BEGIN { printf "%.1f", busy * 100.0 / total }')
                fi
                printf '  %-5s %5s%%\n' "$cpu" "$pct"
        done

        prev_cpu_stats=("${curr_cpu_stats[@]}")
}

# 计算两次 /proc/stat 采样之间单个 CPU 平均经过的 tick 数。
calc_avg_cpu_total_delta()
{
        local curr_cpu_stats=("$@")
        local idx prev curr cpu total idle prev_cpu prev_total prev_idle
        local total_sum=0 nr=0

        if ((${#prev_cpu_stats[@]} == 0 || ${#curr_cpu_stats[@]} == 0)); then
                echo 0
                return
        fi

        for idx in "${!curr_cpu_stats[@]}"; do
                prev=${prev_cpu_stats[$idx]:-}
                curr=${curr_cpu_stats[$idx]}
                [[ -n "$prev" ]] || continue

                IFS=: read -r prev_cpu prev_total prev_idle <<<"$prev"
                IFS=: read -r cpu total idle <<<"$curr"
                [[ "$cpu" == "$prev_cpu" ]] || continue

                total_sum=$((total_sum + total - prev_total))
                nr=$((nr + 1))
        done

        if ((nr == 0)); then
                echo 0
        else
                echo $((total_sum / nr))
        fi
}

# 从 /proc/PID/stat 读取任务当前 CPU 和累计运行 tick。
read_task_stat()
{
        local task_pid=$1
        local stat_file="/proc/$task_pid/stat"

        if [[ ! -r "$stat_file" ]]; then
                return 1
        fi

        awk -v pid="$task_pid" '
        {
                stat = $0
                sub(/^.*\) /, "", stat)
                n = split(stat, f, " ")
                utime = f[12]
                stime = f[13]
                processor = f[37]
                printf "%s:%s:%s\n", pid, processor, utime + stime
        }' "$stat_file"
}

# 读取所有测试任务的瞬时状态采样。
read_task_stats()
{
        local task_pid

        for task_pid in "${work_pids[@]}"; do
                read_task_stat "$task_pid" || true
        done
}

# 基于两次 /proc/PID/stat 采样差值，打印任务最近一个采样窗口的 CPU 利用率。
print_task_cpu_usage()
{
        local avg_cpu_total_delta=$1
        shift
        local curr_task_stats=("$@")
        local idx prev curr task_pid psr ticks prev_pid prev_psr prev_ticks
        local tick_delta pct

        if ((${#prev_task_stats[@]} == 0 || ${#curr_task_stats[@]} == 0 || avg_cpu_total_delta <= 0)); then
                echo "task CPU interval snapshot: <warming up>"
                prev_task_stats=("${curr_task_stats[@]}")
                return
        fi

        echo "task CPU interval snapshot:"
        printf '%7s %3s %6s %s\n' "PID" "PSR" "%CPU" "COMMAND"
        for idx in "${!curr_task_stats[@]}"; do
                prev=${prev_task_stats[$idx]:-}
                curr=${curr_task_stats[$idx]}
                [[ -n "$prev" ]] || continue

                IFS=: read -r prev_pid prev_psr prev_ticks <<<"$prev"
                IFS=: read -r task_pid psr ticks <<<"$curr"
                [[ "$task_pid" == "$prev_pid" ]] || continue

                tick_delta=$((ticks - prev_ticks))
                pct=$(awk -v delta="$tick_delta" -v total="$avg_cpu_total_delta" 'BEGIN { printf "%.1f", delta * 100.0 / total }')
                printf '%7s %3s %6s %s\n' "$task_pid" "$psr" "$pct" "bash"
        done

        prev_task_stats=("${curr_task_stats[@]}")
}

# 打印测试负载的 ext 状态、任务 CPU 分布和每 CPU 利用率。
print_workload_section()
{
        local idx pid_list
        local curr_cpu_stats=()
        local curr_task_stats=()
        local avg_cpu_total_delta

        clear 2>/dev/null || true
        echo "[6] 2x-cpu busy workload"
        echo "online_cpus=$nr_cpus busy_tasks=$nr_busy_tasks"
        for idx in "${!work_pids[@]}"; do
                echo "busy[$idx] pid=${work_pids[$idx]}"
                print_task_ext_state "${work_pids[$idx]}"
        done
        echo

        mapfile -t curr_cpu_stats < <(read_cpu_stats || true)
        mapfile -t curr_task_stats < <(read_task_stats || true)
        avg_cpu_total_delta=$(calc_avg_cpu_total_delta "${curr_cpu_stats[@]}")

        print_task_cpu_usage "$avg_cpu_total_delta" "${curr_task_stats[@]}"
        echo

        print_per_cpu_usage "${curr_cpu_stats[@]}"
        echo
}

# 打印动态观测时长和刷新间隔说明。
print_footer()
{
        echo "第 [6] 项默认观测 ${OBSERVE_DURATION}s，每 ${OBSERVE_INTERVAL}s 刷新一次。按 Ctrl-C"
}

# 执行一次基础检测输出；这些项目不随循环刷新。
print_static_observation()
{
        print_header
        print_sched_ext_state
        print_observed_task_state
        print_show_state_section
        print_events_section
        print_scx_cpu0_stdout_hint
}

# 执行一轮动态检测输出；当前只有测试负载状态需要周期刷新。
print_dynamic_observation_once()
{
        print_workload_section
        print_footer
}

# 主观测循环；只周期刷新动态检测项，达到默认观测时长后退出。
observe_loop()
{
        local start_ts elapsed

        print_static_observation
        echo "按 Enter 开始刷新第 [6] 项。"
        read -r _unused
        mapfile -t prev_cpu_stats < <(read_cpu_stats || true)
        mapfile -t prev_task_stats < <(read_task_stats || true)
        sleep "$OBSERVE_INTERVAL"
        start_ts=$(date +%s)

        while true; do
                print_dynamic_observation_once

                elapsed=$(($(date +%s) - start_ts))
                if ((elapsed >= OBSERVE_DURATION)); then
                        break
                fi

                sleep "$OBSERVE_INTERVAL"
        done
}

# 脚本主入口：解析参数、检查依赖、准备负载、注册清理逻辑并开始观测。
main()
{
        parse_args "$@"
        check_dependencies
        setup_workloads
        trap cleanup EXIT INT TERM
        observe_loop
}

main "$@"
