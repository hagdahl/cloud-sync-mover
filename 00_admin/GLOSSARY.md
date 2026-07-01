# GLOSSARY

| Term | Definition |
|---|---|
| Files-On-Demand (FoD) | Molnklientläge där filer visas i Utforskaren men innehållet laddas ned först vid åtkomst. |
| Platshållare (placeholder) | En online-only-fil: 0 byte lokalt, innehållet bara i molnet. Attribut `RECALL` (0x400000). |
| Hydrering | Att ladda ned en platshållares innehåll så den blir lokalt tillgänglig. |
| Pin / always-keep | "Behåll alltid på den här enheten". Attribut `PINNED` (0x80000). Sätts med `attrib +P`. |
| Metod A | Molnklientens egen flytt av datamappen: avlänka → länka om → Välj plats. Enda stödda vägen (OneDrive). |
| Junction | NTFS-kataloglänk. Fungerar INTE som flyttmetod för en aktiv synkmapp (inode-fällan). |
| Inode-fälla | Synkmotorn tolkar ändrad rotidentitet (via junction/robocopy) som "innehållet raderat" → molnradering. |
| KFM (Known Folder Move) | Skrivbord/Dokument/Bilder omdirigerade in i synkmappen. Pekas om med `SHSetKnownFolderPath`. |
| SMR | Shingled Magnetic Recording — arkivdisk, usel på små slumpvisa skrivningar. Olämplig för aktiv synk. |
| WAL | SQLite Write-Ahead Logging. Klientens state-DB är i WAL-läge och öppen — läs bara snapshot/immutable. |
| Throttling | Servern strypor anrop (HTTP 429/403) vid för hög frekvens, t.ex. under masshydrering. |
| RECALL / PINNED | Filattribut 0x400000 (online-only) resp. 0x80000 (pinnad). Grunden för status-klassning i fas 0. |
| Moln-facit | Molnets tillstånd (kvot/objekt via provider-API) som sanningskälla; jämförs före/efter för att bevisa att molnet är orört. |