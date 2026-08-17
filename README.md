# SteamDriveOrder

**The app is `SteamDriveOrder.exe` in this folder.** Everything else is source and extras.

**v1.0** — a small Windows tool that puts Steam's **Install to** / **Storage** drive list in the order you want.

Steam does not expose a reorder control. It remembers libraries in the order they were added, and it keeps that list in **two** files. Edit only one of them — or edit while Steam is still running — and the old order comes back.

This project is **free**. Tips are optional: [Garrett's Project on Patreon](https://www.patreon.com/GarrettsProjects).

## What it does

1. Finds your Steam install from the registry.
2. Reads both `libraryfolders.vdf` files.
3. Lets you sort by drive letter or drag libraries up and down.
4. Closes Steam if it is running.
5. Writes **both** files, keeping each library's games and IDs with that drive.
6. Saves a backup first, then restarts Steam so the new order is used.

It does **not** delete games, remove libraries, or change where titles are installed. It only changes the display order.

## Why the order keeps coming back

Steam stores the list here:

- `Steam\config\libraryfolders.vdf` (the copy Steam treats as the source of truth)
- `Steam\steamapps\libraryfolders.vdf`

If you empty the steamapps copy and leave the config copy alone, Steam writes the full list back on the next launch. Existing `SteamLibrary` folders on other drives are also rediscovered, so deleting entries is not enough.

## Run it

**SteamDriveOrder.exe** is in this folder. Unzip and double-click it.

Windows 10/11, with the Steam desktop client installed. No extra runtime. You can also get the same exe from [GitHub Releases](https://github.com/Gmenasco/SteamDriveOrder/releases) or [Patreon](https://www.patreon.com/GarrettsProjects).

Windows may warn that the app is unsigned. That is expected for a small open-source tool. Choose **More info** → **Run anyway** if SmartScreen appears.

1. Drag drives or use the arrows, or click **Sort A-Z** for C, D, E, F.
2. If Steam is running, click **Close Steam**. After about 10 seconds a **Force** button appears if something is stuck.
3. Click **Apply to Steam**. Both files are updated, Steam restarts, and this app exits.

Backups land in `%LOCALAPPDATA%\SteamDriveOrder\backups\`.

From source (under `resources\`):

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\SteamDriveOrder.ps1
```

Or double-click `resources\SteamDriveOrder.bat`.

Command line, no window:

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\SteamDriveOrder.ps1 -SortDriveLetters -KeepClientFirst -Apply
```

## Bugs

Open a [GitHub Issue](https://github.com/Gmenasco/SteamDriveOrder/issues). Include your Windows version, Steam path, and what you clicked. Do not paste a full `libraryfolders.vdf` unless you have stripped account names.

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File .\resources\tests\Vdf.Tests.ps1
```

Rebuild the executable (needs the `ps2exe` module once):

```powershell
Install-Module ps2exe -Scope CurrentUser
powershell -ExecutionPolicy Bypass -File .\resources\build\Build-Exe.ps1
```

The built file is `SteamDriveOrder.exe` in this folder.

## Tips

The tool stays free. [Garrett's Project on Patreon](https://www.patreon.com/GarrettsProjects) is an optional tip jar, not a paywall.

## Disclaimer

SteamDriveOrder is unofficial and is not affiliated with, endorsed by, or sponsored by Valve or Steam. It edits Steam configuration files on your machine. Use at your own risk. The Steam client can change this format in a future update.

## License

MIT. See [LICENSE](LICENSE).
