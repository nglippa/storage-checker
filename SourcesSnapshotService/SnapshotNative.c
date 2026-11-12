#include "SnapshotNative.h"
#include <sys/snapshot.h>
#include <sys/mount.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/acl.h>
#include <membership.h>
#include <uuid/uuid.h>
#include <Security/SecTask.h>
#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

// Return fd or negative errno. Identity comes from the held descriptor, not a cached path/device.
int sm_snapshot_open(const char *path, const char *uuid, const char *device) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY);
    if (fd < 0) return -errno;
    struct statfs fs; struct stat st;
    struct attrlist attrs = {0}; attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    struct { uint32_t length; uuid_t uuid; } identity;
    struct { uint32_t length; vol_capabilities_attr_t caps; } capabilities;
    uuid_t expected;
    int error = EINVAL;
    if (uuid_parse(uuid, expected) || fstat(fd, &st) || fstatfs(fd, &fs)) goto fail;
    if (strcmp(fs.f_fstypename, "apfs") || (fs.f_flags & MNT_RDONLY) || strcmp(fs.f_mntonname, path) || strncmp(fs.f_mntfromname, "/dev/", 5) || strcmp(fs.f_mntfromname+5, device)) goto fail;
    attrs.volattr = ATTR_VOL_INFO | ATTR_VOL_UUID;
    if (fgetattrlist(fd, &attrs, &identity, sizeof(identity), 0)) { error = errno; goto fail; }
    if (uuid_compare(expected, identity.uuid)) goto fail;
    attrs.volattr = ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES;
    if (fgetattrlist(fd, &attrs, &capabilities, sizeof(capabilities), 0)) { error = errno; goto fail; }
    if (!(capabilities.caps.valid[VOL_CAPABILITIES_INTERFACES] & VOL_CAP_INT_SNAPSHOT) || !(capabilities.caps.capabilities[VOL_CAPABILITIES_INTERFACES] & VOL_CAP_INT_SNAPSHOT)) { error = ENOTSUP; goto fail; }
    return fd;
fail:
    close(fd); return -error;
}
int sm_snapshot_create(int fd, const char *name) { return fs_snapshot_create(fd, name, 0) == 0 ? 0 : errno; }
int sm_snapshot_delete(int fd, const char *name) { return fs_snapshot_delete(fd, name, 0) == 0 ? 0 : errno; }
int sm_snapshot_mount(int fd, const char *path, const char *name) {
    return fs_snapshot_mount(fd, path, name, SNAPSHOT_MNT_NOEXEC | SNAPSHOT_MNT_NOSUID | SNAPSHOT_MNT_NODEV | SNAPSHOT_MNT_DONTBROWSE | SNAPSHOT_MNT_NOFOLLOW) == 0 ? 0 : errno;
}
int sm_snapshot_unmount(const char *path) { return unmount(path, 0) == 0 ? 0 : errno; }
int sm_snapshot_has_entitlement(void) {
    SecTaskRef task = SecTaskCreateFromSelf(NULL);
    if (!task) return 0;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.developer.vfs.snapshot"), NULL);
    int result = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)value);
    if (value) CFRelease(value); CFRelease(task); return result;
}
// Grant only directory traversal to the requesting UID. Never disable snapshot file ownership.
int sm_snapshot_allow_search(const char *path, uint32_t uid) {
    uuid_t user; if (mbr_uid_to_uuid(uid, user)) return EINVAL;
    acl_t acl = acl_get_file(path, ACL_TYPE_EXTENDED);
    if (!acl) acl = acl_init(1);
    if (!acl) return errno;
    acl_entry_t existing;
    int flag = ACL_FIRST_ENTRY;
    while (acl_get_entry(acl, flag, &existing) == 0) {
        flag = ACL_NEXT_ENTRY;
        void *q = acl_get_qualifier(existing);
        int same = q && !uuid_compare(q, user); if (q) acl_free(q);
        if (same) { acl_free(acl); return 0; }
    }
    acl_entry_t entry; acl_permset_t permissions;
    if (acl_create_entry(&acl, &entry) || acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) || acl_set_qualifier(entry, user) || acl_get_permset(entry, &permissions) || acl_add_perm(permissions, ACL_SEARCH) || acl_set_permset(entry, permissions) || acl_set_file(path, ACL_TYPE_EXTENDED, acl)) { int e = errno; acl_free(acl); return e; }
    acl_free(acl); return 0;
}
