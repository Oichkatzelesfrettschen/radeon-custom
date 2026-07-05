/* SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Terascale Functionalists
 *
 * Read-only GUI_DEBUG read-diff: detect whether GUI_DEBUG0..4 are dynamic
 * (free-running counters / activity status) or static (candidate config/control).
 * Maps resource2 (the 64KiB radeon register MMIO BAR) with PROT_READ ONLY -- the
 * binary has no write path, so it cannot perturb any register.  Consent-gated.
 * All five offsets read-completed in the deep inventory (no wedge).
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define BAR 0x10000u

static int
read_sysfs_hex(const char *path, unsigned *value)
{
   char buf[32];
   int fd = open(path, O_RDONLY);
   if (fd < 0) {
      perror(path);
      return -1;
   }
   ssize_t got = read(fd, buf, sizeof(buf) - 1);
   close(fd);
   if (got <= 0) {
      fprintf(stderr, "%s: empty sysfs value\n", path);
      return -1;
   }
   buf[got] = 0;
   *value = (unsigned)strtoul(buf, NULL, 16);
   return 0;
}

static int
verify_rs480_device(const char *device_dir)
{
   char path[256];
   unsigned vendor, device;
   snprintf(path, sizeof(path), "%s/vendor", device_dir);
   if (read_sysfs_hex(path, &vendor))
      return -1;
   snprintf(path, sizeof(path), "%s/device", device_dir);
   if (read_sysfs_hex(path, &device))
      return -1;
   if (vendor != 0x1002 || device != 0x5974) {
      fprintf(stderr,
              "refused: %s is vendor=0x%04x device=0x%04x, not RS480 1002:5974\n",
              device_dir, vendor, device);
      return -1;
   }
   return 0;
}

static int
env_int(const char *name, int fallback)
{
   const char *value = getenv(name);
   if (!value || !*value)
      return fallback;
   int parsed = atoi(value);
   return parsed > 0 ? parsed : fallback;
}

int
main(void)
{
   const char *consent = getenv("GUI_DEBUG_READDIFF_ACCEPTED");
   if (!consent || strcmp(consent, "1")) {
      fprintf(stderr, "refused: set GUI_DEBUG_READDIFF_ACCEPTED=1\n");
      return 2;
   }

   const char *device_dir = "/sys/bus/pci/devices/0000:01:05.0";
   if (verify_rs480_device(device_dir))
      return 2;

   char resource_path[256];
   snprintf(resource_path, sizeof(resource_path), "%s/resource2", device_dir);
   int fd = open(resource_path, O_RDONLY | O_SYNC);
   if (fd < 0) {
      perror("open");
      return 1;
   }
   volatile uint8_t *m = mmap(NULL, BAR, PROT_READ, MAP_SHARED, fd, 0);
   if (m == MAP_FAILED) {
      perror("mmap");
      close(fd);
      return 1;
   }

   struct {
      unsigned off;
      const char *nm;
   } r[] = {
      {0x0140, "CONFIG_MEMSIZE(static-ctrl)"},
      {0x16a0, "GUI_DEBUG0"},
      {0x16a4, "GUI_DEBUG1"},
      {0x16a8, "GUI_DEBUG2"},
      {0x16ac, "GUI_DEBUG3"},
      {0x16b0, "GUI_DEBUG4"},
   };
   int n = sizeof(r) / sizeof(r[0]);
   int samples = env_int("GUI_DEBUG_READDIFF_SAMPLES", 12);
   int interval_ms = env_int("GUI_DEBUG_READDIFF_INTERVAL_MS", 1000);

   printf("sample");
   for (int i = 0; i < n; i++)
      printf("\t%s", r[i].nm);
   printf("\n");
   for (int s = 0; s < samples; s++) {
      printf("%d", s);
      for (int i = 0; i < n; i++) {
         uint32_t v = *(volatile uint32_t *)(m + r[i].off);
         printf("\t0x%08x", v);
      }
      printf("\n");
      struct timespec ts = {
         .tv_sec = interval_ms / 1000,
         .tv_nsec = (long)(interval_ms % 1000) * 1000L * 1000L,
      };
      nanosleep(&ts, NULL);
   }
   munmap((void *)m, BAR);
   close(fd);
   return 0;
}
