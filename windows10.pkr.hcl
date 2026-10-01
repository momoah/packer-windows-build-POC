packer {
  required_plugins {
    qemu = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "qemu" "windows_soe" {
  # 22H2 is the final Win10 release and you already have it downloaded
  iso_url      = "Win10_22H2_English_x64.iso"
  #iso_checksum = "none" # swap for "sha256:<hash>" from: sha256sum Win10_22H2_English_x64.iso
  iso_checksum = "sha256:f41ba37aa02dcb552dc61cef5c644e55b5d35a8ebdfac346e70f80321343b506"
  disk_size    = "40G"
  format       = "qcow2"
  headless     = true
  cpus         = 2
  memory       = 4096
  accelerator  = "kvm"

  # Be explicit so the drivers in Autounattend.xml match the hardware
  disk_interface = "virtio"     # needs viostor
  net_device     = "virtio-net" # needs NetKVM

  boot_wait    = "2s"

  # Extracted driver folders, NOT the whole virtio-win.iso
  # (Windows can't read drivers from inside a nested .iso file)
  cd_files = [
    "./Autounattend.xml",
    "./drivers",
    "./installers"
  ]
  cd_label = "OEMDRV"

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = "Password123!"
  winrm_timeout  = "1h"

  # Clean shutdown after provisioning instead of a hard stop
  shutdown_command = "C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown /quiet /unattend:C:\\Windows\\System32\\Sysprep\\unattend.xml"
  shutdown_timeout = "15m"
}

build {
  sources = ["source.qemu.windows_soe"]

  provisioner "powershell" {
    script = "./scripts/setup.ps1"
  }

  provisioner "file" {
    source      = "./unattend-clone.xml"
    destination = "C:/Windows/System32/Sysprep/unattend.xml"
  }

  provisioner "file" {
    source      = "./cloudbase-init/cloudbase-init.conf"
    destination = "C:/Program Files/Cloudbase Solutions/Cloudbase-Init/conf/cloudbase-init.conf"
  }
}
