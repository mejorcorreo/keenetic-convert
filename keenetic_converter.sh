#!/bin/bash

# Функция для вывода сообщения и ожидания подтверждения
confirm_continue() {
    read -p "$1 (y/n): " choice
    case "$choice" in
        y|Y ) return 0;;
        n|N ) echo "Скрипт завершен."; exit 1;;
        * ) echo "Неверный ввод. Пожалуйста, введите y или n."; confirm_continue "$1";;
    esac
}

# Шаг 1: Приветствие
echo "Добро пожаловать!"
echo "Этот скрипт предназначен для конвертирования файла конфигурации Antizapret под роутер Keenetic"
echo "и создания файла маршрутов для Keenetic."
confirm_continue "Хотите продолжить?" || exit 1

# Шаг 2: Выбор DNS серверов
declare -A dns_pairs=(
    [1]="77.88.8.8 8.8.8.8"
    [2]="8.8.8.8 1.1.1.1"
    [3]="1.1.1.1 9.9.9.10"
    [4]="9.9.9.10 8.8.8.8"
)

echo "Выберите пару DNS серверов:"
# Сортируем ключи численно и выводим в правильном порядке
for key in $(echo "${!dns_pairs[@]}" | tr ' ' '\n' | sort -n); do
    echo "$key. ${dns_pairs[$key]}"
done

while true; do
    read -p "Введите номер пары DNS (1-${#dns_pairs[@]}): " dns_choice
    if [[ -n "${dns_pairs[$dns_choice]}" ]]; then
        selected_dns=(${dns_pairs[$dns_choice]})
        DNS1=${selected_dns[0]}
        DNS2=${selected_dns[1]}
        echo "Выбраны DNS: $DNS1 и $DNS2"
        break
    else
        echo "Неверный выбор. Пожалуйста, введите число от 1 до ${#dns_pairs[@]}."
    fi
done

# Шаг 3: Выбор пользователя из конфигурации WireGuard
CONFIG_FILE="/etc/wireguard/antizapret.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Ошибка: файл конфигурации $CONFIG_FILE не найден!"
    exit 1
fi

# Извлекаем имена клиентов и приватные ключи
mapfile -t clients < <(grep "# Client = " "$CONFIG_FILE" | cut -d'=' -f2 | sed 's/^ //')
mapfile -t private_keys < <(grep "# PrivateKey = " "$CONFIG_FILE" | cut -d'=' -f2 | sed 's/^ //')

