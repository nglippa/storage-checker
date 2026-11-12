# Local APFS snapshot capability investigation

Date: 2026-11-12. Target: macOS 27.2, build 26B123. Status: native lifecycle
success **NOT VERIFIED**. This follow-up does not enable management, install a
helper, change system protections or replace the published 3.0.0 package.

## Credentials, privileges and capabilities

A paid developer membership, Developer ID certificate and notarization are not
inherent prerequisites for compiling or running a local snapshot caller. They
must not be conflated with the filesystem authorization and entitlement checks
performed by macOS. Full Disk Access does not satisfy those separate checks.
Ad-hoc signing is possible without a developer certificate; adding an entitlement
to a signature does not itself authorize that entitlement.

The pinned [public XNU dispatcher](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/vfs/vfs_syscalls.c#L14342-L14418)
checks a recognized snapshot entitlement before a separate root/device-write
authorization check. This indicates that root alone does not bypass the first
check in that source. The source is not established as the exact source of this
installed kernel, so it is supporting evidence rather than a substitute for a
target-machine test. Listing follows a different
[getattrlistbulk wrapper](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/libsyscall/wrappers/fs_snapshot.c#L37-L48).

Apple's [signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements),
[provisioning profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
and [notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
describe distinct identity, entitlement authorization and distribution concerns.
This investigation establishes neither a generally available grant process for
`com.apple.developer.vfs.snapshot` nor that paying for membership would grant it.

## Direct disposable-image probes

`scripts/prepare-apfs-platform-probe.sh` prepares a fresh 256 MB APFS sparse image
and a plain ad-hoc native probe. `tests/APFSSnapshotPlatformProbe.c` has no target
arguments: its mountpoint, UUID, BSD device and unique snapshot name are compiled
for that image. It verifies the descriptor identity and invokes the native
create function without the production helper's root/entitlement preflight.
It attempts deletion only after that invocation successfully creates its own
snapshot. No existing user snapshot is selected for deletion.

Two app-like variants were also prepared locally with the same native probe:

| Probe | Actual result |
| --- | --- |
| Plain ad-hoc caller, UID 501, no snapshot entitlement | Verified disposable target; native create returned `EPERM` (errno 1); no deletion attempted |
| Ad-hoc caller claiming `com.apple.developer.vfs.snapshot`, no provisioning profile | Terminated with SIGKILL before main; no native API result |
| Plain caller as administrator/root | Pending user-run administrator test; no result established |

The system AMFI log explicitly attributes the second termination to an ad-hoc
signature containing restricted entitlements (`AppleMobileFileIntegrityError`,
code -424). Thus self-adding this entitlement was rejected on this target.
It does not establish a universal requirement for paid membership or notarization.

The initial management-suite denial tests stopped at the application's preflight;
they did **not** establish the kernel's behavior. These direct probes address that
evidence gap. No native creation or deletion succeeded in the completed probes.
The disposable image is retained mounted while the requested administrator test
is pending. Raw logs and its generated target identity remain local temporary
evidence rather than public repository artifacts.

## Documented utility alternatives checked

Read-only inspection covered installed man pages for `diskutil`, `tmutil`,
`apfs.util`, `apfs_systemsnapshot`, and `bless`; `apropos snapshot`; APFS bundle
resources; and executable names in `/usr/bin`, `/usr/sbin`, `/usr/libexec`.

- `diskutil apfs` documents listing and deletion, with no general creation verb.
- `tmutil localsnapshot` creates Time Machine-managed snapshots and does not
  provide the requested arbitrary-volume, arbitrary-name ownership domain.
- `apfs.util` documents no creation verb. Its `-R` schedules a destructive revert;
  its `-s` changes UUIDs. Neither was invoked.
- `apfs_systemsnapshot -s name -v mountpoint` is documented for Signed System
  Volumes and requires disabling authenticated-root SIP from recoveryOS. It is
  outside this product's scope; no system protection was changed.
- `bless --create-snapshot` is a root/boot snapshot workflow that selects the next
  boot root. It is not a general data-volume creator for this product.

This bounded inventory found no documented general named-snapshot creation
utility suitable for an unentitled caller on an ordinary APFS data/image volume.
It is not a claim that every possible OS interface has been exhausted. Private
interfaces and system-protection workarounds were not pursued.

## Implementation consequences and remaining checks

Keep the current fail-closed native capability gate. The same-Team identity and
profile requirements are choices of this implementation's privileged boundary,
not universal APFS filesystem requirements. Startup Data is currently excluded
by the product's role-bearing-volume policy; no Data-volume mutation test proves
that the OS itself forbids it.

Remaining acceptance: root-only plain probe; a supported accepted capability
route if required; successful disposable-volume create/readback/protect/compare/
unmount/preview/delete/readback; real authorization and installed-helper security
testing. No internal/external user-drive mutation is authorized by these probes.

The read-only intelligence and the local swap-presentation changes remain usable
independently of this capability investigation.
