# Linux内核调试参数与配置指南

## 一、内核调试参数（/proc/sys/kernel/）

### 1. **panic_on_warn**

**作用**：当内核发出warning时自动触发panic，用于快速定位严重警告。
**使用方法**：

```bash
# 启用warn时自动panic
echo 1 > /proc/sys/kernel/panic_on_warn

# 禁用（默认）
echo 0 > /proc/sys/kernel/panic_on_warn
```

### 2. **softlockup_panic**

**作用**：检测到softlockup（软锁死）时自动panic，用于诊断CPU长时间处于内核态的问题。
**使用方法**：

```bash
# 启用softlockup时自动panic
echo 1 > /proc/sys/kernel/softlockup_panic

# 调整softlockup检测阈值（秒）
echo 20 > /proc/sys/kernel/watchdog_thresh
```

### 3. **hung_task** 相关参数

**作用**：检测长时间得不到调度的任务（hung task），帮助诊断任务挂起问题。
**使用方法**：

```bash
# 设置hung task检测超时时间（秒）
echo 120 > /proc/sys/kernel/hung_task_timeout_secs

# hung task发生时自动panic
echo 1 > /proc/sys/kernel/hung_task_panic

# 控制hung task检测的详细程度（0-10，越大越详细）
echo 5 > /proc/sys/kernel/hung_task_check_count
```

### 4. **其他相关调试参数**

```bash
# 控制panic后自动重启的延迟（秒）
echo 10 > /proc/sys/kernel/panic

# 控制panic后自动重启（0=禁用，>0=延迟秒数）
echo 60 > /proc/sys/kernel/panic_on_oops

# 控制oops时是否panic
echo 1 > /proc/sys/kernel/panic_on_oops
```

## 二、内核调试配置选项（CONFIG_*）

### 1. **内存调试配置**

| 配置选项                                      | 作用                                                        | 性能影响 | 备注                             |
| :-------------------------------------------- | :---------------------------------------------------------- | :------- | :------------------------------- |
| **CONFIG_KASAN=y**                            | 内核地址消毒器，检测use-after-free、out-of-bounds等内存错误 | 较大     | 内存访问越界检测                 |
| **CONFIG_DEBUG_KMEMLEAK=y**                   | 内核内存泄漏检测                                            | **严重** | **会导致系统明显卡顿**           |
| **CONFIG_DEBUG_KMEMLEAK_AUTO_SCAN=y**         | 自动定期扫描内存泄漏                                        | **严重** | **周期性卡顿，建议测试环境使用** |
| **CONFIG_DEBUG_KMEMLEAK_MEM_POOL_SIZE=16000** | 内存泄漏检测的内存池大小                                    | 内存占用 | 默认值可能不够，需要调整         |

### 2. **锁调试配置**

| 配置选项                        | 作用                       | 性能影响 | 备注             |
| :------------------------------ | :------------------------- | :------- | :--------------- |
| **CONFIG_LOCKDEP=y**            | 锁依赖关系检测，防止死锁   | 中等     | 会记录所有锁操作 |
| **CONFIG_LOCK_STAT=y**          | 锁统计信息收集             | 小       | 额外的统计开销   |
| **CONFIG_DEBUG_ATOMIC_SLEEP=y** | 检测原子上下文中的睡眠操作 | 小       | 增加检查点       |

### 3. **其他调试配置**

```bash
# 编译内核时在.config文件中添加：
CONFIG_DEBUG_KERNEL=y        # 启用内核调试（基础）
CONFIG_DEBUG_INFO=y          # 包含调试信息（增大内核体积）
CONFIG_DEBUG_LIST=y          # 链表调试
CONFIG_DEBUG_SG=y            # SG表调试
CONFIG_DEBUG_NOTIFIERS=y     # Notifier调试
CONFIG_DEBUG_CREDENTIALS=y   # 凭证调试

# 强烈建议仅在测试环境开启的配置：
# CONFIG_DEBUG_KMEMLEAK=y    # 内存泄漏检测 - 会导致系统卡顿
# CONFIG_DEBUG_KMEMLEAK_AUTO_SCAN=y  # 自动扫描 - 周期性卡顿
```

## 三、外部超参调试接口实现

### 1. **Debugfs调试接口实现**

