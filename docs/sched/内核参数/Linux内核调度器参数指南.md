# Linux 内核调度器参数指南

> 整合 features.h 特性开关 + /sys/kernel/debug/sched/ 配置接口 + /proc/sys/kernel/ 参数

## 前言：EEVDF调度器入门

---

### 从CFS说起：为什么需要EEVDF

#### CFS的设计理念

**CFS（Completely Fair Scheduler，完全公平调度器）** 自Linux 2.6.23引入以来，一直是内核的默认调度器。它的核心思想简单优雅：

```
┌─────────────────────────────────────────────────────────────┐
│  CFS核心：总是选择 vruntime 最小的任务运行                    │
│                                                             │
│  vruntime = 实际运行时间 × (NICE_0_LOAD / 任务权重)          │
│                                                             │
│  权重高 → vruntime增长慢 → 被调度更频繁                       │
└─────────────────────────────────────────────────────────────┘
```

这个设计在大多数场景下表现良好，但在**延迟敏感型任务**上遇到了困境。

#### CFS的局限性：一个具体场景

假设你正在开发一个网络请求处理服务：

```
场景：处理每个请求只需 0.5ms CPU时间，但要求极快响应

CFS的做法：
┌─────────────────────────────────────────────────────────────┐
│  任务A（你的服务）：nice=0，权重1024，每次运行0.5ms          │
│  任务B（后台计算）：nice=0，权重1024，每次运行50ms           │
│                                                             │
│  问题：任务A运行时间短，vruntime增长慢，会被频繁调度          │
│        但每次被调度时，可能刚运行就被任务B抢占！              │
│                                                             │
│  时间线示意：                                                │
│  A运行0.5ms → B运行 → B运行 → A运行0.5ms → B运行 → ...      │
│       ↑                                                   │
│  任务A虽然调度频繁，但响应延迟无法保证                       │
└─────────────────────────────────────────────────────────────┘
```

#### 为什么降低nice值不够？

你可能会想：把服务进程的nice值调低（提高权重）不就行了？

```
问题：nice值只影响调度频率，不保证响应速度

nice=-10 (权重=1446) vs nice=0 (权重=1024)
┌─────────────────────────────────────────────────────────────┐
│  权重提高 → vruntime增长更慢 → 调度更频繁                    │
│                                                             │
│  但是：                                                     │
│  1. 被调度 ≠ 能立即运行完                                    │
│  2. 其他任务的time slice未完成时，你仍需等待                 │
│  3. CFS没有"短任务优先完成"的概念                            │
│                                                             │
│  结果：调度频率提高了，但响应延迟仍然不可预测                 │
└─────────────────────────────────────────────────────────────┘
```

**核心矛盾**：CFS只有**权重**一个参数，无法同时表达"我需要更多CPU时间"和"我需要更快响应"。

---

### EEVDF是什么？

#### 全称和核心思想

**EEVDF**（Earliest Eligible Virtual Deadline First，最早合格虚拟截止时间优先）是Linux 6.6开始引入的新调度策略。

```
EEVDF核心：从所有 eligible（有资格）的任务中，选择 deadline 最早的运行

两个关键条件：
┌─────────────────────────────────────────────────────────────┐
│  1️⃣ eligible（有资格）：lag >= 0，即"被欠了CPU时间"           │
│  2️⃣ deadline最早：虚拟截止时间距离现在最近                   │
└─────────────────────────────────────────────────────────────┘
```

#### 关键创新：双参数调度

| 调度器 | 参数数量 | 参数说明 | 效果 |
|--------|----------|----------|------|
| **CFS** | 1个 | 权重（nice值） | 只能控制时间分配比例 |
| **EEVDF** | 2个 | 权重 + 时间片（slice） | 时间分配比例 + 延迟敏感度 |

**时间片（slice）的作用**：

```
vd = vruntime + slice / weight

slice越小 → deadline越早 → 越容易被选中 → 响应越快！
```

这解决了CFS的根本问题：**现在你可以同时设置"我需要多少CPU时间"（权重）和"我需要多快响应"（slice）**。

#### 一个直观的类比：银行柜台

想象一个银行有多个柜台，客户排队办理业务：

```
CFS模式（只看权重）：
┌─────────────────────────────────────────────────────────────┐
│  VIP客户（权重高）：可以插队到前面                            │
│  但一旦开始办理，必须等他办完才能服务下一个                   │
│                                                             │
│  问题：VIP办小事也要等很久，普通客户办大事会阻塞VIP           │
└─────────────────────────────────────────────────────────────┘

EEVDF模式（权重 + 时间片）：
┌─────────────────────────────────────────────────────────────┐
│  每个客户有：                                                │
│  - 优先级权重（决定插队能力）                                │
│  - 预计办理时长（slice，决定"截止时间"）                      │
│                                                             │
│  规则：                                                     │
│  1. 只服务"被欠时间"的客户（eligible规则）                   │
│  2. 在符合条件的客户中，选截止时间最近的                      │
│                                                             │
│  结果：办小事的客户快速完成，办大事的公平等待                 │
└─────────────────────────────────────────────────────────────┘
```

---

### EEVDF核心算法（简化版）

#### 虚拟截止时间（Virtual Deadline）

```
公式：vd = vruntime + vslice
其中：vslice = slice / weight

直观理解：
┌─────────────────────────────────────────────────────────────┐
│  每个任务都有一个"截止日期"                                   │
│  deadline越早 → 越优先被调度                                  │
│                                                             │
│  vd = vruntime + (slice / weight)                           │
│       ↑             ↑                                        │
│  已经运行的      本次请求的时间片                             │
│  虚拟时间        （按权重缩放后）                              │
│                                                             │
│  关键：slice越小 → vslice越小 → deadline越早！                │
└─────────────────────────────────────────────────────────────┘
```

**示例计算**：

```
任务A：weight=1024, slice=0.75ms, vruntime=100ms
任务B：weight=1024, slice=5ms,   vruntime=98ms

deadline_A = 100 + 0.75 = 100.75ms  ← 更早，优先调度！
deadline_B = 98 + 5 = 103ms
```

注意：虽然任务B的vruntime更小（在CFS中会优先调度），但EEVDF选择deadline更早的任务A。

#### Lag（延迟差）的概念

```
lag = 理应获得的CPU时间 - 实际获得的CPU时间

公式：lag_i = weight × (V - vruntime_i)
             其中 V = 队列平均虚拟时间

含义：
┌─────────────────────────────────────────────────────────────┐
│  lag > 0：被欠了时间 → 应该补偿 → 优先调度                    │
│  lag < 0：多用了时间 → 需要等待 → 暂停调度                    │
│  lag = 0：公平公正 → 正常参与竞争                              │
└─────────────────────────────────────────────────────────────┘
```

#### Eligible（有资格）的含义

```
规则：只有 lag >= 0 的任务才有资格被调度

这个机制保证了公平性：
┌─────────────────────────────────────────────────────────────┐
│  场景：任务刚运行完一个长周期，lag为负                        │
│                                                             │
│  CFS：可以立即重新竞争（如果vruntime还不够大）                │
│  EEVDF：必须等待lag恢复到>=0才能参与竞争                      │
│                                                             │
│  效果：防止"刚跑完又立即被选中"的不公平现象                    │
└─────────────────────────────────────────────────────────────┘
```

#### 调度决策流程

