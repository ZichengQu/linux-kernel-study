基于版本：

  commit: 6fc5139b143bebaaad870ad98c24a75f0e7f6de1
  release: 6.6.0-6fc5139b143b
  arch: aarch64
  panic: Kernel panic - not syncing: hung_task: blocked tasks

  下面按“怎么一步步定位”的顺序整理。最后给完整故障模型路径树。

  ## 一、定位推导过程

  ### 1. 先确认 panic 类型

  命令：

  sys
  bt

  关键输出：

  PANIC: "Kernel panic - not syncing: hung_task: blocked tasks"
  COMMAND: "khungtaskd"

  bt:
    panic
    check_hung_uninterruptible_tasks
    watchdog

  推导：

  这不是 oops、空指针、BUG_ON，也不是直接的 softlockup/hardlockup；这是 khungtaskd 检测到长期 D 状态任务后，因为 hung_task_call_panic 打开而主动 panic。

  所以后续重点不是看 panic CPU 在做什么，而是找“哪些任务长期 D 状态、它们分别等什么”。

  ———

  ### 2. 从 hung task 日志里找第一个明显的锁等待者：systemd

  日志里有：

  task:systemd state:D pid:1

  Call trace:
    mutex_lock
    cgroup_kn_lock_live
    cgroup_mkdir

  对应源码：

  kernel/cgroup/cgroup.c:cgroup_mkdir:cgroup_kn_lock_live:5922
  kernel/cgroup/cgroup.c:cgroup_kn_lock_live:cgroup_lock:1689

  推导：

  systemd 创建 cgroup 目录时进入：

  cgroup_mkdir()
    cgroup_kn_lock_live()
      cgroup_lock()
        mutex_lock(&cgroup_mutex)

  所以第一步怀疑：cgroup_mutex 被某个任务长期持有。

  ———

  ### 3. 查 cgroup_mutex owner，定位持锁者 cgexec

  命令：

  p cgroup_mutex -x

  关键输出：

  owner.counter = 0xffff202809d09501

  这里要注意：Linux mutex owner 的低位可能编码 flag，不是直接 task 指针。真实 task 地址需要低位清零：

  0xffff202809d09501 & ~0x7 = 0xffff202809d09500

  命令：

  bt 0xffff202809d09500

  关键输出：

  PID: 462769 COMMAND: "cgexec"

  wait_for_completion
  affine_move_task
  __set_cpus_allowed_ptr_locked
  __set_cpus_allowed_ptr
  set_cpus_allowed_ptr
  cpuset_attach_task
  cpuset_attach
  cgroup_migrate_execute
  cgroup_migrate
  cgroup_attach_task
  __cgroup1_procs_write
  cgroup1_tasks_write

  推导：

  cgroup_mutex 的 owner 是 cgexec。它正在写 cgroup v1 tasks 文件，把某个任务迁移到目标 cgroup。路径是：

  cgroup1_tasks_write()
    __cgroup1_procs_write()
      cgroup_kn_lock_live()      # 获取 cgroup_mutex
      cgroup_procs_write_start()
      cgroup_attach_task()
        cgroup_migrate()
          cgroup_migrate_execute()
            cpuset_attach()
              cpuset_attach_task()
                set_cpus_allowed_ptr()
                  affine_move_task()
                    wait_for_completion()

  所以 systemd 只是受害者：它等 cgroup_mutex，而锁被 cgexec 持有。

  ———

  ### 4. 明确 cgexec 为什么会持有 cgroup_threadgroup_rwsem 写侧

  相关源码条件：

  kernel/cgroup/cgroup-v1.c:cgroup1_tasks_write:__cgroup1_procs_write:541
  kernel/cgroup/cgroup-v1.c:__cgroup1_procs_write:cgroup_kn_lock_live:498
  kernel/cgroup/cgroup-v1.c:__cgroup1_procs_write:cgroup_procs_write_start:502
  kernel/cgroup/cgroup.c:cgroup_procs_write_start:threadgroup_locked = pid || threadgroup:2994
  kernel/cgroup/cgroup.c:cgroup_procs_write_start:cgroup_attach_lock:2995
  kernel/cgroup/cgroup.c:cgroup_attach_lock:percpu_down_write(cgroup_threadgroup_rwsem):2489

  解释：

  cgroup1_tasks_write() 传入的是 threadgroup=false，但 cgroup_procs_write_start() 会解析用户写入的 pid：

  *threadgroup_locked = pid || threadgroup;
  cgroup_attach_lock(*threadgroup_locked);

  因此，只要写入的 pid 非 0，就会：

  cgroup_attach_lock(true)
    cpus_read_lock()
    percpu_down_write(&cgroup_threadgroup_rwsem)

  vmcore 中也支持这一点：

  p cgroup_threadgroup_rwsem
    block.counter = 1
    waiters non-empty

  推导：

  cgexec 不只是持有 cgroup_mutex，还让 cgroup_threadgroup_rwsem 进入写侧阻塞状态，后续 fork/exit 的 threadgroup read 侧会被挡住。

  ———

  ### 5. 查 sched_ext 状态，确认处于 enable 临界区

  命令：

  p scx_ops_enable_state_var
  p scx_ops_enable_state_str
  p scx_ops_bypassed_for_enable
  p scx_ops_bypass_depth

  关键输出：

  scx_ops_enable_state_var.counter = 0
  scx_ops_enable_state_str[0] = "enabling"
  scx_ops_bypassed_for_enable = true
  scx_ops_bypass_depth = 1

  推导：

  sched_ext 仍在 SCX_OPS_ENABLING，bypass 仍然打开。
  所以这个 vmcore 不能直接归因于 err_disable_unlock_all 后提前 scx_ops_bypass(false) 那类问题。

  ———

  ### 6. 查 scx_fork_rwsem，定位 sched_ext_enabl 卡点

  命令：

  p scx_fork_rwsem

  关键输出：

  writer.task = 0xffff202005b30000
  block.counter = 1
  waiters non-empty

  命令：

  bt 0xffff202005b30000
  bt -l 6993

  关键输出：

  PID: 6993 COMMAND: "sched_ext_enabl"

  percpu_down_write
  scx_ops_enable_workfn  kernel/sched/ext.c:5381

  源码：

  kernel/sched/ext.c:scx_ops_enable_workfn:percpu_down_write(scx_fork_rwsem):5381
  kernel/locking/percpu-rwsem.c:percpu_down_write:rcu_sync_enter:231
  kernel/locking/percpu-rwsem.c:percpu_down_write:readers_active_check:249

  推导：

  sched_ext_enabl 并不是已经完整拿到写锁后不释放。更准确地说：

  percpu_down_write(&scx_fork_rwsem)
    rcu_sync_enter()       # 关闭 reader fast path
    block = 1              # 新 reader 进入慢路径等待
    wait old readers drain # 等旧 reader 计数清零

  所以要继续找：谁是旧 reader，为什么不退出 scx_fork_rwsem 读侧？

  ———

  ### 7. 找 scx_fork_rwsem 的旧 reader：stress-ng

  命令：

  foreach bt | grep -A35 -B8 "cgroup_css_set_fork"

  关键输出：

  PID: 462757 COMMAND: "stress-ng"

  percpu_rwsem_wait
  __percpu_down_read
  cgroup_css_set_fork
  cgroup_can_fork
  copy_process
  kernel_clone

  为什么它是 scx_fork_rwsem 旧 reader？看源码顺序：

  kernel/fork.c:copy_process:sched_fork:2618
  kernel/sched/core.c:sched_fork:scx_pre_fork:4697
  kernel/sched/ext.c:scx_pre_fork:percpu_down_read(scx_fork_rwsem):3725

  之后才到：

  kernel/fork.c:copy_process:cgroup_can_fork:2743
  kernel/cgroup/cgroup.c:cgroup_can_fork:cgroup_css_set_fork:6756
  kernel/cgroup/cgroup.c:cgroup_css_set_fork:cgroup_threadgroup_change_begin:6627

  释放 scx_fork_rwsem 读锁的位置更靠后：

  kernel/fork.c:copy_process:sched_post_fork:2874
  kernel/sched/ext.c:scx_post_fork:percpu_up_read(scx_fork_rwsem):3762

  错误路径释放位置：

  kernel/fork.c:copy_process:sched_cancel_fork:2930
  kernel/sched/ext.c:scx_cancel_fork:percpu_up_read(scx_fork_rwsem):3777

  推导：

  stress-ng 已经执行过：

  sched_fork()
    scx_pre_fork()
      percpu_down_read(&scx_fork_rwsem)

  所以它持有 scx_fork_rwsem 旧读侧。

  但它卡在：

  cgroup_css_set_fork()
    cgroup_threadgroup_change_begin()
      percpu_down_read(&cgroup_threadgroup_rwsem)

  还没有走到 sched_post_fork() 或 sched_cancel_fork()，所以无法释放 scx_fork_rwsem 读侧。

  这解释了：

  sched_ext_enabl 为什么一直卡在 scx_fork_rwsem 写侧：
  它在等 stress-ng 这种旧 reader 退出，但旧 reader 卡在 cgroup_threadgroup_rwsem。

  ———

  ### 8. 新 fork/kthreadd 不是根因，是扩散结果

  日志和 foreach bt 里有：

  kthreadd
    scx_pre_fork
    __percpu_down_read(&scx_fork_rwsem)

  推导：

  这些不是旧 reader。它们是在 scx_fork_rwsem.block=1 之后来的新 reader，被 enable 写侧挡住。

  所以它们解释“系统为什么无法再 fork/kthread”，但不是让 sched_ext_enabl 无法前进的直接原因。

  直接原因仍然是旧 reader stress-ng 卡住未释放。

  ———

  ### 9. 原先怀疑 cgexec 卡在 migration completion，但后续证据修正了这个判断

  cgexec 栈停在：

  wait_for_completion
  affine_move_task

  一开始自然会怀疑：migration completion 没完成。

  但进一步命令：

  task -R pid,comm,cpu,__state,on_cpu,on_rq,migration_pending,migration_flags 0xffff202809d09500

  关键输出：

  pid = 462769
  comm = "cgexec"
  cpu = 0
  __state = 0
  on_cpu = 0
  on_rq = 1
  migration_pending = 0x0
  migration_flags = 0

  推导：

  __state=0 是 TASK_RUNNING，on_rq=1 表示已经在 runqueue 上。
  migration_pending=0x0 表示目标 task 上没有仍挂着的 pending affinity migration。

  所以更准确的结论是：

  cgexec 不是仍然不可唤醒地等 completion。
  它大概率已经被 completion 唤醒，但还没被调度运行回去。

  这一步把问题从“migration completion 没完成”修正为“cgexec runnable 但饥饿”。

  ———

  ### 10. 查 CPU0 runqueue，确认 cgexec 被 RT stress-ng 饿死

  命令：

  runq -c 0 -g

  关键输出：

  CPU 0
    CURRENT: PID: 462764 COMMAND: "stress-ng"

    RT_RQ:
       [ 50] PID: 462764 COMMAND: "stress-ng"
       [ 50] PID: 462761 COMMAND: "stress-ng"

    CFS_RQ:
       ...
       [120] PID: 462769 COMMAND: "cgexec"

  命令：

  task -R pid,comm,cpu,__state,on_cpu,on_rq,prio,policy,sched_class 0xffff202809d09500
  p &ext_sched_class
  p &fair_sched_class
  p &rt_sched_class

  关键输出：

  cgexec:
    __state = 0
    on_rq = 1
    prio = 120
    policy = 0
    sched_class = 0xffff8000822e0338 <fair_sched_class>

  &fair_sched_class = 0xffff8000822e0338
  &rt_sched_class   = 0xffff8000822e0250
  &ext_sched_class  = 0xffff8000822e0420

  推导：

  cgexec 是 CFS 普通任务，已经 runnable，但 CPU0 上 RT_RQ 里有 prio 50 的 stress-ng。调度类优先级上 RT 高于 CFS，所以只要 RT 任务持续 runnable，CFS cgexec 就不会运行。

  ———

  ### 11. 查 RT throttling 参数，确认 CFS 没有预留 CPU

  命令：

  p sysctl_sched_rt_runtime
  p sysctl_sched_rt_period

  关键输出：

  sysctl_sched_rt_runtime = 1000000
  sysctl_sched_rt_period  = 1000000

  源码：

  kernel/sched/sched.h:global_rt_runtime:2456
  kernel/sched/sched.h:global_rt_period:2448
  kernel/sched/rt.c:sched_rt_runtime_exceeded:1009

  关键逻辑：

  if (runtime >= sched_rt_period(rt_rq))
          return 0;

  推导：

  RT runtime 等于 RT period，表示 RT 任务每 1s 周期最多可以跑满 1s。
  这等价于不给 CFS 预留时间。

  因此 CPU0 上：

  RT stress-ng 可以持续压住 CFS cgexec
  cgexec 已经 runnable 但不能运行
  cgexec 不能释放 cgroup_mutex / cgroup_threadgroup_rwsem

  ———

  ### 12. 最终判断：不是传统锁闭环死锁，而是 RT 饥饿导致的锁传播型 hang

  严格说，不是这种传统死锁：

  A 持锁 X 等锁 Y
  B 持锁 Y 等锁 X

  更准确是：

  RT stress-ng 饿死 CFS cgexec
    -> cgexec 持有 cgroup_mutex / cgroup_threadgroup 写侧不能释放
    -> stress-ng fork 卡在 cgroup_threadgroup_rwsem read，同时持有 scx_fork_rwsem 旧读侧
    -> sched_ext_enabl 等 scx_fork_rwsem 旧 reader drain
    -> 新 fork/kthreadd 被 scx_fork_rwsem.block 挡住
    -> systemd 等 cgroup_mutex
    -> khungtaskd 触发 hung task panic

  sched_ext 是放大器：它在 enable 过程中用 scx_fork_rwsem 排除 fork，一个卡住的旧 fork reader 足以阻塞整个 enable。
  但让 cgexec 不释放 cgroup 锁的直接现场原因，是 CPU0 上 RT 任务跑满周期导致 CFS cgexec 饥饿。

  ———

  ## 二、故障模型路径树

  触发条件:
  kernel/sched/sched.h:global_rt_runtime:sysctl_sched_rt_runtime:2456 # vmcore 中 sysctl_sched_rt_runtime=1000000，RT runtime 被换算为 1s
        kernel/sched/sched.h:global_rt_period:sysctl_sched_rt_period:2448 # vmcore 中 sysctl_sched_rt_period=1000000，RT period 也是 1s
                [BUG-1] kernel/sched/rt.c:sched_rt_runtime_exceeded:runtime>=period:1009 # runtime 等于 period 时不触发 RT throttling，RT 任务可以跑满整个周期，不给 CFS 预留 CPU
                        kernel/sched/core.c:__schedule:switch_to:5326 # CPU0 runq 显示当前运行 RT stress-ng，CFS cgexec 虽然 runnable 但未被切上 CPU

  cgexec 持锁路径:
  kernel/cgroup/cgroup-v1.c:cgroup1_tasks_write:__cgroup1_procs_write:541 # cgexec 写 cgroup v1 tasks，进入任务迁移入口
        kernel/cgroup/cgroup-v1.c:__cgroup1_procs_write:cgroup_kn_lock_live:498 # 对目标 cgroup 建立 live 保护，并进入 cgroup 全局锁路径
                kernel/cgroup/cgroup.c:cgroup_kn_lock_live:cgroup_lock:1689 # 获取 cgroup_mutex；vmcore 中 cgroup_mutex owner 解码后是 cgexec task ffff202809d09500
                        kernel/cgroup/cgroup-v1.c:__cgroup1_procs_write:cgroup_procs_write_start:502 # 解析写入的 pid 并准备 cgroup attach 同步
                                kernel/cgroup/cgroup.c:cgroup_procs_write_start:threadgroup_locked:2994 # 对 cgroup v1 tasks 写入非零 pid 时 threadgroup_locked 为 true
                                        kernel/cgroup/cgroup.c:cgroup_procs_write_start:cgroup_attach_lock:2995 # 进入 attach 锁路径，开始稳定 threadgroup
                                                kernel/cgroup/cgroup.c:cgroup_attach_lock:cpus_read_lock:2487 # cgroup attach 先禁止 CPU hotplug，满足 cpuset attach 约束
                                                        kernel/cgroup/cgroup.c:cgroup_attach_lock:percpu_down_write(cgroup_threadgroup_rwsem):2489 # 获取 cgroup_threadgroup_rwsem 写侧，阻塞 fork/exit 的 threadgroup read 侧
                                                                kernel/cgroup/cgroup-v1.c:__cgroup1_procs_write:cgroup_attach_task:522 # 在持有 cgroup_mutex 和 cgroup_threadgroup 写侧期间执行任务迁移
                                                                        kernel/cgroup/cgroup.c:cgroup_attach_task:cgroup_migrate:2966 # 构造并执行 cgroup migration
                                                                                kernel/cgroup/cgroup.c:cgroup_migrate:cgroup_migrate_execute:2933 # 执行各 controller 的 attach 回调
                                                                                        kernel/cgroup/cgroup.c:cgroup_migrate_execute:ss->attach:2673 # 调用 cpuset controller 的 attach 回调
                                                                                                kernel/cgroup/cpuset.c:cpuset_attach:cpuset_attach_task:3553 # cpuset 对迁移任务更新 CPU/mem 约束
                                                                                                        kernel/cgroup/cpuset.c:cpuset_attach_task:set_cpus_allowed_ptr:3509 # 修改目标任务 cpumask，可能触发 affinity migration
                                                                                                                kernel/sched/core.c:affine_move_task:wait_for_completion:2957 # cgexec 栈停在 affinity migration completion 等待点
                                                                                                                        [WINDOW] kernel/sched/core.c:affine_move_task:TASK_RUNNING/on_rq:2957 # vmcore 显示 cgexec __state=0、on_rq=1、migration_pending=0，说明已可运行但还未返回释放 cgroup 锁
                                                                                                                                [BUG-2] kernel/sched/core.c:__schedule:switch_to:5326 # CPU0 RT_RQ 有 prio 50 stress-ng，cgexec 在 CFS_RQ 中 runnable；RT 不限流导致 cgroup 锁持有者饥饿

  旧 fork reader 阻塞路径:
  kernel/fork.c:copy_process:sched_fork:2618 # stress-ng fork 时先进入 scheduler fork 初始化
        kernel/sched/core.c:sched_fork:scx_pre_fork:4697 # sched_fork 早期调用 sched_ext fork 前置钩子
                kernel/sched/ext.c:scx_pre_fork:percpu_down_read(scx_fork_rwsem):3725 # stress-ng 已拿到 scx_fork_rwsem 读侧，成为 sched_ext enable 等待的旧 reader
                        kernel/fork.c:copy_process:cgroup_can_fork:2743 # fork 后续进入 cgroup fork 准入检查
                                kernel/cgroup/cgroup.c:cgroup_can_fork:cgroup_css_set_fork:6756 # 为 child 准备 css_set，并需要 cgroup threadgroup 同步
                                        kernel/cgroup/cgroup.c:cgroup_css_set_fork:cgroup_threadgroup_change_begin:6627 # vmcore 中 PID 462757 stress-ng 卡在这里
                                                include/linux/cgroup-defs.h:cgroup_threadgroup_change_begin:percpu_down_read(cgroup_threadgroup_rwsem):825 # 被 cgexec 持有的 cgroup_threadgroup_rwsem 写侧阻塞
                                                        [WINDOW] kernel/fork.c:copy_process:sched_post_fork:2874 # 只有 fork 继续推进到 sched_post_fork 才能释放 scx_fork_rwsem 读侧；当前未到达
                                                                kernel/sched/ext.c:scx_post_fork:percpu_up_read(scx_fork_rwsem):3762 # 正常释放点未执行，所以 stress-ng 继续占着 scx_fork_rwsem 旧读侧
                                                        [WINDOW] kernel/fork.c:copy_process:sched_cancel_fork:2930 # 错误路径也要走 sched_cancel_fork 才能释放 scx_fork_rwsem 读侧；当前也未到达
                                                                kernel/sched/ext.c:scx_cancel_fork:percpu_up_read(scx_fork_rwsem):3777 # 取消 fork 的释放点未执行

  sched_ext enable 阻塞路径:
  kernel/sched/ext.c:scx_ops_enable_workfn:scx_ops_set_enable_state:5283 # vmcore 中 scx_ops_enable_state_var=0，对应 SCX_OPS_ENABLING
        kernel/sched/ext.c:scx_ops_enable_workfn:scx_ops_bypass:5352 # enable 期间打开 bypass；vmcore 中 scx_ops_bypassed_for_enable=true、bypass_depth=1
                kernel/sched/ext.c:scx_ops_enable_workfn:percpu_down_write(scx_fork_rwsem):5381 # sched_ext_enabl 进入 scx_fork_rwsem 写侧，vmcore 中 writer.task=ffff202005b30000
                        kernel/locking/percpu-rwsem.c:percpu_down_write:rcu_sync_enter:231 # 写侧先关闭 reader fast path，让后续 reader 进入慢路径
                                kernel/locking/percpu-rwsem.c:percpu_down_write:__percpu_down_write_trylock/block:237 # vmcore 中 scx_fork_rwsem.block=1，说明新 fork reader 已被挡住
                                        kernel/locking/percpu-rwsem.c:percpu_down_write:readers_active_check:249 # 写侧等待旧 reader 计数归零；旧 reader 是卡在 cgroup_threadgroup_rwsem 的 stress-ng
                                                [WINDOW] kernel/sched/ext.c:scx_ops_enable_workfn:scx_cgroup_lock:5399 # enable 尚未推进到 cgroup 初始化和后续 unlock；故障停在 fork 排他阶段

  新 fork/kthreadd 扩散路径:
  kernel/fork.c:copy_process:sched_fork:2618 # kthreadd/clone 新 fork 请求进入 scheduler fork 初始化
        kernel/sched/core.c:sched_fork:scx_pre_fork:4697 # 新 fork 也必须进入 sched_ext pre_fork
                kernel/sched/ext.c:scx_pre_fork:percpu_down_read(scx_fork_rwsem):3725 # 因 scx_fork_rwsem.block=1，新 reader 不能再进入
                        kernel/locking/percpu-rwsem.c:__percpu_down_read:percpu_rwsem_wait:177 # vmcore 中 kthreadd 和多个 clone 卡在 __percpu_down_read/percpu_rwsem_wait
                                kernel/locking/percpu-rwsem.c:percpu_rwsem_wait:schedule:162 # 新 fork 进入 TASK_UNINTERRUPTIBLE，扩大 hung task 面

  systemd cgroup 扩散路径:
  kernel/cgroup/cgroup.c:cgroup_mkdir:cgroup_kn_lock_live:5922 # systemd 创建 cgroup 目录，需要进入 cgroup live lock
        kernel/cgroup/cgroup.c:cgroup_kn_lock_live:cgroup_lock:1689 # cgroup_lock 需要 cgroup_mutex；该锁被 cgexec 持有
                [WARN] kernel/cgroup/cgroup.c:cgroup_mkdir:mutex_lock(cgroup_mutex):5922 # vmcore 中 systemd 卡在 cgroup_mkdir->cgroup_kn_lock_live->mutex_lock，成为 hung task 报告对象

  终端症状:
  kernel/hung_task.c:check_hung_uninterruptible_tasks:check_hung_task:213 # khungtaskd 扫描 TASK_UNINTERRUPTIBLE，发现 systemd/kthreadd/stress-ng 等长期 D 状态
        [PANIC] kernel/hung_task.c:check_hung_uninterruptible_tasks:panic:226 # hung_task_call_panic 打开后触发 panic("hung_task: blocked tasks")

  最终归纳：

  这不是传统锁闭环死锁，而是 RT 饥饿触发的锁传播型系统 hang。

  直接条件：
    sysctl_sched_rt_runtime == sysctl_sched_rt_period == 1000000
    CPU0 上 RT stress-ng 可长期压住 CFS cgexec

  关键传播：
    cgexec 已 runnable 但不能运行
    -> cgroup_mutex / cgroup_threadgroup_rwsem 写侧不释放
    -> stress-ng fork 卡在 cgroup_threadgroup_rwsem read，且持有 scx_fork_rwsem 旧 read
    -> sched_ext_enabl 等 scx_fork_rwsem 旧 reader drain
    -> 新 fork/kthreadd 被挡住
    -> systemd 等 cgroup_mutex
    -> hung_task panic

  3a5edcb8683f / 4a1d9d73aabc 不是这个 vmcore 的直接命中点；现场仍在 SCX_OPS_ENABLING，且 bypass 仍打开。