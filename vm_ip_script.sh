#!/bin/bash

# --- FUNCIONES ---

listar_redirecciones() {
    echo -e "\n--- REDIRECCIONES ACTUALES ---"
    # Mostramos la tabla NAT, cadena PREROUTING, con números de línea
    sudo iptables -t nat -L PREROUTING -n --line-numbers | grep -E "dpt:|DNAT|num"
    echo "-------------------------------"
}

crear_redireccion() {
    read -p "Puerto externo (el que se verá desde fuera): " p_ext
    read -p "IP de la Maquina Virtual (interna): " ip_int
    read -p "Puerto de la Maquina Virtual: " p_int
    
    sudo iptables -t nat -A PREROUTING -p tcp --dport "$p_ext" -j DNAT --to-destination "$ip_int":"$p_int"
    
    if [ $? -eq 0 ]; then
        echo "✅ Redirección creada: Port $p_ext -> $ip_int:$p_int"
    else
        echo "❌ Error al crear la redirección."
    fi
}

eliminar_redireccion() {
    listar_redirecciones
    read -p "Ingrese el número de línea que desea eliminar: " num_linea
    sudo iptables -t nat -D PREROUTING "$num_linea"
    
    if [ $? -eq 0 ]; then
        echo "✅ Regla eliminada correctamente."
    else
        echo "❌ No se pudo eliminar la regla. ¿El número es correcto?"
    fi
}

editar_redireccion() {
    echo "Para editar, primero eliminaremos la regla vieja y crearemos una nueva."
    eliminar_redireccion
    echo "Ahora, ingresa los nuevos datos:"
    crear_redireccion
}

# --- MENÚ PRINCIPAL ---

while true; do
    echo -e "\n============================"
    echo "   GESTOR DE REDIRECCIONES  "
    echo "============================"
    echo "1. Listar redirecciones"
    echo "2. Crear nueva redirección"
    echo "3. Editar una redirección"
    echo "4. Eliminar una redirección"
    echo "5. Salir"
    read -p "Seleccione una opción [1-5]: " opcion

    case $opcion in
        1) listar_redirecciones ;;
        2) crear_redireccion ;;
        3) editar_redireccion ;;
        4) eliminar_redireccion ;;
        5) echo "¡Adiós!"; exit 0 ;;
        *) echo "Opción no válida." ;;
    esac
done