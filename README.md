# Auto Azure Files -> Veeam NAS Sync

This repository contains a PowerShell script, `auto_nas.ps1`, that discovers Azure Files shares and synchronizes them into an existing Veeam NAS/File Share backup job.

## LEGAL DISCLAIMER

This repository and the script `auto_nas.ps1` are provided for informational and operational convenience purposes only.

This script was written by someone who is not a professional software developer and was created with the help of artificial intelligence (AI). Because of this, it may contain bugs, errors, or behaviour that may not suit every environment.

It is provided as-is, with no guarantees that it will work correctly, securely, or meet your specific needs. Please review, test, and validate the script in your own environment before using it, especially in production.

You are responsible for how the script is used, including testing, security checks, backups, and change control.

This is not an official Veeam product and is not supported by Veeam. Using this script does not create any support or warranty obligations from Veeam.

The sync is add-only:
- It adds newly discovered shares to Veeam inventory when missing.
- It adds missing shares to the target job scope.
- It does not remove existing job scope entries.

## What The Script Does

1. Loads configuration from inline defaults in the script (with optional parameter overrides).
2. Enumerates Azure Files shares from a storage account using Azure File service REST API (Shared Key auth).
3. Converts each share to SMB UNC format (`\\account.file.core.windows.net\share`).
4. Optionally exits in list-only mode.
5. Connects to Veeam REST API (`/api/oauth2/token`).
6. Ensures credentials and each SMB share exist in Veeam unstructured inventory.
7. Adds only missing shares to the specified `FileBackup` job scope.
8. Writes timestamped status output to the console.

## Prerequisites

- Execution host with PowerShell:
  - `pwsh` (PowerShell 7+) or Windows PowerShell 5.1.
  - Script runtime supports both Windows and Linux.
- Network access:
  - Outbound HTTPS access to `https://<storage-account>.file.core.windows.net`
  - Outbound HTTPS access to Veeam REST API on `https://<veeam-server>:9419` (default)
- Veeam-side SMB connectivity:
  - TCP 445 access from Veeam data mover/proxy components to Azure Files UNC paths.
- Azure PowerShell module (optional fallback only):
  - `Az.Storage`
- Veeam Backup & Replication REST API enabled on the target VBR server.
- An existing Veeam NAS/File Share backup job.

## Configuration

Configuration defaults are embedded directly in `auto_nas.ps1` in the `param(...)` block.
Update those defaults for your environment, or override values via script parameters.
The script does not currently read environment variables directly.

Required values:
- `StorageAccountName` (`AZURE_STORAGE_ACCOUNT` label in error messages)
- `StorageAccountKey` (`AZURE_STORAGE_KEY` label in error messages)
- `VeeamJobName` (required for sync mode)
- `VeeamUsername` (required for sync mode)
- `VeeamPassword` (required for sync mode)

Optional values:
- `VeeamServer` (when empty/whitespace, script falls back to `localhost`)
- `VeeamCacheRepositoryName` (defaults to `Default Backup Repository` when empty/whitespace)
- `AzureFilesHostSuffix` (defaults to `file.core.windows.net`)
- `AzureFilesSmbUsername` (defaults to `Azure\<storage-account-name>`)
- `ListOnly` via `-ListOnly` switch
- `AllowInsecureVeeamTls` via `-AllowInsecureVeeamTls` switch (enabled by default; affects both Azure Files REST and Veeam REST TLS validation)
- `EnableTranscript` via `-EnableTranscript` switch (enabled by default)
- `TranscriptPath` via `-TranscriptPath` (optional full file path)

Notes:
- If `VeeamServer` is provided as hostname only, the script uses `https://<hostname>:9419`.
- You can also pass a full URL (for example, `https://veeam01.contoso.local:9443`).

## Usage

List shares only (no Veeam changes):

```powershell
pwsh .\auto_nas.ps1 -ListOnly
```

Run synchronization (default behavior uses insecure TLS mode):

```powershell
pwsh .\auto_nas.ps1
```

Explicitly enable insecure TLS mode (equivalent to default):

```powershell
pwsh .\auto_nas.ps1 -AllowInsecureVeeamTls
```

Run synchronization with strict TLS certificate validation:

```powershell
pwsh .\auto_nas.ps1 -AllowInsecureVeeamTls:$false
```

Run synchronization with an explicit transcript file path:

```powershell
pwsh .\auto_nas.ps1 -TranscriptPath "/var/lib/veeam/scripts/sandbox/auto_nas-transcript.txt"
```

Run synchronization without transcript capture:

```powershell
pwsh .\auto_nas.ps1 -EnableTranscript:$false
```

Run with explicit parameters (overrides inline defaults):

```powershell
pwsh .\auto_nas.ps1 `
  -StorageAccountName "mystorage" `
  -StorageAccountKey "<key>" `
  -VeeamJobName "Azure Files Job" `
  -VeeamServer "veeam01.contoso.local"
```

## Logging

- Console output includes timestamps and log level.
- PowerShell transcript capture is enabled by default (`Start-Transcript` / `Stop-Transcript`).
- If `-TranscriptPath` is not provided, the script picks a writable default path.
- On Linux VBR sandbox runs, the default transcript target is `/var/lib/veeam/scripts/sandbox` when writable.

## Security Notes

- This version uses inline configuration values in the script, including sensitive values.
- Keep the repository private and restrict file permissions on the script.
- Rotate credentials/keys immediately if the script is exposed.
- Use a dedicated least-privilege Veeam account for REST API access.
- Use least-privilege accounts for both Azure and Veeam operations.
- Insecure TLS mode is enabled by default for this script. Use `-AllowInsecureVeeamTls:$false` in production once certificate trust and hostname validation are correct.
- Azure share discovery is fail-fast: if discovery fails, the script exits with error to avoid syncing from stale inventory.

## Troubleshooting

- Error: `not an SMB path`
  - Ensure paths are in UNC format (`\\server\share`) and use the latest script version.
- Error: `Unable to enumerate Azure Files shares via REST...`
  - Verify storage account name and key.
  - Verify DNS/network access to `https://<storage-account>.file.core.windows.net`.
  - If strict TLS mode is enabled, verify certificate trust and hostname validation, or remove `-AllowInsecureVeeamTls:$false`.
  - If this runs as a Veeam pre-job script in Linux sandbox, verify outbound TCP 443 from the VBR host/sandbox to Azure Files endpoints is allowed.
  - For VBR Linux sandbox runs, script version `2026.03.06.13`+ auto-sets a writable `HOME` when missing to avoid `The home directory of the current user could not be determined.` from web cmdlets.
  - If required in your environment, install fallback module: `Install-Module Az.Storage -Scope AllUsers`.
- Error: `Veeam REST API call failed ... /api/oauth2/token`
  - Verify `VEEAM_USERNAME` and `VEEAM_PASSWORD`.
  - Verify VBR REST API endpoint and port (`9419` by default).
  - Verify TLS trust for the VBR API certificate on the host running the script when strict mode is enabled.
  - If your environment uses self-signed or hostname-mismatched certificates, do not force strict mode (`-AllowInsecureVeeamTls:$false`) until certs are fixed.
- Access/authentication errors
  - Confirm `VEEAM_USERNAME` and `VEEAM_PASSWORD` are valid in Veeam.
  - Confirm SMB/network access and permissions to Azure Files and Veeam.

## Repository Layout

- `auto_nas.ps1`: main automation script
- `README.md`: usage, configuration, and troubleshooting guide
- `swagger.json`: REST API schema/reference file stored in this repository
