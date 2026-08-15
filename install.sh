#!/bin/sh

username="torrserver"
dirInstall="/opt/torrserver"
serviceName="torrserver"
scriptname=$(basename "$0")
architecture="arm64"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ---------------------------------------------------------
# Функции
# ---------------------------------------------------------

colorize() {
    color=$1
    text=$2

    case $color in
        red)
            printf "${RED}%s${NC}" "$text"
            ;;
        green)
            printf "${GREEN}%s${NC}" "$text"
            ;;
        yellow)
            printf "${YELLOW}%s${NC}" "$text"
            ;;
        *)
            printf "%s" "$text"
            ;;
    esac
}

isRoot() {
    [ "$(id -u)" -eq 0 ]
}

# ---------------------------------------------------------
# Пользователь
# ---------------------------------------------------------

addUser() {
    if isRoot; then
        [ "$username" = "root" ] && return 0

        if grep -q "^$username:" /etc/passwd; then
            echo " - Пользователь $username уже существует!"
            return 0
        else
            adduser -D -H -h "$dirInstall" -s /bin/false -G nogroup "$username"

            if [ $? -eq 0 ]; then
                chmod 755 "$dirInstall"
                echo " - Пользователь $username добавлен!"
            else
                echo " - Не удалось добавить пользователя $username!"
                return 1
            fi
        fi
    fi
}

delUser() {
    if isRoot; then
        [ "$username" = "root" ] && return 0

        if grep -q "^$username:" /etc/passwd; then
            deluser "$username" 2>/dev/null

            if [ $? -eq 0 ]; then
                echo " - Пользователь $username удален!"
            else
                echo " - Не удалось удалить пользователя $username!"
            fi
        else
            echo " - Пользователь $username не найден!"
        fi
    fi
}

# ---------------------------------------------------------
# Проверка процесса
# ---------------------------------------------------------

checkRunning() {
    pidof TorrServer-linux-arm64 2>/dev/null | head -n 1
}

# ---------------------------------------------------------
# Получение IP
# ---------------------------------------------------------

getIP() {
    iface=$(ip route | grep default | awk '{print $5}' | head -n 1)

    if [ -n "$iface" ]; then
        ip addr show dev "$iface" \
            | grep 'inet ' \
            | awk '{print $2}' \
            | cut -d/ -f1 \
            | head -n 1
    fi
}

# ---------------------------------------------------------
# Интернет
# ---------------------------------------------------------

checkInternet() {
    echo " Проверяем соединение с Интернетом..."

    if ! ping -c 2 google.com >/dev/null 2>&1; then
        echo " - Нет Интернета. Проверьте ваше соединение."
        exit 1
    fi

    echo " - соединение с Интернетом успешно"
}

# ---------------------------------------------------------
# Получение последней версии TorrServer
# ---------------------------------------------------------

getLatestRelease() {
    curl -fsSL \
        --connect-timeout 10 \
        --max-time 30 \
        https://api.github.com/repos/YouROK/TorrServer/releases/latest \
        | grep '"tag_name":' \
        | sed -E 's/.*"([^"]+)".*/\1/' \
        | head -n 1
}

# ---------------------------------------------------------
# Остановка TorrServer
# ---------------------------------------------------------

