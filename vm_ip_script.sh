#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "Este script debe ejecutarse con sudo o como root"
   exit 1
fi

sysctl -w net.ipv4.ip_forward=1 > /dev/null

# Validar IP
validar_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        echo "Error: '$ip' no es una IP válida"
        return 1
    fi
}

# Validar puerto
validar_puerto() {
    local puerto=$1
    if [[ $puerto =~ ^[0-9]+$ ]] && [ "$puerto" -ge 1 ] && [ "$puerto" -le 65535 ]; then
        return 0
    else
        echo "Error: Puerto debe ser un número entre 1 y 65535"
        return 1
    fi
}

menu() {
    echo -e "\n======================================"
    echo "    GESTOR PORT-FORWARDING PROXMOX"
    echo "======================================"
    echo "1) Listar Redirecciones"
    echo "2) Crear Nueva (Port -> VM)"
    echo "3) Eliminar Redirección"
    echo "4) Guardar reglas (persistencia)"
    echo "5) Inventario Máquinas Virtuales"
    echo "6) Salir"
    read -p "Seleccione una opción: " opcion
}

listar() {
    echo -e "\n--- REGLAS NAT ACTIVAS ---"
    local reglas=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "DNAT")
    if [[ -z "$reglas" ]]; then
        echo "No hay reglas de redirección activas."
    else
        echo "$reglas"
    fi
}

crear() {
    echo -e "\n--- NUEVA REDIRECCIÓN (AUTODETECCIÓN POR VMID) ---"
    
    read -p "Introduce el ID de la VM (VMID): " vmid
    
    if [[ -n "$vmid" ]]; then
        echo "🔍 Buscando MAC e IP para la VM $vmid..."
        
        local mac=$(qm config "$vmid" 2>/dev/null | grep -i "net0" | grep -o -P '([a-fA-F0-9]{2}:){5}[a-fA-F0-9]{2}' | tr '[:upper:]' '[:lower:]')
        
        if [[ -n "$mac" ]]; then
            local ip_sugerida=$(ip neighbor show | grep "$mac" | awk '{print $1}' | head -n 1)
            
            if [[ -n "$ip_sugerida" ]]; then
                echo "💡 IP detectada automáticamente: $ip_sugerida"
                read -p "Presiona Enter para usarla o escribe la IP manualmente: " ip_input
                ip_vm=${ip_input:-$ip_sugerida}
            else
                echo "⚠️  MAC encontrada ($mac), pero la IP no está en la tabla ARP."
                echo "💡 Sugerencia: Asegúrate de que la VM esté encendida y haya tenido tráfico."
                read -p "Introduce la IP de la VM manualmente: " ip_vm
            fi
        else
            echo "❌ No se encontró configuración de red para la VM $vmid."
            read -p "Introduce la IP de la VM manualmente: " ip_vm
        fi
    else
        read -p "Introduce la IP de la VM manualmente: " ip_vm
    fi

    validar_ip "$ip_vm" || return
    
    read -p "Puerto Externo (Host Proxmox): " p_ext
    validar_puerto "$p_ext" || return
    
    read -p "Puerto de la VM Destino: " p_vm
    validar_puerto "$p_vm" || return
    
    read -p "Protocolo (tcp/udp) [tcp]: " protocolo
    protocolo=${protocolo:-tcp}

    if iptables -t nat -A PREROUTING -p "$protocolo" --dport "$p_ext" -j DNAT --to-destination "$ip_vm:$p_vm"; then
        iptables -t nat -A POSTROUTING -d "$ip_vm" -p "$protocolo" --dport "$p_vm" -j MASQUERADE
        echo -e "\n✅ Redirección establecida con éxito:"
        echo "   [$protocolo] Host:$p_ext ---> VM($vmid - $ip_vm):$p_vm"
    else
        echo "❌ Error crítico al aplicar las reglas de iptables."
    fi
}

eliminar() {
    echo -e "\n--- SELECCIONAR REGLA A ELIMINAR ---"
    listar
    
    local reglas=$(iptables -t nat -L PREROUTING -n --line-numbers | grep "DNAT")
    if [[ -z "$reglas" ]]; then
        echo "No hay reglas para eliminar."
        return
    fi
    
    read -p "Introduce el número de línea a eliminar (o Enter para cancelar): " num
    
    if [[ -z "$num" ]]; then
        echo "Operación cancelada."
        return
    fi
    
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        echo "Error: Debes introducir un número válido"
        return
    fi
    
    if iptables -t nat -D PREROUTING "$num" 2>/dev/null; then
        echo "Regla eliminada correctamente."
    else
        echo "Error al eliminar la regla. Verifica el número."
        return 1
    fi
}

# Guardar reglas (persistencia)
guardar_reglas() {
    echo "Guardando reglas en /etc/iptables/rules.v4..."
    if mkdir -p /etc/iptables 2>/dev/null && iptables-save > /etc/iptables/rules.v4 2>/dev/null; then
        echo "Reglas guardadas correctamente."
        echo "Para restaurarlas automáticamente, instala iptables-persistent:"
        echo "  apt-get install iptables-persistent"
    else
        echo "Error al guardar las reglas. Verifica permisos."
    fi
}

inventario_maquinas() {
    echo -e "\n--- INVENTARIO DE MÁQUINAS VIRTUALES ---"
    lista_vms=$(qm list)
    echo "$lista_vms"
    for vm in $lista_vms; do
        vm_id=$(echo $vm | awk '{print $1}')
        vm_name=$(echo $vm | awk '{print $2}')
        echo "VM ID: $vm_id, Nombre: $vm_name"
    done | columnn -t
}

# Bucle principal
while true; do
    menu
    case $opcion in
        1) listar ;;
        2) crear ;;
        3) eliminar ;;
        4) guardar_reglas ;;
        5) inventario_maquinas ;;
        6) exit 0 ;;
        *) echo "Opción no válida." ;;
    esac
done