```
EEVDF调度决策流程：
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  pick_next_task()                                           │
│         │                                                   │
│         ▼                                                   │
│  ┌─────────────────┐                                        │
│  │ 当前任务有slice │──Yes──→ 继续运行当前任务                │
│  │ 保护且未过期？   │                                        │
│  └────────┬────────┘                                        │
│           │No                                               │
│           ▼                                                 │
│  ┌─────────────────┐                                        │
│  │ 检查红黑树中    │                                        │
│  │ 每个任务        │                                        │
│  └────────┬────────┘                                        │
│           │                                                 │
│           ▼                                                 │
│  ┌─────────────────┐    ┌─────────────────┐                │
│  │ lag >= 0 ?      │──No→│ 跳过（不eligible）│               │
│  │ (eligible检查)  │    └─────────────────┘                │
│  └────────┬────────┘                                        │
│           │Yes                                              │
│           ▼                                                 │
│  ┌─────────────────────────────────────┐                    │
│  │ 在eligible任务中，选deadline最小的   │                    │
│  └─────────────────────────────────────┘                    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

### EEVDF vs CFS 全面对比

#### 核心机制对比

| 维度 | CFS | EEVDF | 影响 |
|------|-----|-------|------|
| **调度参数** | 单参数（权重） | 双参数（权重 + slice） | 更灵活的控制 |
| **调度决策** | 选择vruntime最小 | 选择eligible中deadline最小 | 更公平 |
| **延迟保证** | 隐式（依赖权重） | 显式（通过slice） | 更可预测 |
| **公平性机制** | vruntime追赶 | lag守恒 | 更精确 |
| **红黑树排序** | 按vruntime | 按deadline | 选择更高效 |
| **时间片概念** | 动态计算 | 固定base_slice | 更稳定 |

#### 时间片对比

| 特性 | CFS | EEVDF |
|------|-----|-------|
| **时间片计算** | `sched_latency / nr_running` | 固定 `base_slice_ns`（默认0.7ms） |
| **是否可调** | 间接（通过调整sched_latency） | 直接设置slice |
| **对延迟的影响** | 任务数变化时波动 | 稳定可预测 |

#### 抢占机制对比

| 场景 | CFS | EEVDF |
|------|-----|-------|
| **唤醒抢占** | vruntime比较 | deadline比较 + PREEMPT_SHORT |
| **时间片保护** | 无明确保护 | RUN_TO_PARITY保护当前任务 |
| **短任务优先** | 依赖权重 | 可通过小slice显式实现 |

---

### 性能维度对比

#### 延迟（Latency）

```
EEVDF优势：
┌─────────────────────────────────────────────────────────────┐
│  短slice任务 → deadline更早 → 响应更快                        │
│                                                             │
│  配置示例：                                                  │
│  - 网络服务：slice=0.5ms，保证请求快速响应                    │
│  - UI线程：slice=1ms，保证流畅交互                            │
│                                                             │
│  CFS对比：                                                  │
│  只能通过提高权重间接实现，效果有限且不可预测                  │
└─────────────────────────────────────────────────────────────┘
```

**配置建议**：
```bash
# 查看默认slice
cat /sys/kernel/debug/sched/base_slice_ns
# 默认约700000ns = 0.7ms

# 时延敏感型任务可通过sched_setattr()设置更小的slice
```

#### 吞吐量（Throughput）

```
EEVDF特性：
┌─────────────────────────────────────────────────────────────┐
│  RUN_TO_PARITY：保护当前任务的slice不被抢占                   │
│                                                             │
│  优点：                                                    │
│  - 减少上下文切换                                           │
│  - 提高缓存局部性                                           │
│  - 更稳定的执行                                             │
│                                                             │
│  权衡：                                                    │
│  - 短任务唤醒时可能需要等待                                  │
│  - 可通过PREEMPT_SHORT缓解                                   │
└─────────────────────────────────────────────────────────────┘
```

**配置建议**：
```bash
# 批处理任务可设置较大slice
# 通过特性开关调整行为
echo PREEMPT_SHORT > /sys/kernel/debug/sched/features   # 允许短任务抢占
echo NO_PREEMPT_SHORT > /sys/kernel/debug/sched/features # 保护当前任务
```

#### 公平性（Fairness）

```
EEVDF优势：
┌─────────────────────────────────────────────────────────────┐
│  lag机制保证精确的时间分配                                    │
│                                                             │
│  PLACE_LAG：任务睡眠后lag保持不变                             │
│  DELAY_DEQUEUE：负lag任务延迟出队，消耗lag                    │
│  DELAY_ZERO：正lag唤醒时裁剪为0，防止积累优势                 │
│                                                             │
│  效果：                                                    │
│  - 睡眠任务不会获得不公平优势                                │
│  - 长时间睡眠后醒来不会立即霸占CPU                           │
│  - 解决了CFS的FAIR_SLEEPERS问题                              │
└─────────────────────────────────────────────────────────────┘
```

#### 实时性（Real-time）

| 定位 | 说明 |
|------|------|
| **RT调度类** | 硬实时保证，需要权限 |
| **EEVDF** | 软实时，无需权限，介于RT和CFS之间 |
| **CFS** | 通用调度，无实时保证 |

**适用场景**：需要比CFS更好响应但不需要硬实时的任务（如网络服务、音频处理）。

---

### 如何使用EEVDF

#### 查看当前配置

```bash
# 查看默认时间片
cat /sys/kernel/debug/sched/base_slice_ns
# 输出示例：700000 (即0.7ms)

# 查看启用的特性
cat /sys/kernel/debug/sched/features

# 查看调度器详细状态
cat /sys/kernel/debug/sched/debug
```

#### 调整slice（程序方式）

```c
#include <sched.h>
#include <sys/syscall.h>

struct sched_attr {
    uint32_t size;
    uint32_t sched_policy;
    uint64_t sched_flags;
    int32_t sched_nice;
    uint32_t sched_priority;
    uint64_t sched_runtime;  // 这就是slice！
    // ...
};

// 设置slice为0.5ms
struct sched_attr attr = {
    .size = sizeof(attr),
    .sched_policy = SCHED_NORMAL,  // CFS/EEVDF
    .sched_runtime = 500000,        // 500000ns = 0.5ms
};
syscall(SYS_sched_setattr, getpid(), &attr, 0);
```

#### 调整slice（命令行方式）

```bash
# 使用chrt（部分版本支持）
# 或通过内核参数调整全局默认值

# 在启动参数中设置
# kernel.sched_base_slice_ns = 1000000  # 1ms
```

#### 特性开关控制

```bash
# 开启/关闭特定特性
echo RUN_TO_PARITY > /sys/kernel/debug/sched/features
echo NO_PREEMPT_SHORT > /sys/kernel/debug/sched/features

