##################################################
# qemu_start_x86
##################################################
#!/bin/bash

image_path=$1

if [ -z "$image_path" ]; then
    echo "Usage: $0 <image_path>"
    image_path=~/code/linux-mainline/arch/x86/boot/bzImage
    #exit 1
fi

qemu-system-x86_64 \
    -m 8G \
	-smp 4,sockets=1,cores=4,threads=1 \
	-kernel ${image_path} \
	-append "console=ttyS0 root=/dev/sda rw earlyprintk=serial net.ifnames=0 nokaslr systemd.unified_cgroup_hierarchy=true cgroup1_writeback debug no_hash_pointers" \
	-drive file=rootfs.img,format=raw \
	-nographic \
	-net user,hostfwd=tcp::10023-:22 \
	-net nic,model=e1000 \
	-pidfile vm.pid \
	-hdc ./disk.img \
	-gdb tcp::1122 \
	2>&1 | tee vm.log

#-hdc ./disk.img \
#-gdb tcp::1122 -S \ # 开启 debug 调试，会直接卡住，需要 gdb 连接并continue放行后才会继续执行

##################################################
# qemu_ssh_x86
##################################################
ssh -p 10023 root@0.0.0.0

##################################################
# qemu_scp_x86
##################################################
scp -P 10023 repro root@localhost:/root/

##################################################
# gdb_x86_debug
##################################################
#!/bin/bash

vmlinx_path=$1

if [ -z "$vmlinx_path" ]; then
    echo "Usage: $0 <vmlinx_path>"
    vmlinx_path=~/code/linux-mainline/vmlinux
    #exit 1
fi

echo "===================="
echo "target remote localhost:1122"
echo "===================="

/home/hulk/code/tools/gdb-15.2/gdb_build/gdb/gdb ${vmlinx_path}
