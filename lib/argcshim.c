/* Give Qt an argument list inside Quickshell.
 *
 * QtWebEngine builds Chromium's command line from QCoreApplication::arguments()
 * and calls qFatal when it comes back empty:
 *
 *   FATAL: Argument list is empty, the program name is not passed to
 *          QCoreApplication. base::CommandLine cannot be properly initialized.
 *
 * Quickshell parses its own command line and deliberately keeps Qt out of argv,
 * so it hands Q[Gui]Application a hard-coded argc of 0 next to the real argv
 * (qs::launch::launch, `movl $0x0,-0x2e8(%rbp)` in 0.3.1). Nothing on the
 * command line can change it, and there is no config or environment switch:
 * the value is a constant in the binary.
 *
 * Both constructors take argc by reference, so setting it to 1 before
 * delegating gives Qt the program name — the only thing Chromium is asking for.
 * Everything else about the process is left alone.
 *
 * This is preloaded across the session, so it refuses to act anywhere but in
 * Quickshell, and only when argc really is 0. In every other process it is
 * dead weight and nothing more.
 *
 * Built by install.sh; loaded by an LD_PRELOAD line in ~/.config/hypr/envs.conf.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef void (*ctor_t)(void *, int *, char **, int);

static int host_is_quickshell(void) {
  static int cached = -1;
  if (cached >= 0) return cached;

  char path[4096];
  ssize_t used = readlink("/proc/self/exe", path, sizeof path - 1);
  if (used <= 0) {
    cached = 0;
    return cached;
  }
  path[used] = '\0';

  const char *name = strrchr(path, '/');
  name = name ? name + 1 : path;
  cached = strcmp(name, "quickshell") == 0;
  return cached;
}

static void give_qt_a_program_name(int *argc, char **argv) {
  if (!host_is_quickshell()) return;
  if (!argc || *argc != 0 || !argv || !argv[0]) return;

  *argc = 1;
  fprintf(stderr, "argcshim: argc 0 -> 1 so QtWebEngine can start\n");
}

static void delegate(const char *symbol, void *self, int *argc, char **argv,
                     int version) {
  ctor_t real = (ctor_t)dlsym(RTLD_NEXT, symbol);
  if (!real) {
    fprintf(stderr, "argcshim: could not find %s, giving up\n", symbol);
    return;
  }
  give_qt_a_program_name(argc, argv);
  real(self, argc, argv, version);
}

void qgui_application_ctor(void *self, int *argc, char **argv, int version)
    asm("_ZN15QGuiApplicationC1ERiPPci");
void qgui_application_ctor(void *self, int *argc, char **argv, int version) {
  delegate("_ZN15QGuiApplicationC1ERiPPci", self, argc, argv, version);
}

void qapplication_ctor(void *self, int *argc, char **argv, int version)
    asm("_ZN12QApplicationC1ERiPPci");
void qapplication_ctor(void *self, int *argc, char **argv, int version) {
  delegate("_ZN12QApplicationC1ERiPPci", self, argc, argv, version);
}
