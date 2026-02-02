#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "Este script debe ejecutarse con sudo o como root"
   exit 1
fi

CACHE_FILE="/var/lib/proxmox-nat-cache"
mkdir -p "$(dirname "$CACHE_FILE")"
touch "$CACHE_FILE"

sysctl -w net.ipv4.ip_forward=1 > /dev/null

validar_ip() {
    [[ $1 =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || { echo "Error: IP inválida"; return 1; }
}

validar_puerto() {
    [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || { echo "Error: Puerto inválido"; return 1; }
}

actualizar_cache() {
    local vmid=$1; local ip=$2
    if [[ -n "$ip" && "$ip" != "-" ]]; then
        sed -i "/^$vmid /d" "$CACHE_FILE"
        echo "$vmid $ip" >> "$CACHE_FILE"
    fi
}

leer_cache() { awk -v id="$1" '$1==id {print $2}' "$CACHE_FILE"; }

obtener_ip_smart() {
    local vmid=$1
    local mac=""
    
    if qm list 2>/dev/null | grep -q "\b$vmid\b"; then
        mac=$(qm config "$vmid" 2>/dev/null | grep -i "^net0" | grep -oP '([a-fA-F0-9]{2}:){5}[a-fA-F0-9]{2}' | head -n 1)
    elif pct list 2>/dev/null | grep -q "\b$vmid\b"; then
        mac=$(pct config "$vmid" 2>/dev/null | grep -i "^net0" | grep -oP 'hwaddr=\K([a-fA-F0-9]{2}:){5}[a-fA-F0-9]{2}' | head -n 1)
    fi
    mac=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
    
    if [[ -n "$mac" ]]; then
        local ip_arp=$(ip neighbor show | grep -i "$mac" | awk '{print $1}' | grep -vE "^fe80" | head -n 1)
        if [[ -n "$ip_arp" ]]; then
            actualizar_cache "$vmid" "$ip_arp"
            echo "$ip_arp"
            return
        fi
    fi

    local ip_conf=""
    if [ -f "/etc/pve/qemu-server/$vmid.conf" ]; then
         ip_conf=$(grep -oP 'ip=\K[0-9.]+' "/etc/pve/qemu-server/$vmid.conf" 2>/dev/null | head -n 1)
    fi
    if [[ -n "$ip_conf" ]]; then
        actualizar_cache "$vmid" "$ip_conf"
        echo "$ip_conf"
        return
    fi

    leer_cache "$vmid"
}

obtener_nombre_desde_ip() {
    local target_ip=$1
    target_ip=$(echo "$target_ip" | tr -d '[:space:]')
    
    local mac_arp=$(ip neighbor show | grep -w "$target_ip" | awk '{print $5}' | tr '[:upper:]' '[:lower:]' | head -n 1)
    if [[ -n "$mac_arp" ]]; then
        local file=$(grep -rli "$mac_arp" /etc/pve/qemu-server /etc/pve/lxc 2>/dev/null | head -n 1)
        if [[ -n "$file" ]]; then
            local vmid=$(basename "$file" | cut -d. -f1)
            local name=$(grep -E "^(name|hostname):" "$file" | awk '{print $2}' | tr -d '[:cntrl:]')
            echo "[ID $vmid] $name"
            return
        fi
    fi

    local file_static=$(grep -rl "$target_ip" /etc/pve/qemu-server /etc/pve/lxc 2>/dev/null | head -n 1)
    if [[ -n "$file_static" ]]; then
        local vmid=$(basename "$file_static" | cut -d. -f1)
        local name=$(grep -E "^(name|hostname):" "$file_static" | awk '{print $2}' | tr -d '[:cntrl:]')
        echo "[ID $vmid] $name"
        return
    fi

    local vmid_cache=$(awk -v ip="$target_ip" '$2==ip {print $1}' "$CACHE_FILE" | head -n 1)
    
    if [[ -n "$vmid_cache" ]]; then
        local conf_file=$(ls /etc/pve/qemu-server/${vmid_cache}.conf /etc/pve/lxc/${vmid_cache}.conf 2>/dev/null | head -n 1)
        if [[ -n "$conf_file" ]]; then
             local name=$(grep -E "^(name|hostname):" "$conf_file" | awk '{print $2}' | tr -d '[:cntrl:]')
             echo "[ID $vmid_cache] $name (Caché)"
             return
        fi
    fi

    echo "Desconocida"
}

menu() {
    echo -e "\n======================================"
    echo "     GESTOR NAT PROXMOX (V3.3)"
    echo "======================================"
    echo "1) Listar Redirecciones"
    echo "2) Crear Nueva"
    echo "3) Eliminar Redirección"
    echo "4) Guardar reglas (Persistencia)"
    echo "5) Inventario Máquinas (Actualiza Caché)"
    echo "6) Salir"
    read -p "Seleccione una opción: " opcion
}

listar() {
    echo -e "\n--- REDIRECCIONES NAT ---"
    local reglas=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "DNAT")
    
    if [[ -z "$reglas" ]]; then echo "No hay reglas activas."; return; fi

    printf "%-4s %-5s %-8s %-8s %-15s %-25s\n" "NUM" "PROT" "HOST_P" "VM_P" "IP_VM" "NOMBRE"
    echo "-----------------------------------------------------------------------"
    
    echo "$reglas" | while read -r line; do
        local num=$(echo "$line" | awk '{print $1}')
        local prot=$(echo "$line" | awk '{print $3}')
        local p_ext=$(echo "$line" | grep -oP 'dpt:\K[0-9]+')
        local to_full=$(echo "$line" | grep -oP 'to:\K[0-9.:]+')
        
        local target_ip=${to_full%:*}
        local target_port=${to_full##*:}
        [[ "$target_port" == "$target_ip" ]] && target_port="$p_ext"

        local nombre=$(obtener_nombre_desde_ip "$target_ip")
        
        if [[ "$nombre" == "Desconocida" ]]; then continue; fi
        
        printf "%-4s %-5s %-8s %-8s %-15s %-25s\n" "$num" "$prot" "$p_ext" "$target_port" "$target_ip" "$nombre"
    done
    echo ""
    echo "(Las reglas desconocidas están ocultas. Usa 'Eliminar' para ver todas)"
}

crear() {
    echo -e "\n--- NUEVA REDIRECCIÓN ---"
    read -p "Introduce el ID de la VM: " vmid
    local ip_vm=$(obtener_ip_smart "$vmid")
    
    if [[ -n "$ip_vm" ]]; then
        echo "IP detectada: $ip_vm"
        read -p "Usar esta IP (Enter) o escribir otra: " ip_input
        ip_vm=${ip_input:-$ip_vm}
    else
        read -p "IP no detectada. Escribe la IP manualmente: " ip_vm
    fi
    
    validar_ip "$ip_vm" || return
    read -p "Puerto Host (Entrada): " p_ext; validar_puerto "$p_ext" || return
    read -p "Puerto VM (Interno): " p_vm; validar_puerto "$p_vm" || return
    
    iptables -t nat -A PREROUTING -p tcp --dport "$p_ext" -j DNAT --to-destination "$ip_vm:$p_vm"
    iptables -t nat -A POSTROUTING -d "$ip_vm" -p tcp --dport "$p_vm" -j MASQUERADE
    
    actualizar_cache "$vmid" "$ip_vm"
    echo "Regla aplicada. Recuerda GUARDAR (Opción 4)."
}

eliminar() {
    echo -e "\n--- ELIMINAR REGLA (SE MUESTRAN TODAS) ---"
    local reglas=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "DNAT")
    
    printf "%-4s %-5s %-8s %-15s %-25s\n" "NUM" "PROT" "PUERTO" "IP_VM" "NOMBRE"
    echo "-----------------------------------------------------------------------"
    echo "$reglas" | while read -r line; do
        local num=$(echo "$line" | awk '{print $1}')
        local prot=$(echo "$line" | awk '{print $3}')
        local p_ext=$(echo "$line" | grep -oP 'dpt:\K[0-9]+')
        local to_full=$(echo "$line" | grep -oP 'to:\K[0-9.:]+')
        local target_ip=${to_full%:*}
        local nombre=$(obtener_nombre_desde_ip "$target_ip")
        printf "%-4s %-5s %-8s %-15s %-25s\n" "$num" "$prot" "$p_ext" "$target_ip" "$nombre"
    done
    
    echo ""
    read -p "Número de regla a eliminar: " num
    [[ -n "$num" ]] && iptables -t nat -D PREROUTING "$num" && echo "Eliminada."
}

guardar_reglas() {
    local rules="/etc/iptables.nat.rules"
    iptables-save > "$rules"
    local svc="/etc/systemd/system/proxmox-nat-restore.service"
    if [[ ! -f "$svc" ]]; then
        echo "[Unit]
        Description=NAT Restore
        After=network.target
        [Service]
        Type=oneshot
        ExecStart=/sbin/iptables-restore $rules
        RemainAfterExit=yes
        [Install]
        WantedBy=multi-user.target" > "$svc"
        systemctl daemon-reload; systemctl enable proxmox-nat-restore.service >/dev/null 2>&1
    fi
    echo "Reglas guardadas y persistencia activa."
}

inventario_maquinas() {
    echo -e "\n--- INVENTARIO (DETECTANDO...) ---"
    printf "%-8s %-25s %-10s %-20s\n" "ID" "NOMBRE" "ESTADO" "IP"
    echo "-------------------------------------------------------------------"
    
    (qm list | awk 'NR>1 {print $1, $2, $3}'; pct list | awk 'NR>1 {print $1, $3, $2}') | sort -n | while read -r id nombre estado; do
        local ip="-"
        local origen=""
        local ip_detectada=$(obtener_ip_smart "$id")
        
        if [[ -n "$ip_detectada" ]]; then
            ip="$ip_detectada"
            local ip_cache=$(leer_cache "$id")
            if [[ "$estado" == "stopped" ]]; then origen="(Caché)"; elif [[ "$ip_detectada" == "$ip_cache" ]]; then origen=""; fi
        else
             ip="No detectada"
        fi
        printf "%-8s %-25s %-10s %-20s\n" "$id" "$nombre" "$estado" "$ip $origen"
    done
}

while true; do menu; case $opcion in 1) listar ;; 2) crear ;; 3) eliminar ;; 4) guardar_reglas ;; 5) inventario_maquinas ;; 6) exit 0 ;; *) echo "Opción no válida." ;; esac; done