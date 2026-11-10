# CloudKit setup (one time)

Sync uses the private database of container `iCloud.com.jsglazer.tech-pomodoro`, zone `Pomodoro`, with three record types (`IntervalRecord`, `Settings`, and `MirrorRecord` for iPhone mirroring of the Mac timer: one per iPhone, per Mac and per APNs broadcast channel), each carrying its value as a JSON `payload`. Every build targets the **Production** environment (see the entitlements in `project.yml`), so the Developer ID Mac app and the Xcode-installed iPhone app share one database.

Production record types cannot be created by the app at runtime, so the schema has to exist there before sync works:

1. Register the container: any signed build with `-allowProvisioningUpdates` (the DMG export in `MakeDMG.sh`, or `MakeiOSDeploy.sh`) creates `iCloud.com.jsglazer.tech-pomodoro` on team PWGXN26URQ and adds iCloud to the App IDs.
2. Import the schema into Development, either in CloudKit Console (icloud.developer.apple.com → the container → Schema → Record Types → add the three types and fields listed in `schema.ckdb`) or with cktool after saving a management token (`xcrun cktool save-token --type management`):
   ```
   xcrun cktool import-schema --team-id PWGXN26URQ --container-id iCloud.com.jsglazer.tech-pomodoro --environment development --file CloudKit/schema.ckdb
   ```
3. In CloudKit Console, **Deploy Schema Changes…** to Production.

Until then the Settings tab shows the CloudKit error next to "Sync via iCloud"; the app works normally, and anything not yet uploaded is offered again on the next launch.

**After a schema change** (1.0.15 added `MirrorRecord`): repeat steps 2 and 3. Importing the whole `schema.ckdb` again is safe; existing types are left as they are. Until `MirrorRecord` is in Production, mirroring reads nothing and the Mac's status line shows the CloudKit error.

**1.0.23 (paper corrections): no schema change.** Paper corrections are stored as `IntervalRecord`-type records named `pc-<uuid>`, with the correction's JSON in `payload` and its `modifiedAt` in `startedAt`, so nothing needs deploying in the CloudKit console. Older app versions fail to decode such a payload as an interval and skip it.