stopTorrServer() {
    echo " - Останавливаем TorrServer..."

    /etc/init.d/$serviceName stop 2>/dev/null

    # Ждём завершения процесса
    i=0

    while pidof TorrServer-linux-arm64 >/dev/null 2>&1 && [ $i -lt 10 ]; do
        sleep 1
        i=$((i + 1))
    done

    # Если процесс всё ещё работает
    if pidof TorrServer-linux-arm64 >/dev/null 2>&1; then
        echo " - Процесс не завершился. Принудительно останавливаем..."

        killall TorrServer-linux-arm64 2>/dev/null

        sleep 2
    fi

    # Финальная проверка
    if pidof TorrServer-linux-arm64 >/dev/null 2>&1; then
        echo " - Не удалось остановить TorrServer!"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------
# Скачивание TorrServer
# ---------------------------------------------------------

downloadTorrServer() {

    binName="TorrServer-linux-arm64"

    if [ ! -d "$dirInstall" ]; then
        mkdir -p "$dirInstall"
    fi

    echo " - Определяем последнюю версию TorrServer..."

    latestVersion=$(getLatestRelease)

    if [ -z "$latestVersion" ]; then
        echo " - Не удалось определить последнюю версию!"
        echo " - Проверьте доступ к GitHub."
        return 1
    fi

    echo " - Последняя версия: $latestVersion"

    urlBin="https://github.com/YouROK/TorrServer/releases/download/${latestVersion}/${binName}"

    tempFile="$dirInstall/${binName}.new"

    echo " - Загружаем TorrServer..."
    echo " - URL: $urlBin"

    rm -f "$tempFile"

    if ! curl -fL \
        --connect-timeout 15 \
        --max-time 600 \
        --retry 3 \
        --retry-delay 2 \
        -o "$tempFile" \
        "$urlBin"; then

        echo " - Ошибка загрузки TorrServer!"
        rm -f "$tempFile"

        return 1
    fi

    # Проверяем, что файл существует
    if [ ! -f "$tempFile" ]; then
        echo " - Загруженный файл не найден!"
        rm -f "$tempFile"

        return 1
    fi

    # Проверяем, что файл не пустой
    if [ ! -s "$tempFile" ]; then
        echo " - Загруженный файл пустой!"
        rm -f "$tempFile"

        return 1
    fi

    # Проверяем минимальный размер файла
    fileSize=$(wc -c < "$tempFile" 2>/dev/null)

    if [ "$fileSize" -lt 1000000 ]; then
        echo " - Ошибка: загруженный файл слишком маленький ($fileSize байт)!"
        echo " - Возможно, GitHub вернул ошибку вместо бинарника."

        rm -f "$tempFile"

        return 1
    fi

    chmod +x "$tempFile"

    # Проверяем ELF-файл
    if command -v file >/dev/null 2>&1; then
        fileInfo=$(file "$tempFile" 2>/dev/null)

        echo " - Тип файла: $fileInfo"

        echo "$fileInfo" | grep -qi "ELF" || {
            echo " - Ошибка: загруженный файл не является ELF-бинарником!"
            rm -f "$tempFile"
            return 1
        }
    fi

    # Только теперь заменяем старый бинарник
    mv -f "$tempFile" "$dirInstall/$binName"

    if [ $? -ne 0 ]; then
        echo " - Не удалось заменить старый TorrServer!"
        rm -f "$tempFile"

        return 1
    fi

    chmod +x "$dirInstall/$binName"

    echo " - TorrServer $latestVersion успешно установлен!"

    return 0
}

# ---------------------------------------------------------
# Обновление
# ---------------------------------------------------------

UpdateVersion() {

    if ! stopTorrServer; then
        echo " - Обновление отменено!"
        return 1
    fi

    if ! downloadTorrServer; then
        echo " - Обновление не выполнено!"
        echo " - Запускаем установленную версию..."

        /etc/init.d/$serviceName start

        return 1
    fi

    echo " - Запускаем TorrServer..."

    /etc/init.d/$serviceName start

    sleep 2

    if pidof TorrServer-linux-arm64 >/dev/null 2>&1; then
        echo " - TorrServer успешно запущен!"
        echo " - TorrServer обновлен!"
        return 0
    else
        echo " - ВНИМАНИЕ: TorrServer не запустился!"
        return 1
    fi
}

# ---------------------------------------------------------
# Удаление
# ---------------------------------------------------------

cleanup() {

    /etc/init.d/$serviceName stop 2>/dev/null
    /etc/init.d/$serviceName disable 2>/dev/null

    rm -f /etc/init.d/$serviceName 2>/dev/null

    rm -rf "$dirInstall" 2>/dev/null

    delUser
}

uninstall() {

    if ! checkInstalled; then
        echo " - TorrServer не установлен."
        return
    fi

    echo ""
    echo " Директория c TorrServer - ${dirInstall}"
    echo ""
    echo " Это действие удалит все данные TorrServer,"
    echo " включая базу данных торрентов и настройки!"
    echo ""

    read -p " Вы уверены что хотите удалить программу? ($(colorize red Y)es/$(colorize yellow N)o) " answer_del </dev/tty

    if [ "$answer_del" != "${answer_del#[YyДд]}" ]; then

        cleanup

        echo " - TorrServer удален из системы!"
        echo ""

    else
        echo " - Удаление отменено."
        echo ""
    fi
}

# ---------------------------------------------------------
# Справка
# ---------------------------------------------------------

helpUsage() {

    echo "$scriptname"
    echo ""
    echo "  -i | --install | install - установка последней версии"
    echo "  -u | --update  | update  - обновление до последней версии"
    echo "  -r | --remove  | remove  - удаление TorrServer"
    echo "  -h | --help    | help    - эта справка"
}

# ---------------------------------------------------------
# Проверка установки
# ---------------------------------------------------------

checkInstalled() {

    if [ -f "$dirInstall/TorrServer-linux-arm64" ]; then
        echo " - TorrServer найден в директории $dirInstall"
        return 0
    else
        echo " - TorrServer не найден"
        return 1
    fi
}

# ---------------------------------------------------------
# Установка
# ---------------------------------------------------------

installTorrServer() {

    echo " Устанавливаем и настраиваем TorrServer..."

    if [ -f "$dirInstall/TorrServer-linux-arm64" ]; then

        read -p " TorrServer уже установлен. Хотите обновить? ($(colorize green Y)es/$(colorize yellow N)o) " answer_up </dev/tty

        if [ "$answer_up" != "${answer_up#[YyДд]}" ]; then
            UpdateVersion
            return
        fi

    fi

    binName="TorrServer-linux-arm64"

    if [ ! -d "$dirInstall" ]; then
        mkdir -p "$dirInstall"
    fi

    # Установка новой версии
    if ! downloadTorrServer; then
        echo " - Установка TorrServer отменена!"
        exit 1
    fi

    addUser

    # -----------------------------------------------------
    # Порт
    # -----------------------------------------------------

    read -p " Хотите изменить порт для TorrServer (по умолчанию 8090)? ($(colorize yellow Y)es/$(colorize green N)o) " answer_cp </dev/tty

    if [ "$answer_cp" != "${answer_cp#[YyДд]}" ]; then

        read -p " Введите номер порта: " answer_port </dev/tty

        servicePort=$answer_port

    else

        servicePort="8090"

    fi

    # -----------------------------------------------------
    # Авторизация
    # -----------------------------------------------------

    read -p " Включить авторизацию на сервере? ($(colorize green Y)es/$(colorize yellow N)o) " answer_auth </dev/tty

    if [ "$answer_auth" != "${answer_auth#[YyДд]}" ]; then

        read -p " Пользователь: " answer_user </dev/tty
        isAuthUser=$answer_user

        read -p " Пароль: " answer_pass </dev/tty
        isAuthPass=$answer_pass

        echo " Сохраняем $isAuthUser:$isAuthPass в ${dirInstall}/accs.db"

        echo -e "{\n  \"$isAuthUser\": \"$isAuthPass\"\n}" > "$dirInstall/accs.db"

        authOptions="--port $servicePort --path $dirInstall --httpauth"

    else

        authOptions="--port $servicePort --path $dirInstall"

    fi

    # -----------------------------------------------------
    # OpenWrt init script
    # -----------------------------------------------------

    cat << EOF > /etc/init.d/$serviceName
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1

PROG="$dirInstall/TorrServer-linux-arm64"

start_service() {
    procd_open_instance

    procd_set_param command \$PROG $authOptions

    procd_set_param respawn

    procd_set_param stdout 1
    procd_set_param stderr 1

    procd_close_instance
}

stop_service() {
    killall TorrServer-linux-arm64 2>/dev/null
}

reload_service() {
    stop
    start
}
EOF

    chmod +x /etc/init.d/$serviceName

    /etc/init.d/$serviceName enable
    /etc/init.d/$serviceName start

    sleep 2

    serverIP=$(getIP)

    echo ""

    if pidof TorrServer-linux-arm64 >/dev/null 2>&1; then
        echo " TorrServer успешно запущен!"
    else
        echo " ВНИМАНИЕ: TorrServer не запустился!"
    fi

    echo ""

    echo " TorrServer установлен в директории ${dirInstall}"

    echo ""

    echo " Теперь вы можете открыть браузер по адресу:"
    echo " http://${serverIP}:${servicePort}"

    echo ""

    if [ -n "$isAuthUser" ]; then
        echo " Для авторизации используйте пользователя «$isAuthUser» с паролем «$isAuthPass»"
        echo ""
    fi
}

# ---------------------------------------------------------
# Первичная проверка
# ---------------------------------------------------------

initialCheck() {

    if ! isRoot; then
        echo " Вам нужно запустить скрипт от root."
        echo " Пример: sh $scriptname"
        exit 1
    fi

    checkInternet
}

# ---------------------------------------------------------
# Основной код
# ---------------------------------------------------------

case $1 in

    -i|--install|install)

        initialCheck

        installTorrServer

        exit
        ;;

    -u|--update|update)

        initialCheck

        if checkInstalled; then
            UpdateVersion
        fi

        exit
        ;;

    -r|--remove|remove)

        uninstall

        exit
        ;;

    -h|--help|help)

        helpUsage

        exit
        ;;

esac

# ---------------------------------------------------------
# Интерактивное меню
# ---------------------------------------------------------

while true; do

    echo ""
    echo "============================================================="
    echo " Скрипт установки TorrServer для OpenWrt/FriendlyWrt"
    echo "============================================================="
    echo ""
    echo " Введите $scriptname -h для вызова справки"
    echo ""

    read -p " Хотите установить или настроить TorrServer? ($(colorize green Y)es|$(colorize yellow N)o) Для удаления введите «$(colorize red D)elete» " ydn </dev/tty

    case $ydn in

        [YyДд]*)

            initialCheck

            installTorrServer

            break
            ;;

        [DdУу]*)

            uninstall

            break
            ;;

        [NnНн]*)

            break
            ;;

        *)

            echo " Введите $(colorize green Y)es, $(colorize yellow N)o или $(colorize red D)elete"
            ;;

    esac

done

echo ""
echo " Удачи!"
echo ""