# 常用特性组合：
# 时延敏感型：PREEMPT_SHORT + NEXT_BUDDY
# 吞吐优先型：NO_PREEMPT_SHORT + 大base_slice_ns
```

---

### 常见问题解答

**Q: EEVDF会完全替代CFS吗？**

A: 是的。从Linux 6.6开始，EEVDF已成为默认调度策略。CFS的代码被重构为EEVDF实现，但用户接口保持兼容。

**Q: 现有的nice值设置还有效吗？**

A: 完全有效。nice值仍然控制权重，影响任务获得CPU时间的比例。EEVDF新增的slice参数用于控制延迟敏感度。

**Q: 如何判断我的任务是否受益于EEVDF？**

A: 如果你的任务符合以下特征，EEVDF会有帮助：
- 运行时间短（< 1ms）
- 需要快速响应（< 10ms延迟）
- 间歇性运行（网络请求处理、事件驱动）

**Q: EEVDF有什么缺点？**

A: 主要考虑点：
- 配置复杂度增加（双参数 vs 单参数）
- eligible检查有少量开销
- 理解成本较高

---

> **下一步**：理解EEVDF基础后，可以通过 [第二部分：运行时参数配置](#第二部分运行时参数配置) 调整调度器行为，或通过 [第三部分：调度器特性](#第三部分调度器特性features) 深入了解RUN_TO_PARITY、PREEMPT_SHORT等EEVDF核心特性。

---

## 第一部分：内核启动参数（cmdline）

### 1.1 基础调度控制

| 参数          | 说明                                                  | 使用方法                            | 备注                                                        |
| ------------- | ----------------------------------------------------- | ----------------------------------- | ----------------------------------------------------------- |
| `noautogroup` | 禁用自动进程组功能，避免为交互式桌面进程创建任务组    | 启动命令行添加 `noautogroup`        | 也可通过 `sysctl kernel.sched_autogroup_enabled=0` 动态关闭 |
| `schedstats=` | 控制调度器统计信息收集，用于性能分析与调试            | `schedstats=on` 或 `schedstats=off` | 也可通过 `sysctl kernel.sched_schedstats=1/0` 动态调整      |
| `nohz=`       | 全局开关tickless模式，控制CPU空闲时是否停止定时器tick | `nohz=on`（默认）或 `nohz=off`      | 细粒度控制需使用 `nohz_full=`                               |
| `nohz_full=`  | 在指定CPU上启用完全无滴答模式，减少内核干扰           | `nohz_full=1,3,5-7`（CPU列表）      | 需配合 `rcu_nocbs=` 和 `isolcpus=` 使用                     |
| `isolcpus=`   | 将CPU从通用调度器中隔离，用于特定应用或实时任务       | `isolcpus=2,4,6`（CPU列表）         | 隔离后需手动绑定任务（taskset/cpuset）                      |

### 1.2 高级调度控制

| 参数                         | 说明                                       | 使用方法                                  | 备注                                               |
| ---------------------------- | ------------------------------------------ | ----------------------------------------- | -------------------------------------------------- |
| `sched_thermal_decay_shift=` | 调节热压力信号衰减速率，影响任务放置与迁移 | `sched_thermal_decay_shift=2`（范围0-10） | 需 `CONFIG_SCHED_THERMAL_PRESSURE=y`，仅启动时设置 |
| `nohlt` / `hlt`              | 控制CPU空闲行为：空循环 vs 省电halt状态    | 启动命令行添加 `nohlt` 或 `hlt`           | 二者互斥，`nohlt`用于低延迟或调试                  |
| `psi=`                       | 控制PSI（资源压力）功能开关                | `psi=1`（启用）或 `psi=0`（关闭）         | 也可通过 `sysctl kernel.pressure.*` 查看指标       |
| `relax_domain_level=`        | 设置调度域负载均衡的"松弛"级别             | `relax_domain_level=1`（范围-1到5）       | 数值越大，越大范围内避免负载均衡                   |
| `sched_cluster=`             | 启用集群调度支持（针对ARM big.LITTLE等）   | `sched_cluster=1` 或 `sched_cluster=0`    | 需 `CONFIG_SCHED_CLUSTER=y`                        |

---

## 第二部分：运行时参数配置

### 2.1 /proc/sys/kernel/ 调度参数

| 参数                              | 说明                      | 默认值    | 设置方法                                                     |
| --------------------------------- | ------------------------- | --------- | ------------------------------------------------------------ |
| `sched_autogroup_enabled`         | 自动进程组开关            | 1         | `echo 0 > /proc/sys/kernel/sched_autogroup_enabled`          |
| `sched_cfs_bandwidth_slice_us`    | CFS带宽控制的时间配额粒度 | 5000μs    | `echo 10000 > /proc/sys/kernel/sched_cfs_bandwidth_slice_us` |
| `sched_child_runs_first`          | fork时子进程优先运行      | 0         | `echo 1 > /proc/sys/kernel/sched_child_runs_first`           |
| `sched_cluster`                   | 集群调度开关              | 0         | `echo 1 > /proc/sys/kernel/sched_cluster`                    |
| `sched_deadline_period_max_us`    | 实时进程最大调度周期      | 4194304μs | `echo 2000000 > /proc/sys/kernel/sched_deadline_period_max_us` |
| `sched_deadline_period_min_us`    | 实时进程最小调度周期      | 100μs     | `echo 200 > /proc/sys/kernel/sched_deadline_period_min_us`   |
| `sched_prio_load_balance_enabled` | 同优先级任务跨CPU负载均衡 | 1         | `echo 0 > /proc/sys/kernel/sched_prio_load_balance_enabled`  |
| `sched_rr_timeslice_ms`           | RT轮转调度时间片长度      | 100ms     | `echo 50 > /proc/sys/kernel/sched_rr_timeslice_ms`           |
| `sched_rt_period_us`              | RT带宽控制周期长度        | 1000000μs | `echo 2000000 > /proc/sys/kernel/sched_rt_period_us`         |
| `sched_rt_runtime_us`             | RT带宽周期内允许运行时间  | 950000μs  | `echo 900000 > /proc/sys/kernel/sched_rt_runtime_us`         |
| `sched_schedstats`                | 调度统计信息收集开关      | 0         | `echo 1 > /proc/sys/kernel/sched_schedstats`                 |
| `sched_util_low_pct`              | 潮汐调度亲和性阈值        | 85        | `echo 75 > /proc/sys/kernel/sched_util_low_pct`              |

### 2.2 /sys/kernel/debug/sched/ 调试参数

| 参数                | 说明                                   | 默认值    | 设置方法                                                   |
| ------------------- | -------------------------------------- | --------- | ---------------------------------------------------------- |
| `debug`             | 调度器详细运行状态接口                 | -         | `cat /sys/kernel/debug/sched/debug`                        |
| `features`          | 当前启用的调度特性                     | -         | `cat /sys/kernel/debug/sched/features`                     |
| `migration_cost_ns` | 任务迁移成本估算                       | 500000ns  | `echo 1000000 > /sys/kernel/debug/sched/migration_cost_ns` |
| `nr_migrate`        | 负载均衡时单次迁移任务最大数量         | 32        | `echo 16 > /sys/kernel/debug/sched/nr_migrate`             |
| `tunable_scaling`   | 调度参数放大策略（0=无,1=线性,2=对数） | 1         | `echo 2 > /sys/kernel/debug/sched/tunable_scaling`         |
| `verbose`           | 调度域详细显示和错误检查开关           | 0         | `echo 1 > /sys/kernel/debug/sched/verbose`                 |
| `latency_warn_ms`   | 系统响应延迟告警阈值                   | 100ms     | `echo 100 > /sys/kernel/debug/sched/latency_warn_ms`       |
| `latency_warn_once` | 延迟告警是否只触发一次                 | 1         | `echo 1 > /sys/kernel/debug/sched/latency_warn_once`       |
| `base_slice_ns`     | CFS调度器默认时间片长度                | ~700000ns | `echo 3000000 > /sys/kernel/debug/sched/base_slice_ns`     |

### 2.3 /sys/kernel/debug/sched/numa_balancing/ NUMA参数

| 参数                 | 说明                     | 设置方法                                             |
| -------------------- | ------------------------ | ---------------------------------------------------- |
| `hot_threshold_ms`   | "热页"识别阈值           | `echo 100 > .../numa_balancing/hot_threshold_ms`     |
| `scan_delay_ms`      | 任务启动后的初始扫描延迟 | `echo 10 > .../numa_balancing/scan_delay_ms`         |
| `scan_period_min_ms` | 最小扫描间隔             | `echo 100 > .../numa_balancing/scan_period_min_ms`   |
| `scan_period_max_ms` | 最大扫描间隔             | `echo 10000 > .../numa_balancing/scan_period_max_ms` |
| `scan_size_mb`       | 单次扫描的内存大小       | `echo 256 > .../numa_balancing/scan_size_mb`         |

---

## 第三部分：调度器特性（Features）

### 3.1 EEVDF/CFS 核心调度

#### RUN_TO_PARITY

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | true                                                         |
| **功能说明** | EEVDF 调度器的"切片保护（slice protection）"机制。当一个任务被调度选中后，保证它至少运行完自己的时间片（通常直到 deadline）才重新调度，防止频繁抢占 |
| **关键代码** | `fair.c:set_protect_slice()` — `if (sched_feat(RUN_TO_PARITY)) slice = cfs_rq_min_slice(cfs_rq);` |
| **开启优点** | 减少上下文切换、提高吞吐量、更好的缓存局部性、适合批处理/CPU密集型任务 |
| **关闭优点** | 更好的响应延迟、更公平的调度机会、适合交互式场景             |

---

#### RUN_TO_PARITY_WAKEUP

| 属性           | 说明                                                         |
| -------------- | ------------------------------------------------------------ |
| **默认值**     | true                                                         |
| **状态**       | ⚠️ **主线版本已废弃** — 该特性在主线中已不存在，相关逻辑由 RUN_TO_PARITY + PREEMPT_SHORT 实现 |
| **功能说明**   | 当带有正 lag 的任务被唤醒时，保护当前任务的 slice 不被过度抢占。正 lag 意味着任务"欠了"运行时间，其 vruntime 较小，可能导致当前任务过早变得 ineligible |
| **原关键代码** | `fair.c:__pick_eevdf()` — 当 current 任务还在保护期内，跳过 eligibility 检查 |
| **开启优点**   | 减少唤醒抢占、提高缓存局部性、更稳定的调度、适合 IO 密集型   |
| **关闭优点**   | 唤醒响应更快、更低的延迟                                     |

---

#### PREEMPT_SHORT

| 属性                        | 说明                                                         |
| --------------------------- | ------------------------------------------------------------ |
| **默认值**                  | true                                                         |
| **依赖关系**                | 与 RUN_TO_PARITY 配合使用                                    |
| **功能说明**                | 允许具有更短 slice 的唤醒任务取消当前任务的 RUN_TO_PARITY 保护，实现短任务的快速抢占。解决"长任务保护过久导致短任务响应慢"的问题 |
| **关键代码**                | `fair.c:wakeup_preempt_fair()` — `if (sched_feat(PREEMPT_SHORT) && (pse->slice < se->slice)) { preempt_action = PREEMPT_WAKEUP_SHORT; goto pick; }` |
| **与 RUN_TO_PARITY 的配合** | RUN_TO_PARITY 开 + PREEMPT_SHORT 开：当前任务受保护，但短 slice 任务可抢占；RUN_TO_PARITY 开 + PREEMPT_SHORT 关：当前任务完全受保护；RUN_TO_PARITY 关：无保护，按 EEVDF 正常调度 |
| **开启优点**                | 短任务快速响应、降低交互延迟、适合微服务/桌面交互            |
| **关闭优点**                | 稳定吞吐、减少上下文切换、适合批处理/编译服务器              |

---

#### PLACE_LAG

| 属性              | 说明                                                         |
| ----------------- | ------------------------------------------------------------ |
| **默认值**        | true                                                         |
| **功能说明**      | EEVDF 调度器的核心放置策略，基于 "lag"（延迟差）计算任务的虚拟运行时间。lag = avg_vruntime(cfs_rq) - se->vruntime。正 lag 表示任务"欠了"运行时间应优先调度，负 lag 表示"多跑了"时间应等待 |
| **关键代码**      | `fair.c:place_entity()` — `if (sched_feat(PLACE_LAG) && cfs_rq->nr_queued && se->vlag) { lag = se->vlag; ... }` |
| **与 CFS 的区别** | 传统 CFS：基于 min_vruntime + 补偿，简单但不完全公平；EEVDF+PLACE_LAG：基于 avg_vruntime() 计算，精确保持 lag 守恒 |
| **开启优点**      | 睡眠/唤醒公平性（长睡眠任务醒来不获额外优势）、解决传统 CFS 的 sleep+wake 公平性缺陷 |
| **关闭缺点**      | 无法保证 EEVDF 核心机制，公平性下降                          |

---

#### PLACE_DEADLINE_INITIAL

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | true                                                         |
| **功能说明** | 新任务首次入队时（ENQUEUE_INITIAL），将初始时间片减半（vslice /= 2），使新任务更容易被选中运行。根据 EEVDF 公式 vd_i = ve_i + r_i/w_i，更小的 r_i 意味着更早的 deadline |
| **关键代码** | `fair.c:place_entity()` — `if (sched_feat(PLACE_DEADLINE_INITIAL) && (flags & ENQUEUE_INITIAL)) vslice /= 2;` |
| **开启优点** | 新任务快速响应、用户启动程序时立即看到效果、适合交互式场景   |
| **关闭缺点** | 新任务可能等待较久、启动响应慢                               |

---

#### PLACE_REL_DEADLINE

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | true                                                         |
| **功能说明** | 任务被迁移（migration）或调整权重等操作时，保持其相对虚拟截止时间不变。当任务因负载均衡而非睡眠被迁移时，保留其相对 deadline，维持延迟保证的连续性 |
| **关键代码** | `fair.c:dequeue_entity()` — `if (sched_feat(PLACE_REL_DEADLINE) && !sleep) { se->deadline -= se->vruntime; se->rel_deadline = 1; }` |
| **开启优点** | 迁移后公平性保持、延迟保证连续、避免因迁移造成的延迟不连续   |
| **关闭缺点** | 迁移后任务可能获得不公平的 deadline、EEVDF 延迟保证失效      |

---

#### DELAY_DEQUEUE

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | true                                                         |
| **配合特性** | DELAY_ZERO                                                   |
| **功能说明** | EEVDF 处理 sleep/wake 公平性的核心机制。当任务因 sleep 请求出队时，如果它不 eligible（有负 lag），不立即从运行队列移除，而是标记为 delayed dequeue，让其负 lag 在队列中继续随 rq 虚拟时间被动衰减，而非只保留为静态 vlag 快照 |
| **关键代码** | `fair.c:dequeue_entity()` — `if (sched_feat(DELAY_DEQUEUE) && delay && !entity_eligible(cfs_rq, se)) { set_delayed(se); return false; }` |
| **核心问题** | 解决”任务通过短暂 sleep 逃避负 lag”问题。如果立即出队，负 lag 只是静态保存；延迟出队则让负 lag 在队列中动态衰减 |
| **开启优点** | 完整的 sleep/wake 公平性，防止长时间睡眠任务被过度惩罚或过度优待 |

---

#### DELAY_ZERO

| 属性                      | 说明                                                         |
| ------------------------- | ------------------------------------------------------------ |
| **默认值**                | true                                                         |
| **配合特性**              | DELAY_DEQUEUE                                                |
| **功能说明**              | 当延迟任务最终被选中或唤醒时，如果其 vlag > 0（正 lag，欠了运行时间），将其裁剪为 0。防止任务积累过大的正 lag 优势，与 DELAY_DEQUEUE 配合形成完整的公平性保护 |
| **关键代码**              | `fair.c:finish_delayed_dequeue_entity()` — `if (sched_feat(DELAY_ZERO) && se->vlag > 0) se->vlag = 0;` |
| **与 DELAY_DEQUEUE 配合** | DELAY_DEQUEUE 开 + DELAY_ZERO 开 = 完美 lag 守恒；DELAY_DEQUEUE 开 + DELAY_ZERO 关 = 负 lag 消耗但正 lag 保留（可积累不公平优势）；DELAY_DEQUEUE 关 = 公平性无法保证 |
| **开启优点**              | 配合 DELAY_DEQUEUE 实现完整的 lag 守恒、防止过度补偿、周期性任务公平 |

---

### 3.2 唤醒优化类

#### NEXT_BUDDY

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | false                                                        |
| **功能说明** | 优先调度最近被唤醒的任务（cfs_rq->next）。在 pick_next_task_fair 中，如果设置了 next buddy 且 eligible，优先选择它 |
| **关键代码** | `fair.c:wakeup_preempt_fair()` — `if (sched_feat(NEXT_BUDDY) && set_preempt_buddy(cfs_rq, wake_flags, pse, se)) { ... }` |
| **开启优点** | 提高缓存局部性（刚唤醒任务可能使用刚访问数据）、减少唤醒延迟 |
| **关闭优点** | 更公平的调度、默认关闭是保守策略、保证吞吐                   |

---

#### CACHE_HOT_BUDDY

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | true                                                         |
| **功能说明** | 在负载均衡时，认为 buddy（next/prev）任务是缓存热的，减少将其迁移走的倾向。在 can_migrate_task 中，如果任务是 next buddy，认为其缓存热，返回 1 阻止迁移 |
| **关键代码** | `fair.c:can_migrate_task()` — `if (sched_feat(CACHE_HOT_BUDDY) && env->dst_rq->nr_running && (&p->se == cfs_rq_of(&p->se)->next)) return 1;` |
| **开启优点** | 保持缓存局部性、减少跨 CPU 缓存失效、CPU 密集型任务受益      |

---

#### PICK_BUDDY

| 属性                   | 说明                                                         |
| ---------------------- | ------------------------------------------------------------ |
| **默认值**             | true                                                         |
| **相关特性**           | NEXT_BUDDY（设置 buddy）、CACHE_HOT_BUDDY（保护 buddy）      |
| **功能说明**           | Buddy 机制的总开关，控制调度器是否优先选择 buddy 任务。Buddy 来源：NEXT_BUDDY 唤醒设置、yield_to_task() 主动让出、cgroup dequeue/pick 操作 |
| **关键代码**           | `fair.c:__pick_eevdf()` — `if (sched_feat(PICK_BUDDY) && cfs_rq->next && entity_eligible(cfs_rq, cfs_rq->next)) return cfs_rq->next;` |
| **与 NEXT_BUDDY 关系** | NEXT_BUDDY 控制"是否在唤醒时设置 buddy"，PICK_BUDDY 控制"是否优先选择 buddy"。两者配合：NEXT_BUDDY 设置 → PICK_BUDDY 选择 |
| **开启优点**           | 提升缓存性能、快速选择降低底噪（不遍历红黑树）、在生产者-消费者模式下相对更友好一些 |
| **关闭优点**           | 严格 EEVDF 选择（按 deadline）、完全公平、适合高公平性要求场景 |

---

#### WAKEUP_PREEMPTION

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | true                                                         |
| **功能说明** | 允许在唤醒时检查并执行抢占的总开关。关闭则唤醒不会触发抢占检查 |
| **关键代码** | `fair.c:wakeup_preempt_fair()` — `if (!sched_feat(WAKEUP_PREEMPTION)) return;` — 关闭时直接返回，不执行抢占逻辑 |
| **开启优点** | 改善响应延迟、及时调度应该运行的任务、刚唤醒的高优先级任务可抢占 |
| **关闭危害** | 唤醒不会触发抢占、虽然可提升吞吐，但会明显影响高优先级任务的响应时延 |

---

#### TTWU_QUEUE

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | true (非RT) / false (PREEMPT_RT)                             |
| **功能说明** | 使用 wake list + IPI 而非直接唤醒远程 CPU 任务。将 wakeup 请求放入目标 CPU 的队列，通过 IPI 在目标 CPU 上处理，避免跨 CPU 直接操作 rq->lock |
| **关键代码** | `core.c:ttwu_queue_wakelist()` — `if (sched_feat(TTWU_QUEUE) && ttwu_queue_cond(p, cpu)) { __ttwu_queue_wakelist(p, cpu, wake_flags); return true; }` |
| **开启优点** | 减少锁竞争（避免多 CPU 竞争同一 rq->lock）、减少跨 CPU 缓存 bounce、提高高负载多核系统性能 |
| **关闭优点** | 减少唤醒延迟（需 IPI）                                       |

---

### 3.3 负载均衡类

#### SIS_PROP

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | false                                                        |
| **状态**     | ⚠️ **主线已废弃** — 功能已被 SIS_UTIL 替代                    |
| **功能说明** | Select Idle CPU Search — 基于属性限制空闲 CPU 搜索范围。当没有 idle core 时，根据扫描成本动态调整搜索范围，防止在大型系统上过度扫描 |
| **开启优点** | 在大型系统上减少 select_idle_cpu 扫描时间、避免在多 CPU 系统扫描太久 |
| **关闭优点** | 可能找到更优 CPU、更完整负载均衡                             |

---

#### SIS_UTIL

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | true                                                         |
| **功能说明** | 基于 CPU 利用率（util_avg）之和来选择空闲 CPU。不使用简单的 CPU 计数，而是用 LLC domain 中所有 CPU 的 util_avg 之和评估空闲程度，选择负载最低的区域 |
| **关键代码** | `fair.c:select_idle_cpu()` — `if (sched_feat(SIS_UTIL)) { sd_share = rcu_dereference_all(per_cpu(sd_llc_shared, target)); if (sd_share) nr = READ_ONCE(sd_share->nr_idle_scan) + 1; }` |
| **开启优点** | 更准确的空闲 CPU 选择（考虑实际利用而非仅 idle 状态）、更好的负载分布、适合混合工作负载 |

---

#### STEAL

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | false                                                        |
| **状态**     | ⚠️ **hulk自研特性**                                           |
| **功能说明** | 当 CPU 空闲时（newidle），从过载的 CPU 偷取 CFS 任务，提高 CPU 利用率 |
| **开启优点** | 提高 CPU 利用率、更好的负载均衡、适合利用率敏感场景          |
| **开启缺点** | 可能影响缓存性能（偷来的任务缓存冷）                         |

---

#### LB_MIN

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | false                                                        |
| **功能说明** | 在负载均衡时，跳过负载非常小（< 16）的任务。迁移小任务的成本可能高于收益 |
| **关键代码** | `fair.c:detach_tasks()` — `if (sched_feat(LB_MIN) && load < 16 && !env->sd->nr_balance_failed) goto next;` |
| **开启优点** | 避免小任务迁移开销、减少不必要迁移                           |
| **关闭缺点** | 可能导致负载不均衡（小任务累积在一个 CPU 上）                |

---

#### ATTACH_AGE_LOAD

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | true                                                         |
| **功能说明** | 任务附加到新 cfs_rq 时立即更新其负载的 age，不跳过 age load 更新 |
| **关键代码** | `fair.c:attach_entity_cfs_rq()` — `update_load_avg(cfs_rq, se, sched_feat(ATTACH_AGE_LOAD) ? 0 : SKIP_AGE_LOAD);` |
| **开启优点** | 负载估计更准确（任务入队时立即更新）、更好的负载均衡决策（调度器有准确信息） |

---

#### ILB_COST_CHECKER

| 属性         | 说明                                             |
| ------------ | ------------------------------------------------ |
| **默认值**   | false                                            |
| **关键代码** | `fair.c:sched_balance_newidle()` — `if (sched_feat(ILB_COST_CHECKER)) {limit = sysctl_sched_migration_cost;} else {limit = sd->max_newidle_lb_cost;}` |
| **功能说明** | 控制 idle load balancer 使用默认可调的成本阈值或 sched_domain 阈值进行决策 |
| **用途**     | 调优 idle load balance 的触发条件                |

---

#### WA_IDLE, WA_WEIGHT, WA_BIAS

| 属性          | 默认值 | 关键代码                                                     | 功能说明                                                     |
| ------------- | ------ | ------------------------------------------------------------ | ------------------------------------------------------------ |
| **WA_IDLE**   | true   | `fair.c:wake_affine()` — `if (sched_feat(WA_IDLE)) target = wake_affine_idle(this_cpu, prev_cpu, sync);` | wake_affine 基于 idle CPU 决策，优先选择 idle CPU            |
| **WA_WEIGHT** | true   | `fair.c:wake_affine()` — `if (sched_feat(WA_WEIGHT) && target == nr_cpumask_bits) target = wake_affine_weight(sd, p, this_cpu, prev_cpu, sync);` | wake_affine 基于 CPU 负载权重决策，考虑任务权重和 CPU 负载   |
| **WA_BIAS**   | true   | `fair.c:wake_affine_weight()` — `if (sched_feat(WA_BIAS)) this_eff_load *= 100;` | wake_affine 偏向选择 waker CPU（当前 CPU），减少任务迁移     |
| **协同效果**  |        |                                                              | **分层决策，非互斥选择**：WA_IDLE 是第一优先级，有 idle 就选 idle；WA_WEIGHT 是第二优先级，没 idle 就比负载；WA_BIAS 是负载比较时的偏置，让 this_cpu 看起来更重，提高迁移门槛。WA_BIAS 并不是"什么时候执行"的问题，而是"执行 WA_WEIGHT 时是否带上这个偏置" |
| **开启优点**  |        |                                                              | 更好的任务放置（综合考虑多种因素）、减少任务迁移（倾向于当前 CPU） |

---

#### NI_RANDOM

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | true                                                         |
| **功能说明** | 使用随机化算法控制 newidle balance 触发频率。基于历史成功率（newidle_ratio）动态调整，通过 1024 面骰子决定是否执行。成功率高则更频繁执行，成功率低则减少无效扫描 |
| **关键代码** | `fair.c:sched_balance_newidle()` — `if (sched_feat(NI_RANDOM)) { u32 d1k = sched_rng() % 1024; weight = 1 + sd->newidle_ratio; if (d1k > weight) { update_newidle_stats(sd, 0); continue; } }` |
| **开启优点** | 有助于多核或众核模式下减少全局锁竞争、自适应成功率、节省 CPU（避免无效扫描）、NUMA 友好，但可能可能错过迁移机会、延迟增加（需等下次 newidle） |
| **关闭优点** | 每次 newidle 都尝试（更积极）、不错过任何机会、但开销增加    |

---

### 3.4 时间片与调度类

#### HRTICK / HRTICK_DL

| 属性          | 默认值 | 关键代码                                                     | 功能说明                                                     |
| ------------- | ------ | ------------------------------------------------------------ | ------------------------------------------------------------ |
| **HRTICK**    | false  | `sched.h:hrtick_enabled_fair()` — `if (!sched_feat(HRTICK)) return 0;` | 使用 hrtimer（高精度定时器）而非 tick 进行 CFS 调度          |
| **HRTICK_DL** | false  | `sched.h:hrtick_enabled_dl()` — `if (!sched_feat(HRTICK_DL)) return 0;` | 为 DEADLINE 调度器启用高精度 tick                            |
| **开启优点**  |        |                                                              | 更精确的调度时间（不受 tick 粒度限制）、精确控制任务切换时机、减少不必要唤醒 |
| **开启缺点**  |        |                                                              | 增加功耗（hrtimer 比 tick 耗电）、需要硬件支持               |

---

#### UTIL_EST

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | true                                                         |
| **状态**     | ⚠️ **主线版本已废弃**，功能合并到 UTIL_EST                    |
| **功能说明** | 在 PELT 基础上增加 util_est 估计值。PELT 的 util_avg 会快速衰减导致睡眠任务负载被低估，UTIL_EST 记录未衰减的峰值估计，保持负载估计准确性 |
| **关键代码** | `fair.c:util_est_enqueue()` — `if (!sched_feat(UTIL_EST)) return; enqueued = cfs_rq->avg.util_est; enqueued += _task_util_est(p); WRITE_ONCE(cfs_rq->avg.util_est, enqueued);` |
| **开启优点** | 更准确的负载估计（睡眠任务不被低估）、更快的利用率响应、更好的负载均衡决策、适合突发工作负载 |

---

### 3.5 实时性优化类

#### RT_PUSH_IPI

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | true (有 HAVE_RT_PUSH_IPI)                                   |
| **关键代码** | `rt.c:push_rt_tasks()` — `if (sched_feat(RT_PUSH_IPI)) { tell_cpu_to_push(this_rq); return; }` |
| **功能说明** | 当高优先级 RT 任务需要运行时，使用 IPI 通知目标 CPU 推送任务，而非让其他 CPU 来 pull。避免 thundering herd 问题 |
| **开启优点** | 减少锁竞争、更快的 RT 响应（推送比拉取快）、避免多 CPU 同时竞争 |

---

#### RT_RUNTIME_SHARE

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | false                                                        |
| **关键代码** | `rt.c:balance_runtime()` — `if (!sched_feat(RT_RUNTIME_SHARE)) return;` |
| **功能说明** | 允许 RT 运行时配额跨 CPU 共享。一个 CPU 的 RT 配额可以借给其他 CPU |
| **开启优点** | 更灵活（配额可借用）、充分利用 RT 时间                       |
| **关闭优点** | 更可预测（每个 CPU 配额独立）、更确定性、适合严格 RT 要求    |

---

#### NONTASK_CAPACITY

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | true                                                         |
| **关键代码** | `core.c:update_rq_clock_task()` — `if ((irq_delta + steal) && sched_feat(NONTASK_CAPACITY)) update_irq_load_avg(rq, irq_delta + steal);` |
| **功能说明** | 计算 CPU 容量时，排除非任务时间（中断、软中断等）。CPU 容量 = 实际可用于任务的容量，而非理论容量 |
| **开启优点** | 更准确的容量估计（CPU 容量考虑 IRQ 使用）、更好的负载均衡（不会将任务迁移到 IRQ 重的 CPU） |

---

### 3.6 调试与告警类

#### WARN_DOUBLE_CLOCK

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | false                                                        |
| **关键代码** | `core.c:update_rq_clock()` — `if (sched_feat(WARN_DOUBLE_CLOCK)) WARN_ON_ONCE(rq->clock_update_flags & RQCF_UPDATED);` |
| **功能说明** | 检测单次 rq->lock 区间内重复调用 `update_rq_clock()`，发出 WARN 警告 |
| **用途**     | 调试用，帮助发现调度器代码中的 clock 更新问题，仅调试时开启，生产环境关闭 |

---

#### LATENCY_WARN

| 属性         | 说明                                                         |
| ------------ | ------------------------------------------------------------ |
| **默认值**   | false                                                        |
| **关键代码** | `core.c:scheduler_tick()` — `if (sched_feat(LATENCY_WARN)) resched_latency = cpu_resched_latency(rq);` |
| **功能说明** | 当 need_resched 设置后超过阈值时间仍未调度时打印告警。配合 `/sys/kernel/debug/sched/latency_warn_ms` 设置阈值（默认 100ms） |
| **用途**     | 监控调度延迟，发现系统响应问题，调试/监控用，需要时可开启。相关参数：`latency_warn_ms`、`latency_warn_once` |

---

## 第四部分：特性组合效应分析

以下分析多个特性组合使用时产生的协同效果，帮助理解为什么某些特性需要配合使用。

> **实践说明**：本节组合基于真实生产环境调优经验提炼，针对 Linux 6.6 内核升级后的常见问题提供解决方案。

### 4.1 内核升级恢复组合（ILB_COST_CHECKER + migration_cost_ns）

> **关键场景**：解决 Linux 6.6 内核升级后 CPU 利用率异常升高的问题

**背景问题：**

Linux 6.6 内核提交 `c5b0a7eefc70` 移除了 `newidle_balance` 中的 `sysctl_sched_migration_cost` 条件检查，导致：

- `newidle_balance` 执行更频繁
- CPU 利用率相比旧内核上升
- 调度开销增加

**组合特性：**

| 特性/参数         | 配置          | 说明                                             |
| ----------------- | ------------- | ------------------------------------------------ |
| ILB_COST_CHECKER  | 开启          | 恢复 migration_cost 条件检查（需要内核补丁支持） |
| migration_cost_ns | 1000000 (1ms) | 提高 newidle_balance 触发门槛                    |

**组合效果：**

- ILB_COST_CHECKER：恢复 `avg_idle < migration_cost_ns` 条件检查
- migration_cost_ns：提高触发门槛，减少无效的负载均衡扫描
- 双重条件确保只在预期空闲时间足够长时才执行 newidle balance

**协同原理：**

```
newidle_balance 触发条件：
┌─────────────────────────────────────────────────────────┐
│  6.6内核之前：                                           │
│    if (avg_idle < migration_cost_ns) skip_balance;      │
│                                                         │
│  6.6内核移除后：                                         │
│    // 无条件执行 newidle_balance                         │
│                                                         │
│  开启 ILB_COST_CHECKER + migration_cost_ns=1ms：        │
│    if (avg_idle < 1ms) skip_balance;  // 恢复条件检查   │
│    → 减少不必要的负载均衡扫描                            │
│    → CPU 利用率恢复到旧内核水平                          │
└─────────────────────────────────────────────────────────┘
```

**适用场景：** 内核从 5.x 升级到 6.6+ 后 CPU 利用率异常

**配置示例：**

```bash
# 方式1：通过特性开关（需要内核补丁支持）
echo ILB_COST_CHECKER > /sys/kernel/debug/sched/features

