count = 0
count1 = 0
count2 = 0
pid_cpu_dict = {}
with open("trace_66_4_taskset0-3_20250821_150537", "r") as f:
    for line in f:
        if 'orig_cpu' not in line:
            continue
        
        orig_cpu = int(line.split("orig_cpu=")[1].split(" ")[0])
        dest_cpu = int(line.split("dest_cpu=")[1].split(" ")[0])
        pid = int(line.split("pid=")[1].split(" ")[0])
        # 总迁移次数
        if orig_cpu != dest_cpu:
            count += 1
            if pid not in pid_cpu_dict:
                pid_cpu_dict[pid] = [0, 0, 0]
            pid_cpu_dict[pid][0] += 1
		
		# 跨cluster次数
        if (orig_cpu // 4) != (dest_cpu // 4):
            count1 += 1
            if pid not in pid_cpu_dict:
                pid_cpu_dict[pid] = [0, 0, 0]
            pid_cpu_dict[pid][1] += 1

		# 跨NUMA次数
        if (orig_cpu // 32) != (dest_cpu // 32):
            count2 += 1
            if pid not in pid_cpu_dict:
                pid_cpu_dict[pid] = [0, 0, 0]
            pid_cpu_dict[pid][2] += 1

print("cpu mig %d, cluster mig %d, numa mig %d" %(count,count1,count2))
for pid, counts in pid_cpu_dict.items():
    print('pid={}, cpu={}, cluster={}, numa={}'.format(pid, counts[0], counts[1], counts[2]))
