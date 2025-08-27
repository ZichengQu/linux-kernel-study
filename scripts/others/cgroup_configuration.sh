#!/bin/bash

# Cgroup 管理脚本 (直接操作文件系统)
# 功能: 创建、配置和管理 cgroup

not_executed() {
	# 使用介绍
	mount -t cgroup2 none /sys/fs/cgroup || mount -t cgroup none /sys/fs/cgroup
	chmod +x cgroup.sh

	# 显示帮助
	./cgroup.sh -h

	# 创建 cgroup
	./cgroup.sh -c

	# 设置资源限制
	./cgroup.sh -s

	# 将现有进程添加到 cgroup
	./cgroup.sh -a 1234

	# 删除 cgroup
	./cgroup.sh -d

	# 列出所有 cgroup
	./cgroup.sh -l
}

set -e

# 配置变量
CGROUP_NAME="qzc_cgroup"
CGROUP_PATH="/sys/fs/cgroup"  # Cgroup 挂载点
CPU_QUOTA=50000               # 50ms CPU时间 (单位: μs)
CPU_PERIOD=100000             # 100ms周期 (单位: μs)
MEMORY_LIMIT="500M"           # 内存限制 500MB (单位: 字节, 可以使用 K,M,G 后缀)
CPUSET_CPUS="0-1"             # 可使用的CPU核心范围 (例如: "0-1" 或 "0,2")
CPUSET_MEMS="0"               # 可使用的内存节点 (通常为0)
SUBSYSTEMS="cpu memory cpuset" # 要控制的子系统 (添加了cpuset)

# 显示帮助信息
show_help() {
    cat << EOF
使用方法: $0 [选项]
选项:
  -c, --create      创建 cgroup
  -s, --set-limits  设置资源限制
  -a, --add-pid     将现有进程添加到 cgroup
  -d, --delete      删除 cgroup
  -l, --list        列出所有 cgroup
  -h, --help        显示此帮助信息

示例:
  $0 -c             创建 cgroup
  $0 -s             设置资源限制
  $0 -a 1234        将 PID 1234 添加到 cgroup
  $0 -d             删除 cgroup
EOF
}

# 检查 cgroup 文件系统是否已挂载
check_cgroup_mounted() {
    if ! mount | grep -q "cgroup on $CGROUP_PATH"; then
        echo "错误: Cgroup 文件系统未挂载在 $CGROUP_PATH"
        echo "尝试挂载: sudo mount -t cgroup2 none $CGROUP_PATH || sudo mount -t cgroup none $CGROUP_PATH"
        exit 1
    fi
}

# 设置 CPU 亲和性 (CPU pinning)
set_cpuset() {
    echo "设置 CPU 亲和性: CPUs: $CPUSET_CPUS, Memory Nodes: $CPUSET_MEMS"
    
    # 设置 CPU 亲和性 (cgroup v1)
    if [ -f "$CGROUP_PATH/cpuset/$CGROUP_NAME/cpuset.cpus" ]; then
        echo $CPUSET_CPUS | sudo tee "$CGROUP_PATH/cpuset/$CGROUP_NAME/cpuset.cpus" > /dev/null
        echo $CPUSET_MEMS | sudo tee "$CGROUP_PATH/cpuset/$CGROUP_NAME/cpuset.mems" > /dev/null
    # 设置 CPU 亲和性 (cgroup v2)
    elif [ -f "$CGROUP_PATH/$CGROUP_NAME/cpuset.cpus" ]; then
        echo $CPUSET_CPUS | sudo tee "$CGROUP_PATH/$CGROUP_NAME/cpuset.cpus" > /dev/null
        echo $CPUSET_MEMS | sudo tee "$CGROUP_PATH/$CGROUP_NAME/cpuset.mems" > /dev/null
    else
        echo "警告: 未找到 cpuset 控制文件，可能不支持 CPU 亲和性设置"
    fi
    
    echo "✅ CPU 亲和性设置成功"
}

# 创建 cgroup
create_cgroup() {
    echo "创建 cgroup: $CGROUP_NAME"
    
    for subsystem in $SUBSYSTEMS; do
        local subsystem_path="$CGROUP_PATH/$subsystem/$CGROUP_NAME"
        echo "创建 $subsystem 子系统 cgroup: $subsystem_path"
        sudo mkdir -p "$subsystem_path"
        
        # 确保当前用户有权限操作新创建的 cgroup
        sudo chmod 755 "$subsystem_path"
    done
    
    echo "✅ Cgroup 创建成功"
}

