#!/usr/bin/env python3

"""
该脚本用于将调度/trace 导出的 JSON 统计记录，
按进程和线程维度聚合为 Sleep、Runnable、Running 三类状态的总时长与发生次数，
以便进行调度行为分析。
"""

#!/usr/bin/env python3
import json
import sys
import re
from collections import defaultdict

# =========================
# PID / TID blacklist
# =========================
SKIP_PIDS = {
    # 例如：
    # 1, 2, 1234
}

SKIP_TIDS = {
    # 例如：
    # 100, 200
}

# =========================
# State classification
# =========================
SLEEP_STATES = {"Sleeping", "Uninterruptible Sleep"}
RUNNABLE_STATES = {"Runnable", "Runnable (Preempted)"}
RUNNING_STATES = {"Running"}


# =========================
# Duration parser
# =========================
def parse_duration_to_ms(val: str) -> float:
    val = val.strip()
    m = re.fullmatch(r"([0-9]*\.?[0-9]+)\s*(µs|ms|s)", val)
    if not m:
        raise ValueError(f"Unknown duration format: {val}")

    num = float(m.group(1))
    unit = m.group(2)

    if unit == "µs":
        return num / 1000.0
    elif unit == "ms":
        return num
    elif unit == "s":
        return num * 1000.0

    raise ValueError(f"Unhandled unit: {unit}")


# =========================
# Stat helpers
# =========================
def init_stat():
    return {
        "sleep_time_ms": 0.0,
        "sleep_occ": 0,
        "runnable_time_ms": 0.0,
        "runnable_occ": 0,
        "running_time_ms": 0.0,
        "running_occ": 0,
    }


def update_stat(stat, state, avg_dur_ms, occ):
    total_time = avg_dur_ms * occ
    if state in SLEEP_STATES:
        stat["sleep_time_ms"] += total_time
        stat["sleep_occ"] += occ
    elif state in RUNNABLE_STATES:
        stat["runnable_time_ms"] += total_time
        stat["runnable_occ"] += occ
    elif state in RUNNING_STATES:
        stat["running_time_ms"] += total_time
        stat["running_occ"] += occ


# =========================
# Filter helpers
# =========================
def should_skip_record(r, skip_pids, skip_tids):
    pid = r.get("pid")
    tid = r.get("tid", pid)

    try:
        pid = int(pid)
    except (TypeError, ValueError):
        pid = None

    try:
        tid = int(tid)
    except (TypeError, ValueError):
        tid = None

    if pid in skip_pids:
        return True
    if tid in skip_tids:
        return True
    return False


# =========================
# Aggregation
# =========================
def aggregate_global(records, skip_pids, skip_tids):
    total = init_stat()
    by_thread = defaultdict(init_stat)

    for r in records:
        if should_skip_record(r, skip_pids, skip_tids):
            continue

        update_stat(
            total,
            r["state"],
            parse_duration_to_ms(r["avg_dur"]),
            int(r["occurrences"])
        )
        update_stat(
            by_thread[r.get("thread_name", "unknown")],
            r["state"],
            parse_duration_to_ms(r["avg_dur"]),
            int(r["occurrences"])
        )

    return total, by_thread


def aggregate_by_pid(records, skip_pids, skip_tids):
    stats = defaultdict(lambda: {
        "total": init_stat(),
        "threads": defaultdict(init_stat)
    })

    for r in records:
        if should_skip_record(r, skip_pids, skip_tids):
            continue

        pid = r["pid"]
        tname = r.get("thread_name", "unknown")

        update_stat(
            stats[pid]["total"],
            r["state"],
            parse_duration_to_ms(r["avg_dur"]),
            int(r["occurrences"])
        )
        update_stat(
            stats[pid]["threads"][tname],
            r["state"],
            parse_duration_to_ms(r["avg_dur"]),
            int(r["occurrences"])
        )

    return stats


# =========================
# Output helpers
# =========================
def fmt_time(ms):
    return f"{ms/1000:.1f}s" if ms >= 1000 else f"{ms:.1f}ms"


def inline_stat(stat):
    return (
        f"sleep: {fmt_time(stat['sleep_time_ms'])}, sleep_occ: {stat['sleep_occ']}, "
        f"runnable: {fmt_time(stat['runnable_time_ms'])}, runnable_occ: {stat['runnable_occ']}, "
        f"running: {fmt_time(stat['running_time_ms'])}, running_occ: {stat['running_occ']}"
    )


def print_block(title, total, threads):
    print(f"\n{title}:")
    print("{")
    print(f"  total: {{ {inline_stat(total)} }},")
    print("  Threads: {")
    for name, stat in sorted(threads.items()):
        print(f"    {name}: {{ {inline_stat(stat)} }},")
    print("  }")
    print("}")


# =========================
# Main
# =========================
def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <input.json> [--with-pid]")
        sys.exit(1)

    input_file = sys.argv[1]
    with_pid = "--with-pid" in sys.argv[2:]

    with open(input_file, "r", encoding="utf-8") as f:
        records = json.load(f)

    # PID level (optional)
    if with_pid:
        pid_all = aggregate_by_pid(records, SKIP_PIDS, SKIP_TIDS)
        for pid in sorted(pid_all.keys(), key=int):
            print_block(
                f"PID {pid}",
                pid_all[pid]["total"],
                pid_all[pid]["threads"]
            )

    # Global
    g_total, g_threads = aggregate_global(records, SKIP_PIDS, SKIP_TIDS)
    print_block("Global", g_total, g_threads)


if __name__ == "__main__":
    main()


"""
结果示例：

# 所有进程维度，都会单独统计
PID 17650:
{
  total: { sleep: 400.3s, sleep_occ: 843, runnable: 75.5ms, runnable_occ: 865, running: 34.8ms, running_occ: 867 },
  Threads: {
    aos_event: { sleep: 101.3s, sleep_occ: 171, runnable: 30.4ms, runnable_occ: 174, running: 6.7ms, running_occ: 174 },
    dds_discovery: { sleep: 97.4s, sleep_occ: 142, runnable: 24.2ms, runnable_occ: 147, running: 12.2ms, running_occ: 147 },
    dds_io: { sleep: 100.3s, sleep_occ: 428, runnable: 20.4ms, runnable_occ: 440, running: 14.8ms, running_occ: 442 },
    subscriber: { sleep: 101.3s, sleep_occ: 102, runnable: 0.6ms, runnable_occ: 104, running: 1.0ms, running_occ: 104 },
  }
}

# 全局会单独累加统计
Global:
{
  total: { sleep: 20041.0s, sleep_occ: 74157, runnable: 5.3s, runnable_occ: 74966, running: 1.9s, running_occ: 75015 },
  Threads: {
    aos_event: { sleep: 4039.2s, sleep_occ: 6823, runnable: 605.3ms, runnable_occ: 6937, running: 328.5ms, running_occ: 6944 },
    dds_discovery: { sleep: 3897.2s, sleep_occ: 5715, runnable: 976.9ms, runnable_occ: 5859, running: 505.8ms, running_occ: 5861 },
    dds_io: { sleep: 4012.5s, sleep_occ: 17024, runnable: 977.8ms, runnable_occ: 17424, running: 611.9ms, running_occ: 17464 },
    subscriber: { sleep: 4046.1s, sleep_occ: 4075, runnable: 149.5ms, runnable_occ: 4162, running: 55.6ms, running_occ: 4162 },
    unified_timer: { sleep: 4046.0s, sleep_occ: 40520, runnable: 2.6s, runnable_occ: 40584, running: 429.3ms, running_occ: 40584 },
  }
}
"""
