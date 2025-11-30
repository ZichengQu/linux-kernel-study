# Linux 调度器关键路径的 kprobe 钩子与参数示例

## 前置提要

- 对kprobe了解有限，仅通过常见用例总结归纳，可能存在错误理解
- 部分偏移量不对，需基于具体内核，自行修改

## kprobe 参数访问与结构体偏移获取方法

如果需要钩子函数里的参数，则：

- 第一个参数：可能是 %x0，也可能是 $arg1，需要注意不同环境
- 第二个参数：可能是 %x1，也可能是 $arg2，需要注意不同环境
- 第三个参数：依次类推
- 偏移查询：如 struct rq 的 nr_running，可以通过

```sh
# 方法一：通过 pahole 获取
# pahole -C rq vmlinux | grep nr_running
	unsigned int               nr_running;           /*     4     4 */

# 方法二：通过 gdb 获取
# gdb vmlinux # 进入 gdb
GNU gdb (GDB) openEuler 14.1-11.oe2403
...
Reading symbols from vmlinux...
(gdb) ptype /o struct rq # 获取 rq 中相关属性的偏移量
/* offset      |    size */  type = struct rq {
/*      0      |       4 */    raw_spinlock_t lock;
/*      4      |       4 */    unsigned int nr_running;
```

## kprobe 调度常见钩子函数

```sh
# idle / nohz_full
echo 'p:enter_tick_nohz_idle_enter tick_nohz_idle_enter' >> /sys/kernel/debug/tracing/kprobe_events
echo 'p:enter_tick_nohz_idle_exit tick_nohz_idle_exit' >> /sys/kernel/debug/tracing/kprobe_events
echo 'p:enter_do_idle do_idle' >> /sys/kernel/debug/tracing/kprobe_events
echo 'r:exit_do_idle do_idle retval=$retval' >> /sys/kernel/debug/tracing/kprobe_events
echo 'p:enter_schedule_idle schedule_idle' >> /sys/kernel/debug/tracing/kprobe_events
echo 'r:exit_schedule_idle schedule_idle retval=$retval' >> /sys/kernel/debug/tracing/kprobe_events
```

```sh
# resched
echo 'p:enter_resched_curr resched_curr rq_addr=$arg1:x64 nr_running=+4($arg1):u32 cfsrq_nr_running=+16($arg1):u32' >> /sys/kernel/debug/tracing/kprobe_events
echo 'r:exit_resched_curr resched_curr' >> /sys/kernel/debug/tracing/kprobe_events
```

```sh
# 入队
echo 'p:enter_enqueue_task_fair enqueue_task_fair rq_addr=$arg1:x64 nr_running=+4($arg1):u32 cfsrq_nr_running=+144($arg1):u32 cfsrq_addr=+560($arg2):x64 p_se_addr=$arg2:x64' >> /sys/kernel/debug/tracing/kprobe_events
echo 'r:exit_enqueue_task_fair enqueue_task_fair retval=$retval' >> /sys/kernel/debug/tracing/kprobe_events
```

```sh
# 选任务 / 切换
echo 'p:enter_pick_next_task_fair pick_next_task_fair rq_addr=$arg1:x64 nr_running=+4($arg1):u32 cfsrq_nr_running=+144($arg1):u32' >> /sys/kernel/debug/tracing/kprobe_events
echo 'r:exit_pick_next_task_fair pick_next_task_fair retval=$retval' >> /sys/kernel/debug/tracing/kprobe_events
echo 'p:enter_set_next_task_fair set_next_task_fair p_se_addr=$arg2:x64' >> /sys/kernel/debug/tracing/kprobe_events
echo 'r:exit_set_next_task_fair set_next_task_fair' >> /sys/kernel/debug/tracing/kprobe_events
echo 'p:enter_put_prev_task_fair put_prev_task_fair p_se_addr=$arg2:x64' >> /sys/kernel/debug/tracing/kprobe_events
echo 'r:exit_put_prev_task_fair put_prev_task_fair' >> /sys/kernel/debug/tracing/kprobe_events
```

```sh
# cgroup 限流 / 解除限流
echo 'p:enter_throttle_cfs_rq throttle_cfs_rq cfsrq_addr=$arg1:x64 load_weight=+0($arg1):u64' >> /sys/kernel/debug/tracing/kprobe_events
echo 'r:exit_throttle_cfs_rq throttle_cfs_rq' >> /sys/kernel/debug/tracing/kprobe_events
echo 'p:enter_unthrottle_cfs_rq unthrottle_cfs_rq cfsrq_addr=$arg1:x64 load_weight=+0($arg1):u64' >> /sys/kernel/debug/tracing/kprobe_events
echo 'r:exit_unthrottle_cfs_rq unthrottle_cfs_rq' >> /sys/kernel/debug/tracing/kprobe_events
```