# 方式2：调整 migration_cost_ns（适用于所有 6.6+ 内核）
echo 1000000 > /sys/kernel/debug/sched/migration_cost_ns
```

---

### 4.2 吞吐优先组合（大 base_slice_ns + NO_PREEMPT_SHORT）

> **关键场景**：数据面服务、批处理服务器等吞吐敏感型业务

**组合特性：**

| 特性/参数        | 配置                        | 说明               |
| ---------------- | --------------------------- | ------------------ |
| base_slice_ns    | 15000000-20000000 (15-20ms) | 大时间片减少切换   |
| NO_PREEMPT_SHORT | 开启                        | 禁用短任务抢占保护 |
| ILB_COST_CHECKER | 开启                        | 减少负载均衡干扰   |

**组合效果：**

- 大时间片：任务连续运行时间更长，缓存局部性更好
- 禁用短任务抢占：当前任务不受唤醒的短任务干扰
- 减少负载均衡：任务留在当前 CPU，减少迁移开销

**协同原理：**

```
吞吐优先调度流程：
┌─────────────────────────────────────────────────────────┐
│  任务A正在运行，slice = 20ms                             │
│                                                         │
│  PREEMPT_SHORT=off 时：                                 │
│    短任务B唤醒 → 不能抢占A → A继续运行完slice            │
│    → 减少上下文切换                                      │
│    → 提高吞吐量                                          │
│                                                         │
│  PREEMPT_SHORT=on 时：                                  │
│    短任务B唤醒 → B的slice < A的slice → B可以抢占A        │
│    → 增加上下文切换                                      │
│    → 降低吞吐量（但提高响应速度）                         │
└─────────────────────────────────────────────────────────┘
```

**适用场景：** 数据面转发、批处理服务器、科学计算

**配置示例：**

```bash
# 吞吐优先配置
echo 20000000 > /sys/kernel/debug/sched/base_slice_ns
echo NO_PREEMPT_SHORT > /sys/kernel/debug/sched/features
echo 1000000 > /sys/kernel/debug/sched/migration_cost_ns
```

---

### 4.3 负载均衡抑制组合（ILB_COST_CHECKER + interval调整）

> **关键场景**：稳定负载的策略处理服务、控制面服务

**组合特性：**

| 参数              | 配置路径             | 推荐值    | 说明         |
| ----------------- | -------------------- | --------- | ------------ |
| ILB_COST_CHECKER  | features             | 开启      | 条件检查     |
| migration_cost_ns | debugfs              | 1000000   | 迁移门槛     |
| min_interval      | domain*/min_interval | 增大2-3倍 | 减少空闲均衡 |
| max_interval      | domain*/max_interval | 增大2-3倍 | 减少忙时均衡 |
| busy_factor       | domain*/busy_factor  | 32        | 忙时间隔延长 |

**组合效果：**

- newidle 时：通过 ILB_COST_CHECKER + migration_cost_ns 控制触发
- 周期性均衡：通过增大 interval 减少频率
- 忙时均衡：通过 busy_factor 延长间隔

**协同原理：**

```
负载均衡抑制流程：
┌─────────────────────────────────────────────────────────┐
│  1. newidle balance 触发检查：                          │
│     avg_idle < migration_cost_ns(1ms) → 跳过            │
│                                                         │
│  2. 周期性 balance 频率：                               │
│     interval = clamp(min_interval, ..., max_interval)   │
│     增大 min_interval → 减少均衡次数                     │
│                                                         │
│  3. 忙时均衡间隔：                                       │
│     interval *= busy_factor                             │
│     busy_factor=32 → 间隔延长2倍                         │
│                                                         │
│  综合效果：全面降低调度开销                              │
└─────────────────────────────────────────────────────────┘
```

**适用场景：** 策略处理服务、稳定负载的控制面服务

**配置示例：**

```bash
# 负载均衡抑制配置
echo 1000000 > /sys/kernel/debug/sched/migration_cost_ns

