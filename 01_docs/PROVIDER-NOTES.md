# PROVIDER-NOTES — tjänstespecifika detaljer

Det enda specifika i detta projekt är vilka tjänster och klientversioner det är testat mot. Inga miljöer, personer eller system nämns.

## OneDrive (Personal och Business)

- **Flyttmetod:** Metod A — Inställningar → Konto → **Avlänka den här datorn**, kör sedan om inloggningen och välj **Välj plats/Change location** → peka på måldisken. Detta är enda av Microsoft stödda vägen. Junction/symlink stöds inte. Cachen kan inte flyttas — den byggs om på ny plats (vid behov via Reset).
- **Testade klientversioner:** 26.106.0603.0003 och 26.108.0607.0002 (Windows).
- **Files-On-Demand-attribut:** online-only = `FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS` (0x400000); pinnad "behåll alltid" = `FILE_ATTRIBUTE_PINNED` (0x80000). Pinna med `attrib +P` (ej `.NET SetAttributes`).
- **Tillstånd/diagnos:** `%LOCALAPPDATA%\Microsoft\OneDrive\settings\<konto>\` — SQLite. Nyckelfiler: `SyncEngineDatabase.db` (tabeller `od_ClientFile_Records.fileStatus`, `od_ServiceOperationHistory.resultCode/scenarioName`, `od_ThrottleHistory`), `OCSI.db` (`ocsi_property_records.conflictJson`). Konton: `Personal`, `Business1`, ...
- **Loggar:** `%LOCALAPPDATA%\Microsoft\OneDrive\logs\<konto>\` — `.aodl` (klartext, magic `EBFGONED`), `.odlgz` (gzip).
- **Known Folder Move:** om Skrivbord/Dokument/Bilder är omdirigerade in i OneDrive, peka om via `SHSetKnownFolderPath` (shell32) efter flytten.
- **Moln-facit:** Microsoft Graph, `Connect-MgGraph -Scopes Files.Read`, `Invoke-MgGraphRequest` mot `/me/drive` (kvot). Graph exponerar inga synkloggar.

## Google Drive för desktop

- **Flyttmetod:** byt mappens plats i klientens **inställningar** (motsvarar Metod A). Streaming-läge (File Stream) håller inget lokalt; spegelläge (Mirror) speglar lokalt.
- **Testad generation:** 2024–2025-klienten.
- **Kritisk lärdom (inode-fällan):** flytta ALDRIG en spegel-mapp via junction eller robocopy och starta klienten mot den — klienten tolkar ändrad rotidentitet som "innehållet raderat" och lägger objekt i molnets papperskorg, och kan platta ut mappstrukturen. Håll klienten helt avstängd tills moln och lokalt är konsekventa; återställ i molnet parent-first om något trashats.
- **Diskval:** en aktivt synkad Drive-spegel på en SMR-disk ger 100 % diskaktivitet — undvik.
- **Loggar:** `%LOCALAPPDATA%\Google\DriveFS\Logs\drive_fs.txt` (klartext) — sök `MIRROR_GDOC_DELETED` (radering), `changed inode` (identitetsändring).

## Generellt
Vilken provider som helst med Files-On-Demand + en inbyggd "byt plats"-funktion passar mönstret. Har klienten ingen sådan funktion: eskalera, flytta aldrig bakom klientens rygg.