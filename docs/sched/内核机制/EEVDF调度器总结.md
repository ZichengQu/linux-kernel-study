# EEVDF 概述

若想仔细了解EEVDF，最好结合源码（`kernel/sched/fair.c`）和参考资料，同步理解。

个人理解，可能存在误区。

---

## 全称：

**Earliest Eligible Virtual Deadline First**

---

## 核心思想：

从 CFS 就绪队列 (cfs_rq) 中选择下一个调度实体 (se) 时，需满足：

* 从所有 **有资格运行 (eligible)** 的 se 中
* 选择 **虚拟截止时间 (virtual deadline)** 距离当前时刻最近的 se

注：eligible 和 virtual deadline 的具体定义将在下文说明。

---

## 引入 EEVDF 的原因

### 解决 CFS 的局限性：

对延迟敏感型任务（短时运行、需快速响应但无需大时间片），若配置低 nice 值（高权重）：

* 因运行时间短，其 vruntime 相对落后
* 导致调度频率升高，但实际无法用完分配的时间片

### 关键矛盾：

降低 nice 值仅能因 vruntime 相对落后，而提高相对调度频率，无法保证选择性快速响应。

### 替代方案及不足性：

* 使用实时任务 (RT) 压制 CFS 任务，但需 root 权限修改优先级

### EEVDF 定位：

在 RT 和 CFS 之间提供更灵活的响应机制，其响应能力介于 RT 和 CFS 之间。

---

## 核心概念：lag & vlag

### 定义：

```txt
lag_i = S - s_i = w_i * (V - v_i) = w_i * V - w_i * v_i
```

* S：进程应获得的真实时间
* s_i：进程已使用的真实时间
* w_i：进程权重
* V：进程应获得的虚拟时间
* v_i：进程已使用的虚拟时间

```txt
vlag_i = lag_i / w_i（虚拟时间差）
```

### 思考点：为何 s_i = w_i * v_i？

答：因 CFS 通过权重将真实时间转换为虚拟时间，确保公平性。公式 s_i = w_i * v_i 体现了权重对时间分配的缩放作用。更多参考可结合 CFS 相关原理，本文仅针对 EEVDF，此处不展开。

---

## 核心概念：Virtual Deadline (vd_i)

### 定义：

```txt
vd_i = ve_i + r_i / w_i
```

* vd_i：调度实体的当前 deadline
* ve_i：调度实体的当前 vruntime
* w_i：调度实体的权重
* r_i：请求大小 (request_size)，反映进程对延迟的敏感度
* r_i 越小，对延迟越敏感