# 需要先开启 verbose 查看调度域
echo Y > /sys/kernel/debug/sched/verbose

# 调整调度域参数（示例：domain0）
echo 64 > /sys/kernel/debug/sched/domains/cpu0/domain0/min_interval
echo 128 > /sys/kernel/debug/sched/domains/cpu0/domain0/max_interval
echo 32 > /sys/kernel/debug/sched/domains/cpu0/domain0/busy_factor
```

---

### 4.4 完整EEVDF公平性组合（PLACE_LAG + DELAY_DEQUEUE + DELAY_ZERO）

> **关键场景**：所有生产环境，防止 sleep+wake 攻击

**组合特性：** PLACE_LAG + DELAY_DEQUEUE + DELAY_ZERO

**组合效果：**

- PLACE_LAG：使用 avg_vruntime 计算初始放置位置，保持 lag
- DELAY_DEQUEUE：延迟负 lag 任务出队，让其消耗 lag
- DELAY_ZERO：裁剪正 lag，防止积累不公平优势

**协同原理：**

```
任务生命周期 lag 处理：
1. 入队时：PLACE_LAG 根据 lag 调整 vruntime
2. 运行时：lag 随时间变化
3. 睡眠时：DELAY_DEQUEUE 处理负 lag（留在队列消耗）
4. 唤醒时：DELAY_ZERO 处理正 lag（裁剪防止过度优势）
```

**适用场景：** 所有场景，强烈推荐全部开启

---

### 4.5 短任务快速响应组合（PREEMPT_SHORT + WAKEUP_PREEMPTION + NEXT_BUDDY）

> **关键场景**：会话管理服务、链式访问服务等时延敏感型业务

**组合特性：** PREEMPT_SHORT + WAKEUP_PREEMPTION + NEXT_BUDDY

**组合效果：**

- PREEMPT_SHORT：允许短 slice 任务绕过 RUN_TO_PARITY 保护
- WAKEUP_PREEMPTION：唤醒时允许抢占
- NEXT_BUDDY：优先调度刚唤醒的任务

**协同原理：**

```
唤醒抢占流程：
1. WAKEUP_PREEMPTION 启用唤醒抢占检查
2. PREEMPT_SHORT 判断唤醒任务 slice 是否更短
3. 如果更短，绕过当前任务的 slice 保护
4. NEXT_BUDDY 标记唤醒任务为下次优先选择
```

**适用场景：** 会话管理服务、链式访问服务、低延迟服务

---

### 4.6 缓存优先调度组合（PICK_BUDDY + CACHE_HOT_BUDDY）

> **关键场景**：计算密集型、缓存敏感应用

**组合特性：** PICK_BUDDY + CACHE_HOT_BUDDY

**组合效果：**

- PICK_BUDDY：优先选择 buddy 任务
- CACHE_HOT_BUDDY：负载均衡时保护缓存热的 buddy

**协同原理：**

```
缓存保护流程：
1. 唤醒时设置任务为 buddy
2. 选择任务时 PICK_BUDDY 优先选择 buddy（缓存可能还热）
3. 负载均衡时 CACHE_HOT_BUDDY 减少迁移 buddy
```

**适用场景：** CPU 密集型、缓存敏感应用

---

### 4.7 大系统自适应组合（NI_RANDOM + SIS_UTIL + TTWU_QUEUE）

> **关键场景**：64+ CPU 大型系统、云原生环境

**组合特性：** NI_RANDOM + SIS_UTIL + TTWU_QUEUE

**组合效果：**

- NI_RANDOM：随机化控制 newidle balance 频率
- SIS_UTIL：基于利用率选择空闲 CPU
- TTWU_QUEUE：使用 IPI 队列远程唤醒

**协同原理：**

```
大规模系统优化：
1. TTWU_QUEUE 减少 rq->lock 竞争（避免跨 CPU 直接操作）
2. SIS_UTIL 基于实际利用率而非简单计数选择 CPU
3. NI_RANDOM 自适应控制 newidle balance 触发频率
```

**适用场景：** 64+ CPU 大型系统、云原生环境

---

## 第五部分：故障排查决策树

> **说明**：本节基于真实生产环境问题排查经验，针对 Linux 6.6 内核升级后的常见问题提供排查流程。

### 5.1 内核升级后 CPU 利用率劣化

> **关键场景**：内核从 5.x 升级到 6.6+ 后 CPU 利用率异常升高

```
问题：内核升级后 CPU 利用率异常升高
│
├─ 步骤1：确认内核版本
│   ├─ 6.6 及以上 → 可能是 newidle balance 问题
│   └─ 6.5 及以下 → 检查其他原因
│
├─ 步骤2：检查 newidle balance 频率
│   │
│   ├─ 查看负载均衡统计：
│   │   cat /proc/schedstat | grep -E "cpu[0-9]+"
│   │   # 重点关注 newidle 相关字段
│   │
│   └─ 使用 perf 追踪：
│       perf stat -e sched:sched_load_balance -a sleep 10
│
├─ 步骤3：检查 migration_cost_ns
│   │
│   ├─ 查看当前值：
│   │   cat /sys/kernel/debug/sched/migration_cost_ns
│   │
│   ├─ 如果 < 500000 → 增大到 1ms
│   │   echo 1000000 > /sys/kernel/debug/sched/migration_cost_ns
│   │
│   └─ 如果有 ILB_COST_CHECKER 特性 → 确认开启
│       echo ILB_COST_CHECKER > /sys/kernel/debug/sched/features
│
├─ 步骤4：检查 avg_idle 与 max_idle_balance_cost
│   │
│   ├─ 查看各 CPU 的 avg_idle：
│   │   cat /sys/kernel/debug/sched/debug | grep avg_idle
│   │
│   └─ 比较 avg_idle 与 migration_cost
│       如果 avg_idle 经常 < migration_cost → 正常跳过
│       如果仍频繁执行 → 需要调整阈值
│
└─ 步骤5：调整调度域参数
    │
    ├─ 增大 min_interval/max_interval：
    │   echo 64 > /sys/kernel/debug/sched/domains/cpu0/domain0/min_interval
    │   echo 128 > /sys/kernel/debug/sched/domains/cpu0/domain0/max_interval
    │
    └─ 增大 busy_factor：
        echo 32 > /sys/kernel/debug/sched/domains/cpu0/domain0/busy_factor
