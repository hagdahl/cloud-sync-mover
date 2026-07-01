# VERIFY-PROMPT — verifiera att ett projekt/jobb fungerar efter en flytt

> Återanvändbar prompt att klistra in (peka på rätt projektmapp) efter att projektfiler/beroenden flyttats till ny disk eller ny sökväg. Mål: bevisa att projektet fortfarande startar och kör INNAN det körs skarpt nästa gång. Kör som granskning (dry-run) — ändra inget utan godkännande.

## Sökvägshistorik (vanlig antagandekrock)
Data flyttar ofta mellan platser över tid (strömmad molnenhet → lokal spegel → annan disk, nådd via junction). Gamla absoluta sökvägar lever kvar i script/config och måste hittas och rättas. Flagga särskilt hårdkodade sökvägar som pekar på en tidigare plats.

## Gör detta (rapportera PASS/FAIL per punkt)

1. **Sökvägar pekar rätt.** Verifiera att projektmapp + nyckelfiler finns. Sök `*.py, *.ps1, *.json, *.env*, config*` efter hårdkodade absoluta sökvägar; flagga varje som pekar på en tidigare disk/plats. Ersätt med relativ sökväg eller central config.
2. **Python-venv (vanligaste felkällan).** Kontrollera `.venv\pyvenv.cfg` (`home = ...`) och `.venv\Scripts\`. Smoke-test: `python.exe -c "import sys; print(sys.prefix)"`. Felar → återskapa venv + `pip install -r requirements.txt`.
3. **Node-beroenden.** node_modules är oftast sökvägsoberoende men symlänkar/.bin kan brytas. Smoke-test projektets test/lint. Fel → `npm ci`.
4. **Config & hemligheter.** `.env`/`config.local` finns och pekar rätt. Inga sökvägar mot tidigare plats.
5. **Schemalagda jobb.** Lista tasks kopplade till projektet; kontrollera att Action/arbetskatalog pekar rätt. En path-flytt bryter ALLA tasks — repointa alla. Verifiera med manuell trigger (`Start-ScheduledTask`), inte genom att vänta på nästa fönster.
6. **Tjänster/MCP.** Om projektet exponerar en server/endpoint: verifiera att den startar och svarar.
7. **Synkens hälsa.** Om filerna ligger i en synkmapp: bekräfta att strukturen i molnet är intakt och att klientens loggar inte visar växande raderingar.
8. **Funktionellt smoke-test.** Kör minsta "hello world"/enhetstest. Rapportera utfall.

## Rapportformat
Tabell: `Steg | Status (PASS/FAIL/WARN) | Detalj/åtgärd`. Avsluta med "Klart att köra: JA/NEJ" + åtgärdslista.

## Vanliga åtgärder vid FAIL
- gammal sökväg → central config eller relativ sökväg.
- venv trasig → återskapa.
- node_modules trasig → `npm ci`.
- task pekar fel → uppdatera Action, verifiera med manuell trigger.
- synk trashar/plattar ut → stäng av klienten direkt, återställ molnet parent-first.