#!/bin/bash
set -euo pipefail

# ========= 配色 =========
C_INFO="\033[1;32m[INFO]\033[0m"
C_CMD="\033[1;34m[CMD]\033[0m"
C_ERR="\033[1;31m[ERROR]\033[0m"

# ========= 输出函数 =========
log()      { echo -e "$C_INFO $1"; }
run_cmd()  { echo -e "$C_CMD $1"; eval "$1"; }
log_cmd()  { echo -e "$C_CMD $1"; echo "（仅打印，未执行）"; }

# ========= Git 同步代码 =========
update_repo() {
    log "同步代码：git fetch + reset"
    run_cmd "git fetch origin"
    run_cmd 'git reset --hard origin/qzc/branch_name'
}

# ========= 内核构建 =========
build_kernel() {
    log "开始构建 Kernel..."

    NR_CPUS=$(nproc)

    log "设置 Makefile 的 EXTRAVERSION = qzc"
    run_cmd "sed -i 's/^EXTRAVERSION =.*/EXTRAVERSION =qzc/' Makefile"

    run_cmd "make clean -s"

    run_cmd "make defconfig -s" # openeuler_defconfig

    run_cmd "make menuconfig"

    run_cmd "make -j$NR_CPUS -s"
}

# ========= 安装内核 =========
install_kernel() {
    NR_CPUS=$(nproc)

    log "安装 modules..."
    run_cmd "sudo make modules_install -j$NR_CPUS -s INSTALL_MOD_STRIP=1"

    log "安装 kernel..."
    run_cmd "sudo make install -j$NR_CPUS -s INSTALL_MOD_STRIP=1"

    log "设置 grub 默认启动项：0"
    run_cmd "sudo grub2-set-default 0"
}

# ========= 更新 GRUB cmdline =========
append_cmdline() {
    KERNEL_VERSION=$(ls -t /boot/vmlinuz-* | head -n1 | xargs basename | sed 's/^vmlinuz-//')
    log "检测到当前已安装的最新内核版本（reboot之后会用到的内核版本）：$KERNEL_VERSION"

    GRUB_ARGS="systemd.unified_cgroup_hierarchy=0" # cgroup v1
    # GRUB_ARGS="systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all" # cgroup v2

    log "追加 GRUB 启动参数：$GRUB_ARGS"
    run_cmd "sudo grubby --update-kernel=/boot/vmlinuz-$KERNEL_VERSION --args=\"$GRUB_ARGS\""
}

# ========= 总流程入口 =========
usage() {
    echo "用法：$0 [update|build|install|cmdline|all]"
    exit 0
}

ACTION="${1:-all}"

case "$ACTION" in
    update)    update_repo ;;
    build)     build_kernel ;;
    install)   install_kernel ;;
    cmdline)   append_cmdline ;;
    all)
        # update_repo
        build_kernel
        install_kernel
        append_cmdline
        log "全部流程完成！请重启系统以使用新内核。"
        ;;
    *) usage ;;
esac
