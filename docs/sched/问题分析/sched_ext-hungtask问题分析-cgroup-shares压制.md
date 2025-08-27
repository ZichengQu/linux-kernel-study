基于版本：

  commit: 6fc5139b143bebaaad870ad98c24a75f0e7f6de1

  结论摘要

  本次 hung task 不是传统 ABBA 死锁。当前证据指向一种非闭环等待和全局放大模型：

  /usr/lib/ld-linux-aarch64.so.1 对应的 address_space->i_mmap_rwsem 上有大量 writer waiter。队首 waiter 是 PID 20597 cpu_sim，状态为 TASK_RUNNING/on_rq=1/on_cpu=0，被限制在 CPU123 的低权重 cgroup
  child_low 中；同 CPU 上高权重 cgroup child_high 正在运行 PID 16509。PID 12725 / 14283 两个 bash fork 任务已经持有 scx_fork_rwsem read，并在 dup_mmap()->i_mmap_lock_write() 等同一把 i_mmap_rwsem，因
  此无法走到 scx_post_fork() 释放 read。与此同时 PID 8309 sched_ext_enabl 正在 percpu_down_write(&scx_fork_rwsem) 等旧 reader drain，且 block=1 已阻断新 fork reader，最终扩散为大量 fork/clone D 状态并
  触发 hung task panic。

  关键 Crash 证据与推导

  1. sched_ext 当前处于 enable 阶段，写侧等待 scx_fork_rwsem

  crash> p scx_ops_enable_state_var
  scx_ops_enable_state_var = {
    counter = 0
  }

  crash> p scx_ops_bypassed_for_enable
  scx_ops_bypassed_for_enable = true

  crash> p scx_ops_bypass_depth
  scx_ops_bypass_depth = 1

  crash> p scx_fork_rwsem
  scx_fork_rwsem = {
    writer = {
      task = 0xffff002818571500
    },
    waiters = {
      head = {
        next = 0xffff8001dfb7bad8,
        prev = 0xffff8001d7e73ad8
      }
    },
    block = {
      counter = 1
    }
  }

  scx_ops_enable_state_var.counter = 0 对应 SCX_OPS_ENABLING。writer.task = 0xffff002818571500 是 PID 8309：

  crash> bt -f 8309
  PID: 8309  TASK: ffff002818571500  COMMAND: "sched_ext_enabl"
   #3 percpu_down_write
   #4 scx_ops_enable_workfn

  因此 PID 8309 已进入 percpu_down_write(&scx_fork_rwsem)，block.counter=1 表示新 fork reader 已被挡住，writer 正在等旧 reader drain。

  2. PID 12725 / 14283 是旧 reader，阻塞在 dup_mmap()

  crash> bt -fl 12725
  PID: 12725  TASK: ffff2020082a0000  COMMAND: "bash"
   #4 rwsem_down_write_slowpath  /home/jf/OLK-6.6/kernel/locking/rwsem.c:1178
   #5 down_write                 /home/jf/OLK-6.6/kernel/locking/rwsem.c:1306
   #6 dup_mmap                   /home/jf/OLK-6.6/./include/linux/fs.h:550
   #7 dup_mm                     /home/jf/OLK-6.6/kernel/fork.c:1805
   #8 copy_mm
   #9 copy_process               /home/jf/OLK-6.6/kernel/fork.c:2648

  crash> bt -fl 14283
  PID: 14283  TASK: ffff00209b406900  COMMAND: "bash"
   #4 rwsem_down_write_slowpath  /home/jf/OLK-6.6/kernel/locking/rwsem.c:1178
   #5 down_write                 /home/jf/OLK-6.6/kernel/locking/rwsem.c:1306
   #6 dup_mmap                   /home/jf/OLK-6.6/./include/linux/fs.h:550
   #7 dup_mm                     /home/jf/OLK-6.6/kernel/fork.c:1805
   #8 copy_mm
   #9 copy_process               /home/jf/OLK-6.6/kernel/fork.c:2648

  copy_process() 中 sched_fork() 早于 copy_mm()。sched_fork() 会调用 scx_pre_fork() 获取 scx_fork_rwsem read；释放发生在更晚的 sched_post_fork()->scx_post_fork()。因此这两个任务已经是 scx_fork_rwsem
  的旧 reader，但还没有走到释放路径。

  3. 为什么等待的是 mapping->i_mmap_rwsem

  bt -fl 指出阻塞点是 include/linux/fs.h:550：

  static inline void i_mmap_lock_write(struct address_space *mapping)
  {
        down_write(&mapping->i_mmap_rwsem);
  }

  所以 down_write() 的参数就是 &mapping->i_mmap_rwsem。

  不能直接从栈里随便挑地址作为锁地址。正确推导来自 rwsem_down_write_slowpath() 的第一个参数：

  crash> dis -l rwsem_down_write_slowpath
  0xffff800081b11210 <rwsem_down_write_slowpath+48>: mov x28, x0

  AArch64 ABI 中 x0 是第一个参数，即 struct rw_semaphore *sem。函数入口把 sem 保存到 x28。任务睡眠后，x28 保存在 task->thread.cpu_context.x28：

  crash> p/x ((struct task_struct *)0xffff2020082a0000)->thread.cpu_context.x28
  $43 = 0xffff00208065d1f8

  因此 PID 12725 当前等待的 rwsem 地址是：

  0xffff00208065d1f8

  校验该地址确实是有效 rwsem：

  crash> struct rw_semaphore 0xffff00208065d1f8 -x
  struct rw_semaphore {
    count = {
      counter = 0x2
    },
    owner = {
      counter = 0x0
    },
    wait_list = {
      next = 0xffff8001e0dd3558,
      prev = 0xffff8001dea336e8
    }
  }

  count=0x2 表示 RWSEM_FLAG_WAITERS，不是 writer owner。owner=0 表示当前没有可见 owner；这把锁处于有 waiters、等待队列推进的状态。

  4. 从 rwsem 反推 address_space

  已知：

  crash> p/x &((struct address_space *)0)->i_mmap_rwsem
  $44 = 0x98

  所以：

  mapping = 0xffff00208065d1f8 - 0x98
          = 0xffff00208065d160

  校验 address_space：

  crash> struct address_space 0xffff00208065d160 -x
  struct address_space {
    host = 0xffff00208065cfe8,
    ...
    i_mmap_rwsem = {
      count = {
        counter = 0x2
      },
      owner = {
        counter = 0x0
      },
      wait_list = {
        next = 0xffff8001e0dd3558,
        prev = 0xffff8001dea336e8
      }
    },
    ...
  }

  这里的 inode 地址不是凭空出现的，而是 address_space.host 字段：

  crash> p/x ((struct address_space *)0xffff00208065d160)->host
  $45 = 0xffff00208065cfe8

  因此后续读取 inode 的地址来源是：

  ((struct address_space *)0xffff00208065d160)->host

  5. 从 address_space.host 定位 inode 和文件路径

  crash> struct inode 0xffff00208065cfe8 -x
  struct inode {
    i_mode = 0x81ed,
    i_sb = 0xffff002802c39000,
    i_mapping = 0xffff00208065d160,
    i_ino = 0x20c0176,
    ...
    i_dentry = {
      first = 0xffff0020a639ef08
    },
    i_fop = 0xffff80007e6cdc80 <ext4_file_operations>,
    ...
  }

  从 inode 的 alias 链反推出 dentry：

  crash> p/x &((struct dentry *)0)->d_u.d_alias
  $51 = 0xb0

  所以：

  dentry = inode->i_dentry.first - offsetof(struct dentry, d_u.d_alias)
         = 0xffff0020a639ef08 - 0xb0
         = 0xffff0020a639ee58

  校验 dentry：

  crash> struct dentry 0xffff0020a639ee58 -x
  struct dentry {
    d_name = {
      name = 0xffff0020a639ee90 "ld-linux-aarch64.so.1"
    },
    d_inode = 0xffff00208065cfe8,
    d_sb = 0xffff002802c39000,
    ...
  }

  最终路径：

  crash> files -d 0xffff0020a639ee58
       DENTRY           INODE           SUPERBLK     TYPE PATH
  ffff0020a639ee58 ffff00208065cfe8 ffff002802c39000 REG  /usr/lib/ld-linux-aarch64.so.1

  完整对象链为：

  rwsem 0xffff00208065d1f8
    -> container_of(address_space.i_mmap_rwsem)
    -> address_space 0xffff00208065d160
    -> address_space.host
    -> inode 0xffff00208065cfe8
    -> inode.i_dentry.first - offsetof(dentry.d_u.d_alias)
    -> dentry 0xffff0020a639ee58
    -> /usr/lib/ld-linux-aarch64.so.1

  6. 同一把 i_mmap_rwsem 上的 waiter

  rw_semaphore.wait_list 偏移：

  crash> p/x &((struct rw_semaphore *)0)->wait_list
  $42 = 0x18

  所以 wait_list head 为：

  0xffff00208065d1f8 + 0x18 = 0xffff00208065d210

  读取 wait_list：

  crash> list -H 0xffff00208065d210 -s rwsem_waiter.task,type,timeout,handoff_set -x
  ffff8001e0dd3558
    task = 0xffff00209bf5d400,
    type = RWSEM_WAITING_FOR_WRITE,
    timeout = 0x100138f47,
    handoff_set = 0x0

  ...

  ffff8000c6eb39c8
    task = 0xffff2020082a0000,
    type = RWSEM_WAITING_FOR_WRITE,
    timeout = 0x1001399f6,
    handoff_set = 0x0

  ...

  ffff8001e185b9c8
    task = 0xffff00209b406900,
    type = RWSEM_WAITING_FOR_WRITE,
    timeout = 0x10013bde3,
    handoff_set = 0x0

  其中：

  0xffff2020082a0000 -> PID 12725 bash
  0xffff00209b406900 -> PID 14283 bash
  0xffff00209bf5d400 -> PID 20597 cpu_sim，队首 waiter

  7. 队首 waiter PID 20597 的状态

  crash> task 0xffff00209bf5d400
  PID: 20597  COMMAND: "cpu_sim"
  __state = 0
  on_cpu = 0
  on_rq = 1
  prio = 139
  sched_class = 0xffff8000822e0338 <fair_sched_class>
  policy = 0
  nr_cpus_allowed = 1

  调用栈：

  crash> bt -fl 0xffff00209bf5d400
  PID: 20597  TASK: ffff00209bf5d400  CPU: 123  COMMAND: "cpu_sim"
   #4 rwsem_down_write_slowpath
   #5 down_write
   #6 unlink_file_vma_batch_process  /home/jf/OLK-6.6/./include/linux/fs.h:550
   #7 unlink_file_vma_batch_final
   #8 free_pgtables
   #9 unmap_region.constprop.0
  #10 do_vmi_align_munmap
  #11 do_vmi_munmap
  #12 __vm_munmap
  #13 vm_munmap
  #14 elf_map
  #15 load_elf_interp
  #16 load_elf_binary
  #17 search_binary_handler
  #18 exec_binprm
  #19 bprm_execve
  #20 do_execveat_common
  #21 __arm64_sys_execve

  这说明 PID 20597 不是锁 owner，而是同一把 i_mmap_rwsem 的队首 writer waiter。它已经 runnable，但没有运行到重新抢锁并推进队列。

  8. CPU123 上的 cgroup 运行队列和 cgroup 名称

  crash> runq -c 123 -g
  CPU 123
    CURRENT: PID: 16509  TASK: ffff002087d38000  COMMAND: "cpu_sim"
    ROOT_TASK_GROUP: ffff800083e11780  CFS_RQ: ffff202f9fd636c0
       TASK_GROUP: ffff0020a4bf8400  CFS_RQ: ffff20280be1c800
          TASK_GROUP: ffff002808b7f800  CFS_RQ: ffff20280b65b400
             [100] PID: 16509  TASK: ffff002087d38000  COMMAND: "cpu_sim" [CURRENT]
          TASK_GROUP: ffff002808b7e000  CFS_RQ: ffff20280c0e9000
             [139] PID: 23732  TASK: ffff0020855c9500  COMMAND: "cpu_sim"
             [139] PID: 20597  TASK: ffff00209bf5d400  COMMAND: "cpu_sim"
             [139] PID: 21257  TASK: ffff0020855caa00  COMMAND: "cpu_sim"
             [139] PID: 28405  TASK: ffff00216c318000  COMMAND: "cpu_sim"
             [139] PID: 23866  TASK: ffff00209c03e900  COMMAND: "cpu_sim"
             [139] PID: 26303  TASK: ffff0020aa1b0000  COMMAND: "cpu_sim"
             [139] PID: 20135  TASK: ffff0020a659bf00  COMMAND: "cpu_sim"
             [139] PID: 23745  TASK: ffff00208ccd9500  COMMAND: "cpu_sim"

  两个 task_group 的父级相同：

  crash> p/x ((struct task_group *)0xffff002808b7f800)->parent
  $62 = 0xffff0020a4bf8400

  crash> p/x ((struct task_group *)0xffff002808b7e000)->parent
  $63 = 0xffff0020a4bf8400

  定位 cgroup 对象：

  crash> p/x ((struct task_group *)0xffff002808b7f800)->css.cgroup
  $90 = 0xffff00280c064000

  crash> p/x ((struct task_group *)0xffff002808b7e000)->css.cgroup
  $91 = 0xffff00280c066000

  定位 kernfs node：

  crash> p/x ((struct cgroup *)0xffff00280c064000)->kn
  $92 = 0xffff002803ce9b00

  crash> p/x ((struct cgroup *)0xffff00280c066000)->kn
  $95 = 0xffff0028111c7050

  读取 cgroup 名称：

  crash> p ((struct kernfs_node *)0xffff002803ce9b00)->name
  $93 = 0xffff00280230b350 "child_high"

  crash> p ((struct kernfs_node *)0xffff0028111c7050)->name
  $96 = 0xffff00280230b2b0 "child_low"

  确认二者同父级：

  crash> p/x ((struct kernfs_node *)0xffff002803ce9b00)->__parent
  $94 = 0xffff002097a77680

  crash> p/x ((struct kernfs_node *)0xffff0028111c7050)->__parent
  $97 = 0xffff002097a77680

  权重证据：

  crash> p/d ((struct task_group *)0xffff002808b7f800)->shares
  $68 = 268435456

  crash> p/d ((struct task_group *)0xffff002808b7e000)->shares
  $69 = 2048

  crash> p/d ((struct task_group *)0xffff002808b7f800)->load_avg.counter
  $70 = 177560

  crash> p/d ((struct task_group *)0xffff002808b7e000)->load_avg.counter
  $71 = 524

  crash> p/x ((struct task_group *)0xffff002808b7f800)->scx_flags
  $72 = 0x1

  crash> p/d ((struct task_group *)0xffff002808b7f800)->scx_weight
  $73 = 10000

  crash> p/x ((struct task_group *)0xffff002808b7e000)->scx_flags
  $74 = 0x1

  crash> p/d ((struct task_group *)0xffff002808b7e000)->scx_weight
  $75 = 1

  绑核证据：

  crash> p/d ((struct task_struct *)0xffff00209bf5d400)->nr_cpus_allowed
  $84 = 1

  crash> p/x ((struct task_struct *)0xffff00209bf5d400)->cpus_mask.bits[1]
  $86 = 0x800000000000000

  crash> p/d ((struct task_struct *)0xffff002087d38000)->nr_cpus_allowed
  $87 = 1

  crash> p/x ((struct task_struct *)0xffff002087d38000)->cpus_mask.bits[1]
  $89 = 0x800000000000000

  二者均只允许在 CPU123 上运行。

  父级 CFS 状态：

  crash> p/x ((struct cfs_rq *)0xffff20280be1c800)->curr
  $76 = 0xffff20280b65f800

  crash> p/x ((struct cfs_rq *)0xffff20280be1c800)->tasks_timeline.rb_leftmost
  $77 = 0xffff20280c0e8810

  crash> p/x &((struct sched_entity *)0)->run_node
  $78 = 0x10

  rb_leftmost - offsetof(sched_entity.run_node) = 0xffff20280c0e8800，对应 child_low 的 group se。但 rb_leftmost 只是红黑树上最左实体，不等于下一次一定被 pick。EEVDF 还要通过 entity_eligible() /
  vruntime_eligible() 判断。

  9. sched_ext prod 曾经报告 runnable task stall

  [5315.437305] sched_ext: BPF scheduler "prod" disabled (runnable task stall)
  [5315.444888] sched_ext: prod: cc1[9968] failed to run for 35.316s

  [5389.485701] sched_ext: BPF scheduler "prod" disabled (runnable task stall)
  [5389.493679] sched_ext: prod: bash[14280] failed to run for 43.784s

  该日志对应源码：

  kernel/sched/ext.c:check_rq_for_timeouts:scx_ops_error_kind:3458

  说明此前 prod 调度器已经出现过 runnable task 长时间未运行的问题。最终 panic 时 Sched_ext: prod (enabling)，说明这次故障发生在重新 enable 的窗口中。

  ABBA 判定

  本次未观察到传统 ABBA 死锁。

  传统 ABBA 需要：
    线程A: holds LockA -> waits LockB
    线程B: holds LockB -> waits LockA
    闭环: LockA -> LockB -> LockA

  本次观察到的是：

  线程A:
    PID 8309 sched_ext_enabl
      -> waits scx_fork_rwsem old readers drain

  线程B/C:
    PID 12725 / 14283 bash
      -> holds scx_fork_rwsem read
      -> waits mapping->i_mmap_rwsem write

  线程D:
    PID 20597 cpu_sim
      -> rwsem wait_list 队首
      -> TASK_RUNNING / on_rq=1 / on_cpu=0
      -> 尚未运行到重新抢锁并推进 rwsem 队列

  缺失的 ABBA 边是：

  没有证据显示 mapping->i_mmap_rwsem 的 owner 或 reader 反向等待 scx_fork_rwsem。

  并且 i_mmap_rwsem.owner = 0，count = 0x2，说明这把 rwsem 当前不是由某个可见 writer owner 持有，而是等待队列需要被 runnable 队首 waiter 推进。

  非闭环等待根因

  锁持有者为什么不能释放锁：

  本次在 i_mmap_rwsem 上没有可见 owner。rwsem 状态为 count=0x2、owner=0，表示有 waiters 标志。队列头 PID 20597 是 writer waiter，状态为 TASK_RUNNING/on_rq=1/on_cpu=0，但没有实际运行到重新尝试
  rwsem_try_write_lock() 并推进队列。

  等待者为什么被挡住：

  PID 12725 / 14283 在 fork 过程中执行 dup_mmap()，需要 i_mmap_lock_write(mapping)，即 down_write(&mapping->i_mmap_rwsem)。由于同一把 rwsem 的队列前方已有大量 writer waiter，二者作为后续 writer waiter
  睡眠在 rwsem_down_write_slowpath()。

  该状态为什么长期不恢复：

  PID 20597 所在 cgroup 为 child_low，只允许在 CPU123 上运行。同 CPU 上 child_high 权重显著更高，当前 PID 16509 正在运行。child_low 虽然在父级 CFS rb_leftmost 上可见，但 EEVDF pick 仍需
  entity_eligible()/vruntime_eligible()，rb_leftmost 不等价于下一次必然运行。结合 dmesg 中 prod runnable task stall 以及当前 sched_ext 处于 SCX_OPS_ENABLING 的窗口，局部 runnable waiter 未及时推进，进
  一步被 scx_fork_rwsem 写侧等待旧 reader drain 放大成全局 fork 阻塞。

  人读版传播链

  主阻塞链：

  /usr/lib/ld-linux-aarch64.so.1 的 address_space->i_mmap_rwsem 上存在 writer wait_list
    -> 队首 waiter PID 20597 cpu_sim 已 runnable/on_rq，但在 CPU123 child_low 中长期未推进
      -> PID 12725 / 14283 bash 在 dup_mmap()->i_mmap_lock_write() 等同一把 rwsem write
        -> PID 12725 / 14283 已持有 scx_fork_rwsem read，无法走到 scx_post_fork()->percpu_up_read()
          -> PID 8309 sched_ext_enabl 在 percpu_down_write(&scx_fork_rwsem) 等旧 reader drain
            -> sched_ext enable 停留在 SCX_OPS_ENABLING

  扩散分支 A：

  scx_fork_rwsem.block = 1
    -> 新 fork reader 被挡在 scx_pre_fork()
      -> systemd/kthreadd/chronyd/sshd/crond/bash 等后续 fork/clone 进入 D 状态

  扩散分支 B：

  大量 fork/clone D 状态超过 hung_task_timeout
    -> khungtaskd 检测到 blocked tasks
      -> hung_task_call_panic 打开
        -> panic("hung_task: blocked tasks")

  故障模型路径树

  sched_ext enable 写侧：

  kernel/sched/ext.c:scx_ops_enable_workfn:scx_ops_set_enable_state:5283 # sched_ext enable 进入 SCX_OPS_ENABLING，vmcore 中 scx_ops_enable_state_var.counter=0
        kernel/sched/ext.c:scx_ops_enable_workfn:scx_ops_bypass:5352 # enable 期间打开 bypass，vmcore 中 scx_ops_bypassed_for_enable=true
                kernel/sched/ext.c:scx_ops_enable_workfn:scx_ops_bypassed_for_enable:5353 # enable bypass 状态保持，vmcore 中 scx_ops_bypass_depth=1
                        kernel/sched/ext.c:scx_ops_enable_workfn:percpu_down_write:5381 # enable 写侧尝试独占 scx_fork_rwsem，vmcore writer.task=PID 8309
                                kernel/locking/percpu-rwsem.c:percpu_down_write:rcu_sync_enter:231 # 通知后续 reader 进入慢路径
                                kernel/locking/percpu-rwsem.c:percpu_down_write:__percpu_down_write_trylock:237 # 设置 sem->block，vmcore 中 scx_fork_rwsem.block=1
                                kernel/locking/percpu-rwsem.c:percpu_down_write:readers_active_check:249 # 等旧 reader 的 per-cpu read_count 归零；PID 12725/14283 未退出 read 临界区

  旧 fork reader 侧：

  kernel/fork.c:copy_process:sched_fork:2618 # fork 早期先执行调度初始化
        kernel/sched/core.c:sched_fork:scx_pre_fork:4697 # sched_fork 调用 sched_ext fork 前置钩子
                kernel/sched/ext.c:scx_pre_fork:percpu_down_read:3725 # PID 12725/14283 成功获取 scx_fork_rwsem read，成为 enable writer 等待的旧 reader
                        kernel/fork.c:copy_process:copy_mm:2648 # fork 继续复制 mm，说明任务已经越过 scx_pre_fork
                                kernel/fork.c:copy_mm:dup_mm:<line?> # copy_mm 进入 dup_mm；该行号需以目标 vmlinux 对应源码确认为准
                                        kernel/fork.c:dup_mm:dup_mmap:1805 # dup_mm 调用 dup_mmap 复制 VMA
                                                kernel/fork.c:dup_mmap:i_mmap_lock_write:784 # 复制 file-backed VMA 时需要写锁保护 mapping->i_mmap
                                                        include/linux/fs.h:i_mmap_lock_write:down_write:550 # down_write(&mapping->i_mmap_rwsem)，当前 mapping 为 /usr/lib/ld-linux-aarch64.so.1
                                                                kernel/locking/rwsem.c:rwsem_down_write_slowpath:RWSEM_WAITING_FOR_WRITE:1123 # PID 12725/14283 作为 writer waiter 等待该 rwsem
                                                                kernel/locking/rwsem.c:rwsem_down_write_slowpath:rwsem_add_waiter:1128 # waiter 加入 wait_list，crash 中可见二者均在 0xffff00208065d210 队列上
                                                                kernel/locking/rwsem.c:rwsem_down_write_slowpath:schedule_preempt_disabled:1178 # writer waiter 睡眠，无法继续 fork 后半段

  旧 fork reader 释放路径未到达：

  kernel/fork.c:copy_process:sched_post_fork:2874 # 正常 fork 成功后才会进入 sched_post_fork
        kernel/sched/core.c:sched_post_fork:scx_post_fork:4774 # sched_post_fork 调用 sched_ext fork 后置钩子
                kernel/sched/ext.c:scx_post_fork:percpu_up_read:3762 # 这里释放 scx_fork_rwsem read；PID 12725/14283 因阻塞在 dup_mmap 未到达

  i_mmap_rwsem 队首 waiter 侧：

  fs/binfmt_elf.c:load_elf_binary:load_elf_interp:1277 # PID 20597 exec 过程中加载 ELF interpreter
        fs/binfmt_elf.c:load_elf_interp:elf_map:669 # 映射 interpreter 段
                fs/binfmt_elf.c:elf_map:vm_munmap:384 # ELF 映射过程中先 unmap 旧地址区间
                        mm/mmap.c:vm_munmap:__vm_munmap:3121 # 进入 munmap 内核路径
                                mm/mmap.c:__vm_munmap:do_vmi_munmap:3111 # 执行 VMA unmap
                                        mm/mmap.c:do_vmi_munmap:do_vmi_align_munmap:2798 # 对齐并拆除目标 VMA 区间
                                                mm/mmap.c:do_vmi_align_munmap:unmap_region:2721 # 进入 unmap_region 释放映射
                                                        mm/mmap.c:unmap_region:free_pgtables:2471 # 释放页表并处理 file-backed VMA
                                                                mm/memory.c:free_pgtables:unlink_file_vma_batch_final:418 # 释放页表期间批量 unlink file VMA
                                                                        mm/mmap.c:unlink_file_vma_batch_final:unlink_file_vma_batch_process:176 # 存在 file-backed VMA batch，继续处理同一 mapping
                                                                                mm/mmap.c:unlink_file_vma_batch_process:i_mmap_lock_write:149 # PID 20597 等同一把 mapping->i_mmap_rwsem
                                                                                        include/linux/fs.h:i_mmap_lock_write:down_write:550 # down_write(&mapping->i_mmap_rwsem)，rwsem 地址 0xffff00208065d1f8
                                                                                                kernel/locking/rwsem.c:rwsem_down_write_slowpath:rwsem_first_waiter:1131 # PID 20597 位于 wait_list 队首，后续 waiter 包含 PID 12725/14283
                                                                                                [BUG-1] kernel/locking/rwsem.c:rwsem_down_write_slowpath:schedule_preempt_disabled:1178 # 队首 writer waiter 已 runnable/on_rq 但长期未获得实际运行，rwsem 队列进展保证在此处失效

  调度背景和 runnable stall 证据：

  kernel/sched/ext.c:scx_watchdog_workfn:check_rq_for_timeouts:3478 # sched_ext watchdog 周期性检查 runnable task 是否长期未运行
        kernel/sched/ext.c:check_rq_for_timeouts:scx_ops_error_kind:3458 # dmesg 中 prod 曾报告 runnable task stall：任务 failed to run for 35s/43s
                kernel/sched/fair.c:pick_eevdf:entity_eligible:1222 # CFS/EEVDF 选择 leftmost 前仍要判断 eligible，rb_leftmost 不等于必然下一次运行
                        kernel/sched/fair.c:entity_eligible:vruntime_eligible:1060 # child_low 的可运行状态需要通过 vruntime_eligible 才能被选中
                                [WINDOW] kernel/sched/fair.c:vruntime_eligible:avg_vs_key_load:1006 # 极端 cgroup weight、单 CPU 绑定和当前 runnable 队列形成低权重任务长期不推进窗口

  cgroup 权重和绑核状态：

  kernel/sched/fair.c:pick_next_entity:pick_eevdf:5756 # CPU123 父级 CFS 在 child_high 与 child_low group se 间选择下一实体
        kernel/sched/fair.c:pick_eevdf:curr_protect_or_best:1256 # 当前 child_high group se 可继续被保留，child_low 即使 leftmost 也需满足 eligible
                kernel/sched/fair.c:entity_eligible:vruntime_eligible:1060 # child_low group se 是否可被 pick 取决于 EEVDF eligible 判断
                        [WINDOW] kernel/sched/fair.c:vruntime_eligible:weight_skew:1006 # crash 证据显示 child_high shares=268435456/scx_weight=10000，child_low shares=2048/scx_weight=1，且二者均绑 CPU123

  新 fork 扩散侧：

  kernel/fork.c:copy_process:sched_fork:2618 # 后续 systemd/kthreadd/chronyd/sshd/crond/bash 等 fork 进入 copy_process
        kernel/sched/core.c:sched_fork:scx_pre_fork:4697 # 新 fork 同样进入 scx_pre_fork
                kernel/sched/ext.c:scx_pre_fork:percpu_down_read:3725 # scx_fork_rwsem.block=1 后新 reader 被 writer 阻断
                        [WARN] kernel/locking/percpu-rwsem.c:percpu_down_write:__percpu_down_write_trylock:237 # writer 设置 block 是正常机制，但旧 reader 不退出时会放大全局 fork 阻塞

  终端症状：

  kernel/hung_task.c:check_hung_uninterruptible_tasks:check_hung_task:213 # khungtaskd 扫描到多个 TASK_UNINTERRUPTIBLE 任务
        kernel/hung_task.c:check_hung_uninterruptible_tasks:hung_task_call_panic:225 # hung_task_call_panic 开启后准备触发 panic
                [PANIC] kernel/hung_task.c:check_hung_uninterruptible_tasks:panic:226 # Kernel panic: hung_task: blocked tasks

  根因分层

  直接阻塞点：

  PID 12725 / 14283 在 fork 的 dup_mmap() 中等待 /usr/lib/ld-linux-aarch64.so.1 的 mapping->i_mmap_rwsem 写锁。

  直接阻塞它们的队列状态：

  同一把 i_mmap_rwsem 的 wait_list 队首是 PID 20597。该任务是 writer waiter，TASK_RUNNING/on_rq=1/on_cpu=0，但没有运行到推进 rwsem 队列。

  系统级放大点：

  PID 12725 / 14283 在持有 scx_fork_rwsem read 的情况下阻塞，PID 8309 sched_ext_enabl 在 percpu_down_write(&scx_fork_rwsem) 等旧 reader drain。writer 设置 block=1 后，新 fork reader 全部被阻断。

  长期不恢复背景：

  PID 20597 位于 CPU123 的 child_low cgroup，child_low 与 child_high 同父级、同 CPU 绑定，但权重显著低于 child_high。dmesg 还显示 prod 调度器此前已有 runnable task stall。该调度背景使 i_mmap_rwsem 队
  首 waiter 长时间没有推进；sched_ext enable 阶段的 scx_fork_rwsem 写侧等待进一步把局部等待放大为全局 fork hung。

  需要保留的边界：

  单独的 cpu.shares 差异不应被写成“必然导致 7200 秒或 10000 秒不调度”的充分条件。更稳妥的结论是：极端 cgroup 权重和单 CPU 绑定构成低权重任务长期不推进的关键背景；sched_ext prod runnable stall 和
  enable 窗口中的 scx_fork_rwsem 全局 drain 机制，是本次 hung task panic 的系统级放大路径。