# 设置 CPU 和内存限制
set_limits() {
    echo "设置 CPU 限制: $CPU_QUOTA/$CPU_PERIOD μs"
    
    # 设置 CPU 限制 (cgroup v1)
    if [ -f "$CGROUP_PATH/cpu/$CGROUP_NAME/cpu.cfs_quota_us" ]; then
        echo $CPU_QUOTA | sudo tee "$CGROUP_PATH/cpu/$CGROUP_NAME/cpu.cfs_quota_us" > /dev/null
        echo $CPU_PERIOD | sudo tee "$CGROUP_PATH/cpu/$CGROUP_NAME/cpu.cfs_period_us" > /dev/null
    # 设置 CPU 限制 (cgroup v2)
    elif [ -f "$CGROUP_PATH/$CGROUP_NAME/cpu.max" ]; then
        echo "$CPU_QUOTA $CPU_PERIOD" | sudo tee "$CGROUP_PATH/$CGROUP_NAME/cpu.max" > /dev/null
    else
        echo "警告: 未找到 CPU 控制文件，可能不支持 CPU 控制"
    fi
    
    echo "设置内存限制: $MEMORY_LIMIT"
    
    # 设置内存限制 (cgroup v1)
    if [ -f "$CGROUP_PATH/memory/$CGROUP_NAME/memory.limit_in_bytes" ]; then
        echo $MEMORY_LIMIT | sudo tee "$CGROUP_PATH/memory/$CGROUP_NAME/memory.limit_in_bytes" > /dev/null
    # 设置内存限制 (cgroup v2)
    elif [ -f "$CGROUP_PATH/$CGROUP_NAME/memory.max" ]; then
        echo $MEMORY_LIMIT | sudo tee "$CGROUP_PATH/$CGROUP_NAME/memory.max" > /dev/null
    else
        echo "警告: 未找到内存控制文件，可能不支持内存控制"
    fi
    
    # 设置 CPU 亲和性
    set_cpuset
    
    echo "✅ 资源限制设置成功"
}

# 将现有进程添加到 cgroup
add_pid_to_cgroup() {
    local pid="$1"
    if [ -z "$pid" ]; then
        echo "错误: 未提供进程ID"
        exit 1
    fi
    
    echo "将进程 $pid 添加到 cgroup $CGROUP_NAME"
    
    for subsystem in $SUBSYSTEMS; do
        # cgroup v1
        if [ -d "$CGROUP_PATH/$subsystem/$CGROUP_NAME" ]; then
            echo $pid | sudo tee "$CGROUP_PATH/$subsystem/$CGROUP_NAME/cgroup.procs" > /dev/null
        # cgroup v2
        elif [ -d "$CGROUP_PATH/$CGROUP_NAME" ]; then
            echo $pid | sudo tee "$CGROUP_PATH/$CGROUP_NAME/cgroup.procs" > /dev/null
        fi
    done
    
    echo "✅ 进程已添加到 cgroup"
}

# 删除 cgroup
delete_cgroup() {
    echo "删除 cgroup: $CGROUP_NAME"
    
    for subsystem in $SUBSYSTEMS; do
        local subsystem_path="$CGROUP_PATH/$subsystem/$CGROUP_NAME"
        if [ -d "$subsystem_path" ]; then
            echo "删除 $subsystem 子系统 cgroup: $subsystem_path"
            sudo rmdir "$subsystem_path"
        fi
    done
    
    # 对于 cgroup v2
    local cgroup_v2_path="$CGROUP_PATH/$CGROUP_NAME"
    if [ -d "$cgroup_v2_path" ]; then
        echo "删除 cgroup v2: $cgroup_v2_path"
        sudo rmdir "$cgroup_v2_path"
    fi
    
    echo "✅ Cgroup 删除成功"
}

# 列出所有 cgroup
list_cgroups() {
    echo "当前系统中的 cgroup:"
    
    # 列出 cgroup v1
    if [ -d "$CGROUP_PATH/cpu" ]; then
        echo "Cgroup v1:"
        find "$CGROUP_PATH" -name "*.procs" -o -name "*.max"
    fi
    
    # 列出 cgroup v2
    if [ -d "$CGROUP_PATH" ] && [ ! -d "$CGROUP_PATH/cpu" ]; then
        echo "Cgroup v2:"
        find "$CGROUP_PATH" -name "cgroup.procs" -o -name "*.max"
    fi
}

# 主函数
main() {
    # 检查 cgroup 文件系统是否已挂载
    check_cgroup_mounted
    
    # 如果没有提供任何参数，显示帮助信息并退出
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--create)
                create_cgroup
                shift
                ;;
            -s|--set-limits)
                set_limits
                shift
                ;;
            -a|--add-pid)
                add_pid_to_cgroup "$2"
                shift 2
                ;;
            -d|--delete)
                delete_cgroup
                shift
                ;;
            -l|--list)
                list_cgroups
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 执行主函数
main "$@"
