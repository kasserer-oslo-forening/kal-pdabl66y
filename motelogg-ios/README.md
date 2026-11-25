# Møtelogg for iPhone

Tar opp møter (også med låst skjerm), transkriberer med Gemini omtrent hvert 20. sekund, oppsummerer og lagrer møtene på telefonen.

## Slik bygger du appen (første gang)

1. **Hent filene:** Last ned dette repoet som ZIP (grønn «Code»-knapp → Download ZIP) og pakk det ut.
2. **Lag prosjektet:** Åpne Xcode → *File → New → Project* → **iOS → App**.
   - Product Name: `Motelogg`
   - Interface: **SwiftUI**, Language: **Swift**, Storage: **None**
3. **Bytt ut filene:** Slett `ContentView.swift` og `MoteloggApp.swift` som Xcode lagde (*Move to Trash*).
   Dra inn de tre filene fra `motelogg-ios/Motelogg/` i prosjektet (huk av *Copy items if needed*).
4. **Mikrofontillatelse:** Klikk på prosjektet → target **Motelogg** → fanen **Info** → `+` →
   *Privacy - Microphone Usage Description* = `Møtelogg tar opp møter for å transkribere dem.`
5. **Opptak med låst skjerm:** Fanen **Signing & Capabilities** → `+ Capability` → **Background Modes** → huk av **Audio, AirPlay, and Picture in Picture**.
6. **Signering:** Samme fane → *Team* → velg Apple-ID-en din (*Personal Team*).
   Sett **Minimum Deployments** til iOS 17 eller nyere (fanen *General*).
7. **Installer:** Koble iPhonen til med kabel, velg den øverst i Xcode og trykk ▶︎ (Run).
   - Første gang: på iPhonen, slå på *Innstillinger → Personvern og sikkerhet → Utviklermodus*.
   - Stol på utvikleren: *Innstillinger → Generelt → VPN og enhetsadministrasjon* → Apple-ID-en din → *Stol på*.
8. Åpne appen → tannhjulet → lim inn Gemini API-nøkkelen.

Med gratis Apple-ID må appen installeres på nytt fra Xcode hver 7. dag. Møtene beholdes.
