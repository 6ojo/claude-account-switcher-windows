# claude desktop account switcher (Windows)

originally by Philipp Stracker, modified for windows 
[`stracker-phil/claude_quick.sh`](https://gist.github.com/stracker-phil/9f84927a556632c7f9cc06663b534f14) and [blog post](https://philippstracker.com/multiple-claude-instances).

---

## usage

1. download or clone this repository. keep the files together — they depend on each other.
2. open **`claude_quick.bat`**.
3. select an option from the menu:
   - **1**: auto-select & launch instance with most usage remaining
   - **2**: launch the default instance
   - **3**: select and launch an existing named instance (e.g. `work`, `personal`)
   - **4**: create a new instance
   - **5**: view account usage limits & reset timers
   - **6**: delete an instance
   - **7**: create a Desktop shortcut for an instance
   - **8**: run read-only diagnostics (paths, install type, instances, protocol handler)
   - **9**: exit

---

## files

| file | role |
| --- | --- |
| `claude_quick.bat` | entry point — launches `claude_quick.ps1` |
| `claude_quick.ps1` | menu, command dispatch, and user-facing actions |
| `claude_common.ps1` | shared helpers: executable resolution, instance discovery, usage stats, launching |
| `claude_diagnose.ps1` | read-only diagnostics report |
| `claude_auto_select.ps1` | standalone usage-based auto-selector |

`claude_common.ps1` is dot-sourced by the other scripts and is not meant to be run directly.

---

## or

directly from PowerShell or Command Prompt:

```powershell
# auto-select and launch instance with most usage remaining
.\claude_quick.ps1 auto

# run standalone auto-selector script
.\claude_auto_select.ps1

# show interactive menu
.\claude_quick.ps1

# launch a specific instance directly
.\claude_quick.ps1 <name>

# view usage limits & reset timers across all accounts
.\claude_quick.ps1 usage

# list all instances and shortcut status
.\claude_quick.ps1 list

# create a desktop shortcut for an instance
.\claude_quick.ps1 shortcut <name>

# delete an instance
.\claude_quick.ps1 delete <name>

# run diagnostics
.\claude_quick.ps1 diagnose
```

Or via `claude_quick.bat`:
```cmd
claude_quick.bat auto
claude_quick.bat usage
claude_quick.bat list
claude_quick.bat diagnose
```

---

## auto-select & usage recalculation
- the reset times are estimates
- highest 5hr limit chosen

every time `auto` is run (`.\claude_quick.ps1 auto` or `.\claude_auto_select.ps1`):
1. **recalculates usage**: reads `plan-usage-history.json` across all instances (`default` + custom instances in `~/.claude-instances`).
2. **evaluates 5-hour window**: checks active rolling usage (`fh`). if 5 hours have passed since first query, usage resets to 0 (full capacity).
3. **ranks accounts**:
   - lowest 5-hour activity score (`fh` = 0 is best / highest capacity remaining)
   - lowest 7-day usage score (`sd`)
   - longest idle duration
4. **launches best account**: displays the ranking table and launches the top-ranked instance immediately.

---
## creating new instance

- point the program to `Claude.exe` if not detected automatically.
- a fresh isolated instance directory will be created, and Desktop shortcut options will be prompted before launch.
- the script automatically suppresses Electron pre-authentication background warnings (such as `Error: No active account context`) so your console remains clean.

---

## signing in from browser

- close any running instances when prompted so the browser OAuth callback (`claude://`) routes directly to your newly launched instance.
- once signed in, session tokens remain saved in that instance's folder (`~/.claude-instances/<name>`) and will stay logged in independently.

---

## how it works

claude desktop is built on electron. passing `--user-data-dir="C:\Users\<User>\.claude-instances\<name>"` redirects all application state to a isolated folder, allowing multiple instances to run side-by-side without interfering with each other.

---

## credits

- criginal macOS version by [Philipp Stracker](https://github.com/stracker-phil) ([Gist](https://gist.github.com/stracker-phil/9f84927a556632c7f9cc06663b534f14) / [Blog Post](https://philippstracker.com/multiple-claude-instances)).
