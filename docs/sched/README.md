# Linux 内核调度器专题

这里整理 Linux 内核调度器相关学习笔记、参数指南和问题分析。建议先从 EEVDF 原理入手，再看参数配置，最后结合问题分析文档理解实际故障场景。

## 推荐阅读顺序

1. [EEVDF调度器总结](原理/EEVDF调度器总结.md)
2. [Linux内核调度器参数指南](参数/Linux内核调度器参数指南.md)
3. [EEVDF-hungtask问题分析](问题分析/EEVDF-hungtask问题分析.md)
4. [sched_ext-hungtask问题分析-cgroup-shares压制](问题分析/sched_ext-hungtask问题分析-cgroup-shares压制.md)
5. [sched_ext-hungtask问题分析-rt压制](问题分析/sched_ext-hungtask问题分析-rt压制.md)
6. [Linux 内核 Guard/Class 机制完全指南](内核机制/guard_class_usage.md)

## 目录结构

```text
.
├── README.md
├── 原理/
│   └── EEVDF调度器总结.md
├── 参数/
│   └── Linux内核调度器参数指南.md
├── 问题分析/
│   ├── EEVDF-hungtask问题分析.md
│   ├── sched_ext-hungtask问题分析-cgroup-shares压制.md
│   └── sched_ext-hungtask问题分析-rt压制.md
├── 内核机制/
│   └── guard_class_usage.md
└── scripts/
```

## 分类说明

- `原理/`：调度器核心机制、关键数据结构和源码流程。
- `参数/`：启动参数、运行时参数、调度器 feature 组合与排障决策。
- `问题分析/`：hung task、cgroup shares、RT 压制等实际案例。
- `内核机制/`：与调度器代码阅读相关的通用内核机制。
- `scripts/`：调度器问题复现或辅助分析脚本。
