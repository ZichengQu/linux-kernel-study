#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Create controlled workload tasks for scx_qmap FIFO buckets.

set -euo pipefail

SCHED_EXT=/sys/kernel/sched_ext
RUN_MS=5
SLEEP_MS=5
CPU=""
DEPTH=1
QUEUES="0,1,2,3,4"

# nice -> sched_prio_to_weight -> scx.weight -> scx_qmap weight_to_idx()
queue_ids=(0 1 2 3 4)
queue_nices=(10 5 0 -5 -10)
queue_weights=(11 33 100 305 932)
queue_rules=("weight <= 25" "weight <= 50" "weight < 200" "weight < 400" "weight >= 400")

pids=()

usage()
{
        cat <<EOF
Usage: $0 [OPTIONS]

Create controlled workload tasks for scx_qmap FIFO buckets.
Each task loops: busy for RUN_MS, sleep for SLEEP_MS, then become runnable again.
The tasks keep running until this script exits; Ctrl-C cleans them up.

Options:
  --run-ms MS     Busy-loop duration per cycle (default: $RUN_MS)
  --sleep-ms MS   Sleep duration per cycle (default: $SLEEP_MS)
  --cpu CPU       Bind all workload tasks to CPU
  --depth N       Create N tasks per queue (default: $DEPTH)
  --depth quota   Create 1/2/4/8/16 tasks for Q0/Q1/Q2/Q3/Q4
  --queues LIST   Comma-separated queues to create, e.g. 0,4 (default: $QUEUES)
  -h, --help      Show this help

Examples:
  sudo $0
  sudo $0 --run-ms 5 --sleep-ms 5 --cpu 0
  sudo $0 --run-ms 5 --sleep-ms 5 --cpu 0 --depth quota
  sudo $0 --run-ms 5 --sleep-ms 5 --cpu 0 --queues 0,4 --depth 16
EOF
}

need_cmd()
{
        if ! command -v "$1" >/dev/null 2>&1; then
                echo "missing command: $1" >&2
                exit 1
        fi
}

cleanup()
{
        if ((${#pids[@]})); then
                kill "${pids[@]}" >/dev/null 2>&1 || true
                wait "${pids[@]}" >/dev/null 2>&1 || true
        fi
}

parse_args()
{
        while (($#)); do
                case "$1" in
                --run-ms)
                        RUN_MS=${2:?missing value for --run-ms}
                        shift
                        ;;
                --sleep-ms)
                        SLEEP_MS=${2:?missing value for --sleep-ms}
                        shift
                        ;;
                --cpu)
                        CPU=${2:?missing value for --cpu}
                        shift
                        ;;
                --depth)
                        DEPTH=${2:?missing value for --depth}
                        shift
                        ;;
                --queues)
                        QUEUES=${2:?missing value for --queues}
                        shift
                        ;;
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

check_environment()
{
        need_cmd nice
        need_cmd python3
        if [[ -n "$CPU" ]]; then
                need_cmd taskset
        fi

        if ((EUID != 0)); then
                echo "need root: Q3/Q4 require negative nice values (-5/-10)" >&2
                exit 1
        fi

        if [[ -r "$SCHED_EXT/root/ops" ]]; then
                local ops
                ops=$(<"$SCHED_EXT/root/ops")
                if [[ "$ops" != "qmap" ]]; then
                        echo "warning: current sched_ext root/ops is '$ops', not 'qmap'" >&2
                        echo "         start scx_qmap first if you want these tasks handled by qmap" >&2
                fi
        else
                echo "warning: cannot read $SCHED_EXT/root/ops" >&2
        fi

        if ! [[ "$RUN_MS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                echo "invalid --run-ms: $RUN_MS" >&2
                exit 1
        fi
        if ! [[ "$SLEEP_MS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                echo "invalid --sleep-ms: $SLEEP_MS" >&2
                exit 1
        fi
        if [[ -n "$CPU" && ! "$CPU" =~ ^[0-9]+([,-][0-9]+)*$ ]]; then
                echo "invalid --cpu: $CPU" >&2
                exit 1
        fi
        if [[ "$DEPTH" != "quota" && ! "$DEPTH" =~ ^[1-9][0-9]*$ ]]; then
                echo "invalid --depth: $DEPTH" >&2
                exit 1
        fi
        if ! [[ "$QUEUES" =~ ^[0-4](,[0-4])*$ ]]; then
                echo "invalid --queues: $QUEUES" >&2
                exit 1
        fi
}

launch_one()
{
        local queue_id=$1
        local nice_value=$2
        local scx_weight=$3
        local task_id=$4
        local pid
        local cmd=(nice -n "$nice_value" python3 -c '
import sys
import time

run_s = float(sys.argv[1]) / 1000.0
sleep_s = float(sys.argv[2]) / 1000.0

while True:
    deadline = time.monotonic() + run_s
    n = 0
    while time.monotonic() < deadline:
        n = (n + 1) & 0xffffffff
    time.sleep(sleep_s)
' "$RUN_MS" "$SLEEP_MS")

        if [[ -n "$CPU" ]]; then
                taskset -c "$CPU" "${cmd[@]}" &
        else
                "${cmd[@]}" &
        fi
        pid=$!
        pids+=("$pid")

        printf 'Q%d[%02d]: pid=%-8s nice=%4s scx_weight=%4s rule=%s\n' \
                "$queue_id" "$task_id" "$pid" "$nice_value" "$scx_weight" "${queue_rules[$queue_id]}"
}

queue_depth()
{
        local queue_id=$1

        if [[ "$DEPTH" == "quota" ]]; then
                echo $((1 << queue_id))
        else
                echo "$DEPTH"
        fi
}

queue_enabled()
{
        local queue_id=$1
        local queue

        IFS=, read -ra enabled_queues <<<"$QUEUES"
        for queue in "${enabled_queues[@]}"; do
                if [[ "$queue" == "$queue_id" ]]; then
                        return 0
                fi
        done
        return 1
}

launch_workloads()
{
        local idx
        local task_id
        local depth

        echo "Creating controlled workload tasks for scx_qmap FIFO buckets:"
        printf 'Workload cycle: busy=%sms sleep=%sms' "$RUN_MS" "$SLEEP_MS"
        if [[ -n "$CPU" ]]; then
                printf ' cpu=%s' "$CPU"
        fi
        printf ' depth=%s queues=%s' "$DEPTH" "$QUEUES"
        echo
        echo "For single-CPU qmap observation, start scx_qmap with -I to avoid the pinned-task fast local path."
        echo "Use --depth quota when you want the 1/2/4/8/16 FIFO dispatch quota to be visible in trace."
        echo "Use --queues 0,4 --depth 16 to compare Q0 and Q4 with the same number of tasks."
        for idx in "${!queue_ids[@]}"; do
                if ! queue_enabled "${queue_ids[$idx]}"; then
                        continue
                fi
                depth=$(queue_depth "${queue_ids[$idx]}")
                for ((task_id = 0; task_id < depth; task_id++)); do
                        launch_one "${queue_ids[$idx]}" "${queue_nices[$idx]}" "${queue_weights[$idx]}" "$task_id"
                done
        done
        echo
        echo "PIDs: ${pids[*]}"
        echo "Press Ctrl-C to stop and clean up."
}

main()
{
        parse_args "$@"
        check_environment
        trap cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        launch_workloads

        while true; do
                sleep 3600
        done
}

main "$@"
