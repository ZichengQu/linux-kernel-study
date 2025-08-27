count = 0
count1 = 0
count2 = 0
pid_cpu_dict = {}
with open("trace_66_4_20250821_110025", "r") as f:
    for line in f:
        if 'sched_waking' not in line:
            continue

        #waker_comm = line.split(">-")[0].split("<")[1]
        waker_pid = int(line.split("[")[0].split("-")[-1])
        waker_cpu = int(line.split("[")[1].split("]")[0])
        wakee_pid = int(line.split("pid=")[1].split(" ")[0])
        wakee_cpu = int(line.split("target_cpu")[1].split("=")[1])
        wakee_comm = line.split("comm=")[1].split(" ")[0]

        count += 1
        if wakee_pid not in pid_cpu_dict:
            pid_cpu_dict[wakee_pid] = [0, 0, 0, 0]
            pid_cpu_dict[wakee_pid][3] = wakee_comm
        pid_cpu_dict[wakee_pid][0] += 1

        if (wakee_cpu // 4) != (waker_cpu // 4):
            count1 += 1
            if wakee_pid not in pid_cpu_dict:
                pid_cpu_dict[wakee_pid] = [0, 0, 0, 0]
                pid_cpu_dict[wakee_pid][3] = wakee_comm
            pid_cpu_dict[wakee_pid][1] += 1

        if (wakee_cpu // 32) != (waker_cpu // 32):
            count2 += 1
            if wakee_pid not in pid_cpu_dict:
                pid_cpu_dict[wakee_pid] = [0, 0, 0, 0]
                pid_cpu_dict[wakee_pid][3] = wakee_comm
            pid_cpu_dict[wakee_pid][2] += 1

print(" waking cnt %d, cluster %d, numa %d" %(count,count1,count2))
sorted_dict = dict(sorted(pid_cpu_dict.items(), key=lambda x: x[0], reverse=True))
for pid, counts in sorted_dict.items():
    print('pid={}, comm={}, waking={}, cluster={}, numa={}'.format(pid, counts[3], counts[0], counts[1], counts[2]))
