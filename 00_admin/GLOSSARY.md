# GLOSSARY

| Term | Definition |
|---|---|
| Files-On-Demand (FoD) | Cloud client mode where files appear in Explorer but the content is downloaded only on access. |
| Placeholder (placeholder) | An online-only file: 0 bytes locally, the content only in the cloud. Attribute `RECALL` (0x400000). |
| Hydration | Downloading a placeholder's content so it becomes locally available. |
| Pin / always-keep | "Always keep on this device". Attribute `PINNED` (0x80000). Set with `attrib +P`. |
| Method A | The cloud client's own move of the data folder: unlink → relink → Choose location. The only supported path (OneDrive). |
| Junction | NTFS directory link. Does NOT work as a move method for an active sync folder (the inode trap). |
| Inode trap | The sync engine interprets a changed root identity (via junction/robocopy) as "content deleted" → cloud deletion. |
| KFM (Known Folder Move) | Desktop/Documents/Pictures redirected into the sync folder. Repointed with `SHSetKnownFolderPath`. |
| SMR | Shingled Magnetic Recording — archive disk, terrible at small random writes. Unsuitable for active sync. |
| WAL | SQLite Write-Ahead Logging. The client's state DB is in WAL mode and open — read only a snapshot/immutable copy. |
| Throttling | The server throttles calls (HTTP 429/403) at too high a frequency, e.g. during mass hydration. |
| RECALL / PINNED | File attributes 0x400000 (online-only) and 0x80000 (pinned) respectively. The basis for status classification in phase 0. |
| Cloud ground truth | The cloud's state (quota/objects via the provider API) as the source of truth; compared before/after to prove the cloud is untouched. |
