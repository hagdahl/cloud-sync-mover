# DEFINITION_OF_DONE (A5)

En flytt utförd med denna verktygslåda är klar när:

1. **Fas 0-inventering** finns (inventory-CSV + pinlist), och drift-checken (schedule-LastRun vs data-LastWrite) är ren eller åtgärdad.
2. **MD5-baslinje** finns för alla lokala filer (fas 1).
3. **Preflight** grön: fri plats, skrivbarhet, "Uppdaterad"-status, disktyp (ej SMR-varning ignorerad), moln-baslinje sparad.
4. **Flytten utförd via Metod A** (klientens egen funktion) — inte junction.
5. **Strukturverifiering** visar verkliga saknade filer ~0 (endast klassat skräp i "missing").
6. **Hydrerings-medveten efterverify** grön: stickprov 0 online-only, full MD5-jämförelse mot baslinjen med 0 oförklarade mismatch (enhetsberoende genvägar vitlistade).
7. **Moln-facit** oförändrat: kvot-/objekt-diff mot fas-2-baslinjen = 0.
8. **CHANGELOG-post** skriven med rollback.
9. **Radering av källan är INTE gjord** förrän `min_stable_days` dygn stabil synk + uttryckligt `-Execute`; källan flyttas (inte raderas) till backup först.
10. **Loggning räcker** för att felsöka i efterhand (varje fas har `*_done.json` + logg).

Ett projekt-DoD (för själva repot): mandatoriska artefakter finns (README, .gitignore, CHANGELOG, DECISIONS, HANDOVER, GLOSSARY, ARCHITECTURE, USER_GUIDE, config.example, LICENSE), scripten är ASCII-verifierade, ingen PII i spårat innehåll (se `04_tests/validation`).