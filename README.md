# packer-windows-build

Unattended build of a sysprepped **Windows 10 22H2** base image for QEMU/KVM, using Packer.
Clones made from the image boot straight to the desktop, get their hostname, network settings
and first-boot scripts from **Cloudbase-Init** (cloud-init for Windows), and have a working
QEMU guest agent.

> Planned: move to **Windows Server 2022** once a licence is available (see the end of this file).

---

## TL;DR — quick start

```bash
# one-time
./extract-drivers.sh

# build (~18 min)
packer validate -syntax-only windows10.pkr.hcl && packer build -force -on-error=ask windows10.pkr.hcl

# per clone: thin disk + seed ISO
qemu-img create -f qcow2 -F qcow2 -b ../output-windows_soe/packer-windows_soe vms/win10-01.qcow2
xorriso -as genisoimage -volid cidata -joliet -rock -output vms/win10-01-seed.iso meta-data user-data network-config
# then boot it with the command in "Step 5 — Run a clone"
```

Login: `Administrator` / `Password123!` (lab only — see Security).

---

## Requirements

| Tool | Used for |
|---|---|
| Packer 1.11+ with the `qemu` plugin | Running the build (`packer init windows10.pkr.hcl` installs the plugin) |
| QEMU/KVM (`qemu-system-x86_64`, `qemu-img`) | The VM and its disk |
| `xorriso` | Extracting drivers, building seed ISOs; Packer also uses it for the answer-file CD |
| `curl` | Downloading the Cloudbase-Init installer |
| `socat` | Talking to the guest agent from the host |
| A VNC viewer (e.g. TigerVNC) | Watching the build (optional) |

Files you supply (not in git):

| File | Where from |
|---|---|
| `Win10_22H2_English_x64.iso` | Microsoft's Windows 10 download page (English, **not** English International) |
| `virtio-win.iso` | Fedora virtio-win project (built against `virtio-win-0.1.302`) |

---

## Project layout

```
packer-windows-build/
├── windows10.pkr.hcl          # Packer template
├── Autounattend.xml           # Answer file for the INSTALL (read by Windows Setup)
├── unattend-clone.xml         # Answer file for each CLONE's first boot (used by sysprep)
├── extract-drivers.sh         # Pulls drivers from virtio-win.iso, downloads Cloudbase-Init
├── scripts/
│   └── setup.ps1              # Provisioning: installs guest agent + Cloudbase-Init
├── cloudbase-init/
│   └── cloudbase-init.conf    # Cloudbase-Init config baked into the image
├── meta-data                  # Seed: instance-id + hostname
├── user-data                  # Seed: first-boot script
├── network-config             # Seed: static IP (optional)
├── drivers/                   # (generated) viostor, NetKVM, vioserial
├── installers/                # (generated) qemu-ga + Cloudbase-Init MSIs
├── output-windows_soe/        # (generated) the base image
└── vms/                       # (generated) clones, seed ISOs, serial logs
```

`.gitignore`:

```
*.iso
*.log
output-*/
drivers/
vms/
installers/
```

---

## Step 1 — Extract drivers and download installers (one-time)

```bash
./extract-drivers.sh
```

The script:

```bash
#!/bin/bash
mkdir -p drivers installers
xorriso -osirrox on -indev virtio-win.iso \
  -extract /viostor/w10/amd64 drivers/viostor \
  -extract /NetKVM/w10/amd64 drivers/NetKVM \
  -extract /vioserial/w10/amd64 drivers/vioserial \
  -extract /guest-agent/qemu-ga-x86_64.msi installers/qemu-ga-x86_64.msi
chmod -R u+w drivers installers

curl -fLo installers/CloudbaseInitSetup_Stable_x64.msi \
  https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi
```

| Item | Why |
|---|---|
| `viostor` | Disk driver — without it Setup can't see the virtio disk |
| `NetKVM` | Network driver — needed for WinRM |
| `vioserial` | Serial channel the guest agent uses to talk to the host |
| `qemu-ga-x86_64.msi` | The guest agent |
| `CloudbaseInitSetup_Stable_x64.msi` | Cloudbase-Init |

The `chmod` matters: xorriso extracts files read-only, and Packer fails with
`permission denied` when it copies them.

---

## Step 2 — Build the base image

```bash
packer validate -syntax-only windows10.pkr.hcl && packer build -force -on-error=ask windows10.pkr.hcl
```