```c
// 内核模块中的调试变量定义
#include <linux/debugfs.h>

int qzc_debug_param_1 = 0;
int qzc_debug_param_2 = 0;

// 更多调试变量
unsigned int qzc_debug_threshold = 100;
unsigned int qzc_migration_cost = 500000;
bool qzc_enable_feature_x = false;

static struct dentry *qzc_debugfs_dir;

// 调试变量读写回调函数示例
static int qzc_debug_threshold_set(void *data, u64 val)
{
    qzc_debug_threshold = (unsigned int)val;
    pr_info("qzc_debug_threshold set to %u\n", qzc_debug_threshold);
    return 0;
}

static int qzc_debug_threshold_get(void *data, u64 *val)
{
    *val = qzc_debug_threshold;
    return 0;
}
DEFINE_SIMPLE_ATTRIBUTE(qzc_debug_threshold_fops, 
                       qzc_debug_threshold_get, 
                       qzc_debug_threshold_set, 
                       "%llu\n");

// 初始化debugfs接口
static int __init qzc_debugfs_init(void)
{
    qzc_debugfs_dir = debugfs_create_dir("xsched", NULL);
    if (!qzc_debugfs_dir)
        return -ENOMEM;
    
    // 创建简单的整型调试接口
    debugfs_create_u32("qzc_debug_param_1", 
                      0644, 
                      qzc_debugfs_dir, 
                      &qzc_debug_param_1);
    
    debugfs_create_u32("qzc_debug_param_2", 
                      0644, 
                      qzc_debugfs_dir, 
                      &qzc_debug_param_2);
    
    // 创建bool类型调试接口
    debugfs_create_bool("qzc_enable_feature_x", 
                       0644, 
                       qzc_debugfs_dir, 
                       &qzc_enable_feature_x);
    
    // 创建带回调的调试接口
    debugfs_create_file("qzc_sched_threshold", 
                       0644, 
                       qzc_debugfs_dir, 
                       NULL, 
                       &qzc_debug_threshold_fops);
    
    // 创建其他常用调试接口
    debugfs_create_u32("qzc_migration_cost_ns", 
                      0644, 
                      qzc_debugfs_dir, 
                      &qzc_migration_cost);
    
    return 0;
}
late_initcall(qzc_debugfs_init);
```

### 2. **Debugfs使用方式**

```bash
# 查看所有调试参数
ls /sys/kernel/debug/xsched/

# 设置调试参数
echo 1 > /sys/kernel/debug/xsched/qzc_debug_param_1
echo 1 > /sys/kernel/debug/xsched/qzc_debug_param_2

# 查看参数值
cat /sys/kernel/debug/xsched/qzc_debug_param_1

# 启用特性
echo 1 > /sys/kernel/debug/xsched/qzc_enable_feature_x

# 设置阈值
echo 200 > /sys/kernel/debug/xsched/qzc_sched_threshold
```

### 3. **Sysfs调试接口实现**

```c
// 使用sysfs作为调试接口
#include <linux/kobject.h>
#include <linux/sysfs.h>

static struct kobject *qzc_debug_kobj;

// 调试变量
int qzc_sysfs_param_1 = 0;
int qzc_sysfs_param_2 = 0;

// 属性显示函数
static ssize_t qzc_param_1_show(struct kobject *kobj, 
                               struct kobj_attribute *attr, 
                               char *buf)
{
    return sprintf(buf, "%d\n", qzc_sysfs_param_1);
}

// 属性存储函数
static ssize_t qzc_param_1_store(struct kobject *kobj, 
                                struct kobj_attribute *attr, 
                                const char *buf, size_t count)
{
    int ret;
    ret = kstrtoint(buf, 10, &qzc_sysfs_param_1);
    if (ret < 0)
        return ret;
    pr_info("qzc_sysfs_param_1 set to %d\n", qzc_sysfs_param_1);
    return count;
}

// 定义属性
static struct kobj_attribute qzc_param_1_attr = 
    __ATTR(qzc_param_1, 0644, qzc_param_1_show, qzc_param_1_store);

// 第二个参数
static ssize_t qzc_param_2_show(struct kobject *kobj, 
                               struct kobj_attribute *attr, 
                               char *buf)
{
    return sprintf(buf, "%d\n", qzc_sysfs_param_2);
}

static ssize_t qzc_param_2_store(struct kobject *kobj, 
                                struct kobj_attribute *attr, 
                                const char *buf, size_t count)
{
    int ret;
    ret = kstrtoint(buf, 10, &qzc_sysfs_param_2);
    if (ret < 0)
        return ret;
    pr_info("qzc_sysfs_param_2 set to %d\n", qzc_sysfs_param_2);
    return count;
}

static struct kobj_attribute qzc_param_2_attr = 
    __ATTR(qzc_param_2, 0644, qzc_param_2_show, qzc_param_2_store);

// 属性数组
static struct attribute *qzc_debug_attrs[] = {
    &qzc_param_1_attr.attr,
    &qzc_param_2_attr.attr,
    NULL,
};

static struct attribute_group qzc_debug_attr_group = {
    .attrs = qzc_debug_attrs,
};

// 初始化
static int __init qzc_debug_sysfs_init(void)
{
    int ret;
    
    // 创建kobject
    qzc_debug_kobj = kobject_create_and_add("qzc_debug", kernel_kobj);
    if (!qzc_debug_kobj)
        return -ENOMEM;
    
    // 创建属性组
    ret = sysfs_create_group(qzc_debug_kobj, &qzc_debug_attr_group);
    if (ret) {
        kobject_put(qzc_debug_kobj);
        return ret;
    }
    
    return 0;
}

static void __exit qzc_debug_sysfs_exit(void)
{
    kobject_put(qzc_debug_kobj);
}

module_init(qzc_debug_sysfs_init);
module_exit(qzc_debug_sysfs_exit);
```

### 4. **Sysfs使用方式**

```bash
# Sysfs调试接口路径
/sys/kernel/qzc_debug/

# 查看所有参数
ls /sys/kernel/qzc_debug/

# 查看参数值
cat /sys/kernel/qzc_debug/qzc_param_1
cat /sys/kernel/qzc_debug/qzc_param_2

# 设置参数值
echo 100 > /sys/kernel/qzc_debug/qzc_param_1
echo 200 > /sys/kernel/qzc_debug/qzc_param_2

# 监控参数变化（实时查看）
watch -n 1 'cat /sys/kernel/qzc_debug/qzc_param_1'
```