```sh
# cgroup迁移
echo 'p:enter_cpu_cgroup_can_attach cpu_cgroup_can_attach' >> /sys/kernel/debug/tracing/kprobe_events
echo 'r:exit_cpu_cgroup_can_attach cpu_cgroup_can_attach' >> /sys/kernel/debug/tracing/kprobe_events
echo 'p:enter_cpu_cgroup_attach cpu_cgroup_attach' >> /sys/kernel/debug/tracing/kprobe_events
echo 'r:exit_cpu_cgroup_attach cpu_cgroup_attach' >> /sys/kernel/debug/tracing/kprobe_events
echo 'p:enter_sched_move_task sched_move_task tsk_se_addr=$arg1:x64' >> /sys/kernel/debug/tracing/kprobe_events
echo 'r:exit_sched_move_task sched_move_task' >> /sys/kernel/debug/tracing/kprobe_events
```

## kprobe 激活钩子

```sh
# enable all
for e in \
enter_tick_nohz_idle_enter enter_tick_nohz_idle_exit \
enter_do_idle exit_do_idle \
enter_schedule_idle exit_schedule_idle \
enter_resched_curr exit_resched_curr \
enter_enqueue_task_fair exit_enqueue_task_fair \
enter_pick_next_task_fair exit_pick_next_task_fair \
enter_set_next_task_fair exit_set_next_task_fair \
enter_put_prev_task_fair exit_put_prev_task_fair \
enter_throttle_cfs_rq exit_throttle_cfs_rq \
enter_unthrottle_cfs_rq exit_unthrottle_cfs_rq \
enter_cpu_cgroup_can_attach exit_cpu_cgroup_can_attach \
enter_cpu_cgroup_attach exit_cpu_cgroup_attach \
enter_sched_move_task exit_sched_move_task
do
    echo 1 > /sys/kernel/debug/tracing/events/kprobes/$e/enable
done

# 等价于下面的命令，但下面的命令会开启所有的kprobe钩子，上面的只是开启特定的钩子，如果之前插入过某些钩子，下面的命令也会同步开启
echo 1 > /sys/kernel/debug/tracing/events/kprobes/enable
```

## kprobe 禁用钩子

```sh
# disable all
echo 0 > /sys/kernel/debug/tracing/events/kprobes/enable
```

## kprobe 清除钩子

```sh
# clear all
echo > /sys/kernel/debug/tracing/kprobe_events
```

## kprobe trace 查看

```sh
# 调度常用设置和固定 tracepoint 与 该 kprobe wiki 不相关，但常用，因此一起在这里列出
echo nop > /sys/kernel/tracing/current_tracer
echo 140800 > /sys/kernel/debug/tracing/buffer_size_kb # 设置缓冲区大小，否则容易溢出

echo 1 > /sys/kernel/debug/tracing/events/sched/sched_wakeup/enable
echo 1 > /sys/kernel/debug/tracing/events/sched/sched_wakeup_new/enable
echo 1 > /sys/kernel/debug/tracing/events/sched/sched_waking/enable
echo 1 > /sys/kernel/debug/tracing/events/sched/sched_switch/enable
echo 1 > /sys/kernel/debug/tracing/events/sched/sched_migrate_task/enable

# echo stacktrace > /sys/kernel/debug/tracing/events/sched/xxx/trigger

# 记录 kprobe 相关 trace
echo > /sys/kernel/debug/tracing/trace 			# 清空缓冲区
echo 1 > /sys/kernel/debug/tracing/tracing_on 	# 开始跟踪
echo 0 > /sys/kernel/debug/tracing/tracing_on	# 停止跟踪
cat /sys/kernel/debug/tracing/trace				# 查看 trace 记录（会包含 kprobe 相关内容）
cat /sys/kernel/debug/tracing/trace_pipe		# 流式输出：查看 trace 记录（会包含 kprobe 相关内容）
```

kprobe trace 实际使用例子

