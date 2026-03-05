# Push-notiser från Claude Code via ntfy.sh

## Vad gör det här?

Ett bash-skript som installerar **hooks** i Claude Code för push-notiser via [ntfy.sh](https://ntfy.sh). Tre typer av händelser stöds:

- **Stop** — Claude har slutfört en uppgift. Notisen innehåller en sammanfattning av vad som gjordes, hur lång tid det tog och vilka verktyg som användes.
- **PermissionRequest** — Claude behöver tillstånd att köra ett verktyg (t.ex. ett bash-kommando). Du kan godkänna från telefonen utan att växla tillbaka till terminalen.
- **Notification** (idle) — Claude väntar på input. Avstängd som standard eftersom den ofta triggas samtidigt som Stop.

Notiser skickas bara om uppgiften har pågått längre än ett tröskelvärde (standard 30 sekunder), så korta interaktioner inte stör.

## Förberedelser

1. **Ladda ner ntfy-appen** på din telefon:
   - [Google Play](https://play.google.com/store/apps/details?id=io.heckel.ntfy) (Android)
   - [App Store](https://apps.apple.com/app/ntfy/id1625396347) (iOS)

2. **Skapa ett konto** på [ntfy.sh](https://ntfy.sh/app) (gratis).

3. **Skapa ett topic** — detta är kanalen som notiser skickas till.

   > **Viktigt:** Ditt topic-namn fungerar som en adress — **vem som helst som känner till namnet kan prenumerera och läsa dina notiser**. Välj därför ett namn som är långt, unikt och omöjligt att gissa. Blanda gärna in slumpmässiga tecken.
   >
   > Bra: `anna-svensson-claude-x7f9q2`, `dev-notis-kJm82nXp`
   > Dåligt: `test`, `claude`, `notifications`, `mitt-topic`
   >
   > Skriptet validerar topic-namnet och avvisar namn som är för korta (<10 tecken), för vanliga eller har för låg entropi.

4. **Skapa en access token** — gå till *Account* > *Access tokens* på ntfy.sh och skapa en ny token. Kopiera den (börjar med `tk_`).

5. **Prenumerera på ditt topic** i appen så att du tar emot notiser.

## Installation

Kör skriptet i din terminal (kräver `bash` och `python3`):

```bash
bash setup-claude-ntfy.sh --topic "ditt-topic" --token "tk_din_token"
```

### Flaggor

| Flagga            | Beskrivning                                              | Standard        |
|-------------------|----------------------------------------------------------|-----------------|
| `--topic`         | Ditt ntfy-topic (obligatorisk)                           | —               |
| `--token`         | Din access token (obligatorisk)                          | —               |
| `--threshold`     | Antal sekunder innan notis skickas                        | 30              |
| `--server`        | ntfy-server om du kör en egen                            | https://ntfy.sh |
| `--idle`          | Aktivera Notification-hook (väntar-på-input-notiser)     | av              |
| `--no-permission` | Stäng av PermissionRequest-hook (verktygs-tillståndsnotiser) | —           |

### Exempel

```bash
# Grundinstallation
bash setup-claude-ntfy.sh --topic "ditt-topic" --token "tk_din_token"

# Med längre tröskelvärde och idle-notiser
bash setup-claude-ntfy.sh --topic "ditt-topic" --token "tk_din_token" --threshold 60 --idle

# Bara Stop-notiser (inga permission-notiser)
bash setup-claude-ntfy.sh --topic "ditt-topic" --token "tk_din_token" --no-permission
```

## Vad ändrar skriptet?

Skriptet skapar/uppdaterar fyra filer under `~/.claude/`:

| Fil | Vad den gör |
|-----|-------------|
| `hooks/ntfy-config.env` | Sparar topic, token, tröskelvärde och server (chmod 600, bara du kan läsa den). |
| `hooks/ntfy-notify.sh` | Hook-skriptet (delas av alla hook-händelser). Läser sessionens transkript, beräknar hur lång tid uppgiften tog, och skickar notisen. |
| `settings.json` | Registrerar hooks under `hooks.Stop`, `hooks.Notification` och `hooks.PermissionRequest` (befintliga inställningar bevaras). |
| `CLAUDE.md` | Lägger till instruktioner som gör att Claude inkluderar en dold sammanfattning i varje svar, vilken används som notistext. |

Skriptet är **idempotent** — du kan köra det flera gånger utan problem, t.ex. för att byta topic, ändra tröskelvärdet eller slå av/på händelsetyper.

## Så ser notiserna ut

### Stop — uppgift slutförd

> **Claude done: mitt-projekt (2m 15s)**
>
> 📋 Refaktorera auth-modulen<br>
> ✅ Flyttade validering till middleware, uppdaterade 4 filer, alla tester gröna<br>
> 🔧 8 edits · 3 reads · 2 commands · 💻 datornamn

### PermissionRequest — verktyg behöver tillstånd

> **Claude needs permission: mitt-projekt (1m 42s)**
>
> 🔐 Bash<br>
> 📝 rm -rf node_modules · 💻 datornamn

### Notification — väntar på input

> **Claude waiting: mitt-projekt (3m 10s)**
>
> ⏳ Claude is waiting for your input · 💻 datornamn

## Säkerhet

Notiser skickas till en extern server, så känslig data skyddas i två lager:

1. **CLAUDE.md-instruktioner** — Claude instrueras att aldrig inkludera lösenord, API-nycklar, tokens eller andra hemligheter i notissammanfattningen.

2. **Automatisk filtrering** — Innan notisen skickas körs texten genom en filter-funktion som upptäcker och ersätter:
   - Kända token-format (Stripe, GitHub, GitLab, ntfy, Google, AWS, Slack, JWT, SSH-nycklar)
   - Nyckel=värde-mönster där nyckeln antyder en hemlighet (password, token, api_key, secret m.fl.)

   Matchade värden ersätts med `[REDACTED]`.

## Felsökning

- Eventuella fel loggas till `~/.claude/hooks/ntfy-errors.log`.
- Hooken returnerar alltid exit 0 — den kan aldrig avbryta Claude Code.
- Testa manuellt:

```bash
# Stop-notis
echo '{"hook_event_name":"Stop","cwd":"/path/to/project","transcript_path":"/path/to/transcript.jsonl"}' | ~/.claude/hooks/ntfy-notify.sh

# PermissionRequest-notis
echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/path/to/project","transcript_path":"/path/to/transcript.jsonl"}' | ~/.claude/hooks/ntfy-notify.sh

# Notification-notis (idle)
echo '{"hook_event_name":"Notification","message":"Claude is waiting","cwd":"/path/to/project","transcript_path":"/path/to/transcript.jsonl"}' | ~/.claude/hooks/ntfy-notify.sh
```

## Changelog

### 1.0.1 (2026-02-20)

- Notistext börjar nu alltid med stor bokstav (både NTFY-markör och fallback-text)
- CLAUDE.md-instruktioner uppdaterade att begära versaler i markörer

### 1.0.0 (2026-02-20)

- Kompakt notisformat — verktyg och hostname på samma rad
- `--version` och `--history` flaggor
- Topic-validering (längd, entropi, blocklista)
- Känslig data-filtrering (tokens, nyckel=värde-mönster)
- Tre hook-händelser: Stop, PermissionRequest, Notification
- Idempotent installation med inställningsmerge
