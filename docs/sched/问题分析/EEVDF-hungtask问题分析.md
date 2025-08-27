# EEVDF hungtask问题分析

## 1. crash分析

### 1.1 现场现象：系统出现 hung task

- `systemd` 等待 `cgroup_mutex`
- `sh` 持有 `cgroup_mutex`，等待 `cpus_read_lock`
- `kworker/0:0` 持有 `cpus_read_lock`，但**长时间得不到调度**

```sh
crash> runq -c 0 -g
CPU 0
  CURRENT: PID: 330440  TASK: ffff00004cd61540  COMMAND: "stress-ng"
  ROOT_TASK_GROUP: ffff8001025fa4c0  RT_RQ: ffff0000fff42500
	 [no tasks queued]
  ROOT_TASK_GROUP: ffff8001025fa4c0  CFS_RQ: ffff0000fff422c0
	 TASK_GROUP: ffff0000c130fc00  CFS_RQ: ffff00009125a400  <test_cg>
		TASK_GROUP: ffff0000d7cc8800  CFS_RQ: ffff0000c8f86800  <test_test329274_1>
		   [110] PID: 330440  TASK: ffff00004cd61540  COMMAND: "stress-ng" [CURRENT]
		   ...
		   [110] PID: 330291  TASK: ffff0000c02c9540  COMMAND: "stress-ng"
	 [100] PID: 97     TASK: ffff0000c2432a00  COMMAND: "kworker/0:1H"
	 [120] PID: 15     TASK: ffff0000c0368080  COMMAND: "ksoftirqd/0"
	 [120] PID: 50173  TASK: ffff0000741d8080  COMMAND: "kworker/0:0"
	 [120] PID: 58662  TASK: ffff000091180080  COMMAND: "kworker/0:2"

test_cg: 			cfs_bandwidth: period=100000000, quota=18446744073709551615, gse: 0xffff000091258c00, vruntime=127285708384434, deadline=127285714880550, vlag=11721467, weight=338965, my_q=ffff00009125a400, cfs_rq: avg_vruntime=0, zero_vruntime=2029704519792, avg_load=0, nr_running=1

test_test329274_1: 	cfs_bandwidth: period=14000000, quota=14000000, gse: 0xffff0000c8f86400, vruntime=2034894470719, deadline=2034898697770, vlag=0, weight=215291, my_q=ffff0000c8f86800, cfs_rq: avg_vruntime=-422528991, zero_vruntime=8444226681954, avg_load=54, nr_running=19

PID: 330440: 		vruntime=8444367524951, 	deadline=8444932411139, 	vlag=8444932411139, weight=3072, 		last_arrival=4002964107010, last_queued=0, 				exec_start=3872860294100, sum_exec_runtime=22252021900

PID: 330291: 		vruntime=8444229273009, 	deadline=8444946073008, 	vlag=-2701415, 		weight=3072, 		last_arrival=4002964076840, last_queued=4002964550990, 	exec_start=3872859839290, sum_exec_runtime=22310951770

PID: 97: 			vruntime=127285720095197, 	deadline=127285720119423, 	vlag=48453, 		weight=90891264, 	last_arrival=3846600432710, last_queued=3846600721010, 	exec_start=3743307237970, sum_exec_runtime=413405210

PID: 15: 			vruntime=127285722433404, 	deadline=127285724533404, 	vlag=0, 			weight=1048576, 	last_arrival=3506755665780, last_queued=3506852159390, 	exec_start=3461615726670, sum_exec_runtime=16341041340

PID: 50173: 		vruntime=127285722960040, 	deadline=127285725060040, 	vlag=-414755, 		weight=1048576, 	last_arrival=3506828139580, last_queued=3506972354700, 	exec_start=3461676584440, sum_exec_runtime=84414080

PID: 58662: 		vruntime=127285723428168, 	deadline=127285725528168, 	vlag=3049158, 		weight=1048576, 	last_arrival=3505689085070, last_queued=3506848131990, 	exec_start=3460592328510, sum_exec_runtime=89193000

```