```sh
# 实际示例结果

# 设置 kprobe 钩子
[root@localhost hulk-5.10]# echo 'p:enter_resched_curr resched_curr rq_addr=$arg1:x64 nr_running=+4($arg1):u32 cfsrq_nr_running=+16($arg1):u32' >> /sys/kernel/debug/tracing/kprobe_events
# 激活 kprobe 钩子
[root@localhost hulk-5.10]# echo 1 > /sys/kernel/debug/tracing/events/kprobes/enable

# trace 常见配置
[root@localhost hulk-5.10]# echo nop > /sys/kernel/tracing/current_tracer
[root@localhost hulk-5.10]# echo 140800 > /sys/kernel/debug/tracing/buffer_size_kb
[root@localhost hulk-5.10]# echo > /sys/kernel/debug/tracing/trace
[root@localhost hulk-5.10]# echo 1 > /sys/kernel/debug/tracing/tracing_on && sleep 1 && echo 0 > /sys/kernel/debug/tracing/tracing_on

# 查看 kprobe trace 记录
[root@localhost hulk-5.10]# cat /sys/kernel/debug/tracing/trace
# tracer: nop
#
# entries-in-buffer/entries-written: 13/13   #P:160
#
#                                _-----=> irqs-off/BH-disabled
#                               / _----=> need-resched
#                              | / _---=> hardirq/softirq
#                              || / _--=> preempt-depth
#                              ||| / _-=> migrate-disable
#                              |||| /     delay
#           TASK-PID     CPU#  |||||  TIMESTAMP  FUNCTION
#              | |         |   |||||     |         |
            bash-297455  [143] d.... 65722.950986: enter_resched_curr: (resched_curr+0x0/0x10) rq_addr=0xff3e0019ffa31880 nr_running=18 cfsrq_nr_running=0
          <idle>-0       [141] dN... 65723.174628: enter_resched_curr: (resched_curr+0x0/0x10) rq_addr=0xff3e0019ff971880 nr_running=18 cfsrq_nr_running=0
          <idle>-0       [102] d.s.. 65723.227786: enter_resched_curr: (resched_curr+0x0/0x10) rq_addr=0xff3dffd9ffdb1880 nr_running=2 cfsrq_nr_running=0
          <idle>-0       [041] dN... 65723.355865: enter_resched_curr: (resched_curr+0x0/0x10) rq_addr=0xff3e0019fea71880 nr_running=2 cfsrq_nr_running=0
          <idle>-0       [092] dN... 65723.355895: enter_resched_curr: (resched_curr+0x0/0x10) rq_addr=0xff3dffd9ffb31880 nr_running=2 cfsrq_nr_running=0
          <idle>-0       [006] dN... 65723.355961: enter_resched_curr: (resched_curr+0x0/0x10) rq_addr=0xff3dffd9fefb1880 nr_running=2 cfsrq_nr_running=0
          <idle>-0       [090] dN... 65723.355996: enter_resched_curr: (resched_curr+0x0/0x10) rq_addr=0xff3dffd9ffab1880 nr_running=2 cfsrq_nr_running=0
         rt_test-295257  [026] d.s.. 65723.420778: enter_resched_curr: (resched_curr+0x0/0x10) rq_addr=0xff3dffd9ff4b1880 nr_running=2 cfsrq_nr_running=0
          <idle>-0       [094] d.s.. 65723.611785: enter_resched_curr: (resched_curr+0x0/0x10) rq_addr=0xff3dffd9ffbb1880 nr_running=2 cfsrq_nr_running=0
          <idle>-0       [025] d.s.. 65723.675784: enter_resched_curr: (resched_curr+0x0/0x10) rq_addr=0xff3dffd9ff471880 nr_running=2 cfsrq_nr_running=0
         rt_test-295257  [026] d.h.. 65723.712774: enter_resched_curr: (resched_curr+0x0/0x10) rq_addr=0xff3dffd9ff4b1880 nr_running=2 cfsrq_nr_running=0
          <idle>-0       [026] d.h.. 65723.761875: enter_resched_curr: (resched_curr+0x0/0x10) rq_addr=0xff3dffd9ff4b1880 nr_running=2 cfsrq_nr_running=0
          <idle>-0       [045] d.h.. 65723.851523: enter_resched_curr: (resched_curr+0x0/0x10) rq_addr=0xff3e0019feb71880 nr_running=2 cfsrq_nr_running=1

# 关闭 kprobe (需要先将 enable 开关关闭，然后再清除，否则会报错 busy 无法清除)
[root@localhost hulk-5.10]# echo 0 > /sys/kernel/debug/tracing/events/kprobes/enable
[root@localhost hulk-5.10]# echo > /sys/kernel/debug/tracing/kprobe_events
```