可以设置 nice 和 request size (可参考`常用示例的sched_setattr`），该request size与下文的se->slice完全等价。

---

## 核心概念：slice & vslice

### 定义：

```txt
slice：se->deadline = se->vruntime + calc_delta_fair(se->slice, se)
```

因此 slice 决定延迟敏感度，默认值 sysctl_sched_base_slice = 0.75ms（继承自 CFS 的最小调度粒度）

```txt
vslice：vslice = calc_delta_fair(se->slice, se)
```

### 个人思考：

因此其实 slice 现在决定了对时延的敏感程度，当前默认 slice 是 se->slice = sysctl_sched_base_slice = 0.75ms, 其实就是CFS中进程最小调度的时间粒度。
在 CFS 中存在调度周期的概念 sysctl_sched_latency (默认6ms)，即在该段时间内所有进程要调度一遍，但就绪和运行的进程数若>=8，那 sysctl_sched_latency = sysctl_sched_base_slice * nr = 0.75 * nr，该概念目前已在EEVDF中移除（猜测原因是EEVDF 不再依赖固定周期调度，转而基于虚拟截止时间动态决策，但未验证），但是 0.75ms 沿用到默认 slice。linux-mainline现已将 0.75ms 调整至 0.7ms，可参考 e9bed533ec80 ("sched: Reduce the default slice to avoid tasks getting an extra tick")

---

## 关键属性

### cfs_rq->min_vruntime

来源：cfs_rq 中所有 se 的最小 vruntime

维护方式：通过 update_curr() / update_curr() / enqueue() / dequeue() / reweight_entity() 等形式调用 update_min_vruntime()，并更新 cfs_rq->min_vruntime

比如来自于 cfs_rq->curr 或 cfs_rq 的 leftmost.vruntime (备注：该 leftmost 仅基于以 vruntime 排序的 rb-tree，当前 EEVDF 已采用 deadline 作为 rb-tree 的排序方式，因此 cfs_rq->min_vruntime 实际来自于 cfs_rq->curr 或 cfs_rq.root.min_vruntime，其中 root.min_vruntime 代表的是当前节点及其子树中，所有 se 的 vruntime 的最小值)

---

### cfs_rq->avg_load

实际含义：cfs_rq 队列上的所有 se 的总负载（虽然名称是 avg_load，但根据代码来看，其实并不是平均负载，而是总负载之和 Σ(w_i) => W）

---

### cfs_rq->avg_vruntime（为方便讲解，逻辑递进，因此部分描述有误，可暂时这样理解，下一点中会进行纠正）

初始理解：

```txt
cfs_rq->avg_vruntime = Σ(v_i * w_i) / W
```

实际问题：v_i * w_i 易溢出（v_i 为 u64，w_i 为 unsigned long，cfs_rq->avg_vruntime 为 s64）

解决方案：为避免溢出，每个 v_i，都减去一个常数 v0，至于这个常数 v0，其实就是 cfs_rq->min_vruntime：

```txt
cfs_rq->avg_vruntime = Σ(v_i * w_i) / Σ(w_i)
= Σ{[(v_i - v0) + v0] * w_i} / Σ(w_i)
= Σ[(v_i - v0) * w_i + v0 * w_i] / Σ(w_i)
= Σ[(v_i - v0) * w_i] / W + v0
```

avg_vruntime() 函数

作用：计算 cfs_rq 队列中（含 cfs_rq->curr）的 实际平均 avg_vruntime

---

### 针对cfs_rq->avg_vruntime中的纠正

基于上述步骤①②③中的推导（cfs_rq->min_vruntime、cfs_rq->avg_load、cfs_rq->avg_vruntime），与在代码中的实现稍有不同，代码中的各参数含义如下：

```txt
函数avg_vruntime() = Σ[(v_i - v0) * w_i] / W + v0
= (cfs_rq->avg_vruntime / cfs_rq->avg_load) + cfs_rq->min_vruntime
```

```txt
cfs_rq->avg_vruntime = Σ[(v_i - v0) * w_i]
cfs_rq->avg_load = Σ(w_i) = W
cfs_rq->min_vruntime = v0
```

```txt
// 仍然不准确，后面会再次修改
函数avg_vruntime() = Σ[(v_i - v0) * w_i] / W + v0
= (cfs_rq->avg_vruntime / cfs_rq->avg_load) + cfs_rq->min_vruntime
```

因此其实 cfs_rq->avg_vruntime 已经不是 cfs_rq 上真正的所有 se 的 vruntime 的权重加权平均值了，而仅仅是该值的一个计算因子，cfs_rq->min_vruntime、cfs_rq->avg_load、cfs_rq->avg_vruntime 共同计算得到该平均值 => 函数avg_vruntime()。

正在红黑树上的所有 se，有别于某 cpu（比如 cpu 1）对应的 cpu1_rq.cfs 的所有 se，还要额外包含 cfs_rq->curr，因为 cfs_rq->curr 并不在红黑树上，但curr->on_rq = 1。
因此某 cpu 对应的 cfs_rq 的所有 se 的 vruntime 的权重加权平均值，是通过：kernel/sched/fair.c : u64 avg_vruntime(struct cfs_rq *cfs_rq)，使用上述三个计算因子：cfs_rq->min_vruntime、cfs_rq->avg_load、cfs_rq->avg_vruntime，外加 cfs_rq->curr 的 load 和 vruntime 计算得到。
之所以外加 cfs_rq->curr 的 load.weight 和 vruntime，是因为 cfs_rq 中相关属性维护的信息中，并未记录 cfs_rq->curr 的值，因为 cfs_rq->curr 不在 cfs_rq 红黑树上，CFS 任务在入队和出队时，会根据对应 se 的值，更新 cfs_rq 上的相关值，因为 cfs_rq->curr 已经不在红黑树上（已出队），所以统计时，要再额外把 cfs_rq->curr 加回来。

// 这个才是真正的cfs_rq中包含的所有se（包括cfs_rq->curr）的avg_vruntime：
函数avg_vruntime() = Σ[(v_i - v0) * w_i] / W + v0 = (cfs_rq->avg_vruntime + cfs_rq->curr * cfs_rq->curr->load.weight / cfs_rq->avg_load) + cfs_rq->min_vruntime
为何需额外处理 cfs_rq->curr：
cfs_rq->curr 不在红黑树上，统计时需手动将其权重 load.weight 和 vruntime 加入计算。

avg_vruntime() 函数值变化，会因哪些场景导致：
如上所述，函数avg_vruntime() = Σ[(v_i - v0) * w_i] / W + v0 = (cfs_rq->avg_vruntime + cfs_rq->curr * cfs_rq->curr->load.weight / cfs_rq->avg_load) + cfs_rq->min_vruntime。
因此若 cfs_rq->avg_vruntime、cfs_rq->curr、cfs_rq->curr->load.weight、cfs_rq->avg_load 、cfs_rq->min_vruntime 发生变化，则会导致 函数avg_vruntime() 的值发生变化，同时 cfs_rq->avg_vruntime、cfs_rq->avg_load 分别受 se->vruntime、se->load.weight影响，cfs_rq->min_vruntime 又仅仅是被动变化的一个参数，因此影响因素可归纳为 se->vruntime、se->load.weight
因此影响场景为：
某个 se （包括 cfs_rq->curr）的 vruntime 更新时：可能会影响 cfs_rq->min_vruntime，进而影响 cfs_rq->avg_vruntime
某个 se（包括 cfs_rq->curr）对应的进程的 nice 值被改变时：除了会直接影响 cfs_rq->avg_load，也会重新计算 se->vruntime
runqueue 上 enqueue 或 dequeue 进程时

---

## 关键流程

---

### 入队 (enqueue_entity)

---

#### update_curr()

更新 cfs_rq->curr 的 vruntime 和 deadline（暂未深入研究原因），并通过 update_min_vruntime(), 基于：

```txt
max(min(cfs_rq->root->min_vruntime, cfs_rq->curr->vruntime), 
    cfs_rq->min_vruntime)
```

作为最新的 cfs_rq->min_vruntime（取 cfs_rq->curr 与红黑树最小节点的 min_vruntime 的较小值，再与 cfs_rq->min_vruntime 本身比较大小，取较大值，因为 cfs_rq->min_vruntime 单调递增）

因为 cfs_rq->min_vruntime 需要更新，因此导致 cfs_rq->ave_vruntime 也需要同步更新，原因是：

cfs_rq->min_vruntime 更新，会导致 函数ave_vruntime() 的计算结果发生变化，但此时目的只是调整 cfs_rq->min_vruntime（即v0），调整方式只相当于从 cfs_rq->ave_vruntime 抽取部分值加到 cfs_rq->min_vruntime（即v0）中。

因此需维护 函数ave_vruntime() 的计算结果不变，因此需基于 cfs_rq->min_vruntime（即v0），通过 avg_vruntime_update() 重新调整 cfs_rq->ave_vruntime （cfs_rq->avg_vruntime -= cfs_rq->avg_load * delta，delta 即 cfs_rq->min_vruntime 的增量，相当于 delta = 新cfs_rq->min_vruntime - 旧cfs_rq->min_vruntime）。

---

#### place_entity()

任务放置，目的是在真正加入到 cfs_rq 队列前，根据实际情况，改变该 se 的相关属性，如：se->vruntime 和 se->deadline 等。

不逐行阐述代码逻辑和公式推导，请结合源码自行了解，仅针对该函数中的几个关键点进行思考：

如果 se->vruntime 与 函数ave_vruntime() 差值过大，该 se 可能较长时间得不到调度，或者一直在调度，导致其他任务的调度受到较大的影响。

比如一个 se 睡眠了很久，那它的 vruntime 可能很小，如果直接加入 cfs_rq，可能会导致被频繁调度或更具有调度倾向，压制其他 se 的调度。

没有使用 se 原本的 vruntime，而是基于最新的 函数ave_vruntime() 并添加一定的滞后补偿。

---

#### 滞后补偿的计算方式：

基于 se 原本的 vlag，根据要加入的 cfs_rq 的队列，按权重 （se->load.weight）进行缩放，目标是保持相对 vruntime 不变：

```txt
se->vruntime = 函数ave_vruntime() - vlag
```

计算 vlag 的过程思路：

se->vlag 之前在其它 cfs_rq 队列出队时被更新，代表的是在其它 cfs_rq 队列上的虚拟时间之差。试想从一个加入新的 cfs_rq 队列时，为了维护该 se 的“vlag购买力”不变，该如何做？

试想一个 se 的 vlag 是绝对值，当它新加入到某个队列时，应该根据权重（se->load.weight）对其按比例放大，以维护该 se 的 vlag 的“购买力”不变，但同时会相应的导致其他se的 vlag 的购买力降低，但购买力的差值保持不变。

因此：

```txt
se->vlag = vlag * (W + se->load.weight) / W
```

se 加入到这个 cfs_rq 队列时，通过其自身的 se->load.weight 和 cfs_rq.avg_load 进行对比，并放大。

---

#### vslice /= 2 的原因：

针对新任务入队时，可以假设队列中已存在的任务平均都用了一半的时间片配额。而且 vslice 和 deadline 有关，vslice 过大，会导致 se->deadline 距离此刻时间点过远，因此会导致首次调度推迟，所以 vslice /= 2 是为了使新任务更平滑的融入。同时也更符合EEVDF的思想，在所有有资格运行的任务中，选择一个 deadline 最小的任务运行。

---

#### __enqueue_entity()

刚刚引入EEVDF的时候，还是用se->vruntime 排序，通过每个 se->min_deadline 记录当前节点（se->run_node）和左右子树中最小的 deadline。

但现在社区已经修改了 rb-tree 的比较方式，与原本的 cfs_rq 的入队不一致，现在改成了用 se->deadline 排序，用 se->min_vruntime 记录当前节点（se->run_node）和其左右子树中最小的 vruntime 了。

可参考linux-mainline 2227a957e1d5 ("sched/eevdf: Sort the rbtree by virtual deadline")

---

#### avg_vruntime_add()

基于当前入队的 se，更新 cfs_rq->avg_vruntime 和 cfs_rq->avg_load

同步更新该 cfs_rq 对应的 rb-tree 上因新节点（se->run_node）插入，而被影响的所有节点（包括该新节点）的 se->min_vruntime

临时设置 se->min_vruntime = se->vruntime

通过 __entity_less() 比较函数，基于 se->deadline，将其插入到 rb-tree 中

通过 min_vruntime_cb() 回调，刷新该 cfs_rq 中因插入该 se，被影响到的节点的 min_vruntime

---

### 出队 (dequeue_entity)

逻辑与入队对称，逻辑相似，此处省略。

---

### 调整权重 (reweight_entity)

---

#### se 不在 cfs_rq 的运行队列：

当 se 不在 cfs_rq 上的时候，仅需要基于新的 se->load.weight 更新其 vlag，不需要更新其 se->vruntime 和 se->deadline。是因为在入队时 enqueue_entity() -> place_entity() 的时候会计算该 se->vruntime 和 se->deadline。

计算思路是保持真实的 lag 不变，因此：

```txt
se->vlag = div_s64(se->vlag * se->load.weight, weight)
```

其中 se->vlag * se->load.weight 是为了获得真实的 lag，然后再除以新的 weight，得到新的 se->vlag。

---

#### se 在运行队列：

__dequeue_entity()：移除旧权重任务（cfs_rq->curr 无需出队，因为本就不在 cfs_rq 队列上）。

---

#### reweight_eevdf()

原则：保持 lag_i 不变（lag_i = vlag_i * w_i）。

更新公式：

```txt
新 vlag_i = 旧 vlag_i * 旧 w_i / 新 w_i
```

__enqueue_entity：重新加入新权重任务（cfs_rq->curr 同理）。

update_min_vruntime：更新cfs_rq->min_vruntime。

---

#### 备注：

上述逻辑仅基于 LTS 6.6，linux-mainline 已更新，因为在 reweight_entity() 过程中，se->deadline 的值未采用相对大小，未正确缩放，同时未使用 place_entity() 在真正入队 __enqueue_entity() 前，调整其 se->vruntime 和 se->deadline。

具体修改可参考主线补丁：

```txt
6d71a9c61604 ("sched/fair: Fix EEVDF entity placement bug causing scheduling lag")
```

---

## 任务选择 (pick_next_task_fair)

pick_next_entity() => pick_eevdf() 流程：

通过 entity_eligible() 判断 cfs_rq->curr 是否有资格运行，若无资格则将 cfs_rq->curr 赋空

通过 entity_eligible() 判断 cfs_rq 中 leftmost 节点是否有资格运行，若有则直接返回。

备注：这里的 leftmost 并非是 vruntime 最小的 se，而是 deadline 最小的 se。

基于根节点，通过 vruntime_eligible() 判断其左儿子是否有资格运行，若有则递归其左子树，再找。

（现在 cfs_rq 的 rb-tree 基于 se->deadline 排序，左子树的 se->deadline 比右子树的更小，EEVDF的目的是，在所有有资格运行（基于 vruntime）的 se 中，选择 se->deadline 最小的运行，因此若左子树有资格，那最终被选中的 se 一定在左子树中。）

如果左儿子没资格运行，则判断“根节点”是否有资格，若有资格则直接返回“根节点”（注意：此时可能已经是递归过程中的“根节点”了，不一定是 cfs_rq.tasks_timeline.rb_root 的根节点，因此需注意此时是递归过程中）。

（同理，若此时“根节点”有资格，则一定是 deadline 中最小的，哪怕右子树中也存在 vruntime 符合资格的。）

如果左儿子和根都没资格，则递归右子树。

总结：

递归左子树 → 根节点 → 右子树，返回首个 eligible 且 deadline 最小的 se。

若均无 eligible 的 se，在当前代码逻辑中，则会返回 NULL。

---

## eligible 判断 (entity_eligible() 和 vruntime_eligible())

```txt
cfs_rq->avg_vruntime + cfs_rq->curr->vruntime * cfs_rq->curr->load.weight 
和 
(se->vruntime - cfs_rq->min_vruntime) * cfs_rq->avg_load，
比较大小。
```

个人理解是：

所有 se（包括 cfs_rq->curr）的 vruntime 之和，与被判定是否有资格的 se 的 vruntime 做对比，因此右侧：

```txt
(se->vruntime - cfs_rq->min_vruntime) * cfs_rq->avg_load
```

相当于左侧：

```txt
(cfs_rq->avg_vruntime + cfs_rq->curr->vruntime * cfs_rq->curr->load.weight)
```

除 cfs_rq->avg_load。

物理意义：

进程的虚拟时间差是否小于等于队列全局平均水平。

---

## 其它

todo：可继续完善其它关键函数，无固定时间点

---

## 总结

EEVDF 通过引入 lag/vlag 和 virtual deadline，在 CFS 调度类的基础上增强了对延迟敏感任务的响应能力：

* lag/vlag 量化进程的时间分配偏差。
* virtual deadline 动态融合运行时间和延迟需求。
* 调度选择时优先满足 eligible 且 deadline 最近的任务。

具体逻辑建议结合源码（kernel/sched/fair.c）同步理解。

---

## 参考资料

[https://zhuanlan.zhihu.com/p/704413081](https://zhuanlan.zhihu.com/p/704413081)
[https://zhuanlan.zhihu.com/p/683775984](https://zhuanlan.zhihu.com/p/683775984)
[https://citeseerx.ist.psu.edu/document?repid=rep1&type=pdf&doi=805acf7726282721504c8f00575d91ebfd750564#/](https://citeseerx.ist.psu.edu/document?repid=rep1&type=pdf&doi=805acf7726282721504c8f00575d91ebfd750564#/)
[https://lore.kernel.org/lkml/20230531115839.089944915@infradead.org/#/](https://lore.kernel.org/lkml/20230531115839.089944915@infradead.org/#/)

---
