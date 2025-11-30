#!/bin/bash

# 抓取调度轨迹 trace 的脚本

# ===== 配置变量 =====
DEBUG=1  																		# 1=显示调试信息, 0=静默运行

TRACE_BUFFER_SIZE=140800 # 704000
TRACE_EXEC_CMD="/home/qzc/code/OLK-6.6/tools/sched_ext/build/bin/scx_flatcg" 	# 抓trace期间要执行的完整命令

TRACE_OUTPUT_PATH="/tmp/qzc/trace" 												# trace保存到的绝对路径
TRACE_OUTPUT_FILE_NAME="qzc_sched_ext_trace" 									# trace文件名称

# 生成带时间戳的输出文件
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TRACE_OUTPUT_FILE="${TRACE_OUTPUT_PATH}/${TRACE_OUTPUT_FILE_NAME}_${TIMESTAMP}"

debug_echo() {
    if [[ "$DEBUG" -eq 1 ]]; then
        echo "[DEBUG] $*"
    fi
}

# 在trace_reset()中暂未使用
trace_reset_sched() {
	echo 0 > /sys/kernel/debug/tracing/events/sched/sched_wakeup/enable
    echo 0 > /sys/kernel/debug/tracing/events/sched/sched_wakeup_new/enable
    echo 0 > /sys/kernel/debug/tracing/events/sched/sched_waking/enable
    echo 0 > /sys/kernel/debug/tracing/events/sched/sched_switch/enable
    echo 0 > /sys/kernel/debug/tracing/events/sched/sched_migrate_task/enable
}

# 在trace_reset()中暂未使用
trace_reset_irq() {
	echo 0 > /sys/kernel/debug/tracing/events/irq/softirq_raise/enable
	echo 0 > /sys/kernel/debug/tracing/events/irq/softirq_entry/enable
    echo 0 > /sys/kernel/debug/tracing/events/irq/softirq_exit/enable
    echo 0 > /sys/kernel/debug/tracing/events/irq/irq_handler_entry/enable
    echo 0 > /sys/kernel/debug/tracing/events/irq/irq_handler_exit/enable

	# 取消捕获堆栈 stacktrace
	echo '!stacktrace' > /sys/kernel/debug/tracing/events/irq/softirq_entry/trigger
	echo '!stacktrace' > /sys/kernel/debug/tracing/events/irq/softirq_exit/trigger
	echo '!stacktrace' > /sys/kernel/debug/tracing/events/irq/irq_handler_entry/trigger
	echo '!stacktrace' > /sys/kernel/debug/tracing/events/irq/irq_handler_exit/trigger
}

# 在trace_reset()中暂未使用
trace_reset_ipi() {
	echo 0 > /sys/kernel/debug/tracing/events/ipi/ipi_entry/enable
    echo 0 > /sys/kernel/debug/tracing/events/ipi/ipi_exit/enable
}

# 暂未启用，如果没有mount，则需要启用
pre_mount() {
	mount -t debugfs nodev /sys/kernel/debug/
}

trace_reset() {
    debug_echo "重置 tracing 配置"

    echo 0 > /sys/kernel/debug/tracing/tracing_on 	# 停止跟踪
    echo > /sys/kernel/debug/tracing/trace 			# 清空缓冲区
    echo nop > /sys/kernel/tracing/current_tracer 	# 重置为默认tracer

	# 清空函数过滤器
	echo > /sys/kernel/debug/tracing/set_ftrace_filter
	echo > /sys/kernel/debug/tracing/set_graph_function

	# 禁用所有事件跟踪
	echo 0 > /sys/kernel/debug/tracing/events/enable
	echo 0 > /sys/kernel/debug/tracing/options/record-tgid

	# 禁用所有 stacktrace
	for trigger in /sys/kernel/debug/tracing/events/*/*/trigger; do echo '!stacktrace' > "$trigger" 2>/dev/null; done

	echo 0 > /sys/kernel/debug/tracing/options/stacktrace
	
	# trace_reset_sched
	# trace_reset_irq
	# trace_reset_ipi

	# 如果需要，还可以清空 kprobe 和 uprobe 事件
	#echo > kprobe_events
	#echo > uprobe_events
}

trace_set_cache() {
    debug_echo "设置 buffer 大小为 ${TRACE_BUFFER_SIZE} KB"
    echo "$TRACE_BUFFER_SIZE" > /sys/kernel/debug/tracing/buffer_size_kb
}

