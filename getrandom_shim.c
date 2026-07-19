/*
 * LD_PRELOAD shim: on kernels < 3.17 (e.g. some Synology DSM platforms
 * still on 3.10.x), the getrandom(2) syscall doesn't exist. Bun (the
 * runtime claude is compiled with) calls it via libc's generic syscall()
 * rather than the higher-level getrandom() symbol, so intercepting
 * syscall() here and falling back to /dev/urandom on ENOSYS covers every
 * getrandom(2) call site in the process, regardless of which one hits it.
 *
 * On kernels that do have getrandom(2), the real syscall succeeds and this
 * shim is a no-op passthrough.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/syscall.h>

typedef long (*syscall_fn)(long number, ...);
static syscall_fn real_syscall = NULL;

static long fallback_getrandom(void *buf, size_t buflen, unsigned int flags) {
    (void)flags;
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
        long ret = real_syscall(number, a1, a2, a3, a4, a5, a6);
        if (ret == -1 && errno == ENOSYS) {
            fprintf(stderr, "[getrandom_shim] SYS_getrandom -> ENOSYS, falling back to /dev/urandom\n");
            return fallback_getrandom((void *)a1, (size_t)a2, (unsigned int)a3);
        }
        return ret;
    }

    return real_syscall(number, a1, a2, a3, a4, a5, a6);
}