### 1.2 初步分析

```txt
test_cg:	vruntime=127285708384434, deadline=127285714880550
PID: 50173:	vruntime=127285722960040, deadline=127285725060040

vruntime之差：14,575,606
deadline之差：10,179,490

看起来相差的时间远小于1s，task 50173不应该长时间未得到调度，但通过last_arrival、last_queued、exec_start、sum_exec_runtime明显可以发现，task 50173确实应该长时间未调度到了。

因此推测，是否可能在某些特殊场景下，test_cg的vruntime计算有误？
```

## 2. 源码分析

### 2.1 补丁回退分析

```txt
6d71a9c61604 ("sched/fair: Fix EEVDF entity placement bug causing scheduling lag")
https://open.codehub.huawei.com/OpenSourceCenter/openEuler-source/kernel/merge_requests/15405/diffs?commit_id=cc4a866223803b71491778769e43a3075e7304c4

c70fc32f4443 ("sched/fair: Adhere to place_entity() constraints")
https://open.codehub.huawei.com/OpenSourceCenter/openEuler-source/kernel/merge_requests/15405/diffs?commit_id=1248bb79257566c9c020bafc74a6145e4f5c7f01

在hulk-6.6中，回退这两个主线补丁，即可解决hungtask问题。
```

### 2.2 补丁源码分析

```txt
(问题补丁) 6d71a9c61604 ("sched/fair: Fix EEVDF entity placement bug causing scheduling lag")
(已分析无问题，后续不进行展开介绍) c70fc32f4443 ("sched/fair: Adhere to place_entity() constraints")

改动 1：entity_lag() 被合并进 update_entity_lag()，无功能性调整
改动 2：彻底删除 reweight_eevdf()，无需手动在reweight时做 vruntime / deadline 的推到
改动 3：reweight_entity() 时只做“状态变换”，不做“位置计算”
改动 4：重新 enqueue 后，统一调用 place_entity()

补丁的核心修复思路：
1. 不要在 reweight 时手工推导 vruntime / deadline，而是统一交给 place_entity() 来做实体放置。
2. “reweight 不再自己算 vruntime，而是只维护 lag / 相对 deadline，然后重新 place”
```

### 2.3 place_entity()源码分析

