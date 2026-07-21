/*
 * LD_PRELOAD shim: on kernels < 3.17 (e.g. some Synology DSM platforms
 * still on 3.10.x), the getrandom(2) syscall doesn't exist. Bun (the
 * runtime claude is compiled with) calls it via libc's generic syscall()
 * rather than the higher-level getrandom() symbol, so intercepting
 * syscall() catches that. Other programs in the container might instead
 * call the higher-level getrandom() libc symbol directly, so that's
 * overridden too, in case anything else on the system needs it. glibc's
 * arc4random()/arc4random_buf()/arc4random_uniform() are a third path, and
 * OpenSSL's getentropy() (used by sshd, via libcrypto) is a fourth — see
 * the comments above each implementation below for why neither of the
 * first two overrides catches those. Getting this shim to actually reach
 * every one of these paths on a real old-kernel host (not just under the
 * seccomp ENOSYS simulation) also needed installing it via
 * /etc/ld.so.preload, not just LD_PRELOAD — see the Dockerfile.
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
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/syscall.h>
#include <sys/types.h>

typedef long (*syscall_fn)(long number, ...);
static syscall_fn real_syscall = NULL;

/*
 * /dev/urandom is opened lazily, on first actual need, and then the fd is
 * cached in this static and reused forever after — never closed, never
 * reopened. Two things this specifically avoids, both found the hard way
 * against the real sshd binary (via `strace -f`, not guessed):
 *
 * 1. Opening it eagerly at library-load time (a __attribute__((constructor))
 *    tried first) doesn't survive: sshd's master calls
 *    close_range(3, ~0, 0) early in its own startup — a real, independent
 *    OpenSSH hardening step that unconditionally closes every fd above 2,
 *    with no regard for who opened them or why. Any fd opened before that
 *    point is gone, full stop; no fd number or CLOEXEC choice dodges it.
 * 2. Opening it fresh on *every* call (open+read+close each time) works
 *    fine for the master, but not for a later per-connection child: sshd
 *    applies its own internal seccomp-BPF sandbox to that pre-auth,
 *    network-facing process (independent of any container-level seccomp,
 *    and no longer even configurable off via sshd_config's long-removed
 *    UsePrivilegeSeparation directive on modern OpenSSH), and that
 *    sandbox's syscall allowlist has no reason to include open()/openat()
 *    — a healthy sshd never opens new files at that point. A fresh open()
 *    call there gets the whole process killed with SIGSYS.
 *
 * The fix both of those rule out: open once, the first time anything here
 * actually needs a fallback — which in practice happens early in the
 * master's own startup (OpenSSL seeding its PRNG via getentropy(), see
 * below), safely *after* close_range already ran. Caching instead of
 * closing means that same fd is still open and valid when sshd later
 * forks a per-connection child — fork() duplicates the fd table as-is, so
 * the child inherits an already-open fd and never needs to call open() at
 * all, sidestepping the sandbox restriction entirely rather than trying to
 * work around it.
 */
static int urandom_fd = -1;

static long fallback_getrandom(void *buf, size_t buflen) {
    if (urandom_fd < 0) {
        urandom_fd = open("/dev/urandom", O_RDONLY);
        if (urandom_fd < 0) return -1;
    }
    ssize_t total = 0;
    while ((size_t)total < buflen) {
        ssize_t n = read(urandom_fd, (char *)buf + total, buflen - total);
        if (n <= 0) { errno = EIO; return -1; }
        total += n;
    }
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
    if (get_random_bytes(buf, nbytes) < 0) abort();
}

uint32_t arc4random(void) {
    uint32_t val;
    if (get_random_bytes(&val, sizeof(val)) < 0) abort();
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

/*
 * A fourth path, found via a real crash on the real NAS: OpenSSL 3.x
 * (libcrypto.so.3, which sshd links against for its crypto — confirmed via
 * `nm -D libcrypto.so.3`, showing an undefined `getentropy@GLIBC_2.25`
 * import) seeds its own PRNG through glibc's getentropy() wrapper, not
 * getrandom() or syscall() or arc4random* — a *fifth* symbol beyond the
 * three already covered above, and this shim didn't override it, so
 * OpenSSL's calls sailed straight past every override in this file and hit
 * ENOSYS raw. Unlike arc4random's fatal abort, OpenSSL just gives up
 * quietly ("PRNG is not seeded" on stderr) and sshd's *master* process
 * exits outright — not just a per-connection child. Confirmed via `strace
 * -f -e trace=getrandom,openat,...` against the real sshd binary under the
 * seccomp ENOSYS simulation: two getrandom syscalls fail with ENOSYS with
 * no fallback read() in between (unlike calls that do go through this
 * shim), immediately followed by that message and exit. getentropy()'s
 * real contract caps requests at 256 bytes (glibc returns EIO above that)
 * — preserved here for compatibility, though this shim's callers so far
 * never approach that.
 */
int getentropy(void *buffer, size_t length) {
    if (length > 256) { errno = EIO; return -1; }
    if (get_random_bytes(buffer, length) < 0) return -1;
    return 0;
}
