# Serve-Files.ps1

A lightweight HTTP file server for Windows, written in PowerShell. No dependencies, no install. Just run it and share files instantly over your local network.

## Features

- **Directory browsing** — clean dark UI with file type icons
- **File downloads** — click any file to download it
- **Folder zip download** — hover a folder and download its entire contents as a `.zip`, generated on the fly
- **File upload** — drag and drop files into any directory from the browser, with per-file progress bars
- **Live filter** — type to instantly narrow down large directories
- **Basic auth** — optional username/password protection
- **Request logging** — timestamped log file with method, status, response time, and bytes transferred

## Usage

```powershell
# Serve the current directory on port 8080
.\Serve-Files.ps1

# Serve a specific folder
.\Serve-Files.ps1 -Path "C:\Users\You\Downloads"

# Use a different port
.\Serve-Files.ps1 -Port 9000

# Enable basic authentication
.\Serve-Files.ps1 -Username alice -Password hunter2

# Custom log file location
.\Serve-Files.ps1 -LogFile "C:\logs\server.log"
```

On startup the server prints your local and network URLs:

```
  File Server started
  Serving : C:\Users\You\Downloads
  Local   : http://localhost:8080
  Network : http://192.168.1.42:8080
  Auth    : none (open)
  Log     : C:\Users\You\server-2026-04-10.log
```

Press `Ctrl+C` to stop.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Path` | Current directory | Folder to serve |
| `-Port` | `8080` | Port to listen on |
| `-Username` | *(none)* | Enable basic auth with this username |
| `-Password` | *(none)* | Password for basic auth |
| `-LogFile` | `server-YYYY-MM-DD.log` next to the script | Path to the log file |

## Log format

Each request is logged as a tab-aligned line:

```
2026-04-10 14:32:01  GET    200     12ms      4.7 MB  /Downloads/report.pdf
2026-04-10 14:32:05  POST   200      3ms          -   /Downloads  [upload]
2026-04-10 14:32:10  GET    200   1823ms    238.4 MB  /Projects  [zip:Projects]
```

## Notes

- Run as **Administrator** if you get a permissions error on startup — Windows requires elevated rights to open HTTP listeners.
- If PowerShell refuses to run the script, allow it for the current session first:
  ```powershell
  Set-ExecutionPolicy -Scope Process Bypass
  ```
- The server is **read-only by default** except for the upload endpoint. Files outside the served folder are never accessible (path traversal is blocked).
- Zip downloads are buffered in memory before sending, so avoid zipping very large folders.
