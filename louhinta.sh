#!/usr/bin/env bash
set -euo pipefail

MINERSTAT_ACCESSKEY=${1:-}
if [ "${MINERSTAT_ACCESSKEY}" = "" ]; then
  echo "USAGE: ./louhinta.sh MINERSTAT_ACCESSKEY"
  exit 1
fi

if ! cat /proc/cmdline | grep "_iommu=on" >/dev/null; then
  echo "iommu not configured, write yes to configure and reboot"
  read input
  if [ "$input" != "yes" ]; then
    echo "you wrote: $input"
    exit 1
  fi

  sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="amd_iommu=on intel_iommu=on iommu=pt pcie_acs_override=downstream,multifunction nofb nomodeset video=vesafb:off,efifb:off"/' /etc/default/grub
  update-grub
  echo "reboot!"
  reboot
else
  echo "iommu ok"
fi

CORES=1
MEMORY=2048
NAME="${HOSTNAME}-louhinta"
MINERSTAT_VERSION="msos-v1-4-K50-N460-A2030"
MINERSTAT_WORKER="$(hostname)"

mkdir -p /root/.louhinta

set +e
  pvesm set local --content iso,vztmpl,backup,images
set -e

set +e
  EXISTING_VM_ID=$(qm list | grep "${NAME}" | awk '{print $1;}')
set -e

if [ "$EXISTING_VM_ID" = "" ]; then
  VM="$(pvesh get /cluster/nextid)"
else
  VM="$EXISTING_VM_ID"
fi

echo "VM: ${VM}"

if [ -f "/etc/pve/nodes/$(hostname)/qemu-server/${VM}.conf" ]; then
  qm stop $VM
  qm destroy $VM
fi

cd /root/.louhinta
  if [ ! -f "${MINERSTAT_VERSION}.img" ]; then
    curl -L --fail "https://archive.minerstat.com/?file=${MINERSTAT_VERSION}.zip" -o "${MINERSTAT_VERSION}.zip"

    unzip "${MINERSTAT_VERSION}.zip"
    rm "${MINERSTAT_VERSION}.zip"
  else
    echo "/root/.louhinta/${MINERSTAT_VERSION}.img exists"
  fi
cd /root

mkdir -p "/var/lib/vz/images/${VM}"
dd status=progress bs=1M if="/root/.louhinta/${MINERSTAT_VERSION}.img" of="/var/lib/vz/images/$VM/$MINERSTAT_VERSION.raw"

START2=$(fdisk -l /var/lib/vz/images/${VM}/${MINERSTAT_VERSION}.raw | grep "raw2" | awk '{ print $2 }')
START2=$(echo "$START2*512" | bc)
mkdir -p /tmp/minerstat_p2
set +e
  umount /tmp/minerstat_p2
set -e
mount -o loop,offset=$START2 "/var/lib/vz/images/${VM}/${MINERSTAT_VERSION}.raw" /tmp/minerstat_p2

# Create config.js to partition 2
cat > "/tmp/minerstat_p2/config.js" <<EOF
global.accesskey = "${MINERSTAT_ACCESSKEY}";
global.worker = "${MINERSTAT_WORKER}";
EOF

cat "/tmp/minerstat_p2/config.js"

umount /tmp/minerstat_p2
rm -rf /tmp/minerstat_p2

echo "resizing"
qemu-img resize "/var/lib/vz/images/${VM}/${MINERSTAT_VERSION}.raw" +10G
echo "sync"
sync

echo "qm create"
qm create "${VM}" --name "${NAME}"

echo "qm sets"
qm set "${VM}" -args "-cpu 'host,+kvm_pv_unhalt,+kvm_pv_eoi,hv_vendor_id=proxmox,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_reset,hv_vpindex,hv_runtime,hv_relaxed,hv_synic,hv_stimer,hv_tlbflush,hv_ipi,kvm=off'"
qm set "${VM}" -cpu host,hidden=1,flags=+pcid
qm set "${VM}" --machine q35
qm set "${VM}" --memory "${MEMORY}"
qm set "${VM}" --cores "${CORES}"
qm set "${VM}" --net0 virtio,bridge=vmbr0
qm set "${VM}" --scsihw virtio-scsi-pci
qm set "${VM}" --scsi0 "local:${VM}/${MINERSTAT_VERSION}.raw,cache=writeback"

gpus=$(lspci | grep "VGA compatible" | grep "NVIDIA" | cut -d' ' -f1 | cut -d. -f1)
i=0
for gpu in $gpus; do
  qm set "${VM}" "--hostpci${i}" "${gpu},pcie=1"
  let i=${i}+1
done


echo '''#!/usr/bin/env bash
set -euo pipefail

delay=${1:-60}
echo "sleep ${delay}"
sleep "${delay}"

set +e
  echo 0 > /sys/class/vtconsole/vtcon0/bind
  echo 0 > /sys/class/vtconsole/vtcon1/bind
set -e

set +e
  echo efi-framebuffer.0 > /sys/bus/platform/drivers/efi-framebuffer/unbind
  echo efi-framebuffer.1 > /sys/bus/platform/drivers/efi-framebuffer/unbind
set -e
''' > /root/.louhinta/startup
echo "qm start ${VM}" >> /root/.louhinta/startup

chmod +x /root/.louhinta/startup

if crontab -l; then
  old_crontab=$(crontab -l)
else
  old_crontab=""
fi

case $old_crontab in
  *louhinta/startup*)
    echo "already configured in crontab"
  ;;
  *)
    printf "${old_crontab}\n@reboot screen -dmS louhinta bash -l -c '/root/.louhinta/startup'\n" | crontab
  ;;
esac


echo ""
cat "/etc/pve/nodes/$(hostname)/qemu-server/$VM.conf"

echo "start"
/root/.louhinta/startup 0

echo ""
echo "done"
