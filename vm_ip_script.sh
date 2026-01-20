#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "Este script debe ejecutarse con sudo o como root"
   exit 1
fi

sysctl -w net.ipv4.ip_forward=1 > /dev/null

menu() {
    echo -e "\n======================================"
    echo "    GESTOR PORT-FORWARDING PROXMOX"
    echo "======================================"
    echo "1) Listar Redirecciones"
    echo "2) Crear Nueva (Port -> VM)"
    echo "3) Eliminar Redirección"
    echo "4) Salir"
    read -p "Seleccione una opción: " opcion
}

listar() {
    echo -e "\n--- REGLAS NAT ACTIVAS ---"
    iptables -t nat -L PREROUTING -n --line-numbers | grep -E "num|DNAT"
}

crear() {
    read -p "Puerto Externo (del Host Proxmox): " p_ext
    read -p "IP de la VM Destino: " ip_vm
    read -p "Puerto de la VM Destino: " p_vm
    
    iptables -t nat -A PREROUTING -p tcp --dport "$p_ext" -j DNAT --to-destination "$ip_vm":"$p_vm"
    
    iptables -t nat -A POSTROUTING -d "$ip_vm" -p tcp --dport "$p_vm" -j MASQUERADE
    
    echo "Redirección establecida: Host:$p_ext -> VM($ip_vm):$p_vm"
}

eliminar() {
    listar
    read -p "Introduce el número de línea a eliminar: " num
    if [[ -n $num ]]; then
        iptables -t nat -D PREROUTING "$num"
        echo "Regla eliminada."
    else
        echo "Número no válido."
    fi
}

# Bucle principal
while true; do
    menu
    case $opcion in
        1) listar ;;
        2) crear ;;
        3) eliminar ;;
        4) exit 0 ;;
        *) echo "Opción no válida." ;;
    esac
done