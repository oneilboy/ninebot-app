# NinebotApp — bouwen zonder Mac

Deze repo bevat een iOS-app (SwiftUI + CoreBluetooth) die via GitHub Actions
automatisch gebouwd wordt tot een `.ipa`-bestand, zonder dat je zelf een Mac
of Xcode nodig hebt.

## Eenmalige setup

1. **Maak een nieuwe GitHub-repository** (bv. `ninebot-app`), publiek of privé
   maakt niet uit — privé werkt ook prima met GitHub Actions.
2. **Upload deze hele map** naar die repository (via de GitHub-website: "Add
   file" → "Upload files", sleep de hele inhoud van deze map erin — inclusief
   de verborgen map `.github`), of via git:
   ```
   git init
   git remote add origin https://github.com/<jouw-gebruikersnaam>/ninebot-app.git
   git add .
   git commit -m "Initial commit"
   git push -u origin main
   ```

## Elke keer dat je een build wil

1. Ga naar je repository op GitHub → tab **Actions**
2. Kies de workflow **"Build unsigned IPA"** in de lijst links
3. Klik **"Run workflow"** → **"Run workflow"** (groene knop)
4. Wacht 3-5 minuten tot het groene vinkje verschijnt
5. Klik op de voltooide run → onderaan bij **Artifacts** staat
   `NinebotApp-unsigned-ipa` → download (dit is een zip met de `.ipa` erin)
6. Pak de zip uit → je hebt nu `NinebotApp-unsigned.ipa`

Dit gebeurt automatisch ook bij elke `git push` naar de `main`-branch, dus
zodra je code aanpast en pusht, staat er een nieuwe build klaar.

## Installeren op je iPhone (met Sideloadly)

1. Download en installeer **Sideloadly** (gratis, Windows en macOS):
   https://sideloadly.io
2. Sluit je iPhone aan met een kabel
3. Open Sideloadly, sleep `NinebotApp-unsigned.ipa` in het venster
4. Vul je **Apple ID** in (een gewoon, gratis account volstaat)
5. Klik **Start** — Sideloadly ondertekent de app met jouw Apple ID en zet
   hem op je iPhone
6. Eerste keer op je iPhone: **Instellingen → Algemeen → VPN en
   apparaatbeheer** → jouw Apple ID onder "Developer App" → **Vertrouw**
7. De app staat nu als icoon op je beginscherm

**Let op:** met een gratis Apple ID verloopt de installatie na 7 dagen — dan
herhaal je gewoon stap 3-6 met dezelfde `.ipa` (geen nieuwe build nodig,
tenzij je de code hebt aangepast).

## Wat zit er in de app

Een testscherm (`NinebotTestView`) met knoppen om te verbinden met je step,
de auth-handshake te doorlopen, het snelheidsregister uit te lezen, en de
sport-modus limiet te zetten. Vergeet niet `"JOUW-STEP-BLE-NAAM"` in
`Sources/NinebotApp/NinebotTestView.swift` te vervangen door de echte
BLE-naam van je step voor je een build maakt.
