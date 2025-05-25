#!/bin/bash

# Цвета вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Включаем логирование
exec > >(tee -a /root/Keenetic/conversion.log) 2>&1

# Проверка зависимостей
for cmd in wget sed grep cut tee sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || { echo -e "${RED}[Ошибка] $cmd не установлен. Установите его и повторите попытку.${NC}"; exit 1; }
done

AUTO_CONFIRM=false
[[ "$1" == "--yes" ]] && AUTO_CONFIRM=true

STEP=1
step_msg() {
    echo -e "${CYAN}[Шаг $STEP] $1${NC}"
    ((STEP++))
}

confirm_continue() {
    if $AUTO_CONFIRM; then
        return 0
    fi
    read -p "$1 (y/n): " choice
    case "$choice" in
        y|Y ) return 0;;
        n|N ) echo -e "${YELLOW}Скрипт завершен.${NC}"; exit 1;;
        * ) echo -e "${RED}Неверный ввод. Введите y или n.${NC}"; confirm_continue "$1";;
    esac
}

choose_dns() {
    step_msg "Выбор пары DNS-серверов"
    declare -A dns_pairs=(
        [1]="77.88.8.8 8.8.8.8"
        [2]="8.8.8.8 1.1.1.1"
        [3]="1.1.1.1 9.9.9.10"
        [4]="9.9.9.10 8.8.8.8"
        [5]="193.58.251.251 1.1.1.1"
    )
    for key in $(seq 1 ${#dns_pairs[@]}); do
        echo "$key. ${dns_pairs[$key]}"
    done
    while true; do
        read -p "Введите номер пары DNS (1-${#dns_pairs[@]}): " dns_choice
        if [[ -n "${dns_pairs[$dns_choice]}" ]]; then
            selected_dns=(${dns_pairs[$dns_choice]})
            DNS1=${selected_dns[0]}
            DNS2=${selected_dns[1]}
            echo -e "${GREEN}Выбраны DNS: $DNS1 и $DNS2${NC}"
            break
        else
            echo -e "${RED}Неверный выбор. Введите число от 1 до ${#dns_pairs[@]}.${NC}"
        fi
    done
}

select_user() {
    step_msg "Выбор пользователя из конфигурации WireGuard"
    local WG_CONFIG_FILE="/etc/wireguard/antizapret.conf"
    if [[ ! -f "$WG_CONFIG_FILE" ]]; then
        echo -e "${RED}Файл $WG_CONFIG_FILE не найден!${NC}"; exit 1
    fi
    mapfile -t clients < <(grep "# Client = " "$WG_CONFIG_FILE" | cut -d'=' -f2 | sed 's/^ //')
    mapfile -t private_keys < <(grep "# PrivateKey = " "$WG_CONFIG_FILE" | cut -d'=' -f2 | sed 's/^ //')
    if [[ ${#clients[@]} -eq 0 ]]; then
        echo -e "${RED}Клиенты не найдены!${NC}"; exit 1
    fi
    for i in "${!clients[@]}"; do
        echo "$((i+1)). ${clients[$i]}"
    done
    while true; do
        read -p "Выберите пользователя (1-${#clients[@]}): " user_choice
        if [[ $user_choice -ge 1 && $user_choice -le ${#clients[@]} ]]; then
            selected_user="${clients[$((user_choice-1))]}"
            PRIVATE_KEY="${private_keys[$((user_choice-1))]}"
            echo -e "${GREEN}Выбран: $selected_user${NC}"
            break
        else
            echo -e "${RED}Неверный выбор.${NC}"
        fi
    done
}

copy_and_edit_config() {
    step_msg "Создание и изменение конфигурации клиента"
    USER_DIR="/root/Keenetic/Client/$selected_user"
    mkdir -p "$USER_DIR" || { echo -e "${RED}Не удалось создать $USER_DIR${NC}"; exit 1; }
    SOURCE_DIR="/root/antizapret/client/amneziawg/antizapret"
    CONFIG_PATH=$(grep -l "$PRIVATE_KEY" "$SOURCE_DIR"/*.conf)
    [[ -z "$CONFIG_PATH" ]] && { echo -e "${RED}Конфиг не найден!${NC}"; exit 1; }
    FILENAME=$(basename "$CONFIG_PATH")
    NEW_FILENAME=$(echo "$FILENAME" | sed 's/antizapret-//; s/-am//')
    cp "$CONFIG_PATH" "$USER_DIR/$NEW_FILENAME" || { echo -e "${RED}Ошибка копирования${NC}"; exit 1; }
    NEW_CONFIG_FILE="$USER_DIR/$NEW_FILENAME"
    sed -i 's/\(Address *= *[^/]*\)\/32/\1\/24/' "$NEW_CONFIG_FILE"
    sed -i '4,13d' "$NEW_CONFIG_FILE"
    sed -i "/AllowedIPs/ s/$/,$DNS1\/32,$DNS2\/32/" "$NEW_CONFIG_FILE"
    echo -e "${GREEN}SHA256: $(sha256sum "$NEW_CONFIG_FILE" | cut -d ' ' -f1)${NC}"
}

create_routes_file() {
    step_msg "Создание маршрутов"
    ROUTES_SOURCE="/root/antizapret/result/keenetic-wireguard-routes.txt"
    ROUTES_DEST="$USER_DIR/${selected_user}_routes.txt"
    [[ ! -f "$ROUTES_SOURCE" ]] && { echo -e "${RED}Файл маршрутов не найден!${NC}"; exit 1; }
    cp "$ROUTES_SOURCE" "$ROUTES_DEST"
    sed -i "s/DNS_IP_1/$DNS1/g; s/DNS_IP_2/$DNS2/g" "$ROUTES_DEST"
    echo -e "${GREEN}Маршруты сохранены в $ROUTES_DEST${NC}"
}

send_files() {
    step_msg "Отправка файлов в Telegram"
    local TG_SCRIPT="/root/tgsender.sh"
    if [[ -f "$TG_SCRIPT" ]]; then
        OUT1=$("$TG_SCRIPT" "$NEW_CONFIG_FILE" 2>&1)
        [[ $? -ne 0 ]] && echo -e "${RED}Ошибка при отправке $NEW_CONFIG_FILE: $OUT1${NC}"
        OUT2=$("$TG_SCRIPT" "$ROUTES_DEST" 2>&1)
        [[ $? -ne 0 ]] && echo -e "${RED}Ошибка при отправке $ROUTES_DEST: $OUT2${NC}"
    else
        echo -e "${YELLOW}tgsender.sh не найден.${NC}"
        confirm_continue "Скачать и настроить автоматически?" || return
        wget -O "$TG_SCRIPT" https://raw.githubusercontent.com/mejorcorreo/tgsender/refs/heads/main/tgsender.sh || { echo -e "${RED}Ошибка загрузки!${NC}"; exit 1; }
        chmod +x "$TG_SCRIPT"
        read -p "YOUR_CHAT_ID: " chat_id
        read -p "YOUR_BOT_TOKEN: " bot_token
        sed -i "s/<YOUR_CHAT_ID>/$chat_id/g; s/<YOUR_BOT_TOKEN>/$bot_token/g" "$TG_SCRIPT"
        OUT1=$("$TG_SCRIPT" "$NEW_CONFIG_FILE" 2>&1)
        [[ $? -ne 0 ]] && echo -e "${RED}Ошибка при отправке $NEW_CONFIG_FILE: $OUT1${NC}"
        OUT2=$("$TG_SCRIPT" "$ROUTES_DEST" 2>&1)
        [[ $? -ne 0 ]] && echo -e "${RED}Ошибка при отправке $ROUTES_DEST: $OUT2${NC}"
    fi
}

echo -e "${CYAN}Добро пожаловать! Этот скрипт создаёт конфигурации для Keenetic.${NC}"
confirm_continue "Продолжить?"
choose_dns
select_user
copy_and_edit_config
create_routes_file
send_files
echo -e "${GREEN}[Готово] Работа завершена успешно!${NC}" 
