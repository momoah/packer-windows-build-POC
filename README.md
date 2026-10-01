# packer-windows-build

Unattended build of a sysprepped **Windows 10 22H2** base image for QEMU/KVM, using Packer.
Clones made from the image boot straight to the desktop with their own computer name and a
working QEMU guest agent.

> Planned: move to **Windows Server 2022** once a licence is available (see the end of this file).

---

## TL;DR — quick start

```bash
# one-time
./extract-drivers.sh

# build (~18 min)
packer validate -syntax-only windows10.pkr.hcl && packer build -force -on-error=ask windows10.pkr.hcl

# make and boot a clone
qemu-img create -f qcow2 -F qcow2 -b ../output-windows_soe/packer-windows_soe vms/win10-01.qcow2
# then boot it with the command in "Step 4 — Run a clone"
```

Login: `Administrator` / `Password123!` (lab only — see Security).

---

## Requirements

| Tool | Used for |
|---|---|
| Packer 1.11+ with the `qemu` plugin | Running the build (`packer init windows10.pkr.hcl` installs the plugin) |
| QEMU/KVM (`qemu-system-x86_64`, `qemu-img`) | The VM and its disk |
| `xorriso` | Extracting drivers, and Packer uses it to build the answer-file CD |
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
├── windows10.pkr.hcl      # Packer template
├── Autounattend.xml       # Answer file for the INSTALL (read by Windows Setup)
├── unattend-clone.xml     # Answer file for each CLONE's first boot (used by sysprep)
├── extract-drivers.sh     # Pulls the needed bits out of virtio-win.iso
├── scripts/
│   └── setup.ps1          # Provisioning: installs the QEMU guest agent
├── drivers/               # (generated) viostor, NetKVM, vioserial
├── installers/            # (generated) qemu-ga-x86_64.msi
├── output-windows_soe/    # (generated) the base image
└── vms/                   # (generated) clones
```

Suggested `.gitignore`:

```
*.iso
drivers/
installers/
output-*/
vms/
build.log
```

---

## Step 1 — Extract drivers (one-time, or after updating virtio-win.iso)

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
```

| Extracted | Why |
|---|---|
| `viostor` | Disk driver — without it Setup can't see the virtio disk |
| `NetKVM` | Network driver — needed for WinRM |
| `vioserial` | Serial channel the guest agent uses to talk to the host |
| `qemu-ga-x86_64.msi` | The guest agent itself |

The `chmod` matters: xorriso extracts files read-only, and Packer fails with
`permission denied` when it copies them.

---

## Step 2 — Build the base image

```bash
packer validate -syntax-only windows10.pkr.hcl && packer build -force -on-error=ask windows10.pkr.hcl
```

- `-syntax-only`: plain `packer validate` fails whenever an old `output-windows_soe/` exists.
- `-force`: overwrites the previous image. **Delete any clones first** (see Step 3).
- `-on-error=ask`: on failure, keeps the VM alive so you can inspect it.

### What happens, in order

1. Packer builds a small CD (label `OEMDRV`, ~30 MB) containing `Autounattend.xml`, `drivers/` and `installers/`.
2. The VM boots the Windows ISO. Setup finds `Autounattend.xml` on the CD and runs with no prompts:
   loads `viostor` + `NetKVM`, wipes and partitions the disk, installs Windows 10 Pro.
