#!/usr/bin/env python3
"""
seccomp-wrap.py — install a syscall denylist then exec into the session.
Blocks syscalls commonly used for sandbox escape or privilege escalation.
Falls back transparently if libseccomp is unavailable.

Usage: python3 seccomp-wrap.py [--] program [args...]
Installed into $TMPTFS at session start by user.sh.
"""
import ctypes, sys, os


def install_filter():
    SCMP_ACT_ALLOW = 0x7FFF0000
    SCMP_ACT_ERRNO = lambda e: 0x00050000 | (e & 0xFFFF)
    EPERM = 1

    lib = ctypes.CDLL("libseccomp.so.2", use_errno=True)
    lib.seccomp_init.restype                     = ctypes.c_void_p
    lib.seccomp_syscall_resolve_name.restype     = ctypes.c_int
    lib.seccomp_syscall_resolve_name.argtypes    = [ctypes.c_char_p]
    # use seccomp_rule_add_exact — same as seccomp_rule_add with arg_cnt=0
    # but has a fixed (non-variadic) signature, which ctypes handles correctly
    lib.seccomp_rule_add_exact.argtypes          = [ctypes.c_void_p, ctypes.c_uint32,
                                                    ctypes.c_int, ctypes.c_uint]
    lib.seccomp_rule_add_exact.restype           = ctypes.c_int
    lib.seccomp_load.argtypes                    = [ctypes.c_void_p]
    lib.seccomp_release.argtypes                 = [ctypes.c_void_p]

    ctx = lib.seccomp_init(SCMP_ACT_ALLOW)
    if not ctx:
        raise RuntimeError("seccomp_init returned NULL")

    # Denylist — ALLOW everything by default, kill these specifically.
    # Grouped by attack class.
    DENY = [
        # --- process tracing / cross-process memory ---
        b"ptrace",
        b"process_vm_readv",
        b"process_vm_writev",

        # --- kernel image / module loading ---
        b"kexec_load",
        b"kexec_file_load",
        b"init_module",
        b"finit_module",
        b"delete_module",
        b"create_module",
        b"get_kernel_syms",
        b"query_module",

        # --- performance counters (spectre/meltdown side-channels) ---
        b"perf_event_open",

        # --- kernel keyring (credential theft / auth bypass) ---
        b"add_key",
        b"request_key",
        b"keyctl",

        # --- userfaultfd (race-condition exploit primitive) ---
        b"userfaultfd",

        # --- raw hardware I/O ---
        b"iopl",
        b"ioperm",

        # --- swap control ---
        b"swapon",
        b"swapoff",

        # --- re-rooting from inside the session ---
        b"pivot_root",
        b"chroot",

        # --- process accounting ---
        b"acct",

        # --- clock manipulation (belt+suspenders with time namespace) ---
        b"settimeofday",
        b"clock_settime",
        b"clock_adjtime",
        b"adjtimex",

        # --- legacy / dead syscalls ---
        b"uselib",
        b"nfsservctl",
        b"sysfs",
    ]

    for name in DENY:
        nr = lib.seccomp_syscall_resolve_name(name)
        if nr < 0:
            continue  # unknown on this arch — skip silently
        lib.seccomp_rule_add_exact(ctx, SCMP_ACT_ERRNO(EPERM), nr, 0)

    ret = lib.seccomp_load(ctx)
    lib.seccomp_release(ctx)
    if ret != 0:
        raise RuntimeError(f"seccomp_load failed (ret={ret})")


def main():
    args = sys.argv[1:]
    if args and args[0] == "--":
        args = args[1:]
    if not args:
        print("seccomp-wrap: no command given", file=sys.stderr)
        sys.exit(1)

    try:
        install_filter()
    except Exception as e:
        # Fail open — don't abort the session if seccomp is unavailable
        print(f"seccomp-wrap: warning: {e}", file=sys.stderr)

    os.execvp(args[0], args)


if __name__ == "__main__":
    main()
