#!/bin/bash
mkdir -p drivers installers
xorriso -osirrox on -indev virtio-win.iso \
  -extract /viostor/w10/amd64 drivers/viostor \
  -extract /NetKVM/w10/amd64 drivers/NetKVM \
  -extract /vioserial/w10/amd64 drivers/vioserial \
  -extract /guest-agent/qemu-ga-x86_64.msi installers/qemu-ga-x86_64.msi
chmod -R u+w drivers installers
