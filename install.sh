#!/bin/sh

username="torrserver"
dirInstall="/opt/torrserver"
serviceName="torrserver"
scriptname=$(basename "$0")
binName="TorrServer-linux-arm64"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ---------------------------------------------------------
# Вспомогательные функции
# ---------------------------------------------------------

colorize() {
    color="$1"
    text="$2"

    case "$color" in
        red)    printf "${RED}%s${NC}" "$text" ;;
        green)  printf "${GREEN}%s${NC}" "$text" ;;
        yellow) printf "${YELLOW}%s${NC}" "$text" ;;
        *)      printf "%s" "$text" ;;
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
    if isRoot && [ "$username" != "root" ]; then
        if grep -q "^$username:" /etc/passwd; then
            deluser "$username" 2>/dev/null
            echo " - Пользователь $username удален!"
        fi
    fi
}

# ---------------------------------------------------------
# Проверка установлен ли TorrServer
# ---------------------------------------------------------

checkInstalled() {
    if [ -f "$dirInstall/$binName" ]; then
        echo " - TorrServer найден в директории $dirInstall"
        return 0
    else
        echo " - TorrServer не найден"
        return 1
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
# Получение последней версии
# ---------------------------------------------------------

getLatestRelease() {
    curl -fsSL \
        --connect-timeout 15 \
        --max-time 30 \
        "https://api.github.com/repos/YouROK/TorrServer/releases/latest" \
        2>/dev/null |
        sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' |
        head -n 1
}

# ---------------------------------------------------------
# Остановка TorrServer
# ---------------------------------------------------------

stopTorrServer() {

    echo " - Останавливаем TorrServer..."

    /etc/init.d/$serviceName stop 2>/dev/null

    i=0

    while pidof "$binName" >/dev/null 2>&1 && [ "$i" -lt 10 ]; do
        sleep 1
        i=$((i + 1))
    done

    if pidof "$binName" >/dev/null 2>&1; then
        echo " - Принудительно завершаем процесс..."
        killall "$binName" 2>/dev/null
        sleep 2
    fi

    if pidof "$binName" >/dev/null 2>&1; then
        echo " - Не удалось остановить TorrServer!"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------
# Скачивание последней версии
# ---------------------------------------------------------

downloadTorrServer() {

    if [ ! -d "$dirInstall" ]; then
        mkdir -p "$dirInstall"
    fi

    echo " - Проверяем последнюю версию TorrServer..."

    latestVersion="$(getLatestRelease)"

    if [ -z "$latestVersion" ]; then
        echo " - Не удалось определить последнюю версию TorrServer!"
        return 1
    fi

    echo " - Последняя версия: $latestVersion"

    urlBin="https://github.com/YouROK/TorrServer/releases/download/${latestVersion}/${binName}"

    tempFile="$dirInstall/${binName}.new"

    echo " - Загружаем:"
    echo "   $urlBin"

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

    if [ ! -s "$tempFile" ]; then
        echo " - Загруженный файл пустой!"
        rm -f "$tempFile"
        return 1
    fi

    chmod +x "$tempFile"

    # Проверяем, что это действительно ARM64 ELF,
    # если утилита file присутствует.
    if command -v file >/dev/null 2>&1; then

        fileInfo="$(file "$tempFile" 2>/dev/null)"

        echo " - Тип файла: $fileInfo"

        echo "$fileInfo" | grep -qi "ELF" || {
            echo " - Загруженный файл не является ELF!"
            rm -f "$tempFile"
            return 1
        }
    fi

    # Только после успешной загрузки заменяем старый файл.
    mv -f "$tempFile" "$dirInstall/$binName"

    if [ $? -ne 0 ]; then
        echo " - Не удалось заменить бинарник!"
        rm -f "$tempFile"
        return 1
    fi

    chmod +x "$dirInstall/$binName"

    echo " - TorrServer $latestVersion установлен!"

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

        echo " - Обновление не удалось!"
        echo " - Запускаем предыдущую версию..."

        /etc/init.d/$serviceName start

        return 1
    fi

    echo " - Запускаем TorrServer..."

    /etc/init.d/$serviceName start

    sleep 2

    if pidof "$binName" >/dev/null 2>&1; then
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

    rm -f "/etc/init.d/$serviceName" 2>/dev/null
    rm -rf "$dirInstall" 2>/dev/null

    delUser
}

uninstall() {

    if ! checkInstalled; then
        return
    fi

    echo ""
    echo " Директория c TorrServer - ${dirInstall}"
    echo ""
    echo " Это действие удалит все данные TorrServer,"
    echo " включая базу данных торрентов и настройки!"
    echo ""

    read -p " Вы уверены что хотите удалить программу? ($(colorize red Y)es/$(colorize yellow N)o) " answer_del </dev/tty

    case "$answer_del" in
        [YyДд]*)
            cleanup
            echo " - TorrServer удален из системы!"
            ;;
        *)
            echo " - Удаление отменено."
            ;;
    esac
}

