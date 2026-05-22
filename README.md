# Instore Radio (info-beamer package)

Package fuer Audio-Streaming auf info-beamer hosted.

## Features

- Audio-Stream per URL (`stream_url`)
- Start/Stop ueber Control UI
- Anzeige von Stream-Status und Metadaten
- Button zum manuellen Neuladen der Metadaten

## Dateien

- `package.json`: Package-Metadaten
- `package.png`: Package-Icon (64x64)
- `node.json`: Setup-Optionen, Permissions und `control_ui`
- `node.lua`: Stream-Playback + Overlay-Anzeige
- `control.html`: Start/Stop/Refresh Buttons auf der Device-Seite
- `service`: Hintergrundprozess zum Abruf von ICY-Metadaten

## Setup-Optionen

- `stream_url`: Stream-URL
- `autostart`: Stream automatisch starten
- `text`: Titelzeile
- `dummy_text`: Untertitelzeile

## Entwicklung

Push zu GitHub und info-beamer gleichzeitig:

```bash
git push origin master
```
