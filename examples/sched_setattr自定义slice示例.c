// gcc set_slice.c -o set_slice && sudo ./set_slice $PID

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>        // for atoi()
#include <linux/sched.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <string.h>
#include <stdint.h>
#include <sched.h>         // for SCHED_OTHER

struct sched_attr {
    uint32_t size;
    uint32_t sched_policy;
    uint64_t sched_flags;
    int32_t  sched_nice;
    uint32_t sched_priority;
    uint64_t sched_runtime;   // <-- 我们要用的字段
    uint64_t sched_deadline;
    uint64_t sched_period;
};

int sched_setattr(pid_t pid, const struct sched_attr *attr, unsigned int flags)
{
    return syscall(__NR_sched_setattr, pid, attr, flags);
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <pid>\n", argv[0]);
        return 1;
    }

    pid_t pid = atoi(argv[1]);
    struct sched_attr attr;
    memset(&attr, 0, sizeof(attr));
    attr.size = sizeof(attr);
    attr.sched_policy = SCHED_OTHER;  // 普通 CFS 任务
    attr.sched_nice = 0;

    // 设置自定义 slice，比如 2ms
    attr.sched_runtime = 0.5 * 1000 * 1000ULL; // 2ms = 2,000,000ns

    if (sched_setattr(pid, &attr, 0) == -1) {
        perror("sched_setattr");
        return 1;
    }

    printf("✅ Set custom slice (sched_runtime) = %llu ns for pid %d\n",
           (unsigned long long)attr.sched_runtime, pid);
    return 0;
}
