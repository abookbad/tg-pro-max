#ifndef CPROC_H
#define CPROC_H
#include <stdint.h>
#include <sys/types.h>

typedef struct { pid_t pid; pid_t ppid; uid_t uid; int64_t start; char name[33]; } tg_proc;

/// Every process the kernel will describe; returns the count written.
int tg_list(tg_proc *out, int max);
/// Start time (seconds since 1970) or -1 when the pid is gone. Guards against pid reuse before signalling.
int64_t tg_start(pid_t pid);
/// User + system CPU time in nanoseconds; 0 when unavailable (other users' processes).
uint64_t tg_cpu_ns(pid_t pid);
/// Executable path. 0 on success.
int tg_path(pid_t pid, char *buf, int len);
/// Current working directory. 0 on success.
int tg_cwd(pid_t pid, char *buf, int len);
/// argv joined by '\n' (argv[0] included). 0 on success.
int tg_args(pid_t pid, char *buf, int len);
/// Listening TCP ports, deduplicated; returns the count.
int tg_listen_ports(pid_t pid, uint16_t *out, int max);

#endif