```

**验证命令：**

```bash
# 观察调整前后效果
watch -n 1 "cat /proc/schedstat | head -4"

# 持续监控负载均衡
perf record -e sched:sched_load_balance -a sleep 30
perf report

# 观察 CPU 利用率变化
mpstat -P ALL 1 10
```

---

### 5.2 上下文切换过于频繁

> **关键场景**：上下文切换率异常高（>10000/s/core）

```
问题：上下文切换率异常高
│
├─ 步骤1：确认上下文切换频率
│   │
│   ├─ 全局统计：
│   │   cat /proc/stat | grep ctxt
│   │
│   ├─ 每进程统计：
│   │   pidstat -w 1
│   │
│   └─ 使用 perf：
│       perf stat -e context-switches -a sleep 10
│
├─ 步骤2：分析切换原因
│   │
│   ├─ 抢占导致：
│   │   perf trace -e sched:sched_switch --filter "prev_state == R"
│   │
│   ├─ 休眠导致：
│   │   perf trace -e sched:sched_switch --filter "prev_state == S"
│   │
│   └─ 时间片耗尽：
│       检查 base_slice_ns 是否过小
│
├─ 步骤3：检查时间片配置
│   │
│   ├─ 查看当前值：
│   │   cat /sys/kernel/debug/sched/base_slice_ns
│   │
│   └─ 如果 < 1000000 → 增大
│       echo 3000000 > /sys/kernel/debug/sched/base_slice_ns
│
├─ 步骤4：检查 PREEMPT_SHORT
│   │
│   ├─ 查看状态：
│   │   cat /sys/kernel/debug/sched/features | grep PREEMPT_SHORT
│   │
│   └─ 如果开启且非必要 → 关闭
│       echo NO_PREEMPT_SHORT > /sys/kernel/debug/sched/features
│
├─ 步骤5：检查唤醒抢占
│   │
│   ├─ 查看 WAKEUP_PREEMPTION：
│   │   cat /sys/kernel/debug/sched/features | grep WAKEUP_PREEMPTION
│   │
│   └─ 查看唤醒频率：
│       perf stat -e sched:sched_wakeup -a sleep 10
│
└─ 步骤6：检查负载均衡导致
    │
    ├─ 过度均衡可能导致任务迁移 → 增加切换
    │
    └─ 调整迁移成本：
        echo 1000000 > /sys/kernel/debug/sched/migration_cost_ns