- `-syntax-only`: plain `packer validate` fails whenever an old `output-windows_soe/` exists.
- `-force`: overwrites the previous image. **Delete any clones first** (see Step 4).
- `-on-error=ask`: on failure, keeps the VM alive so you can inspect it.

### What happens, in order

1. Packer builds a small CD (label `OEMDRV`) containing `Autounattend.xml`, `drivers/` and `installers/`.
2. The VM boots the Windows ISO. Setup finds `Autounattend.xml` on the CD and runs with no prompts:
   loads `viostor` + `NetKVM`, wipes and partitions the disk, installs Windows 10 Pro.
3. OOBE is skipped; Windows logs in as Administrator and the first-logon commands enable WinRM.
4. Packer connects over WinRM and runs `scripts/setup.ps1`: installs the guest agent and
   Cloudbase-Init (fails the build if either doesn't install).
5. Packer uploads `cloudbase-init/cloudbase-init.conf` over the installer's default config.
6. Packer uploads `unattend-clone.xml` to `C:\Windows\System32\Sysprep\unattend.xml`.
7. The shutdown command runs **sysprep** (`/generalize /oobe /shutdown`), which strips the machine's identity and powers off.
8. Packer compacts the disk into `output-windows_soe/packer-windows_soe` (qcow2).

A good build takes about 15–20 minutes. In the output, look for:

```
QEMU-GA        Running Automatic
cloudbase-init Stopped Automatic
...
--> qemu.windows_soe: VM files in directory: output-windows_soe
```

`cloudbase-init` is **Stopped** on purpose: it should only run on clones, not in the build VM.

### Watching the build

Packer prints a VNC address (`vnc://127.0.0.1:59xx`). Connect in **shared** mode:

```bash
vncviewer -Shared 127.0.0.1:59xx
```

Without `-Shared`, TigerVNC kicks Packer off the VM's VNC connection. To make it permanent,
add `Shared=1` to `~/.vnc/default.tigervnc`.

---

## Step 3 — Write the seed files

The seed is three small text files that tell Cloudbase-Init what to do on the clone's first boot.

`meta-data` — who the VM is:

```yaml
instance-id: win10-01
local-hostname: win10-01
```

`user-data` — a script to run (the first line picks the interpreter):

```powershell
#ps1_sysnative
Set-TimeZone -Id "UTC"
New-Item C:\hello-from-cloudbase-init.txt
```

`network-config` — optional static IP, matched to the network card by MAC:

```yaml
version: 1
config:
  - type: physical
    name: eth0
    mac_address: "52:54:00:12:34:56"
    subnets:
      - type: static
        address: 10.0.2.50
        netmask: 255.255.255.0
        gateway: 10.0.2.2
        dns_nameservers:
          - 10.0.2.3
```

`10.0.2.2` and `10.0.2.3` are QEMU user-networking's built-in gateway and DNS. Leave
`network-config` out entirely to keep DHCP.

## Step 4 — Make a clone and its seed ISO

```bash
mkdir -p vms
qemu-img create -f qcow2 -F qcow2 \
  -b ../output-windows_soe/packer-windows_soe vms/win10-01.qcow2

xorriso -as genisoimage -volid cidata -joliet -rock \
  -output vms/win10-01-seed.iso meta-data user-data network-config
```

- Clones are thin copies that only store their own changes. The `-b` path is relative to the
  **clone's** folder, hence `../`.
- Never modify the base image while clones depend on it. **Rebuilding breaks existing clones** —
  delete them first (`rm vms/*.qcow2`).
- **Running `qemu-img create` again wipes the clone**, including Cloudbase-Init's saved state.
  To keep a clone, only rebuild the seed ISO.
- xorriso warns that `-volid` doesn't comply with ISO 9660. Harmless — Cloudbase-Init accepts
  `cidata` or `CIDATA`.
- To change a seed: shut the VM down first, `rm` the old ISO, then run xorriso again.

## Step 5 — Run a clone

```bash
qemu-system-x86_64 -enable-kvm -m 4096 -smp 2 \
  -drive file=vms/win10-01.qcow2,if=virtio,format=qcow2 \
  -drive file=vms/win10-01-seed.iso,media=cdrom \
  -device virtio-net,netdev=n0,mac=52:54:00:12:34:56 -netdev user,id=n0 \
  -device virtio-serial \
  -chardev socket,path=/tmp/qga.sock,server=on,wait=off,id=qga0 \
  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  -serial file:vms/win10-01-serial.log \
  -usb -device usb-tablet
```

| Option | Why |
|---|---|
| `-drive …seed.iso,media=cdrom` | The Cloudbase-Init seed |
| `mac=52:54:00:12:34:56` | Fixed MAC, so it matches `network-config` |
| `virtio-serial` + `chardev` + `virtserialport` | Guest agent channel, exposed on the host as `/tmp/qga.sock` |
| `-serial file:…` | Cloudbase-Init logs to COM1 — readable on the host |
| `-usb -device usb-tablet` | Accurate mouse pointer without needing to grab it |

Running more than one clone at once? Give each its own MAC, socket path and serial log.

Watch Cloudbase-Init from the host while it boots:

```bash
tail -f vms/win10-01-serial.log
```

On first boot: "Getting ready", then Cloudbase-Init renames the computer and **reboots once**.
Windows may or may not log in automatically after that — log in with the password if asked.

---

## Step 6 — Verify a clone

| Check | How | Expected |
|---|---|---|
| Hostname from seed | In the VM: `hostname` | `win10-01` (without a seed: a random name) |
| User-data ran | `Test-Path C:\hello-from-cloudbase-init.txt` and `Get-TimeZone` | `True`, UTC |
| Static IP | `ipconfig` | `10.0.2.50`, adapter named `eth0` |
| Network works | `Test-NetConnection example.com -Port 443` | `TcpTestSucceeded : True` |
| Keyboard layout | Type `\|` in PowerShell | It appears |
| Guest agent | Host: `socat - UNIX-CONNECT:/tmp/qga.sock` then type `{"execute":"guest-ping"}` | `{"return": {}}` |

Press Ctrl+C to leave socat.

---

## Cloudbase-Init — how it works

Docs: <https://cloudbase-init.readthedocs.io/>

### The split

| Part | Role |
|---|---|
| **Seed ISO** (built on the host with xorriso) | Carries the instructions. Does nothing by itself |
| **Cloudbase-Init** (service inside Windows) | At every boot, finds the disk labelled `cidata`, reads it, and applies it |

Settings like CPUs, RAM and MAC belong to the hypervisor (the QEMU command), not to Cloudbase-Init.

### Three concepts

1. **Metadata service** — *where* settings come from. Ours lists only
   `NoCloudConfigDriveService` (the `cidata` ISO).
2. **Plugins** — *what* gets done: hostname, network, user-data, extending the disk, etc.
3. **State, saved per `instance-id`** — run-once plugins are recorded as done under the
   instance-id and skipped on later boots. **Change the instance-id to make them run again.**
   The state lives in the registry:

   ```powershell
   Get-ChildItem 'HKLM:\SOFTWARE\Cloudbase Solutions\Cloudbase-Init' | Select-Object PSChildName
   ```

   One entry per instance-id this clone has seen.

### `cloudbase-init/cloudbase-init.conf`

| Setting | Notes |
|---|---|
| `metadata_services` | Only NoCloud — no waiting on cloud metadata URLs |
| `plugins` | MTU, hostname, **network config**, extend volumes, user-data, local scripts. **No user/password plugins** — Administrator comes from `unattend-clone.xml` |
| `allow_reboot=true` | Needed for the hostname change and exit codes 1001/1003 |
| `logging_serial_port_settings=COM1,…` | Sends the log to COM1, i.e. `vms/*-serial.log` on the host |

The file is uploaded by Packer, so **changes only reach clones after a rebuild**. To test a
change on a running clone first, edit
`C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf` and reboot.

Plugin names must be exact — module **and** class:

```
cloudbaseinit.plugins.common.networkconfig.NetworkConfigPlugin   ✅
cloudbaseinit.plugins.common.sethostname.NetworkConfigPlugin     ❌ crashes the whole service
```

### User-data exit codes

| Exit code | Reboot now? | Run again next boot? | Use for |
|---|---|---|---|
| `0` | No | No | Normal finished script |
| `1001` | Yes | No | Done, but needs a reboot to complete (e.g. a Windows feature) |
| `1002` | No | Yes | Not finished yet — try again next boot (e.g. waiting on something) |
| `1003` | Yes | Yes | Multi-stage setup |

A script exiting 1002 runs on **every** boot until it exits 0 or the instance-id changes.

### Logs

| Where | What |
|---|---|
| `vms/<clone>-serial.log` (host) | Live log via COM1. **Resets only when QEMU starts** — Windows reboots append, so check timestamps |
| `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log` | Same log, inside Windows |

Useful searches:

```bash
grep -i critical vms/win10-01-serial.log                      # did it crash?
grep -i "Executing plugin" vms/win10-01-serial.log            # what ran
grep -i "already done, skipping" vms/win10-01-serial.log      # what was skipped
grep -i "return code" vms/win10-01-serial.log                 # user-data exit codes
```

The log also captures user-data stdout/stderr (`User_data stdout:` / `stderr:`).

### Practice exercises (all tested)

| # | Do | Proves |
|---|---|---|
| 1 | Delete the file user-data created, reboot | It doesn't come back: run-once state |
| 2 | Change `instance-id`, rebuild the seed ISO, boot the **same** disk | It runs again; a second registry entry appears |
| 3a | `exit 1002`, new instance-id, boot, then reboot | Script runs every boot |
| 3b | `exit 1001`, new instance-id, boot | VM reboots by itself; script marked done |
| 4 | Add `network-config`, set the MAC on the QEMU command | Static IP applied, adapter renamed |

---

## How the other files work

### `windows10.pkr.hcl`

| Setting | Notes |
|---|---|
| `iso_checksum = "sha256:…"` | Must be **quoted**. Get it with `sha256sum Win10_22H2_English_x64.iso` |
| `disk_interface = "virtio"` | Needs `viostor` (not `vioscsi` — that's for virtio-scsi) |
| `net_device = "virtio-net"` | Needs `NetKVM` |
| `cd_files` | `Autounattend.xml`, `./drivers`, `./installers`. Folder names are kept on the CD |
| No `boot_command` | On a blank disk the VM boots from the CD by itself. Typing keys over VNC only caused failures |
| `provisioner "powershell"` | Runs `scripts/setup.ps1` |
| `provisioner "file"` (×2) | Uploads `cloudbase-init.conf`, then `unattend-clone.xml` |
| `shutdown_command` | Runs sysprep with `unattend.xml`; sysprep powers the VM off when done |

### `Autounattend.xml` — the install

| Pass | What it does |
|---|---|
| `windowsPE` | Language; loads drivers from `D:\`, `E:\`, `F:\` (searched recursively — CD letters vary); partitions the disk; generic Pro key |
| `offlineServicing` | Adds the same drivers to the installed Windows (so networking works after install) |
| `oobeSystem` | Skips OOBE screens, sets the Administrator password, auto-logs in, enables WinRM |

Locale: Windows display language `en-US`, keyboard `en-US`, date/number formats `en-GB`.
The language must match the ISO: the **English International** ISO only contains `en-GB`, and
Setup shows the language screen if you ask for `en-US`.

WinRM is enabled with separate `cmd /c` commands. Using PowerShell for these mangles the
quotes in `@{Basic="true"}`, and `winrm quickconfig` refuses to run until the network is set to Private.

### `unattend-clone.xml` — each clone's first boot

| Pass | What it does |
|---|---|
| `generalize` | `PersistAllDeviceInstalls` keeps the VirtIO drivers through sysprep |
| `specialize` | `ComputerName *` gives a random name (Cloudbase-Init renames it if the seed sets a hostname) |
| `oobeSystem` | Skips OOBE, sets the Administrator password, auto-logs in once |

### `scripts/setup.ps1`

Finds each MSI on whichever CD drive it's on, installs it with a log in `C:\Windows\Temp\`, and
**fails the build** if an installer errors or a service doesn't exist. Scripts that always print
"success" hide problems — the first version of this one did.

| Installs | Options |
|---|---|
| `qemu-ga-x86_64.msi` | — |
| `CloudbaseInitSetup_Stable_x64.msi` | `RUN_SERVICE_AS_LOCAL_SYSTEM=1` (no extra service account), `LOGGINGSERIALPORTNAME=COM1`; then stops the service and sets it to Automatic |

---

## Troubleshooting

### Build

| Symptom | Cause | Fix |
|---|---|---|
| `Timeout waiting for WinRM` after 1 h | Windows never finished installing | Watch over VNC to see where it stopped |
| Repeated `connection reset by peer` on the WinRM port | Host port forward works but nothing listens in the guest | Same as above — the problem is inside Windows |
| Setup shows the language screen | `UILanguage` not on the ISO | Match the answer file to the ISO's language |
| Setup shows "Where do you want to install Windows?" with no disks | Disk driver not loaded | Check `drivers/viostor` exists and is on the CD |
| Packer CD step: `permission denied` | Files extracted read-only | `chmod -R u+w drivers installers` |
| `use of closed network connection` / `Error handshaking with VNC: EOF` | A VNC viewer took over the connection | Use `vncviewer -Shared`, or close the viewer and press `r` |
| `Missing newline after argument` | Unquoted string in HCL | Put quotes around the value |
| `Output directory … already exists` from `packer validate` | Validate checks the output folder | Use `packer validate -syntax-only` |
| Build hangs at "Gracefully halting" | Sysprep failed (often a Store app updated in the background) | VNC in, read `C:\Windows\System32\Sysprep\Panther\setupact.log` |

### Clones

| Symptom | Cause | Fix |
|---|---|---|
| A key like `\|` won't type | Guest keyboard layout differs from your keyboard | Set `InputLocale` in both answer files |
| Taskbar search shows "Cortana is not available…" | Windows Search glitch on first login after sysprep | Harmless; open apps via right-click Start |
| `socat` returns nothing | Agent not answering, or socat exited too soon | Use interactive `socat` and wait; check `Get-Service qemu-ga` in the VM |
| Cloudbase-Init seems to do nothing | Service crashed | `grep -i critical` the serial log — usually a mistyped plugin name |
| Seed changes ignored | Same instance-id → plugins already done | Change `instance-id`, rebuild the seed ISO |
| User-data runs even though instance-id didn't change | `qemu-img create` made a fresh clone with no saved state | Only re-run `qemu-img create` when you want a fresh clone |
| Static IP not applied | `NetworkConfigPlugin` missing from the config, or MAC mismatch | Check the `plugins` list; check `mac=` on the QEMU command matches `network-config` |
| Old errors in the serial log | Log is only reset when QEMU starts | Check timestamps |
| Unexpected reboot on first boot | Hostname change, or user-data exit code 1001/1003 | Expected |

Useful logs inside Windows:

| Log | When |
|---|---|
| `X:\Windows\Panther\setupact.log` | During Setup (press **Shift+F10** for a command prompt) |
| `C:\Windows\Panther\UnattendGC\setupact.log` | Answer-file problems after install |
| `C:\Windows\System32\Sysprep\Panther\setupact.log` | Sysprep failures |
| `C:\Windows\Temp\<name>.msi.log` | MSI install problems during the build |
| `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log` | Cloudbase-Init |

---

## Security notes

- `Password123!` is in plain text in three files, and WinRM allows unencrypted Basic auth.
  Fine for an isolated lab; for anything else, move the password into a Packer `variable`
  with `sensitive = true`, pass it with `-var`, and disable WinRM at the end of provisioning.
- Windows auto-login may leave the password in the registry
  (`HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon`, `DefaultPassword`).
- Cloudbase-Init runs as LocalSystem and executes whatever is in `user-data` — treat seed ISOs
  like scripts with admin rights.
- Windows 10 support ended in October 2025. Without an ESU subscription there are no security
  updates — keep these VMs off untrusted networks.

---

## Moving to Windows Server 2022

1. Swap the ISO and checksum in `windows10.pkr.hcl` (rename the file to match).
2. Change the extract paths from `w10` to `2k22` in `extract-drivers.sh`, delete `drivers/`, re-run it.
3. In `Autounattend.xml`:
   - Add `<InstallFrom>` under `<OSImage>` to pick the edition (e.g. `Windows Server 2022 SERVERSTANDARD`).
   - Replace the Windows 10 product key with your licence key.
   - The `<OOBE>` block can be trimmed — Server has no consumer OOBE screens.
4. Cloudbase-Init works the same on Server — no config changes needed.
5. Rebuild and run through the Step 6 checks.

---

## Possible next steps

- Run clones under **libvirt** instead of raw QEMU commands (VMs survive the terminal, reachable network).
- Generate seeds and create VMs with **Ansible** (CPUs/RAM/MAC on the VM, hostname/IP in the seed),
  then configure Windows over WinRM.
