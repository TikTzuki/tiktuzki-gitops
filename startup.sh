touch ~/.bash_aliases
cat <<EOF >> ~/.bash_aliases
alias mk='microk8s'
alias k='microk8s kubectl'
EOF
apt install neovim
microk8s enable dashboard

#microk8s enable hostpath-storage
#microk8s enable registry # Docker registry 32000

# Openvpn3 client installation
sudo mkdir -p /etc/apt/keyrings && curl -fsSL https://packages.openvpn.net/packages-repo.gpg | sudo tee /etc/apt/keyrings/openvpn.asc
DISTRO=$(lsb_release -c -s)
echo "deb [signed-by=/etc/apt/keyrings/openvpn.asc] https://packages.openvpn.net/openvpn3/debian $DISTRO main" | sudo tee /etc/apt/sources.list.d/openvpn-packages.list
sudo apt update
sudo apt install openvpn3-client
