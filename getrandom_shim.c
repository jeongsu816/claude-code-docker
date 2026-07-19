/*
 * LD_PRELOAD shim: on kernels < 3.17 (e.g. some Synology DSM platforms
 * still on 3.10.x), the getrandom(2) syscall doesn't exist. Bun (the
 * runtime claude is compiled with) calls it via libc's generic syscall()
 * rather than the higher-level getrandom() symbol, so intercepting
 * syscall() catches that. Other programs in the container might instead
 * call the higher-level getrandom() libc symbol directly, so that's
 * overridden too, in case anything else on the system needs it.
 *
 * On kernels that do have getrandom(2), the real syscall succeeds and this
 * shim is a no-op passthrough — safe to leave on unconditionally.
 *
 * The ENOSYS fallback is printed to stderr once per process (not per call,
 * since a process can easily make dozens of getrandom() calls). Simple
 * first version — whether that reaches `docker logs` depends on what the
 * calling process's stderr is connected to (supervisord-managed programs
 * like ttyd/filebrowser/sshd already have stderr_logfile=/dev/stderr, so
 * those are covered; an interactive SSH session's stderr goes to the SSH
 * client instead).
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/syscall.h>
#include <sys/types.h>

typedef long (*syscall_fn)(long number, ...);
static syscall_fn real_syscall = NULL;
static int logged = 0;

static void log_fallback_once(void) {
    if (logged) return;
    logged = 1;
    fprintf(stderr,
        "[getrandom_shim] pid=%d: SYS_getrandom -> ENOSYS (kernel lacks "
        "getrandom(2)); falling back to /dev/urandom for this and further "
        "calls\n",
        (int)getpid());
}

static long fallback_getrandom(void *buf, size_t buflen) {
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) return -1;
    ssize_t total = 0;
    while ((size_t)total < buflen) {
        ssize_t n = read(fd, (char *)buf + total, buflen - total);
        if (n <= 0) { close(fd); errno = EIO; return -1; }
        total += n;
    }
    close(fd);
    return total;
}

static long do_getrandom(void *buf, size_t buflen, unsigned int flags) {
    if (!real_syscall) {
        real_syscall = (syscall_fn)dlsym(RTLD_NEXT, "syscall");
    }
    long ret = real_syscall(SYS_getrandom, buf, buflen, flags);
    if (ret == -1 && errno == ENOSYS) {
        log_fallback_once();
        return fallback_getrandom(buf, buflen);
    }
    return ret;
}

ssize_t getrandom(void *buf, size_t buflen, unsigned int flags) {
    return do_getrandom(buf, buflen, flags);
}

long syscall(long number, ...) {
    if (!real_syscall) {
        real_syscall = (syscall_fn)dlsym(RTLD_NEXT, "syscall");
    }

    va_list ap;
    va_start(ap, number);
    long a1 = va_arg(ap, long);
    long a2 = va_arg(ap, long);
    long a3 = va_arg(ap, long);
    long a4 = va_arg(ap, long);
    long a5 = va_arg(ap, long);
    long a6 = va_arg(ap, long);
    va_end(ap);

    if (number == SYS_getrandom) {
        return do_getrandom((void *)a1, (size_t)a2, (unsigned int)a3);
    }

    return real_syscall(number, a1, a2, a3, a4, a5, a6);
}
