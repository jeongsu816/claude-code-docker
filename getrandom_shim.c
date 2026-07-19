/*
 * LD_PRELOAD shim: on kernels < 3.17 (e.g. some Synology DSM platforms
 * still on 3.10.x), the getrandom(2) syscall doesn't exist. Bun (the
 * runtime claude is compiled with) calls it via libc's generic syscall()
 * rather than the higher-level getrandom() symbol, so intercepting
 * syscall() catches that. Other programs in the container might instead
 * call the higher-level getrandom() libc symbol directly, so that's
 * overridden too, in case anything else on the system needs it. glibc's
 * arc4random()/arc4random_buf()/arc4random_uniform() are a third path that
 * needs its own override — see the comment above their implementations
 * below for why neither of the first two overrides catches those.
 *
 * On kernels that do have getrandom(2), the real syscall succeeds and this
 * shim is a no-op passthrough — safe to leave on unconditionally. Since
 * it's always active regardless of the actual kernel, the ENOSYS fallback
 * path is expected/routine rather than exceptional, so it doesn't log
 * anything.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/syscall.h>
#include <sys/types.h>

typedef long (*syscall_fn)(long number, ...);
static syscall_fn real_syscall = NULL;

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

/*
 * glibc >= 2.36's arc4random()/arc4random_buf()/arc4random_uniform() are
 * a separate problem: sshd calls these directly (confirmed via `nm -D
 * /usr/sbin/sshd`, which shows them as undefined GLIBC_2.36 symbols), but
 * glibc's own implementation reaches SYS_getrandom via a raw `syscall`
 * instruction inlined in its internal helper — not through the public
 * getrandom() or syscall() symbols — so neither override above ever sees
 * that call. On ENOSYS glibc treats this as unrecoverable and aborts
 * (`Fatal glibc error: cannot get entropy for arc4random`), which is what
 * was crashing sshd's per-connection child on affected kernels. Since
 * arc4random* are themselves normal exported dynamic symbols, overriding
 * them here intercepts the call before it ever reaches glibc's fragile
 * internal implementation, sidestepping the raw syscall entirely.
 */

static long get_random_bytes(void *buf, size_t buflen) {
    size_t filled = 0;
    while (filled < buflen) {
        long n = do_getrandom((char *)buf + filled, buflen - filled, 0);
        if (n <= 0) return -1;
        filled += (size_t)n;
    }
    return (long)filled;
}

void arc4random_buf(void *buf, size_t nbytes) {
    get_random_bytes(buf, nbytes);
}

uint32_t arc4random(void) {
    uint32_t val;
    get_random_bytes(&val, sizeof(val));
    return val;
}

/* Standard OpenBSD-style rejection sampling, avoids modulo bias. */
uint32_t arc4random_uniform(uint32_t upper_bound) {
    uint32_t r, min;

    if (upper_bound < 2) return 0;

    min = -upper_bound % upper_bound;

    for (;;) {
        r = arc4random();
        if (r >= min) break;
    }

    return r % upper_bound;
}