# ---------------------------------------------------------
# Создание init.d
# ---------------------------------------------------------

createService() {

    cat > "/etc/init.d/$serviceName" << EOF
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1

PROG="$dirInstall/$binName"

start_service() {
    procd_open_instance

    procd_set_param command \$PROG $authOptions

    procd_set_param respawn

    procd_set_param stdout 1
    procd_set_param stderr 1

    procd_close_instance
}

stop_service() {
    killall $binName 2>/dev/null
}

reload_service() {
    stop
    start
}
EOF

    chmod +x "/etc/init.d/$serviceName"
}

# ---------------------------------------------------------
# Установка
# ---------------------------------------------------------

installTorrServer() {

    echo " Устанавливаем и настраиваем TorrServer..."

    if [ -f "$dirInstall/$binName" ]; then

        read -p " TorrServer уже установлен. Хотите обновить? ($(colorize green Y)es/$(colorize yellow N)o) " answer_up </dev/tty

        case "$answer_up" in
            [YyДд]*)
                UpdateVersion
                return
                ;;
            *)
                echo " - Обновление отменено."
                return
                ;;
        esac
    fi

    mkdir -p "$dirInstall"

    if ! downloadTorrServer; then
        echo " - Установка отменена!"
        exit 1
    fi

    addUser

    # -----------------------------------------------------
    # Порт
    # -----------------------------------------------------

    read -p " Хотите изменить порт для TorrServer (по умолчанию 8090)? ($(colorize yellow Y)es/$(colorize green N)o) " answer_cp </dev/tty

    case "$answer_cp" in
        [YyДд]*)
            read -p " Введите номер порта: " answer_port </dev/tty
            servicePort="$answer_port"
            ;;
        *)
            servicePort="8090"
            ;;
    esac

    # -----------------------------------------------------
    # Авторизация
    # -----------------------------------------------------

    read -p " Включить авторизацию на сервере? ($(colorize green Y)es/$(colorize yellow N)o) " answer_auth </dev/tty

    case "$answer_auth" in
        [YyДд]*)

            read -p " Пользователь: " answer_user </dev/tty
            isAuthUser="$answer_user"

            read -p " Пароль: " answer_pass </dev/tty
            isAuthPass="$answer_pass"

            echo " Сохраняем $isAuthUser:$isAuthPass в ${dirInstall}/accs.db"

            printf '{\n  "%s": "%s"\n}\n' \
                "$isAuthUser" "$isAuthPass" > "$dirInstall/accs.db"

            authOptions="--port $servicePort --path $dirInstall --httpauth"
            ;;

        *)
            authOptions="--port $servicePort --path $dirInstall"
            ;;
    esac

    # -----------------------------------------------------
    # Сервис OpenWrt
    # -----------------------------------------------------

    createService

    /etc/init.d/$serviceName enable
    /etc/init.d/$serviceName start

    sleep 2

    serverIP="$(getIP)"

    echo ""

    if pidof "$binName" >/dev/null 2>&1; then
        echo " TorrServer успешно запущен!"
    else
        echo " ВНИМАНИЕ: TorrServer не запустился!"
    fi

    echo ""
    echo " TorrServer установлен в директории ${dirInstall}"
    echo ""
    echo " Теперь вы можете открыть:"
    echo " http://${serverIP}:${servicePort}"
    echo ""

    if [ -n "$isAuthUser" ]; then
        echo " Для авторизации используйте пользователя «$isAuthUser»"
        echo " Пароль: «$isAuthPass»"
        echo ""
    fi
}

# ---------------------------------------------------------
# Первичная проверка
# ---------------------------------------------------------

initialCheck() {

    if ! isRoot; then
        echo " Вам нужно запустить скрипт от root."
        exit 1
    fi

    checkInternet
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
# Аргументы
# ---------------------------------------------------------

case "$1" in

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
# Интерактивный режим
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

    case "$ydn" in

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
