// iOS build of the bundled engine. NodeMobile on iOS ships no POSIX flock
// addon, and the native runtime runs one DSH worker per app container, so the
// session write claim is already exclusive inside the process. Mirror the
// browser worker and treat the kernel lock as acquired.

export async function tryLockExclusive() {}
