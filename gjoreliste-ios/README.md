# Gjøreliste for iPhone

Samme gjøreliste som nettsiden (`gjoreliste/`), som egen app. Den henter og lagrer alt i Supabase, og holder listen **«Gjøreliste» i Påminnelser** lik toppen av lista.

## Bygg i skyen og installer via TestFlight (anbefalt)

Med betalt Apple Developer Program bygges appen av GitHub Actions hver gang noe i `gjoreliste-ios/` endres på `main`, og sendes rett til TestFlight. MacBooken trengs ikke, og appen utløper ikke etter 7 dager.

- **Oppsettet** ligger i `.github/workflows/gjoreliste-ios.yml`.
- **Hemmeligheter** (Settings → Secrets and variables → Actions): `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (hele .p8-fila) og `APPLE_TEAM_ID`.
- **Byggnummeret** settes automatisk fra GitHub (`run_number`). Versjonsnummeret (`MARKETING_VERSION`) endres i prosjektet når det er en ny versjon.
- **Kjøre manuelt:** Actions → «Gjøreliste iOS → TestFlight» → Run workflow.
- **På iPhonen:** installer appen TestFlight. Nye bygg dukker opp der 5–20 minutter etter at bygget er ferdig.

## Slik bygger du appen på Mac (gammel måte, gratis Apple-ID)

1. **Hent filene:** Last ned dette repoet som ZIP (grønn «Code»-knapp → Download ZIP) og pakk det ut.
2. **Åpne prosjektet:** Dobbeltklikk på `gjoreliste-ios/Gjoreliste.xcodeproj`.
3. **Signering:** Klikk på prosjektet → target **Gjoreliste** → fanen **Signing & Capabilities** → *Team* → velg Apple-ID-en din (*Personal Team*).
   Klager Xcode på bundle-ID-en, kan du endre den til for eksempel `no.sparhell.gjoreliste2`.
4. **Installer:** Koble til iPhonen med kabel, velg den øverst i Xcode og trykk ▶︎ (Run).
   Utviklermodus og «Stol på utvikleren» har du allerede slått på for Møtelogg.
5. **Logg inn** med e-posten og passordet du laget på nettsiden («Lag passord» nederst i lista).
6. Svar **Tillat full tilgang** når appen spør om Påminnelser.

Med gratis Apple-ID må appen installeres på nytt fra Xcode hver 7. dag. Dataene ligger i Supabase, så ingenting forsvinner.

**Hvis prosjektfila ikke vil åpne:** Lag et nytt prosjekt i Xcode (*File → New → Project → iOS → App*, navn `Gjoreliste`, SwiftUI, Swift, Storage: None). Slett `ContentView.swift` og `GjorelisteApp.swift` som Xcode lagde, og dra inn filene fra `gjoreliste-ios/Gjoreliste/` (huk av *Copy items if needed*). Under fanen **Info** legger du til *Privacy - Reminders Full Access Usage Description* med en kort tekst. Sett *Minimum Deployments* til iOS 17.

## Slik virker appen

- **Nå:** de samme oppgavene øverst som på nettsiden, med poeng og dagsmål på 100. Resten ligger under «Vis resten».
- Trykk på **sirkelen** for å krysse av. Du kan angre i seks sekunder.
- **Sveip** mot venstre for «I morgen» eller «Stryk», og mot høyre for «Gjort».
- Trykk på **teksten** for detaljer, kilder («Hvor kommer dette fra») og flere valg.
- Det du skriver inn, får `needs_triage = true`, så Claude sorterer det inn.
- Dra ned for å oppdatere. Appen henter også nytt når du åpner den.

## Widgeter

Hold fingeren på låseskjermen eller hjemskjermen → **Tilpass** → **Legg til widgets** → **Gjøreliste**.

- **Låseskjerm:** «Åpne Gjøreliste» (bare ikonet), «Neste oppgave» (bred, viser øverste oppgave) og en linje over klokka.
- **Knapp på låst skjerm:** I kontrollsenteret eller nederst på låseskjermen kan du legge til knappen «Gjøreliste», som åpner appen.
- **Hjemskjerm:** liten, middels og stor. Trykk på sirkelen for å krysse av rett fra widgeten, og på teksten for å åpne oppgaven.

Widgetene viser det appen sist hentet. Avkrysninger fra en widget sendes til databasen neste gang appen åpnes. Appen og widgetene deler data gjennom App Group-en `group.no.sparhell.gjoreliste`.

## Påminnelser

Appen lager listen **«Gjøreliste»** i Påminnelser og synker begge veier:

- Bare oppgavene øverst i lista (5–7 stykker) ligger der, så listen blir aldri lang. Det som er forsinket, står på i dag.
- Krysser du av en påminnelse, også på klokka eller med Siri, blir oppgaven gjort.
- Lager du en ny påminnelse i listen («Hei Siri, legg til … i Gjøreliste»), blir den en ny oppgave Claude sorterer.
- Utsetter eller stryker du en oppgave, forsvinner påminnelsen.
- Sletter du en påminnelse, kommer den tilbake. Bruk «Stryk» i appen i stedet.

Synkingen skjer når appen er åpen eller kommer fram på skjermen. Den kan slås av i menyen øverst til høyre. Koblingen lagres i kolonnen `reminder_id` i tabellen `tasks`.

## Teknisk

- Ren SwiftUI og EventKit for iOS 17. Ingen eksterne pakker: appen snakker med Supabase over HTTPS (Auth og PostgREST), og innloggingen lagres i nøkkelringen.
- Nøkkelen i `API.swift` er den offentlige *publishable*-nøkkelen. Dataene er beskyttet av innlogging og radtilgang i databasen (bare Tors e-postadresser).