```

**验证命令：**

```bash
# 持续监控上下文切换
watch -n 1 "grep ctxt /proc/stat"

# 分析高切换进程
pidstat -w -p ALL 1 10 | sort -k 5 -rn | head -20

# 观察调度器事件
perf record -e 'sched:*' -a sleep 10
perf report
```

---

### 5.3 响应延迟过高

```
问题：响应延迟过高（P99 > 100ms）
│
├─ 步骤1：确认延迟来源
│   │
│   ├─ 应用层延迟：
│   │   应用日志/trace
│   │
│   ├─ 调度延迟：
│   │   perf trace -e sched:sched_switch -p <pid>
│   │
│   └─ 系统整体延迟：
│       cat /proc/pressure/cpu
│
├─ 步骤2：检查 base_slice_ns
│   │
│   ├─ 查看：
│   │   cat /sys/kernel/debug/sched/base_slice_ns
│   │
│   └─ 如果 > 5000000 → 减小
│       echo 1500000 > /sys/kernel/debug/sched/base_slice_ns
│
├─ 步骤3：检查 PREEMPT_SHORT
│   │
│   ├─ 如果关闭 → 开启
│   │   echo PREEMPT_SHORT > /sys/kernel/debug/sched/features
│   │
│   └─ 配合 RUN_TO_PARITY 检查
│       cat /sys/kernel/debug/sched/features | grep RUN_TO_PARITY
│
├─ 步骤4：检查系统负载
│   │
│   ├─ CPU 压力：
│   │   cat /proc/pressure/cpu
│   │
│   ├─ 运行队列深度：
│   │   cat /proc/loadavg
│   │
│   └─ 各 CPU 负载：
│       mpstat -P ALL 1
│
├─ 步骤5：检查 NUMA 配置
│   │
│   ├─ NUMA 命中/未命中：
│   │   numastat -m
│   │
│   └─ 跨 NUMA 迁移：
│       perf stat -e numa:* -a sleep 10
│
└─ 步骤6：检查实时任务干扰
    │
    ├─ 查看 RT 任务：
    │   ps -eLo pid,tid,class,rtprio,comm | grep RR
    │
    └─ RT 带宽配置：
        cat /proc/sys/kernel/sched_rt_runtime_us
