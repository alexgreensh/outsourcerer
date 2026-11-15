#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void pause_target(const char *path) {
  const char *target = getenv("PAUSE_TARGET");
  if (!target) return;
  const char *base = strrchr(target, '/');
  base = base ? base + 1 : target;
  if (strcmp(path, target) && strcmp(path, base)) return;
  int fd = open(getenv("PAUSE_READY"), O_WRONLY | O_CREAT, 0600);
  if (fd >= 0) {
    char buf[32];
    int len = snprintf(buf, sizeof buf, "%ld\n", (long)getpid());
    if (len > 0) (void)write(fd, buf, (size_t)len);
    close(fd);
  }
  while (access(getenv("PAUSE_GO"), F_OK)) usleep(10000);
}

int unlinkat(int fd, const char *path, int flags) {
  if (flags & AT_REMOVEDIR) pause_target(path);
  int (*real_fn)(int, const char *, int) = dlsym(RTLD_NEXT, "unlinkat");
  return real_fn(fd, path, flags);
}

int rmdir(const char *path) {
  pause_target(path);
  int (*real_fn)(const char *) = dlsym(RTLD_NEXT, "rmdir");
  return real_fn(path);
}
