#!/bin/bash

# 性能火焰图生成脚本
# 支持三种模式：在线模式、离线模式和差分模式
#
# 用法:
#   在线模式: ./perf_flame.sh online "<command>"
#   离线模式: ./perf_flame.sh offline [duration] # duration的单位是秒s
#   差分模式: ./perf_flame.sh diff <folded_file1> <folded_file2>
#
# 示例:
#   在线模式: ./perf_flame.sh online "bonnie++ -d /tmp"
#   离线模式: ./perf_flame.sh offline 10
#   差分模式: ./perf_flame.sh diff perf1.folded perf2.folded

set -euo pipefail

# 配置变量
PERF_OUTPUT_PATH="/tmp/qzc/perf"
PERF_OUTPUT_FILE_NAME="qzc_sched_ext_perf"
FREQ=99
FLAMEGRAPH_DIR="./FlameGraph" #  git clone https://github.com/brendangregg/FlameGraph.git -b master FlameGraph && cd ./FlameGraph && chmod +x *.pl

# 创建输出目录
mkdir -p "$PERF_OUTPUT_PATH"

# 生成带时间戳的文件名
generate_filename() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    echo "${PERF_OUTPUT_FILE_NAME}_${timestamp}"
}

# 在线模式 - 执行命令并记录性能数据
perf_record_online() {
    local command=$1
    local output_file=$2
    
    echo "[1/4] perf record (online)..."
    perf record -F "$FREQ" -g -- bash -c "$command"
    mv perf.data "perf.${output_file}.data"
}

# 离线模式 - 记录特定事件的性能数据（简化版，固定参数）
perf_record_offline() {
    local duration=$1
    local output_file=$2
    
    echo "[1/4] perf record (offline)..."
    perf record -e sched:sched_switch -a -g -- sleep "$duration"
    mv perf.data "perf.${output_file}.data"
}

# 处理 perf 数据
process_perf_data() {
    local output_file=$1
    
    echo "[2/4] perf script..."
    perf script -i "perf.${output_file}.data" > "perf.${output_file}.unfold"
    
    echo "[3/4] stackcollapse-perf.pl..."
    "${FLAMEGRAPH_DIR}/stackcollapse-perf.pl" "perf.${output_file}.unfold" > "perf.${output_file}.folded"
}

# 生成火焰图
generate_flamegraph() {
    local input_file=$1
    local output_file=$2
    
    echo "[4/4] flamegraph.pl..."
    "${FLAMEGRAPH_DIR}/flamegraph.pl" "$input_file" > "$output_file"
}

# 生成差分火焰图
generate_diff_flamegraph() {
    local folded1=$1
    local folded2=$2
    local output_file=$3
    
    echo "[1/2] Generating diff folded data..."
    "${FLAMEGRAPH_DIR}/difffolded.pl" "$folded1" "$folded2" > "perf.${output_file}.folded"
    
    echo "[2/2] Generating diff flamegraph..."
    "${FLAMEGRAPH_DIR}/flamegraph.pl" "perf.${output_file}.folded" > "perf.${output_file}.svg"
}

# 移动文件到输出目录
move_to_output() {
    local output_file=$1
    shift
    
    mkdir -p "$PERF_OUTPUT_PATH/$output_file"
    mv "$@" "$PERF_OUTPUT_PATH/$output_file/"
}

# 在线模式主函数
online_mode() {
    local command=$1
    local output_file=$(generate_filename)
    
    perf_record_online "$command" "$output_file"
    process_perf_data "$output_file"
    generate_flamegraph "perf.${output_file}.folded" "perf.${output_file}.svg"
    
    move_to_output "$output_file" "perf.${output_file}."*
    echo "✅ 在线模式 FlameGraph 生成完成: ${PERF_OUTPUT_PATH}/${output_file}/perf.${output_file}.svg"
}

# 离线模式主函数
offline_mode() {
    local duration=${1:-10}
    local output_file=$(generate_filename)
    
    perf_record_offline "$duration" "$output_file"
    process_perf_data "$output_file"
    generate_flamegraph "perf.${output_file}.folded" "perf.${output_file}.svg"
    
    move_to_output "$output_file" "perf.${output_file}."*
    echo "✅ 离线模式 FlameGraph 生成完成: ${PERF_OUTPUT_PATH}/${output_file}/perf.${output_file}.svg"
}

# 差分模式主函数
diff_mode() {
    local folded1=$1
    local folded2=$2
    local output_file=$(generate_filename)
    
    generate_diff_flamegraph "$folded1" "$folded2" "$output_file"
    
    move_to_output "$output_file" "perf.${output_file}"*
    echo "✅ 差分 FlameGraph 生成完成: ${PERF_OUTPUT_PATH}/${output_file}/perf.${output_file}_diff.svg"
}

# 显示用法信息
usage() {
    echo "用法:"
    echo "  在线模式: $0 online \"<command>\""
    echo "  离线模式: $0 offline [duration]"
    echo "  差分模式: $0 diff <folded_file1> <folded_file2>"
    echo ""
    echo "示例:"
    echo "  在线模式: $0 online \"bonnie++ -d /tmp\""
    echo "  离线模式: $0 offline 10"
    echo "  差分模式: $0 diff perf1.folded perf2.folded"
    exit 1
}

# 主函数
main() {
    if [ $# -lt 1 ]; then
        usage
    fi
    
    local mode=$1
    shift
    
    case $mode in
        "online")
            if [ $# -lt 1 ]; then
                echo "错误: 在线模式需要一个参数(命令)"
                usage
            fi
            online_mode "$@"
            ;;
        "offline")
            offline_mode "$@"
            ;;
        "diff")
            if [ $# -lt 2 ]; then
                echo "错误: 差分模式需要两个folded文件作为参数"
                usage
            fi
            diff_mode "$@"
            ;;
        *)
            echo "错误: 未知模式 '$mode'"
            usage
            ;;
    esac
}

# 执行主函数
main "$@"