3. OOBE is skipped; Windows logs in as Administrator and the first-logon commands enable WinRM.
4. Packer connects over WinRM and runs `scripts/setup.ps1` (installs the guest agent; fails the build if it doesn't install).
5. Packer uploads `unattend-clone.xml` to `C:\Windows\System32\Sysprep\unattend.xml`.
6. The shutdown command runs **sysprep** (`/generalize /oobe /shutdown`), which strips the machine's identity and powers off.
7. Packer compacts the disk into `output-windows_soe/packer-windows_soe` (qcow2).

A good build takes about 15–20 minutes and ends with:

```
==> Builds finished. The artifacts of successful builds are:
--> qemu.windows_soe: VM files in directory: output-windows_soe
```

### Watching the build

Packer prints a VNC address (`vnc://127.0.0.1:59xx`). Connect in **shared** mode:

```bash
vncviewer -Shared 127.0.0.1:59xx
```

Without `-Shared`, TigerVNC kicks Packer off the VM's VNC connection. To make it permanent,
add `Shared=1` to `~/.vnc/default.tigervnc`.

---

## Step 3 — Make a clone

Clones are thin copies that only store their own changes, so they start at a few hundred KB:

```bash
mkdir -p vms
qemu-img create -f qcow2 -F qcow2 \
  -b ../output-windows_soe/packer-windows_soe vms/win10-01.qcow2
```

- The `-b` path is relative to the **clone's** folder, hence `../`.
- Never modify the base image while clones depend on it. **Rebuilding breaks existing clones** —
  delete them first (`rm vms/*.qcow2`).

## Step 4 — Run a clone

```bash
qemu-system-x86_64 -enable-kvm -m 4096 -smp 2 \
  -drive file=vms/win10-01.qcow2,if=virtio,format=qcow2 \
  -device virtio-net,netdev=n0 -netdev user,id=n0 \
  -device virtio-serial \
  -chardev socket,path=/tmp/qga.sock,server=on,wait=off,id=qga0 \
  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  -usb -device usb-tablet
```

| Option | Why |
|---|---|
| `virtio-serial` + `chardev` + `virtserialport` | The guest agent channel, exposed on the host as `/tmp/qga.sock` |
| `-usb -device usb-tablet` | Accurate mouse pointer without needing to grab it |

Running more than one clone at once? Give each its own socket path (`/tmp/qga-01.sock`, …).

On first boot the clone shows "Getting ready", may reboot, then logs in automatically once.

---

## Step 5 — Verify a clone

| Check | How | Expected |
|---|---|---|
| Unique identity | In the VM: `hostname` | A random name like `WINDOWS-H8GL6M4` |
| Keyboard layout | Type `\|` in PowerShell | It appears |
| Guest agent | Host: `socat - UNIX-CONNECT:/tmp/qga.sock` then type `{"execute":"guest-ping"}` | `{"return": {}}` |
| Agent detail | Same session: `{"execute":"guest-get-host-name"}` | The clone's hostname |

Press Ctrl+C to leave socat.

---

## How the files work

### `windows10.pkr.hcl`

| Setting | Notes |
|---|---|
| `iso_checksum = "sha256:…"` | Must be **quoted**. Get it with `sha256sum Win10_22H2_English_x64.iso` |
| `disk_interface = "virtio"` | Needs `viostor` (not `vioscsi` — that's for virtio-scsi) |
| `net_device = "virtio-net"` | Needs `NetKVM` |
| `cd_files` | `Autounattend.xml`, `./drivers`, `./installers`. Folder names are kept on the CD |
| No `boot_command` | On a blank disk the VM boots from the CD by itself. Typing keys over VNC only caused failures |
| `shutdown_command` | Runs sysprep with `unattend.xml`; sysprep powers the VM off when done |
| `provisioner "file"` | Uploads `unattend-clone.xml` for sysprep to use |

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
| `specialize` | `ComputerName *` gives each clone a random name |
| `oobeSystem` | Skips OOBE, sets the Administrator password, auto-logs in once |

### `scripts/setup.ps1`

Finds `qemu-ga-x86_64.msi` on whichever CD drive it's on, installs it, and **fails the build**
if the installer errors or the `QEMU-GA` service doesn't exist. Scripts that always print
"success" hide problems — the first version of this one did.

---

## Troubleshooting

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
| A key like `\|` won't type | Guest keyboard layout differs from your keyboard | Set `InputLocale` in both answer files |
| Taskbar search shows "Cortana is not available…" | Windows Search glitch on first login after sysprep | Harmless; open apps via right-click Start |
| `socat` returns nothing | Agent not answering, or socat exited too soon | Use interactive `socat` and wait; check `Get-Service qemu-ga` in the VM |

Useful logs inside Windows:

| Log | When |
|---|---|
| `X:\Windows\Panther\setupact.log` | During Setup (press **Shift+F10** for a command prompt) |
| `C:\Windows\Panther\UnattendGC\setupact.log` | Answer-file problems after install |
| `C:\Windows\System32\Sysprep\Panther\setupact.log` | Sysprep failures |

---

## Security notes

- `Password123!` is in plain text in three files, and WinRM allows unencrypted Basic auth.
  Fine for an isolated lab; for anything else, move the password into a Packer `variable`
  with `sensitive = true`, pass it with `-var`, and disable WinRM at the end of provisioning.
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
4. Rebuild and run through the Step 5 checks.