trace_set_configs() {
    debug_echo "开启调度相关 trace 事件"
	# cat /sys/kernel/tracing/available_tracers 										# 查看可用的跟踪器
    echo nop > /sys/kernel/tracing/current_tracer

	# echo schedule > /sys/kernel/debug/tracing/set_ftrace_filter 						# set_ftrace_filter + function 跟踪器
	# echo select_task_rq_fair > /sys/kernel/debug/tracing/set_graph_function 			# set_graph_function + function_graph 跟踪器

	echo 1 > /sys/kernel/debug/tracing/options/record-tgid								# 记录主进程
	echo 1 > /sys/kernel/debug/tracing/events/sched/sched_stat_runtime/enable			# 记录进程的 vruntime

	# ls /sys/kernel/tracing/events/sched/ # 查看某个子系统下的事件，例如调度事件
	echo 1 > /sys/kernel/debug/tracing/events/sched/sched_waking/enable 				# trace_sched_waking(): try_to_wake_up() 函数的最初阶段。任务尝试被唤醒的最开始阶段，状态还未改变。
    echo 1 > /sys/kernel/debug/tracing/events/sched/sched_wakeup/enable 				# trace_sched_wakeup():try_to_wake_up() 函数的末尾阶段。任务成功从阻塞状态转换到 runnable，放入 runqueue。
    echo 1 > /sys/kernel/debug/tracing/events/sched/sched_wakeup_new/enable 			# trace_sched_wakeup_new(): 在新任务第一次 runnable 时，专门用于新创建任务（fork/clone 后第一次 runnable），不会在普通唤醒中触发。
    echo 1 > /sys/kernel/debug/tracing/events/sched/sched_switch/enable 				# trace_sched_switch(): __schedule() 或者 schedule() 的上下文里，CPU 上的上下文切换完成，旧任务换下，新任务运行。runnable的时间段统计是 trace_sched_switch() - trace_sched_wakeup() 或 trace_sched_wakeup_new()
    echo 1 > /sys/kernel/debug/tracing/events/sched/sched_migrate_task/enable			# trace_sched_migrate_task(): set_task_cpu() 函数中。在任务从一个 CPU 的 runqueue 移动到另一个 CPU 的 runqueue 时触发
	# echo stacktrace > /sys/kernel/debug/tracing/events/sched/xxx/trigger 				# 捕获堆栈，xxx可以是sched_wakeup...sched_migrate_task等
	# echo 1 > /sys/kernel/debug/tracing/options/stacktrace								# 所有堆栈

	# 硬中断
	# echo 1 > /sys/kernel/debug/tracing/events/irq/irq_handler_entry/enable 			# 硬中断开始执行。
    # echo 1 > /sys/kernel/debug/tracing/events/irq/irq_handler_exit/enable				# 硬中断处理完成。
	# echo stacktrace > /sys/kernel/debug/tracing/events/irq/irq_handler_entry/trigger 	# 捕获堆栈
	# echo stacktrace > /sys/kernel/debug/tracing/events/irq/irq_handler_exit/trigger

	# 软中断
	# echo 1 > /sys/kernel/debug/tracing/events/irq/softirq_raise/enable 				# 软中断被置位。当某个软中断被标记为“待执行”时触发，也就是调用 raise_softirq() 或 __raise_softirq_irqoff() 时触发。
	# echo 1 > /sys/kernel/debug/tracing/events/irq/softirq_entry/enable 				# 软中断开始执行。CPU 开始执行某个 softirq handler 时触发，实际执行在 do_softirq() 内部，当 softirq 被调度运行。
    # echo 1 > /sys/kernel/debug/tracing/events/irq/softirq_exit/enable 				# 软中断处理完成。CPU 执行完 softirq handler 后触发，也在 do_softirq() 内部，softirq 执行结束时调用。
	# echo stacktrace > /sys/kernel/debug/tracing/events/irq/softirq_entry/trigger 		# 捕获堆栈
	# echo stacktrace > /sys/kernel/debug/tracing/events/irq/softirq_exit/trigger

	# 过滤 cpu 核
	# echo ffffffff,ffffffff,ffffffff,ffffffff,ffffffff > /sys/kernel/debug/tracing/tracing_cpumask
}

trace_start() {
    debug_echo "开始 tracing"
    echo > /sys/kernel/debug/tracing/trace 			# 清空缓冲区
    echo 1 > /sys/kernel/debug/tracing/tracing_on 	# 开始跟踪
}

trace_exec() {
    debug_echo "执行命令: $TRACE_EXEC_CMD"
    $TRACE_EXEC_CMD
}

trace_info_collect() {
    debug_echo "停止 tracing 并保存到 ${TRACE_OUTPUT_FILE}"
    echo 0 > /sys/kernel/debug/tracing/tracing_on 				# 停止跟踪
    mkdir -p ${TRACE_OUTPUT_PATH}
	cat /sys/kernel/debug/tracing/trace > "$TRACE_OUTPUT_FILE"
}

main() {
    # pre_mount
	trace_reset
    trace_set_cache
    trace_set_configs
    trace_start
    trace_exec
    trace_info_collect
	trace_reset
    debug_echo "trace 采集完成: $TRACE_OUTPUT_FILE"
	debug_echo "trace可视化地址（非华为内部）：https://perfetto.dev && https://ui.perfetto.dev/"
	debug_echo "trace可视化地址（华为内部）：https://devecotesting.rnd.huawei.com/smartperf && http://10.113.189.214:10000/#!/viewer && http://perfetto.harmonyos.rnd.huawei.com"
}

main
