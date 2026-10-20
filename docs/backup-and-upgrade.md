# Backup and upgrade behavior

## This release

The Calendar / Maps / Timeline / Settings navigation and existing controls stay
in place. Styling uses forest green and warm cream with a corresponding dark
palette. Backup stays in Settings → Backup → Export / Import.

There is no Google OAuth dependency in this release. Install and sign in to the
Google Drive iOS app, then enable Drive in Files → Browse → More → Edit. Choose
Drive as the destination in Daymark's Export picker, or select a Drive ZIP from
Import. This route uses the system file provider and works independently of
Daymark's iCloud sync. A Files save confirmation is not a guarantee that Drive
has finished its remote upload; check the Drive app before removing local data.

Apple's setup guide: https://support.apple.com/102238

## Existing users

- The app bundle identifier, production SwiftData store URL, CloudKit container,
  schema and signed-in/anonymous data partitions have not changed.
- An App Store/TestFlight update must keep the same bundle ID and signing team.
  Do not uninstall first. Debug builds intentionally use a separate database;
  an empty Debug library does not demonstrate that production data was lost.
- Export reads modern Original files, SwiftData embedded imageData and legacy
  Application Support/DayPhotos files. Launch-time migration is not a prerequisite.
- The migration retains legacy files and their filenames as fallbacks.
- For signed-in libraries only, missing originals can be downloaded from the
  existing custom CloudKit original-asset zone. Hash and byte count are verified.
  Export never uploads or deletes cloud assets. SwiftData's older mirrored blobs
  still need to finish arriving through normal iCloud mirroring if they are not
  also present in the original-asset zone.
- Missing, corrupt or conflicted originals block a complete export with an error.
  Thumbnails are never silently substituted for originals.

## Archive format v3

A standard ZIP/ZIP64 archive contains entries.json and images/*. The original
image bytes and actual file extensions are preserved. Each entry stores a SHA-256
hash, byte count and calendar day key, in addition to the existing date, capture
time, location, country, city, time zone and caption fields. Dates remain ISO 8601
with fractional seconds (millisecond precision). The day key always uses the
Gregorian calendar, independently of the system display calendar, and preserves
the selected calendar day when restoring in a different time zone.
An inconsistent day key from an older experimental non-Gregorian v3 archive is
rejected rather than silently interpreted as the wrong year. Those files lack a
source-calendar identifier and need their dates reviewed before restoration.

The archive contains all journal entries in the currently open library. Signed-in
and anonymous libraries remain separate; exporting one does not include the other.
Account credentials, appearance preferences, sync bookkeeping and disposable
thumbnail/view caches are not included. Original photos and user metadata are the
source of truth; thumbnail and view assets are regenerated during import.

The writer runs off the main actor and writes one photo at a time. ZIPFoundation
0.9.20 is pinned in Package.resolved. The completed archive is reread and checked
before the file exporter is shown. Photos or metadata changing during preparation
invalidate the snapshot so it can be retried.

The importer accepts v1 embedded-photo JSON and v2/v3 ZIP, including deflate and
ZIP64. It verifies file paths, duplicate records, CRC, and v3 hashes/sizes, and stages
photos before touching library metadata. Export and import preparation also
decode photo pixels through ImageIO: a recognizable header and matching checksum
alone cannot certify a restorable image. It rejects unsupported future versions.
Metadata is capped at 32 MB per ZIP; legacy standalone JSON is capped at 512 MB.
Those limits apply to metadata/legacy JSON, not to the total ZIP size.

## Restore semantics

- The existing confirmation shows the date range, photo count and overlapping days.
- Merge keeps existing days and reports the actual skipped count.
- Overwrite replaces only matching days, preserving local entry IDs so existing
  cloud identities are not orphaned. Other days remain in the library.
- New entries retain their backup IDs unless an ID is already in use or still
  awaiting cloud deletion. In those cases a fresh ID prevents an older in-flight
  deletion from deleting the restored entry.
- All renditions are prepared before changes are applied. Cancellation or an
  invalid photo leaves existing records and referenced files intact.
- Metadata commits in one save; old files are cleaned up only after success.
- Restore completes locally. Optional iCloud sync remains independent.
- Every restored metadata field is recorded as a new local revision, including
  fields equal to an old local baseline. A first sync with an older same-ID cloud
  record therefore does not silently replace the restored values. Later edits
  continue to be detected normally. Different original photos still use the
  existing explicit photo-conflict resolution flow.

## Automated restore verification

The backup checks include complete multi-entry export/import with exact original
bytes and hashes; every user metadata field; Unicode, multiline, empty and nil
values; a new on-disk database reopened twice; edited metadata and replacement
photos exported and imported into another empty library; v1/v2 compatibility;
corrupt and missing originals; cancellation; merge and overwrite; different
calendar preferences and time zones; and restored metadata written to a simulated
remote store. Test libraries, photo directories and remote services are isolated
from the user's real library and iCloud account.

## Next stage: direct Google Drive integration

The user selected Files-based export for this release because a Google OAuth
client has not been created. Direct in-app Drive login, automatic backup,
incremental uploads and automatic retention are not implemented or advertised.

For that stage, configure a Google Cloud project with Drive API enabled, an iOS
OAuth client for com.shizhengcao.Daymark, and an OAuth consent screen. The public
iOS Client ID and its reversed URL scheme are needed; never embed a client secret.
Use drive.file scope, the Google Sign-In iOS SDK, Keychain token storage, visible
Daymark/Backups folders, resumable uploads, and verified backup manifests.

References:
- https://developers.google.com/identity/sign-in/ios/start-integrating
- https://developers.google.com/workspace/drive/api/guides/api-specific-auth
- https://developers.google.com/workspace/drive/api/guides/manage-uploads

## Device release check

On a device containing the released app's real library, install the new signed
Release build over it. Confirm the same dates and photos appear, export to Files,
then verify a separate empty test library can import that archive. Also exercise
Drive upload/download with the actual account and network. Simulator tests use
synthetic photos and cannot verify a user's real iCloud/Google account or the
App Store upgrade installation itself.