```

**验证命令：**

```bash
# 测量调度延迟
perf sched record -- sleep 60
perf sched latency

# 监控进程等待时间
perf trace -e sched:sched_switch -p <pid> sleep 30
```

---

### 5.4 吞吐量不足

```
问题：吞吐量低于预期
│
├─ 步骤1：确认吞吐瓶颈
│   │
│   ├─ CPU 利用率：
│   │   mpstat -P ALL 1
│   │
│   ├─ I/O 瓶颈：
│   │   iostat -x 1
│   │
│   └─ 内存瓶颈：
│       vmstat 1
│
├─ 步骤2：检查上下文切换率
│   │
│   ├─ 如果过高(>10000/s/core)：
│   │   → 参见 6.2 上下文切换过于频繁
│   │
│   └─ 如果正常 → 继续检查调度参数
│
├─ 步骤3：检查 base_slice_ns
│   │
│   ├─ 查看：
│   │   cat /sys/kernel/debug/sched/base_slice_ns
│   │
│   └─ 如果 < 1000000 → 增大
│       echo 10000000 > /sys/kernel/debug/sched/base_slice_ns
│
├─ 步骤4：检查 migration_cost_ns
│   │
│   ├─ 查看：
│   │   cat /sys/kernel/debug/sched/migration_cost_ns
│   │
│   └─ 如果过小 → 增大到 1-2ms
│       echo 1000000 > /sys/kernel/debug/sched/migration_cost_ns
│
├─ 步骤5：检查 PREEMPT_SHORT
│   │
│   ├─ 如果开启且非交互式场景 → 关闭
│   │   echo NO_PREEMPT_SHORT > /sys/kernel/debug/sched/features
│   │
│   └─ 保留 RUN_TO_PARITY 保护
│
├─ 步骤6：检查缓存命中率
│   │
│   └─ 使用 perf：
│       perf stat -e cache-references,cache-misses <workload>
│
└─ 步骤7：检查负载均衡开销
    │
    ├─ 观察均衡频率：
    │   perf stat -e sched:sched_load_balance -a sleep 10
    │
    └─ 如果过高 → 调整 interval 参数
        echo 128 > /sys/kernel/debug/sched/domains/cpu0/domain0/max_interval
```

**验证命令：**

```bash
# 综合性能分析
perf stat -e cycles,instructions,cache-misses,context-switches <workload>

# 查看调度统计
cat /proc/schedstat

# 监控吞吐变化
while true; do
    echo "$(date): $(your_throughput_metric)"
    sleep 1
done
```

---

### 5.5 公平性异常

```
问题：某些任务获得过多/过少 CPU 时间
│
├─ 步骤1：确认公平性问题
│   │
│   ├─ 查看各任务 CPU 时间：
│   │   pidstat -p ALL 1
│   │
│   └─ 查看 vruntime 分布：
│       cat /sys/kernel/debug/sched/debug | grep vruntime
│
├─ 步骤2：检查 DELAY_DEQUEUE
│   │
│   ├─ 查看：
│   │   cat /sys/kernel/debug/sched/features | grep DELAY_DEQUEUE
│   │
│   └─ 如果关闭 → 开启
│       echo DELAY_DEQUEUE > /sys/kernel/debug/sched/features
│
├─ 步骤3：检查 DELAY_ZERO
│   │
│   ├─ 查看：
│   │   cat /sys/kernel/debug/sched/features | grep DELAY_ZERO
│   │
│   └─ 如果关闭 → 开启
│       echo DELAY_ZERO > /sys/kernel/debug/sched/features
│
├─ 步骤4：检查 PLACE_LAG
│   │
│   ├─ 查看：
│   │   cat /sys/kernel/debug/sched/features | grep PLACE_LAG
│   │
│   └─ 如果关闭 → 开启
│       echo PLACE_LAG > /sys/kernel/debug/sched/features
│
├─ 步骤5：分析任务 sleep+wake 模式
│   │
│   └─ 使用 perf 追踪：
│       perf trace -e sched:sched_switch,sched:sched_wakeup -p <pid>
│
└─ 步骤6：检查 nice 值和权重
    │
    ├─ 查看进程优先级：
    │   ps -eo pid,tid,nice,pri,comm
    │
    └─ 检查 cgroup 配置：
        cat /sys/fs/cgroup/<group>/cpu.shares
```

---

### 5.6 负载不均衡

```
问题：某些 CPU 过载，其他空闲
│
├─ 步骤1：确认负载分布
│   │
│   ├─ 各 CPU 利用率：
│   │   mpstat -P ALL 1
│   │
│   └─ 运行队列分布：
│       cat /proc/schedstat | awk '{print "cpu"$1": nr_running="$3}'
│
├─ 步骤2：检查系统规模
│   │
│   ├─ 大型系统(64+ CPU)：
│   │   → 确保 NI_RANDOM 开启
│   │   → 确保 SIS_UTIL 开启
│   │   → 确保 TTWU_QUEUE 开启
│   │
│   └─ 小型系统：
│       → 可关闭 NI_RANDOM 提高均衡积极性
│
├─ 步骤3：检查 migration_cost_ns
│   │
│   ├─ 查看：
│   │   cat /sys/kernel/debug/sched/migration_cost_ns
│   │
│   └─ 如果过大 → 减小，允许更多迁移
│       echo 500000 > /sys/kernel/debug/sched/migration_cost_ns
│
├─ 步骤4：检查 SIS_UTIL
│   │
│   ├─ 查看：
│   │   cat /sys/kernel/debug/sched/features | grep SIS_UTIL
│   │
│   └─ 如果关闭 → 开启
│       echo SIS_UTIL > /sys/kernel/debug/sched/features
│
├─ 步骤5：检查调度域配置
│   │
│   ├─ 查看调度域：
│   │   cat /sys/kernel/debug/sched/debug | grep -A 20 "domain"
│   │
│   └─ 调整 interval：
│       echo 16 > /sys/kernel/debug/sched/domains/cpu0/domain0/min_interval
│       echo 32 > /sys/kernel/debug/sched/domains/cpu0/domain0/max_interval
│
└─ 步骤6：检查 CPU 亲和性绑定
    │
    ├─ 查看进程绑定：
    │   taskset -pc <pid>
    │
    └─ 检查 cpuset 配置：
        cat /sys/fs/cgroup/cpuset/<group>/cpus
```

**验证命令：**

```bash
# 持续监控负载分布
watch -n 1 "mpstat -P ALL 1 1"

# 查看调度统计
cat /proc/schedstat | grep -E "cpu[0-9]+"

# 观察任务迁移
perf trace -e sched:sched_migrate_task -a sleep 10
```

---

## 附录A：特性开关操作方法

### 查看当前特性

```bash
cat /sys/kernel/debug/sched/features
```

### 修改特性

```bash
# 开启特性
echo RUN_TO_PARITY > /sys/kernel/debug/sched/features

# 关闭特性
echo NO_RUN_TO_PARITY > /sys/kernel/debug/sched/features
```

### 常用调试命令

```bash
# 查看调度器状态
cat /sys/kernel/debug/sched/debug

# 查看当前时间片
cat /sys/kernel/debug/sched/base_slice_ns

# 查看迁移成本
cat /sys/kernel/debug/sched/migration_cost_ns
```