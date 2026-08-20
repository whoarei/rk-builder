#include <stdio.h>

int main(void)
{
#if defined(__aarch64__)
    const char *arch = "aarch64";
#elif defined(__x86_64__)
    const char *arch = "x86_64";
#else
    const char *arch = "unknown";
#endif
    printf("hello from rk-builder (arch=%s, gcc=%d.%d.%d)\n",
           arch, __GNUC__, __GNUC_MINOR__, __GNUC_PATCHLEVEL__);
    return 0;
}
