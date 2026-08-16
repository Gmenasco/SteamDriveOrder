# SteamDriveOrder

A small Windows tool that puts Steam's **Install to** / **Storage** drive list in a sensible order (C, D, E, F, …).

Steam does not expose a reorder control. It remembers libraries in the order they were added, and it keeps that list in **two** files. Edit only one of them — or edit while Steam is still running — and the old order comes back.

This project is **free**. Tips are optional.

## What it does

1. Finds your Steam install from the registry.
2. Reads both `libraryfolders.vdf` files.
3. Lets you sort by drive letter or move libraries up and down.
4. Closes Steam if it is running.
5. Writes **both** files, keeping each library's games and IDs with that drive.
6. Saves a backup first.

It does **not** delete games, remove libraries, or change where titles are installed. It only changes the display order.

## Why the order keeps coming back

Steam stores the list here:

- `Steam\config\libraryfolders.vdf` (the copy Steam treats as the source of truth)
- `Steam\steamapps\libraryfolders.vdf`

If you empty the steamapps copy and leave the config copy alone, Steam writes the full list back on the next launch. Existing `SteamLibrary` folders on other drives are also rediscovered, so deleting entries is not enough.

## Run it

Windows 10/11, with the Steam desktop client installed. No extra runtime.

- Double-click `SteamDriveOrder.bat`, or
- `powershell -ExecutionPolicy Bypass -File .\SteamDriveOrder.ps1`

To try every screen **without** closing Steam or writing files:

- Double-click `SteamDriveOrder.Dummy.bat`, or
- `powershell -ExecutionPolicy Bypass -File .\SteamDriveOrder.ps1 -Dummy`

The first window also has a **Dummy / practice mode** checkbox. Leave it on while you test. **Test apply** will say it succeeded, but Steam stays open and both `.vdf` files stay untouched.

Then (live mode):

1. Choose **Alphabetical** or **Custom** on the first screen.
2. Alphabetical sorts C, D, E, F. Custom lets you drag drives (or use the arrows) into any order.
3. Click **Apply to Steam**. Steam will close, both files will be updated, then Steam restarts so the new order is used.

Command line, no window:

```powershell
powershell -ExecutionPolicy Bypass -File .\SteamDriveOrder.ps1 -SortDriveLetters -KeepClientFirst -Apply
```

Dummy command line:

```powershell
powershell -ExecutionPolicy Bypass -File .\SteamDriveOrder.ps1 -Dummy -SortDriveLetters -Apply
```

Point the app at a fake Steam folder (test VM only):

```powershell
powershell -ExecutionPolicy Bypass -File .\SteamDriveOrder.ps1 -Dummy -SteamRoot "C:\Program Files (x86)\Steam"
```

Backups land in `%LOCALAPPDATA%\SteamDriveOrder\backups\`.

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Vdf.Tests.ps1
```

## Share it (GitHub + optional tips)

This repo is meant to stay free. Use GitHub for the code and releases. Use Patreon only as an optional tip jar — not a paywall.

1. Create a public GitHub repository named `SteamDriveOrder` and push.
2. Tip jar is [Garrett's Project on Patreon](https://www.patreon.com/GarrettsProjects).

```powershell
git add .
git commit -m "Initial SteamDriveOrder release."
git remote add origin https://github.com/YOUR_USERNAME/SteamDriveOrder.git
git push -u origin master
```

## Disclaimer

SteamDriveOrder is unofficial and is not affiliated with, endorsed by, or sponsored by Valve or Steam. It edits Steam configuration files on your machine. Use at your own risk. The Steam client can change this format in a future update.

## License

MIT. See [LICENSE](LICENSE).
