# Linux Kernel 学习笔记

Linux 内核调度器相关学习笔记与实用工具 - 散装随心记

## 目录结构

```
.
├── docs/                           # 文档
│   ├── sched/                      # 调度器原理
│   │   ├── README.md
│   │   ├── 原理/
│   │   │   └── EEVDF调度器总结.md
│   │   ├── 参数/
│   │   │   └── Linux内核调度器参数指南.md
│   │   ├── 问题分析/
│   │   │   ├── EEVDF-hungtask问题分析.md
│   │   │   ├── sched_ext-hungtask问题分析-cgroup-shares压制.md
│   │   │   └── sched_ext-hungtask问题分析-rt压制.md
│   │   ├── 内核机制/
│   │   │   └── guard_class_usage.md
│   │   └── scripts/
│   ├── sched_ext/                  # sched_ext 扩展调度器
│   │   └── sched_ext_完整技术文档.md
│   ├── 调试/                       # 调试技术
│   │   ├── Linux内核基础维测手段.md
│   │   └── 调度器kprobe钩子示例.md
│   ├── 命令参考/                   # 常用命令
│   │   └── 调度类相关常用命令.md
│   └── 编译/                       # 内核编译
│       └── 内核编译命令.md
├── examples/                       # 示例代码
│   └── sched_setattr自定义slice示例.c
└── scripts/                        # 脚本工具
    ├── build/                      # 编译脚本
    │   └── make_kernel.sh
    ├── debug/                      # 调试脚本
    │   ├── catch_perf.sh           # 火焰图生成
    │   ├── catch_trace.sh          # trace 采集
    │   └── statistics_*.py         # 调度统计脚本
    └── others/                     # 其他脚本
        ├── cgroup_configuration.sh
        └── qemu.sh
```

## 主要内容

### 调度器原理
- **EEVDF调度器** - Linux 6.6 引入的新调度器，替代 CFS
- **sched_ext** - BPF 扩展调度器框架
- **调度参数配置** - cmdline 参数与 sysctl 配置详解
- **问题分析** - hung task、cgroup shares 压制、RT 压制等案例
- **内核机制** - Guard/Class 等辅助阅读调度器源码的机制说明

### 调试技术
- kprobe 钩子追踪调度器关键路径
- 内核维测参数配置
- trace/perf 性能分析

### 实用工具
- 内核编译自动化脚本
- cgroup 配置脚本
- 调度统计与分析脚本

## 相关链接

- [Linux Kernel Source](https://kernel.org)
- [sched_ext Documentation](https://www.kernel.org/doc/html/latest/scheduler/sched-ext.html)
