# SundaySort

**Your Downloads folder, tidied automatically once a week.**

SundaySort is a small PowerShell tool for Windows. Every week it takes the loose files in your Downloads folder and sorts them into folders by type: PDFs, images, installers, archives and so on. It **never deletes anything**, and every run can be undone.

```
Downloads\                          Downloads\
├── invoice (1).pdf                 ├── Documents\
├── invoice.pdf                     │   ├── PDFs\        invoice.pdf, notes.pdf
├── notes.pdf                       │   ├── Slides\      deck.pptx
├── deck.pptx             ──────▶   │   └── Word\        report.docx
├── report.docx                     ├── Images\          screenshot.png
├── screenshot.png                  ├── Installers\      setup.exe
├── setup.exe                       ├── Archives\        project.zip
└── project.zip                     └── _Duplicates (check, then delete)\
                                        └── invoice (1).pdf
```

## Features

- **Sorts by file type** into 16 folders (Documents, Images, Videos, Audio, Archives, Installers, Code, Design, Fonts and more)
- **Runs on its own every week.** If your PC was off at that time, it runs the next time you turn it on.
- **Never deletes.** Exact duplicates (same contents, checked with SHA-256) go into a `_Duplicates` folder for you to review.
- **Undo with one command.** Every run is logged.
- **Leaves downloads in progress alone.** `.crdownload` and `.part` files, and anything changed in the last 10 minutes, are skipped.
- **Never overwrites files.** If a name is taken, the new file gets ` (2)` added to its name.
- **Custom rules.** Use a small JSON file to add or rename folders.
- No dependencies. It uses Windows PowerShell 5.1, which comes with Windows 10 and 11, and also works with PowerShell 7.

## Install

1. Download this repo: **Code → Download ZIP**, then unzip it. Or use `git clone`.
2. Open PowerShell in that folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install.ps1
```

The installer first shows a **preview** of what it would do. Then it schedules a weekly run for **Sunday at 9 PM**. No admin rights are needed.

To use a different day or time:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install.ps1 -Day Friday -Time "6:30 PM"
```

## Use it without installing

```powershell
.\Sort-Downloads.ps1 -DryRun      # preview only
.\Sort-Downloads.ps1              # sort now
.\Undo-LastSort.ps1               # put everything back
```

| Option | What it does |
|---|---|
| `-DryRun` | Shows what would move. Moves nothing. |
| `-Path <folder>` | Sorts a different folder (default: your Downloads folder, even if you moved it) |
| `-MinAgeMinutes 10` | Skips files changed more recently than this |
| `-RulesFile <file>` | Uses custom folder rules (see below) |
| `-NoDuplicateCheck` | Doesn't look for duplicate files |

## Custom rules

Copy `examples/rules.example.json` and edit it. Each entry is a folder name and the file extensions that go into it. Your rules win over the built-in ones.

```json
{
  "folders": {
    "Images\\Screenshots": [".png"],
    "Books": [".epub", ".pdf"],
    "3D Models": [".stl", ".obj", ".fbx", ".blend"]
  }
}
```

```powershell
powershell -ExecutionPolicy Bypass -File .\Install.ps1 -RulesFile .\my-rules.json
```

## Uninstall

```powershell
& "$env:LOCALAPPDATA\SundaySort\Uninstall.ps1"
```

This removes the weekly task and the installed scripts. Your sorted files stay where they are.

## Where things live

| What | Where |
|---|---|
| Installed scripts | `%LOCALAPPDATA%\SundaySort\` |
| Undo logs | `%LOCALAPPDATA%\SundaySort\logs\` |
| Weekly task | Task Scheduler → `SundaySort - weekly Downloads cleanup` |

## FAQ

**Will it touch folders that are already in Downloads?**
No. It only moves loose files at the top level of the folder.

**Does it send anything anywhere?**
No. It has no network access and no telemetry. Everything stays on your PC.

**Windows says the script "cannot be loaded because running scripts is disabled".**
Use the `powershell -ExecutionPolicy Bypass -File ...` form shown above. It only affects that one command.

## License

[MIT](LICENSE)
