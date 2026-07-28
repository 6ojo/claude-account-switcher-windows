# claude desktop account switcher (Windows)

originally by Philipp Stracker, modified for windows 
[`stracker-phil/claude_quick.sh`](https://gist.github.com/stracker-phil/9f84927a556632c7f9cc06663b534f14) and [blog post](https://philippstracker.com/multiple-claude-instances).

---


## usage

1. download or clone this repository.
2. open **`claude_quick.bat`**.
3. select an option from the menu:
   - **1**: launch the default instance
   - **2**: select and launch an existing named instance (e.g. `work`, `personal`)
   - **3**: create a new instance
   - **4**: delete an instance
   - **5**: create a Desktop shortcut for an instance
   - **6**: run diagnostics to verify paths and active instances
   - **7**: exit

---

## or

directly from PowerShell or Command Prompt:

```powershell
# show interactive menu
.\claude_quick.ps1

# launch a specific instance directly
.\claude_quick.ps1 <name>

# list all instances and shortcut status
.\claude_quick.ps1 list

# create a desktop shortcut for an instance
.\claude_quick.ps1 shortcut <name>

# delete an instance
.\claude_quick.ps1 delete <name>

# run diagnostics
.\claude_quick.ps1 diagnose
```

or via `claude_quick.bat`:
```cmd
claude_quick.bat <name>
claude_quick.bat list
claude_quick.bat diagnose
```

---
## creating new instance

- you may need to point the program to claude.exe
- once thats done, a fresh instance will be created, ready for you to sign in 
---

## signing in from browser

- close any running instances from the taskbar
- you may see an OTP code on your default claude
- once signed in, session tokens remain saved in that instance's folder (`~/.claude-instances/<name>`) and will stay logged in independently.

---

## how it works

claude desktop is built on electron. passing `--user-data-dir="C:\Users\<User>\.claude-instances\<name>"` redirects all application state to a isolated folder, allowing multiple instances to run side-by-side without interfering with each other.

---

## credits

- criginal macOS version by [Philipp Stracker](https://github.com/stracker-phil) ([Gist](https://gist.github.com/stracker-phil/9f84927a556632c7f9cc06663b534f14) / [Blog Post](https://philippstracker.com/multiple-claude-instances)).
