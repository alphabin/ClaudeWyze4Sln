#include <spawn.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <libgen.h>
extern char **environ;
static pid_t child = 0;
static void relay(int sig) { if (child > 0) kill(child, sig); }
int main(void) {
    char exe[4096]; uint32_t n = sizeof exe; _NSGetExecutablePath(exe, &n);
    char script[4096];
    snprintf(script, sizeof script, "%s", READER); (void)exe;
    char *argv[] = {"/usr/bin/python3", "-u", script, NULL};
    signal(SIGTERM, relay); signal(SIGINT, relay);
    if (posix_spawn(&child, argv[0], NULL, NULL, argv, environ) != 0) { perror("spawn"); return 1; }
    int st = 0; waitpid(child, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
}
