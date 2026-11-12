// Direct platform probe, intentionally separate from the production helper's policy gates.
// ProbeTarget.h is generated for ONE freshly created disposable APFS image. No target argv.
#include "SnapshotNative.h"
#include "ProbeTarget.h"
#include <stdio.h>
#include <unistd.h>
#include <errno.h>

#ifndef PROBE_VARIANT
#define PROBE_VARIANT "plain"
#endif

int main(int argc, char **argv) {
    (void)argv;
    if (argc != 1) return 64;
    int fd = sm_snapshot_open(PROBE_MOUNT, PROBE_UUID, PROBE_DEVICE);
    if (fd < 0) {
        printf("{\"uid\":%u,\"target_verified\":false,\"target_errno\":%d}\n", geteuid(), -fd);
        return 1;
    }
    // No geteuid/entitlement preflight: the purpose is to observe the actual kernel result.
    const char *name = PROBE_NAME "." PROBE_VARIANT;
    int entitlement = sm_snapshot_has_entitlement();
    int created = sm_snapshot_create(fd, name);
    int deleted = -1;
    // Never delete a pre-existing snapshot. Only this invocation's successful creation is removed.
    if (created == 0) deleted = sm_snapshot_delete(fd, name);
    printf("{\"variant\":\"%s\",\"uid\":%u,\"target_verified\":true,\"developer_snapshot_entitlement\":%s,\"create_errno\":%d,\"delete_attempted\":%s,\"delete_errno\":%d}\n",
           PROBE_VARIANT, geteuid(), entitlement ? "true" : "false", created, created == 0 ? "true" : "false", deleted);
    close(fd);
    return created == 0 && deleted == 0 ? 0 : 1;
}
