#include "CProc.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <mach/mach_time.h>
#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>

int tg_list(tg_proc *out, int max) {
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return 0;
    int cap = n + 64;
    pid_t *pids = malloc(sizeof(pid_t) * cap);
    if (!pids) return 0;
    n = proc_listallpids(pids, (int)(sizeof(pid_t) * cap));
    int c = 0;
    for (int i = 0; i < n && c < max; i++) {
        if (pids[i] <= 0) continue;
        struct proc_bsdinfo b;
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &b, sizeof b) != (int)sizeof b) continue;
        tg_proc *p = &out[c++];
        p->pid = pids[i]; p->ppid = (pid_t)b.pbi_ppid; p->uid = b.pbi_uid; p->start = (int64_t)b.pbi_start_tvsec;
        strlcpy(p->name, b.pbi_name[0] ? b.pbi_name : b.pbi_comm, sizeof p->name);
    }
    free(pids);
    return c;
}

int64_t tg_start(pid_t pid) {
    struct proc_bsdinfo b;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, sizeof b) != (int)sizeof b) return -1;
    return (int64_t)b.pbi_start_tvsec;
}

uint64_t tg_cpu_ns(pid_t pid) {
    struct rusage_info_v2 r;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&r) != 0) return 0;
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (r.ri_user_time + r.ri_system_time) * tb.numer / tb.denom;
}

int tg_path(pid_t pid, char *buf, int len) {
    return proc_pidpath(pid, buf, (uint32_t)len) > 0 ? 0 : -1;
}

int tg_cwd(pid_t pid, char *buf, int len) {
    struct proc_vnodepathinfo v;
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &v, sizeof v) != (int)sizeof v) return -1;
    strlcpy(buf, v.pvi_cdir.vip_path, (size_t)len);
    return 0;
}

int tg_args(pid_t pid, char *buf, int len) {
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size < sizeof(int)) return -1;
    char *raw = malloc(size);
    if (!raw) return -1;
    if (sysctl(mib, 3, raw, &size, NULL, 0) != 0) { free(raw); return -1; }
    int argc; memcpy(&argc, raw, sizeof argc);
    char *p = raw + sizeof argc, *end = raw + size;
    while (p < end && *p) p++;   // executable path
    while (p < end && !*p) p++;  // padding
    int o = 0;
    for (int i = 0; i < argc && p < end; i++) {
        size_t l = strnlen(p, (size_t)(end - p));
        if (o + (int)l + 2 > len) break;
        if (o) buf[o++] = '\n';
        memcpy(buf + o, p, l); o += (int)l; p += l + 1;
    }
    buf[o] = 0;
    free(raw);
    return 0;
}

int tg_listen_ports(pid_t pid, uint16_t *out, int max) {
    int size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (size <= 0) return 0;
    struct proc_fdinfo *fds = malloc((size_t)size);
    if (!fds) return 0;
    size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, size);
    int n = size / (int)sizeof(struct proc_fdinfo), c = 0;
    for (int i = 0; i < n && c < max; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
        struct socket_fdinfo s;
        if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &s, sizeof s) != (int)sizeof s) continue;
        if (s.psi.soi_kind != SOCKINFO_TCP || s.psi.soi_proto.pri_tcp.tcpsi_state != TSI_S_LISTEN) continue;
        uint16_t port = ntohs((uint16_t)s.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport);
        int dup = 0;
        for (int j = 0; j < c; j++) if (out[j] == port) dup = 1;
        if (!dup && port) out[c++] = port;
    }
    free(fds);
    return c;
}
