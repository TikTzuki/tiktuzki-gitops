touch ~/.bash_aliases
cat <<EOF >> ~/.bash_aliases
alias mk='microk8s'
alias k='microk8s kubectl'
alias kubectl='microk8s kubectl'
alias kst='microk8s kubectl -n kube-system'
EOF

sudo apt install -y neovim
sudo usermod -a -G microk8s tik
newgrp microk8s
microk8s enable dashboard

#microk8s enable hostpath-storage
#microk8s enable registry # Docker registry 32000

# Openvpn3 client installation
sudo mkdir -p /etc/apt/keyrings && curl -fsSL https://packages.openvpn.net/packages-repo.gpg | sudo tee /etc/apt/keyrings/openvpn.asc
DISTRO=$(lsb_release -c -s)
echo "deb [signed-by=/etc/apt/keyrings/openvpn.asc] https://packages.openvpn.net/openvpn3/debian $DISTRO main" | sudo tee /etc/apt/sources.list.d/openvpn-packages.list
sudo apt update
sudo apt install -y openvpn3-client

# Fix kubelite error must match public address:
#sudo nvim /var/snap/microk8s/current/args/kube-apiserver
#--advertise-address=192.168.1.5

#microk8s kubectl -n kube-system edit daemonset calico-node
#Inside the calico-node container env:
#- name: IP_AUTODETECTION_METHOD
#  value: "interface=eth0"