```c
static void
place_entity(struct cfs_rq *cfs_rq, struct sched_entity *se, int flags)
{
	u64 vslice, vruntime = avg_vruntime(cfs_rq);
	s64 lag = 0;

	se->slice = sysctl_sched_base_slice;
	vslice = calc_delta_fair(se->slice, se);

	/*
	 * Due to how V is constructed as the weighted average of entities,
	 * adding tasks with positive lag, or removing tasks with negative lag
	 * will move 'time' backwards, this can screw around with the lag of
	 * other tasks.
	 *
	 * EEVDF: placement strategy #1 / #2
	 */
	if (sched_feat(PLACE_LAG) && cfs_rq->nr_running) {
		struct sched_entity *curr = cfs_rq->curr;
		unsigned long load;

		lag = se->vlag;

		/*
		 * If we want to place a task and preserve lag, we have to
		 * consider the effect of the new entity on the weighted
		 * average and compensate for this, otherwise lag can quickly
		 * evaporate.
		 *
		 * Lag is defined as:
		 *
		 *   lag_i = S - s_i = w_i * (V - v_i)
		 *
		 * To avoid the 'w_i' term all over the place, we only track
		 * the virtual lag:
		 *
		 *   vl_i = V - v_i <=> v_i = V - vl_i
		 *
		 * And we take V to be the weighted average of all v:
		 *
		 *   V = (\Sum w_j*v_j) / W
		 *
		 * Where W is: \Sum w_j
		 *
		 * Then, the weighted average after adding an entity with lag
		 * vl_i is given by:
		 *
		 *   V' = (\Sum w_j*v_j + w_i*v_i) / (W + w_i)
		 *      = (W*V + w_i*(V - vl_i)) / (W + w_i)
		 *      = (W*V + w_i*V - w_i*vl_i) / (W + w_i)
		 *      = (V*(W + w_i) - w_i*l) / (W + w_i)
		 *      = V - w_i*vl_i / (W + w_i)
		 *
		 * And the actual lag after adding an entity with vl_i is:
		 *
		 *   vl'_i = V' - v_i
		 *         = V - w_i*vl_i / (W + w_i) - (V - vl_i)
		 *         = vl_i - w_i*vl_i / (W + w_i)
		 *
		 * Which is strictly less than vl_i. So in order to preserve lag
		 * we should inflate the lag before placement such that the
		 * effective lag after placement comes out right.
		 *
		 * As such, invert the above relation for vl'_i to get the vl_i
		 * we need to use such that the lag after placement is the lag
		 * we computed before dequeue.
		 *
		 *   vl'_i = vl_i - w_i*vl_i / (W + w_i)
		 *         = ((W + w_i)*vl_i - w_i*vl_i) / (W + w_i)
		 *
		 *   (W + w_i)*vl'_i = (W + w_i)*vl_i - w_i*vl_i
		 *                   = W*vl_i
		 *
		 *   vl_i = (W + w_i)*vl'_i / W
		 */
		load = cfs_rq->avg_load;
		if (curr && curr->on_rq)
			load += scale_load_down(curr->load.weight);

		lag *= load + scale_load_down(se->load.weight);
		if (WARN_ON_ONCE(!load))
			load = 1;
		lag = div_s64(lag, load);

        /*
         * high-level 思路总结（基于 vlag / avg_vruntime() 的变化过程）：
         * 假设某个 se 的 vlag 为正，表示它的实际运行时间 vlag > 0 说明该实体运行得比应有份额少，会拖慢 cfs_rq 的 avg_vruntime()。
         * 备注：可以理解 se->vlag 为 avg_vruntime() 和 se 的 vruntime 之间的差值
         * 
         * 前提：se出队后又入队，在出队前、再次入队后，其余不变，cfs_rq上的所有关键属性，se的所有关键属性，不应有变化，因为本质其实不发生任何改变
         * 
         * 1. 出队前：假设该时刻的 avg_vruntime() 为 avg_vruntime_1，se 的 vruntime 为 se_vruntime_1，se 的 vlag 为 se_vlag_1
         * 
         * 2. 出队后 / 入队前：设该时刻的 avg_vruntime() 为 avg_vruntime_2，se 的 vruntime 为 se_vruntime_2，se 的 vlag 为 se_vlag_2
         *
         * 当该 se 出队时，新的 avg_vruntime() 会相对升高，因为少了一个拖累。
         * 因此 avg_vruntime_2 > avg_vruntime_1, 出队后的 vlag 和 vruntime 没有意义，因此不考虑比较（其实此时仍可理解为相等）
         * 
         * 3. 入队后：设该时刻的 avg_vruntime() 为 avg_vruntime_3，se 的 vruntime 为 se_vruntime_3，se 的 vlag 为 se_vlag_3
         * 
         * 当该 se 入队后，因为 se->vlag 是正数，因此还是实际运行时间，比本应运行时间稍，还会对平均虚拟时间造成拖累，
         * 因此 avg_vruntime_3 < avg_vruntime_2，se_vlag_3 = se_vlag_2 = se_vlag_1
         *
         * 已知：
         * 初始：se_vruntime_1 = avg_vruntime_1 - se_vlag_1
         * 出入队后：se_vruntime_3 = avg_vruntime_2 - se_vlag_3
         * avg_vruntime_2 > avg_vruntime_1，avg_vruntime_3 < avg_vruntime_2
         * 因此 se_vruntime_3 > se_vruntime_1，所以导致 avg_vruntime_3 > avg_vruntime_1
         * 最终，avg_vruntime_1 < avg_vruntime_3 < avg_vruntime_2（中间态，忽略），se_vruntime_3 > se_vruntime_1
         * 因此，仅仅出队后再入队，其它东西都不变的情况下，se_vruntime_x 和 avg_vruntime_x 就发生了变化
         * 
         * 在入队过程的 place_entity() 中，se_vruntime_3 = avg_vruntime_2 - se_vlag_3，avg_vruntime_2 已经实质性的发生了变化
         * 若仍想让 se_vruntime_3 = se_vruntime_1，则需要将 se_vlag_3 按某种比例扩大为 se_vlag_3'，
         * 让 avg_vruntime_2 - se_vlag_3' => se_vruntime_3 = se_vruntime_1
         * 因此，se->vlag 的扩大规则，就是公式中描述的基本原理。
         */
	}

	se->vruntime = vruntime - lag;

	if (se->rel_deadline) {
		se->deadline += se->vruntime;
		se->rel_deadline = 0;
		return;
	}

	/*
	 * When joining the competition; the exisiting tasks will be,
	 * on average, halfway through their slice, as such start tasks
	 * off with half a slice to ease into the competition.
	 */
	if (sched_feat(PLACE_DEADLINE_INITIAL) && (flags & ENQUEUE_INITIAL))
		vslice /= 2;

	/*
	 * EEVDF: vd_i = ve_i + r_i/w_i
	 */
	se->deadline = se->vruntime + vslice;
}
```

