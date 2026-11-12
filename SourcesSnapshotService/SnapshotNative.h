#ifndef STORAGE_MONITOR_SNAPSHOT_NATIVE_H
#define STORAGE_MONITOR_SNAPSHOT_NATIVE_H
#include <stdint.h>
int sm_snapshot_open(const char *path, const char *uuid, const char *device);
int sm_snapshot_create(int fd, const char *name);
int sm_snapshot_delete(int fd, const char *name);
int sm_snapshot_mount(int fd, const char *path, const char *name);
int sm_snapshot_unmount(const char *path);
int sm_snapshot_has_entitlement(void);
int sm_snapshot_allow_search(const char *path, uint32_t uid);
#endif
