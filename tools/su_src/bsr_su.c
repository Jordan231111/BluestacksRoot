/* Ungated, daemonless su for BlueStacks (Android 11 x86_64).
 * setuid-root binary: drops to full root and execs the requested command/shell.
 * No host hypercall, no daemon, no gate -> always grants when setuid-root. */
#include <unistd.h>
#include <string.h>
int main(int argc, char** argv) {
    setresgid(0,0,0);
    setresuid(0,0,0);
    const char* sh = "/system/bin/sh";
    int i = 1;
    if (i < argc && (!strcmp(argv[i],"0") || !strcmp(argv[i],"root"))) i++;     /* su 0 / su root */
    if (i < argc && !strcmp(argv[i],"-c")) {                                    /* su [0] -c "cmd" */
        i++;
        if (i < argc) execl(sh, "sh", "-c", argv[i], (char*)0);
        execl(sh, "sh", (char*)0);
    }
    if (i < argc && argv[i][0] != '-') execvp(argv[i], &argv[i]);               /* su 0 id  (direct) */
    execl(sh, "sh", (char*)0);                                                  /* interactive */
    return 1;
}
