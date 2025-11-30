# Linux 内核 Guard/Class 机制完全指南

> 本文档详细介绍 Linux 内核中的 guard/class 机制，这是一种基于 RAII 模式的自动资源管理方式。

---

## 目录

1. [概述](#1-概述)
2. [核心宏定义](#2-核心宏定义)
3. [scoped 系列宏](#3-scoped-系列宏)
4. [条件锁机制](#4-条件锁机制)
5. [实际代码示例](#5-实际代码示例)
6. [最佳实践](#6-最佳实践)
7. [关键文件索引](#7-关键文件索引)

---

## 1. 概述

### 1.1 什么是 RAII？

RAII (Resource Acquisition Is Initialization) 是 C++ 中的一种资源管理技术：
- **资源获取**：在对象构造时完成
- **资源释放**：在对象析构时自动完成

Linux 内核使用 GCC 的 `__cleanup` 属性在 C 语言中实现了类似功能。

### 1.2 `__cleanup` 属性的工作原理

```c
// GCC 扩展语法
void cleanup_func(int *p) {
    // 当变量离开作用域时自动调用
    free(*p);
}

void example(void) {
    int *ptr __cleanup(cleanup_func) = malloc(sizeof(int));
    // 使用 ptr...
}  // ← 这里自动调用 cleanup_func(&ptr)
```

**关键点**：析构函数在变量**离开作用域**时调用，而不是在初始化函数返回时。

### 1.3 为什么需要 guard 机制？

**传统方式的问题**：
```c
// 手动管理锁 - 容易出错
void old_style(void) {
    spin_lock(&lock);

    if (error_condition)
        return;           // ❌ 忘记解锁！死锁风险

    if (another_error)
        goto out;         // 需要 goto 跳转

    // 正常逻辑...

out:
    spin_unlock(&lock);
    return;
}
```

**guard 方式**：
```c
// 自动管理锁 - 安全简洁
void new_style(void) {
    guard(spinlock)(&lock);

    if (error_condition)
        return;           // ✅ 自动解锁

    if (another_error)
        return;           // ✅ 自动解锁

    // 正常逻辑...
}  // ← 离开作用域时自动解锁
```

---

## 2. 核心宏定义

### 2.1 DEFINE_FREE 和 `__free`

最简单的资源释放机制，用于单个变量的自动释放。

**定义**：
```c
// include/linux/cleanup.h
#define DEFINE_FREE(_name, _type, _free) \
    static inline void __free_##_name(void *p) { \
        _type _T = *(_type *)p; \
        _free; \
    }
```

**使用示例**：
```c
// include/linux/cleanup.h - 预定义的 kfree
DEFINE_FREE(kfree, void *, if (_T) kfree(_T))

// 使用
void *alloc_obj(void) {
    void *p __free(kfree) = kmalloc(1024, GFP_KERNEL);
    if (!p)
        return NULL;

    // 使用 p...

    return_ptr(p);  // 阻止自动释放，返回指针给调用者
}

// 如果不调用 return_ptr()，函数结束时自动 kfree(p)
```

**关键宏**：
| 宏 | 说明 |
|---|---|
| `__free(name)` | 声明变量时指定清理函数 |
| `return_ptr(p)` | 返回指针并阻止自动清理 |
| `no_free_ptr(p)` | 仅阻止自动清理，不返回 |

---

### 2.2 DEFINE_CLASS 和 CLASS

定义一个带构造函数和析构函数的类型，用于复杂的资源管理。

**定义**：
```c
// include/linux/cleanup.h:279
#define DEFINE_CLASS(_name, _type, _exit, _init, _init_args...) \
typedef _type class_##_name##_t;                                \
static inline void class_##_name##_destructor(_type *p) {       \
    _type _T = *p; _exit;                                       \
}                                                               \
static inline _type class_##_name##_constructor(_init_args) {   \
    _type t = _init; return t;                                  \
}

#define CLASS(_name, var) \
    class_##_name##_t var __cleanup(class_##_name##_destructor) = \
        class_##_name##_constructor
```

**参数说明**：
| 参数 | 说明 |
|---|---|
| `_name` | 类名 |
| `_type` | 数据类型 |
| `_exit` | 析构代码（`_T` 是变量名） |
| `_init` | 构造表达式 |
| `_init_args` | 构造函数参数 |

**使用示例**：
```c
// kernel/sched/syscalls.c:232 - 管理任务引用计数
DEFINE_CLASS(find_get_task, struct task_struct *,
             if (_T) put_task_struct(_T),   // 析构：释放引用
             find_get_task(pid),             // 构造：获取引用
             pid_t pid)

// 使用
static int do_sched_setscheduler(pid_t pid, int policy, ...) {
    CLASS(find_get_task, p)(pid);  // 构造：获取 task_struct
    if (!p)
        return -ESRCH;

    return sched_setscheduler(p, policy, &lparam);
}  // 析构：自动调用 put_task_struct(p)
```

**另一个示例**：
```c
// include/linux/fs.h:2539 - 管理文件名
DEFINE_CLASS(filename, struct filename *,
             putname(_T),              // 析构：释放文件名
             getname(p),               // 构造：获取用户空间文件名
             const char __user *p)

// 使用
CLASS(filename, f)(pathname);
if (IS_ERR(f))
    return PTR_ERR(f);
// 使用 f...
// 函数结束时自动 putname(f)
```

---

### 2.3 DEFINE_GUARD 和 guard()

专为锁设计的简化宏，是 `DEFINE_CLASS` 的特化版本。

**定义**：
```c
// include/linux/cleanup.h:396
#define DEFINE_GUARD(_name, _type, _lock, _unlock) \
    DEFINE_CLASS(_name, _type,                     \
        if (!__GUARD_IS_ERR(_T)) { _unlock; },     \
        ({ _lock; _T; }), _type _T)

#define guard(_name) CLASS(_name, __UNIQUE_ID(guard))
```

**使用示例**：
```c
// 定义一个 guard
DEFINE_GUARD(my_lock, struct mutex *,
             mutex_lock(_T), mutex_unlock(_T))

// 使用
void example(void) {
    guard(my_lock)(&my_mutex);
    // 临界区代码...
}  // 自动解锁
```

**预定义的 guard**：
```c
// include/linux/mutex.h
DEFINE_GUARD(mutex, struct mutex *, mutex_lock(_T), mutex_unlock(_T))

// include/linux/spinlock.h
DEFINE_GUARD(spinlock, spinlock_t *, spin_lock(_T), spin_unlock(_T))
DEFINE_GUARD(raw_spinlock, raw_spinlock_t *, raw_spin_lock(_T), raw_spin_unlock(_T))

// 使用
guard(mutex)(&my_mutex);
guard(spinlock)(&my_spinlock);
guard(raw_spinlock)(&my_raw_spinlock);
```

---

### 2.4 DEFINE_LOCK_GUARD_0 - 无类型锁

用于不需要锁对象的锁（如 RCU、preempt、irq）。

**定义**：
```c
// include/linux/cleanup.h:561
#define DEFINE_LOCK_GUARD_0(_name, _lock, _unlock, ...) \
    __DEFINE_LOCK_GUARD_0(_name, _lock, _unlock, ##__VA_ARGS__)
```

**预定义示例**：
```c
// include/linux/rcupdate.h:1193
DEFINE_LOCK_GUARD_0(rcu, rcu_read_lock(), rcu_read_unlock())

// include/linux/preempt.h
DEFINE_LOCK_GUARD_0(preempt, preempt_disable(), preempt_enable())

// include/linux/irqflags.h
DEFINE_LOCK_GUARD_0(irq, local_irq_disable(), local_irq_enable())
DEFINE_LOCK_GUARD_0(irqsave,
    local_irq_save(__UNIQUE_ID(lflags)),
    local_irq_restore(__UNIQUE_ID(lflags)))

// 使用
guard(rcu)();           // 进入 RCU 临界区
guard(preempt)();       // 禁止抢占
guard(irq)();           // 禁用本地中断
```

---

### 2.5 DEFINE_LOCK_GUARD_1 - 有类型锁

用于需要锁对象的锁（如 mutex、spinlock）。

**定义**：
```c
// include/linux/cleanup.h:556
#define DEFINE_LOCK_GUARD_1(_name, _type, _lock, _unlock, ...) \
    __DEFINE_LOCK_GUARD_1(_name, _type, _lock, _unlock, ##__VA_ARGS__)
```

**预定义示例**：
```c
// include/linux/mutex.h:253
DEFINE_LOCK_GUARD_1(mutex, struct mutex,
    mutex_lock(_T->lock), mutex_unlock(_T->lock))

// include/linux/spinlock.h
DEFINE_LOCK_GUARD_1(spinlock, spinlock_t,
    spin_lock(_T->lock), spin_unlock(_T->lock))

DEFINE_LOCK_GUARD_1(raw_spinlock, raw_spinlock_t,
    raw_spin_lock(_T->lock), raw_spin_unlock(_T->lock))

// 使用
guard(mutex)(&my_mutex);
guard(spinlock)(&my_spinlock);
```

**自定义锁示例（带额外成员）**：
```c
// kernel/sched/sched.h:1917 - 任务 RQ 锁
DEFINE_LOCK_GUARD_1(task_rq_lock, struct task_struct,
    _T->rq = task_rq_lock(_T->lock, &_T->rf),      // 锁函数
    task_rq_unlock(_T->rq, _T->lock, &_T->rf),     // 解锁函数
    struct rq *rq; struct rq_flags rf)             // 额外成员

// 使用
guard(task_rq_lock)(p);
// 可以通过 guard 变量访问 rq 和 rf
```

---

### 2.6 DEFINE_LOCK_GUARD_2 - 双锁

用于同时获取两个锁的场景，避免死锁。

**定义**：
```c
// kernel/sched/sched.h:3109
#define DEFINE_LOCK_GUARD_2(name, type, _lock, _unlock, ...) \
    __DEFINE_UNLOCK_GUARD(name, type, _unlock, type *lock2; __VA_ARGS__) \
    static inline class_##name##_t class_##name##_constructor(type *lock, type *lock2) { \
        class_##name##_t _T = { .lock = lock, .lock2 = lock2 }; \
        _lock; \
        return _T; \
    }
```

**使用示例**：
```c
// kernel/sched/sched.h:3304 - 双 RQ 锁
DEFINE_LOCK_GUARD_2(double_rq_lock, struct rq,
    double_rq_lock(_T->lock, _T->lock2),
    double_rq_unlock(_T->lock, _T->lock2))

// 使用
guard(double_rq_lock)(src_rq, dst_rq);
// 同时持有两个 RQ 的锁
```

---

## 3. scoped 系列宏

### 3.1 scoped_guard()

将锁的作用域限制在一个代码块内。

**定义**：
```c
// include/linux/cleanup.h:446
#define scoped_guard(_name, args...) \
    for (CLASS(_name, scope_guard_if_exists)(args); \
         scope_guard_if_exists; \
         ({ break; })) \
        if (0) ; else  // 确保需要大括号
```

**使用示例**：
```c
// 基本用法
void example(void) {
    // 非临界区代码...

    scoped_guard(mutex, &lock) {
        // 临界区代码
        data++;
    }  // ← 锁在此释放

    // 非临界区代码...
}

// 嵌套使用
void nested_example(void) {
    scoped_guard(mutex, &outer_lock) {
        // 外层临界区

        scoped_guard(spinlock, &inner_lock) {
            // 内层临界区
        }  // 内层锁释放

        // 继续外层临界区
    }  // 外层锁释放
}
```

**实际代码示例**：
```c
// kernel/sched/core.c:10784-10802
void sched_mm_cid_exit_signals(struct task_struct *t) {
    struct mm_struct *mm = t->mm;

    scoped_guard(mutex, &mm->mm_cid.mutex) {
        if (likely(mm->mm_cid.users > 1)) {
            scoped_guard(raw_spinlock_irq, &mm->mm_cid.lock) {
                if (!__sched_mm_cid_exit(t))
                    return;
            }
            return;
        }
        scoped_guard(raw_spinlock_irq, &mm->mm_cid.lock) {
            mm_cid_transit_to_task(t, this_cpu_ptr(mm->mm_cid.pcpu));
        }
    }
}
```

---

### 3.2 scoped_cond_guard()

条件锁，获取失败时执行指定操作。

**定义**：
```c
// include/linux/cleanup.h:458
#define scoped_cond_guard(_name, _fail, args...) \
    for (CLASS(_name, scope_guard_if_exists)(args); \
         scope_guard_if_exists || ({ _fail; 0; }); \
         ({ break; }))
```

**使用示例**：
```c
// 获取失败时 return
scoped_cond_guard(mutex_try, return, &lock) {
    // 成功获取锁才执行
    data++;
}  // 如果获取失败，执行 return

// 获取失败时 break
for (i = 0; i < 10; i++) {
    scoped_cond_guard(mutex_try, break, &locks[i]) {
        process(i);
    }
}

// 获取失败时打印日志
scoped_cond_guard(mutex_try, pr_warn("lock failed"), &lock) {
    critical_section();
}
```

**实际代码示例**：
```c
// lib/test_context-analysis.c:105
static void test_scoped_cond_guard(void) {
    scoped_cond_guard(raw_spinlock_try, return, &d->lock) {
        d->counter++;
    }
}

// lib/test_context-analysis.c:214-219
static void test_cond_guard_intr(void) {
    scoped_cond_guard(mutex_intr, return, &d->mtx) {
        d->counter++;
    }
}
```

---

## 4. 条件锁机制

### 4.1 DEFINE_GUARD_COND

为锁添加条件获取变体（如 trylock）。

**定义**：
```c
// include/linux/cleanup.h:400
#define DEFINE_GUARD_COND(_name, _ext, _lock) \
    __DEFINE_GUARD_COND(_name, _ext, _lock, _RET)
```

**预定义示例**：
```c
// include/linux/mutex.h:254-255
DEFINE_LOCK_GUARD_1_COND(mutex, _try, mutex_trylock(_T->lock))
DEFINE_LOCK_GUARD_1_COND(mutex, _intr, mutex_lock_interruptible(_T->lock), _RET == 0)

// include/linux/spinlock.h:540
DEFINE_LOCK_GUARD_1_COND(raw_spinlock, _try, raw_spin_trylock(_T->lock))
```

**使用**：
```c
// mutex_try - 尝试获取，不阻塞
scoped_cond_guard(mutex_try, return, &lock) {
    // 成功获取才执行
}

// mutex_intr - 可中断获取
scoped_cond_guard(mutex_intr, return, &lock) {
    // 成功获取或被中断返回
}
```

---

### 4.2 ACQUIRE 和 ACQUIRE_ERR

提供更精细的条件锁控制。

**定义**：
```c
// include/linux/cleanup.h:425-426
#define ACQUIRE(_name, _var) CLASS(_name, _var)
#define ACQUIRE_ERR(_name, _var) __guard_err(_name)(_var)
```

**使用示例**：
```c
// 使用 ACQUIRE 获取锁
ACQUIRE(mutex_intr, lock)(&mtx);
rc = ACQUIRE_ERR(mutex_intr, &lock);
if (rc)
    return rc;  // 获取失败，返回错误码

// 此时 @lock 已持有
critical_section();
// 函数结束时自动释放
```

**PM runtime 示例**：
```c
// include/linux/pm_runtime.h:630-640
#define PM_RUNTIME_ACQUIRE(_dev, _var) \
    ACQUIRE(pm_runtime_active_try, _var)(_dev)

// 使用
PM_RUNTIME_ACQUIRE(dev, lock);
if (ACQUIRE_ERR(pm_runtime_active_try, &lock))
    return -EAGAIN;
// 设备已激活
```

---

## 5. 实际代码示例

### 5.1 kernel/sched/ 使用示例

#### 简单锁使用
```c
// kernel/sched/core.c:1600 - 任务 RQ 锁
void uclamp_update_util_min_rt_default(struct task_struct *p) {
    guard(task_rq_lock)(p);
    __uclamp_update_util_min_rt_default(p);
}

// kernel/sched/core.c:2225 - PI 锁
bool task_state_match(struct task_struct *p, unsigned int state) {
    guard(raw_spinlock_irq)(&p->pi_lock);
    return __task_state_match(p, state);
}

// kernel/sched/core.c:1943 - uclamp mutex
void uclamp_sync_from_min_nice(void) {
    guard(mutex)(&uclamp_mutex);
    // ...
}
```

#### 多锁组合
```c
// kernel/sched/core.c:3341-3342 - 双 PI 锁
guard(double_raw_spinlock)(&arg->src_task->pi_lock, &arg->dst_task->pi_lock);

// 双 RQ 锁
guard(double_rq_lock)(src_rq, dst_rq);
```

#### DEFINE_CLASS 自定义资源
```c
// kernel/sched/sched.h:4100
DEFINE_CLASS(sched_change, struct sched_change_ctx *,
    sched_change_end(_T),                    // 析构
    sched_change_begin(p, flags),            // 构造
    struct task_struct *p, unsigned int flags)

// kernel/sched/core.c:8049
scoped_guard(sched_change, p, DEQUEUE_SAVE)
    p->numa_preferred_nid = nid;
```

---

### 5.2 mm 子系统示例

```c
// mm/memory-tiers.c:713
void memory_tier_update(struct memory_tier *tier) {
    guard(mutex)(&memory_tier_lock);
    // ...
}

// mm/vmstat.c:2137
static void vmstat_update(struct work_struct *w) {
    scoped_guard(rcu) {
        if (cpu_is_isolated(cpu))
            continue;
    }
}

// include/linux/mmap_lock.h:622
DEFINE_GUARD(mmap_read_lock, struct mm_struct *,
    mmap_read_lock(_T), mmap_read_unlock(_T))
DEFINE_GUARD(mmap_write_lock, struct mm_struct *,
    mmap_write_lock(_T), mmap_write_unlock(_T))
```

---

### 5.3 fs 子系统示例

```c
// fs/libfs.c:2145 - RCU 保护
struct dentry *lookup_rcu(struct dentry *parent, const char *name) {
    guard(rcu)();
    dentry = rcu_dereference(*stashed);
    // ...
}

// fs/char_dev.c:122 - chrdevs 锁
int register_chrdev(unsigned int major, const char *name) {
    guard(mutex)(&chrdevs_lock);
    // ...
}

// fs/super.c:914 - sb_lock
struct super_block *alloc_super(struct file_system_type *type) {
    guard(spinlock)(&sb_lock);
    // ...
}
```

---

### 5.4 net 子系统示例

```c
// net/ipv6/ip6mr.c:2375
void ip6mr_cache_resolve(struct mfc6_cache *c) {
    guard(rcu)();
    // ...
}

// net/wireless/wext-sme.c:314
void cfg80211_connect_result(struct net_device *dev) {
    guard(wiphy)(wdev->wiphy);
    // ...
}

// include/net/cfg80211.h:6441
DEFINE_GUARD(wiphy, struct wiphy *,
    mutex_lock(&_T->mtx), mutex_unlock(&_T->mtx))

// include/net/devlink.h:1621
DEFINE_GUARD(devl, struct devlink *, devl_lock(_T), devl_unlock(_T))
```

---

## 6. 最佳实践

### 6.1 何时使用 guard vs scoped_guard

| 场景 | 推荐 | 示例 |
|---|---|---|
| 锁需要保护整个函数 | `guard()` | `guard(mutex)(&lock);` |
| 锁只需保护部分代码 | `scoped_guard()` | `scoped_guard(mutex, &lock) { ... }` |
| 需要在锁释放后执行操作 | `scoped_guard()` | 见下例 |

```c
// 需要在锁释放后执行操作
void example(void) {
    int value;

    scoped_guard(spinlock, &lock) {
        value = protected_data;
    }  // 锁释放

    // 可以安全睡眠
    copy_to_user(buf, &value, sizeof(value));
}
```

### 6.2 错误处理模式

```c
// 模式1: guard + 提前返回
void mode1(void) {
    guard(mutex)(&lock);

    if (error)
        return;  // 自动解锁

    // 正常逻辑
}

// 模式2: scoped_cond_guard
void mode2(void) {
    scoped_cond_guard(mutex_try, return, &lock) {
        // 获取成功才执行
    }
}

// 模式3: ACQUIRE + 错误码
int mode3(void) {
    ACQUIRE(mutex_intr, lock)(&mtx);
    int err = ACQUIRE_ERR(mutex_intr, &lock);
    if (err)
        return err;

    // 正常逻辑
    return 0;
}
```

### 6.3 常见陷阱

#### 陷阱1: 误解析构时机

```c
// ❌ 错误理解：以为析构在 find_get_task 返回时执行
CLASS(find_get_task, p)(pid);
// 实际上析构在 p 离开作用域时执行，不是现在！

// ✅ 正确理解：析构在作用域结束时执行
{
    CLASS(find_get_task, p)(pid);
    // 使用 p...
}  // ← 这里才析构
```

#### 陷阱2: guard 变量作用域

```c
// ❌ 错误：锁在 if 块结束时释放
if (condition) {
    guard(mutex)(&lock);
    // 临界区
}
// 这里已经没有锁保护了！

// ✅ 正确：使用 scoped_guard 明确作用域
scoped_guard(mutex, &lock) {
    if (condition) {
        // 临界区
    }
}
```

#### 陷阱3: 条件锁的错误处理

```c
// ❌ 错误：没有处理获取失败的情况
scoped_guard(mutex_try, , &lock) {  // 空的失败处理
    // 可能根本没获取到锁
}

// ✅ 正确：明确处理失败
scoped_cond_guard(mutex_try, return -EBUSY, &lock) {
    // 确保获取成功才执行
}
```

### 6.4 性能考虑

- guard 机制**零运行时开销**，编译后与传统手动锁代码相同
- `__cleanup` 是编译时机制，不涉及额外的函数调用开销
- 代码体积可能略有增加（内联函数），但通常可忽略

---

## 7. 关键文件索引

| 文件路径 | 说明 |
|---|---|
| `include/linux/cleanup.h` | **核心定义**：所有 guard/class 宏 |
| `include/linux/mutex.h` | mutex guard 定义 |
| `include/linux/spinlock.h` | spinlock guard 定义 |
| `include/linux/rcupdate.h` | RCU guard 定义 |
| `include/linux/preempt.h` | preempt guard 定义 |
| `include/linux/irqflags.h` | irq guard 定义 |
| `include/linux/mmap_lock.h` | mmap_lock guard 定义 |
| `include/linux/rwsem.h` | rwsem guard 定义 |
| `include/linux/fs.h` | filename CLASS 定义 |
| `include/linux/pm_runtime.h` | PM runtime guard 定义 |
| `include/net/cfg80211.h` | wiphy guard 定义 |
| `include/net/devlink.h` | devlink guard 定义 |
| `kernel/sched/sched.h` | 调度器自定义 guard（task_rq_lock, double_rq_lock 等） |
| `kernel/sched/core.c` | 大量 guard 使用示例 |
| `kernel/sched/syscalls.c` | DEFINE_CLASS 使用示例 |
| `lib/test_context-analysis.c` | guard 机制测试用例 |

---

## 附录：宏展开示例

### guard(mutex) 展开

```c
// 原始代码
guard(mutex)(&my_mutex);

// 展开为
class_mutex_t __UNIQUE_ID(guard) __cleanup(class_mutex_destructor) =
    class_mutex_constructor(&my_mutex);

// 构造函数
static inline class_mutex_t class_mutex_constructor(struct mutex *lock) {
    class_mutex_t t;
    mutex_lock(lock);
    t.lock = lock;
    return t;
}

// 析构函数（作用域结束时调用）
static inline void class_mutex_destructor(class_mutex_t *p) {
    class_mutex_t _T = *p;
    if (!__GUARD_IS_ERR(_T)) {
        mutex_unlock(_T.lock);
    }
}
```

### CLASS(find_get_task) 展开

```c
// 原始代码
CLASS(find_get_task, p)(pid);

// 展开为
class_find_get_task_t p __cleanup(class_find_get_task_destructor) =
    class_find_get_task_constructor(pid);

// 构造函数
static inline struct task_struct *class_find_get_task_constructor(pid_t pid) {
    return find_get_task(pid);  // 内部调用 get_task_struct
}

// 析构函数
static inline void class_find_get_task_destructor(struct task_struct **p) {
    struct task_struct *_T = *p;
    if (_T) put_task_struct(_T);  // 释放引用
}
```

---

> 文档版本：2024
> 基于 Linux 内核 v6.x 编写