## 3. reweight_entity 故障模型

```c
static void reweight_entity(struct cfs_rq *cfs_rq, struct sched_entity *se,
			    unsigned long weight)
{
	bool curr = cfs_rq->curr == se;

	if (se->on_rq) {
		/* commit outstanding execution time */
		update_curr(cfs_rq);
		update_entity_lag(cfs_rq, se); // 计算出新的 se->vlag
		se->deadline -= se->vruntime;
		se->rel_deadline = 1;
		cfs_rq->nr_running--;
		if (!curr)
			__dequeue_entity(cfs_rq, se); // 出队，会让 avg_vruntime() 产生变化
		update_load_sub(&cfs_rq->load, se->load.weight);
	}
	dequeue_load_avg(cfs_rq, se);

	/*
	 * Because we keep se->vlag = V - v_i, while: lag_i = w_i*(V - v_i),
	 * we need to scale se->vlag when w_i changes.
	 */
	se->vlag = div_s64(se->vlag * se->load.weight, weight); // 根据新旧权重，对 vlag 进行转换
	if (se->rel_deadline)
		se->deadline = div_s64(se->deadline * se->load.weight, weight);

	update_load_set(&se->load, weight);

#ifdef CONFIG_SMP
	do {
		u32 divider = get_pelt_divider(&se->avg);

		se->avg.load_avg = div_u64(se_weight(se) * se->avg.load_sum, divider);
	} while (0);
#endif

	enqueue_load_avg(cfs_rq, se);
	if (se->on_rq) {
        /*
         * 故障原因是，gse 经常因限流等原因被动执行 reweight，因此当该 gse 作为 cfs_rq->curr 时，在当前 reweight 逻辑下，不会执行 dequeue 和 enqueue，因此 avg_vruntime() 不会发生变化。
         * 若使用 place_entity()，则会预估该 se 加入到 cfs_rq 后对的情况，对 se 的 vlag 进行扩大，但当前该 se 已经在 cfs_rq 上了，因此对 vlag 进行缩放，就会产生问题。
         * 当 vlag 为正数时，gse 的 vruntime 每向前推进一些，在 reweight 时，都可能会过大的后退，因此会一直选择 gse 运行，饿死其它任务。
         */
		place_entity(cfs_rq, se, curr ? ENQUEUE_REWEIGHT_CURR : 0);
		update_load_add(&cfs_rq->load, se->load.weight);
		if (!curr)
			__enqueue_entity(cfs_rq, se); // 入队，会让 avg_vruntime() 产生变化
		cfs_rq->nr_running++;
	}
}
```
