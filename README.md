# Linux Kernel 学习笔记

围绕 Linux 内核源码阅读、调度机制和问题排查整理的个人学习仓库。内容以 **EEVDF 与 sched_ext** 为重点，同时收录调度、同步、中断、内存、追踪等内核笔记，以及 C、计算机基础、数据库和 Java 的复习资料。

## 项目脉络

整个仓库围绕「基础知识 → 内核机制 → 调度专题 → 观测与问题分析」展开：

- **基础与内核知识**：`docs/学习笔记/` 整理通用基础、内核各子系统和面试复习内容，为专题阅读建立知识框架。
- **调度机制深入**：`docs/sched/` 从 EEVDF 原理、参数配置和源码辅助机制入手，延伸到实际故障分析。
- **扩展调度实践**：`docs/sched_ext/` 围绕 BPF 可扩展调度器，串联架构、接口、生命周期、示例策略和实验观测。
- **调试与验证支撑**：`docs/调试/`、`docs/命令参考/`、`docs/编译/` 提供实践参考，`scripts/` 与 `examples/` 配合完成实验和数据分析。

学习笔记侧重知识覆盖，专题文档侧重机制深度，案例与工具帮助把原理和实际现象联系起来。文档涉及不同内核版本，具体实现以各篇说明及对应源码为准。

## 从哪里开始

| 阅读目标 | 建议路线 |
| --- | --- |
| 建立内核知识框架 / 面试复习 | 调度 → 同步 → 中断 → 内存 → 追踪，见下方「内核与基础学习笔记」 |
| 理解 EEVDF | [EEVDF 调度器总结](docs/sched/内核机制/EEVDF调度器总结.md) → [调度器参数指南](docs/sched/内核参数/Linux内核调度器参数指南.md) → [hung task 案例](docs/sched/问题分析/EEVDF-hungtask问题分析.md) |
| 学习 sched_ext | [技术分享](docs/sched_ext/sched_ext_introduction.md) → [完整技术文档](docs/sched_ext/sched_ext_完整技术文档.md) → [观测与负载脚本](docs/sched_ext/scripts/) |
| 排查运行中的问题 | [常用维测命令](<docs/学习笔记/12. Linux 内核 - 常用维测命令.md>) → [追踪工具与选型](<docs/学习笔记/11. Linux 内核 - 追踪 - 面试.md>) → 对照专题案例分析 |

## 文档导航

### 调度器专题

| 文档 | 主要内容 |
| --- | --- |
| [EEVDF 调度器总结](docs/sched/内核机制/EEVDF调度器总结.md) | lag、虚拟截止时间、时间片、关键字段与入队 / 出队 / 任务选择流程 |
| [Linux 内核调度器参数指南](docs/sched/内核参数/Linux内核调度器参数指南.md) | 启动参数、运行时参数、调度器特性开关与组合分析 |
| [Guard / Class 机制指南](docs/sched/内核机制/guard_class_usage.md) | cleanup、作用域资源管理和锁管理宏，辅助阅读内核代码 |
| [EEVDF hung task 问题分析](docs/sched/问题分析/EEVDF-hungtask问题分析.md) | crash 现场、源码与补丁分析、reweight_entity 故障模型 |
| [sched_ext：cgroup shares 压制](docs/sched/问题分析/sched_ext-hungtask问题分析-cgroup-shares压制.md) | cgroup 权重相关的 hung task 排查记录 |
| [sched_ext：RT 压制](docs/sched/问题分析/sched_ext-hungtask问题分析-rt压制.md) | 实时任务压制相关的 hung task 排查记录 |

### sched_ext 专题

| 文档 / 资源 | 主要内容 |
| --- | --- |
| [sched_ext 技术分享](docs/sched_ext/sched_ext_introduction.md) | 核心数据模型、DSQ、ops 生命周期、启停调用栈、安全机制与示例调度器分析 |
| [sched_ext 完整技术文档](docs/sched_ext/sched_ext_完整技术文档.md) | 配置与实验入口、数据结构、调度时序、BPF 接口及关键机制 |
| [观测与负载脚本](docs/sched_ext/scripts/) | scx_cpu0、scx_simple 状态观测，以及 scx_qmap 五级队列测试负载 |
| [配套图片](docs/sched_ext/res/img/) | 五级优先队列的任务分布与优先级示意 |