if [[ ${#clients[@]} -eq 0 ]]; then
    echo "В конфигурации не найдено ни одного клиента!"
    exit 1
fi

echo "Список доступных пользователей:"
for i in "${!clients[@]}"; do
    echo "$((i+1)). ${clients[$i]}"
done

while true; do
    read -p "Выберите пользователя (1-${#clients[@]}): " user_choice
    if [[ $user_choice -ge 1 && $user_choice -le ${#clients[@]} ]]; then
        selected_user="${clients[$((user_choice-1))]}"
        PRIVATE_KEY="${private_keys[$((user_choice-1))]}"
        echo "Выбран пользователь: $selected_user"
        break
    else
        echo "Неверный выбор. Пожалуйста, введите число от 1 до ${#clients[@]}."
    fi
done

# Шаг 4: Создание структуры папок
USER_DIR="/root/Keenetic/Client/$selected_user"
mkdir -p "$USER_DIR" || { echo "Не удалось создать директорию $USER_DIR"; exit 1; }

# Шаг 5: Поиск и копирование файла конфигурации
SOURCE_DIR="/root/antizapret/client/amneziawg/antizapret"
CONFIG_FILE_PATH=$(grep -l "$PRIVATE_KEY" "$SOURCE_DIR"/*.conf)
if [[ -z "$CONFIG_FILE_PATH" ]]; then
    echo "Не удалось найти файл конфигурации для выбранного пользователя!"
    exit 1
fi

CONFIG_FILENAME=$(basename "$CONFIG_FILE_PATH")
echo "Найден файл конфигурации: $CONFIG_FILENAME"
cp "$CONFIG_FILE_PATH" "$USER_DIR/" || { echo "Не удалось скопировать файл конфигурации"; exit 1; }

# Шаг 6: Переименование файла
NEW_CONFIG_NAME=$(echo "$CONFIG_FILENAME" | sed 's/antizapret-//; s/-am//')
mv "$USER_DIR/$CONFIG_FILENAME" "$USER_DIR/$NEW_CONFIG_NAME" || { echo "Не удалось переименовать файл"; exit 1; }

# Шаг 7: Изменение файла конфигурации
CONFIG_FILE="$USER_DIR/$NEW_CONFIG_NAME"

# Изменяем маску сети с /32 на /24 в третьей строке
sed -i '3s/\/32/\/24/' "$CONFIG_FILE"

# Удаляем строки с 4 по 13
sed -i '4,13d' "$CONFIG_FILE"

# Добавляем DNS серверы в AllowedIPs
sed -i "/AllowedIPs/ s/$/,${DNS1}\/32,${DNS2}\/32/" "$CONFIG_FILE"

echo "Файл конфигурации успешно изменен: $CONFIG_FILE"

# Шаг 8: Обработка файла маршрутов
ROUTES_SOURCE="/root/antizapret/result/keenetic-wireguard-routes.txt"
ROUTES_DEST="$USER_DIR/${selected_user}_routes.txt"

if [[ ! -f "$ROUTES_SOURCE" ]]; then
    echo "Ошибка: файл маршрутов $ROUTES_SOURCE не найден!"
    exit 1
fi

cp "$ROUTES_SOURCE" "$ROUTES_DEST" || { echo "Не удалось скопировать файл маршрутов"; exit 1; }

# Заменяем DNS_IP_1 и DNS_IP_2 на выбранные DNS
sed -i "s/DNS_IP_1/$DNS1/g; s/DNS_IP_2/$DNS2/g" "$ROUTES_DEST"

echo "Файл маршрутов успешно создан: $ROUTES_DEST"

# Шаг 9: Отправка файлов через tgsender.sh
if [[ -f "/root/tgsender.sh" ]]; then
    echo "Отправка файлов через Telegram..."
    /root/tgsender.sh "$CONFIG_FILE"
    /root/tgsender.sh "$ROUTES_DEST"
    echo "Файлы отправлены."
else
    echo "Скрипт tgsender.sh не найден."
    confirm_continue "Хотите скачать и настроить tgsender.sh автоматически?" || exit 0
    
    # Скачиваем tgsender.sh
    echo "Скачиваем tgsender.sh..."
    if ! wget -O /root/tgsender.sh https://raw.githubusercontent.com/mejorcorreo/tgsender/refs/heads/main/tgsender.sh; then
        echo "Ошибка при скачивании tgsender.sh!"
        exit 1
    fi
    
    # Делаем скрипт исполняемым
    chmod +x /root/tgsender.sh
    
    # Запрашиваем данные для настройки
    echo "Введите данные для настройки Telegram бота:"
    read -p "YOUR_CHAT_ID: " chat_id
    read -p "YOUR_BOT_TOKEN: " bot_token
    
    # Заменяем значения в скрипте
    sed -i "s/<YOUR_CHAT_ID>/$chat_id/g; s/<YOUR_BOT_TOKEN>/$bot_token/g" /root/tgsender.sh
    
    # Пытаемся отправить файлы
    echo "Пробуем отправить файлы..."
    if /root/tgsender.sh "$CONFIG_FILE" && /root/tgsender.sh "$ROUTES_DEST"; then
        echo "Файлы успешно отправлены!"
    else
        echo "Возникла ошибка при отправке файлов. Проверьте введённые данные."
    fi
fi

echo "Скрипт успешно завершил работу!"