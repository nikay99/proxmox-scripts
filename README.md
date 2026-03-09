# Mit Standardwerten (DHCP)
bash paperclip-install.sh

# Oder mit eigenen Werten
VMID=9001 \
VMNAME=paperclip \
STORAGE=local-lvm \
BRIDGE=vmbr0 \
IPCONFIG0='ip=192.168.1.220/24,gw=192.168.1.1' \
PUBLIC_HOST=agents.cloudm8.net \
bash paperclip-install.sh
 
qm guest exec 9001 -- cat /root/paperclip-install-result.txt