### 内核与基础学习笔记

保留原有文件编号，便于对照已有笔记。

| 编号 | 笔记 |
| --- | --- |
| 1 | [C 语言](<docs/学习笔记/1. C.md>) |
| 2 | [408 基础知识](<docs/学习笔记/2. 408基础知识.md>) |
| 3 | [数据库](<docs/学习笔记/3. 数据库.md>) |
| 4 | [Java](<docs/学习笔记/4. Java.md>) |
| 6 | [Linux 内核：调度](<docs/学习笔记/6. Linux 内核 - 调度 - 面试.md>) |
| 7 | [Linux 内核：同步](<docs/学习笔记/7. Linux 内核 - 同步 - 面试.md>) |
| 8 | [Linux 内核：中断](<docs/学习笔记/8. Linux 内核 - 中断 - 面试.md>) |
| 9 | [Linux 内核：内存](<docs/学习笔记/9. Linux 内核 - 内存 - 面试.md>) |
| 11 | [Linux 内核：追踪](<docs/学习笔记/11. Linux 内核 - 追踪 - 面试.md>) |
| 12 | [Linux 内核：常用维测命令](<docs/学习笔记/12. Linux 内核 - 常用维测命令.md>) |

### 调试、命令与编译

- [Linux 内核基础维测手段](docs/调试/Linux内核基础维测手段.md)：内核调试参数与配置。
- [调度器 kprobe 钩子示例](docs/调试/调度器kprobe钩子示例.md)：调度关键路径的动态探针示例。
- [调度类相关常用命令](docs/命令参考/调度类相关常用命令.md)：调度接口、策略与命令行工具。
- [内核编译命令](docs/编译/内核编译命令.md)：内核构建相关操作记录。

## 目录结构

```text
.
├── README.md
├── docs/
│   ├── sched/
│   │   ├── README.md
│   │   ├── 内核机制/              # EEVDF、Guard / Class
│   │   ├── 内核参数/              # 调度器参数指南
│   │   └── 问题分析/              # EEVDF、sched_ext 故障案例
│   ├── sched_ext/
│   │   ├── sched_ext_introduction.md
│   │   ├── sched_ext_完整技术文档.md
│   │   ├── scripts/               # 观测与测试负载
│   │   └── res/img/               # 配套图片
│   ├── 学习笔记/                  # 内核专题、基础知识与复习资料
│   ├── 调试/
│   ├── 命令参考/
│   └── 编译/
├── examples/
│   └── sched_setattr自定义slice示例.c
└── scripts/
    ├── build/                    # 内核构建与安装
    ├── debug/                    # perf / trace 采集与统计
    └── others/                   # cgroup 配置、QEMU / GDB 命令
```

## 实践资源

实践资源与文档配套，用于验证调度行为、采集运行数据和辅助排查问题。

| 位置 | 内容 | 对应环节 |
| --- | --- | --- |
| [examples/](examples/) | 自定义调度时间片的 C 示例 | 理解调度接口与参数效果 |
| [docs/sched_ext/scripts/](docs/sched_ext/scripts/) | scx_cpu0、scx_simple 观测与 scx_qmap 测试负载 | 验证示例调度策略 |
| [scripts/debug/](scripts/debug/) | perf / trace 采集、调度状态汇总、迁移与唤醒统计 | 从运行数据分析调度行为 |
| [scripts/build/](scripts/build/) | 内核构建与安装脚本 | 准备内核实验环境 |
| [scripts/others/](scripts/others/) | cgroup 配置与 QEMU / GDB 操作参考 | 配置实验场景与调试环境 |

脚本保留了个人实验环境配置，具体用法和适配要求见脚本及相关专题文档。

## 参考入口

- [Linux 内核源码与发布](https://kernel.org/)
- [Linux 内核文档](https://www.kernel.org/doc/html/latest/)
- [sched_ext 官方文档](https://www.kernel.org/doc/html/latest/scheduler/sched-ext.html)
