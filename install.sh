#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

#consts for log check and clear,unit:M
declare -r DEFAULT_LOG_FILE_DELETE_TRIGGER=35

# consts for geo update
PATH_FOR_GEO_IP='/usr/local/x-ui/bin/geoip.dat'
PATH_FOR_CONFIG='/usr/local/x-ui/bin/config.json'
PATH_FOR_GEO_SITE='/usr/local/x-ui/bin/geosite.dat'
URL_FOR_GEO_IP='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat'
URL_FOR_GEO_SITE='https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat'

#Add some basic function here
function LOGD() {
    echo -e "${yellow}[DEG] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[ERR] $* ${plain}"
}

function LOGI() {
    echo -e "${green}[INF] $* ${plain}"
}
# check root
[[ $EUID -ne 0 ]] && LOGE "错误:  必须使用root用户运行此脚本!\n" && exit 1

# check os (Armbian 优先识别为 Debian 兼容)
if [[ -f /etc/armbian-release ]] || grep -Eqi "armbian" /etc/issue 2>/dev/null || grep -Eqi "armbian" /proc/version 2>/dev/null || { [[ -f /etc/os-release ]] && . /etc/os-release && { [[ "${ID}" == "armbian" ]] || [[ "${NAME}" == *Armbian* ]] || [[ "${PRETTY_NAME}" == *Armbian* ]]; }; }; then
    release="debian"
    os_version=99
elif [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
elif [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID_LIKE}" == *"debian"* ]] || [[ "${ID}" == "debian" ]]; then
        release="debian"
    elif [[ "${ID}" == "ubuntu" ]]; then
        release="ubuntu"
    elif [[ "${ID}" == "centos" ]] || [[ "${ID}" == "rhel" ]] || [[ "${ID}" == "rocky" ]] || [[ "${ID}" == "almalinux" ]]; then
        release="centos"
    else
        LOGE "未检测到系统版本，请联系脚本作者！\n" && exit 1
    fi
else
    LOGE "未检测到系统版本，请联系脚本作者！\n" && exit 1
fi

os_version=""

# os version (Armbian 直接视为满足版本要求)
if [[ "${release}" == "debian" ]] && { [[ -f /etc/armbian-release ]] || grep -Eqi "armbian" /etc/issue 2>/dev/null || grep -Eqi "armbian" /proc/version 2>/dev/null; }; then
    os_version=99
else
    if [[ -f /etc/os-release ]]; then
        os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
    fi
    if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
        os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
    fi
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        LOGE "请使用 CentOS 7 或更高版本的系统！\n" && exit 1
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        LOGE "请使用 Ubuntu 16 或更高版本的系统！\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ -n "${os_version}" ]] && [[ ${os_version} -lt 8 ]]; then
        LOGE "请使用 Debian 8 或更高版本的系统！\n" && exit 1
    fi
fi

# ----- CPU 架构识别 -----
# Armbian / 树莓派 / 电视盒子常见 aarch64 / armv7l / armv8l。
# 注意 armv8l 表示 64 位 SoC 跑 32 位用户态，必须按用户态位数区分，
# 否则会静默回退成 amd64，安装后直接 Exec format error。
if ! command -v uname >/dev/null 2>&1; then
    LOGE "未找到 uname 命令，无法确定 CPU 架构！\n" && exit 1
fi
case "$(uname -m)" in
    x86_64 | amd64 | x64)                 arch="amd64" ;;
    aarch64 | arm64)                      arch="arm64" ;;
    armv7l | armv7 | armhf | arm)         arch="armv7" ;;
    armv8l)
        if [[ "$(getconf LONG_BIT 2>/dev/null)" == "64" ]]; then
            arch="arm64"
        else
            arch="armv7"
        fi ;;
    s390x)                                arch="s390x" ;;
    *) LOGE "不支持的 CPU 架构: $(uname -m)，请自行编译 x-ui！\n" && exit 1 ;;
esac
# xray 二进制名：源码 xray/process.go 用 runtime.GOARCH，armv7 对应 bin/xray-linux-arm
case "${arch}" in
    armv7) xray_arch="arm" ;;
    *)     xray_arch="${arch}" ;;
esac
LOGI "检测到系统: ${release:-unknown} / 架构: ${arch} / xray: ${xray_arch}"

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -p "$1 [默认$2]: " temp
        if [[ x"${temp}" == x"" ]]; then
            temp=$2
        fi
    else
        read -p "$1 [y/n]: " temp
    fi
    if [[ x"${temp}" == x"y" || x"${temp}" == x"Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "是否重启面板，重启面板也会重启 xray" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车返回主菜单: ${plain}" && read temp
    show_menu
}

# 下载源：fork 若自行发布 release，改这里即可（默认沿用上游预编译包，含 arm64）
XUI_REPO="${XUI_REPO:-FranzKafkaYu/x-ui}"
# armv7 上游无预编译包时，可把自行编译好的包路径传给本变量跳过下载
XUI_LOCAL_TARBALL="${XUI_LOCAL_TARBALL:-}"

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install -y wget curl tar jq cronie
    else
        # Armbian 最小镜像 apt 列表常为空，先 update
        apt-get update -y
        apt-get install -y -q wget curl tar jq cron
    fi
}

# 安装后强制改端口/账户（上游同名逻辑，本仓库之前委托上游故缺失）
config_after_install() {
    echo -e "${yellow}出于安全考虑，安装/更新完成后需要强制修改端口与账户密码${plain}"
    read -p "确认是否继续,如选择n则跳过本次端口与账户密码设定[y/n]:" config_confirm
    if [[ x"${config_confirm}" == x"y" || x"${config_confirm}" == x"Y" ]]; then
        read -p "请设置您的账户名:" config_account
        echo -e "${yellow}您的账户名将设定为:${config_account}${plain}"
        read -p "请设置您的账户密码:" config_password
        echo -e "${yellow}您的账户密码将设定为:${config_password}${plain}"
        read -p "请设置面板访问端口:" config_port
        echo -e "${yellow}您的面板端口将设定为:${config_port}${plain}"
        /usr/local/x-ui/x-ui setting -username ${config_account} -password ${config_password}
        /usr/local/x-ui/x-ui setting -port ${config_port}
        echo -e "${green}账户密码与端口设定完成${plain}"
    else
        echo -e "${red}已取消设定...${plain}"
        if [[ ! -f "/etc/x-ui/x-ui.db" ]]; then
            local usernameTemp=$(head -c 6 /dev/urandom | base64)
            local passwordTemp=$(head -c 6 /dev/urandom | base64)
            local portTemp=$(echo $RANDOM)
            /usr/local/x-ui/x-ui setting -username ${usernameTemp} -password ${passwordTemp}
            /usr/local/x-ui/x-ui setting -port ${portTemp}
            echo -e "检测到您属于全新安装,出于安全考虑已自动为您生成随机用户与端口:"
            echo -e "###############################################"
            echo -e "${green}面板登录用户名:${usernameTemp}${plain}"
            echo -e "${green}面板登录用户密码:${passwordTemp}${plain}"
            echo -e "${red}面板登录端口:${portTemp}${plain}"
            echo -e "###############################################"
            echo -e "${red}如您遗忘了面板登录相关信息,可在安装完成后输入x-ui,输入选项7查看面板登录信息${plain}"
        else
            echo -e "${red}当前属于版本升级,保留之前设置项,登录方式保持不变${plain}"
        fi
    fi
}

# armv7 从源码编译（GOARCH=arm GOARM=7），并补 xray-linux-arm
build_x-ui_from_source() {
    cd /usr/local/ || exit 1
    if [[ ! -d x-ui-src ]]; then
        git clone --depth 1 "https://github.com/${XUI_REPO}.git" x-ui-src || return 1
    fi
    cd x-ui-src || return 1
    GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -o x-ui . || return 1
    # xray-core 官方 arm32-v7a 包
    local xv=$(curl -Lsk "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    wget -N --no-check-certificate -O /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${xv}/Xray-linux-arm32-v7a.zip" || return 1
    command -v unzip >/dev/null 2>&1 && unzip -o /tmp/xray.zip -d /tmp/xray-arm >/dev/null || return 1
    mkdir -p bin
    cp -f /tmp/xray-arm/xray bin/xray-linux-arm
    chmod +x x-ui bin/xray-linux-arm
    tar czf /usr/local/x-ui-linux-armv7.tar.gz x-ui bin
    return 0
}

install_x-ui() {
    systemctl stop x-ui 2>/dev/null
    cd /usr/local/ || exit 1

    if [[ "${arch}" == "armv7" ]] && [[ -z "${XUI_LOCAL_TARBALL}" ]]; then
        if command -v go >/dev/null 2>&1; then
            LOGI "检测到 armv7，本机已有 go，开始从源码编译 ..."
            build_x-ui_from_source || { LOGE "源码编译失败，请检查 go 环境与网络。"; exit 1; }
        else
            LOGE "上游未提供 armv7 预编译包，且本机没有 go 环境，无法自动安装。\n"
            LOGE "请自行编译后打包为 x-ui-linux-armv7.tar.gz，再执行：\n"
            LOGE "  XUI_LOCAL_TARBALL=/path/to/x-ui-linux-armv7.tar.gz bash <(curl ...) \n"
            LOGE "或改用 arm64 系统镜像（推荐）。\n"
            exit 1
        fi
    fi

    if [[ -n "${XUI_LOCAL_TARBALL}" ]]; then
        last_version="local"
        cp -f "${XUI_LOCAL_TARBALL}" /usr/local/x-ui-linux-${arch}.tar.gz
        LOGI "使用本地安装包: ${XUI_LOCAL_TARBALL}"
    elif [ $# == 0 ]; then
        last_version=$(curl -Lsk "https://api.github.com/repos/${XUI_REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ -z "$last_version" ]]; then
            LOGE "检测 x-ui 版本失败，可能是超出 Github API 限制，请稍后再试或手动指定版本安装。"
            exit 1
        fi
        LOGI "检测到 x-ui 最新版本：${last_version}，开始安装"
        wget -N --no-check-certificate -O /usr/local/x-ui-linux-${arch}.tar.gz "https://github.com/${XUI_REPO}/releases/download/${last_version}/x-ui-linux-${arch}.tar.gz"
    else
        last_version=$1
        wget -N --no-check-certificate -O /usr/local/x-ui-linux-${arch}.tar.gz "https://github.com/${XUI_REPO}/releases/download/${last_version}/x-ui-linux-${arch}.tar.gz"
    fi
    if [[ $? -ne 0 ]]; then
        LOGE "下载 x-ui 失败，请确认机器可访问 Github；armv7 请改用 XUI_LOCAL_TARBALL 或 arm64 镜像。"
        exit 1
    fi

    rm -rf /usr/local/x-ui/
    tar zxvf x-ui-linux-${arch}.tar.gz
    rm -f x-ui-linux-${arch}.tar.gz
    cd x-ui || exit 1
    chmod +x x-ui bin/xray-linux-${xray_arch}
    cp -f x-ui.service /etc/systemd/system/
    wget --no-check-certificate -O /usr/bin/x-ui https://raw.githubusercontent.com/FranzKafkaYu/x-ui/main/x-ui.sh
    chmod +x /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
    config_after_install
    systemctl daemon-reload
    systemctl enable x-ui
    systemctl start x-ui
    LOGI "x-ui v${last_version} 安装完成，面板已启动。"
    echo -e "----------------------------------------------"
    echo -e "x-ui start|stop|restart|status|enable|disable|log|update|install|uninstall|geo"
    echo -e "----------------------------------------------"
}

install() {
    install_base
    install_x-ui $1
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    confirm "本功能会强制重装当前最新版，数据不会丢失，是否继续?" "n"
    if [[ $? != 0 ]]; then
        LOGE "已取消"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    install_base
    install_x-ui $1
    if [[ $? == 0 ]]; then
        LOGI "更新完成，已自动重启面板 "
        exit 0
    fi
}

uninstall() {
    confirm "确定要卸载面板吗,xray 也会卸载?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    systemctl stop x-ui
    systemctl disable x-ui
    rm /etc/systemd/system/x-ui.service -f
    systemctl daemon-reload
    systemctl reset-failed
    rm /etc/x-ui/ -rf
    rm /usr/local/x-ui/ -rf

    echo ""
    echo -e "卸载成功，如果你想删除此脚本，则退出脚本后运行 ${green}rm /usr/bin/x-ui -f${plain} 进行删除"
    echo ""

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

reset_user() {
    confirm "确定要将用户名和密码重置为 admin 吗" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    /usr/local/x-ui/x-ui setting -username admin -password admin
    echo -e "用户名和密码已重置为 ${green}admin${plain}，现在请重启面板"
    confirm_restart
}

reset_config() {
    confirm "确定要重置所有面板设置吗，账号数据不会丢失，用户名和密码不会改变" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    /usr/local/x-ui/x-ui setting -reset
    echo -e "所有面板设置已重置为默认值，现在请重启面板，并使用默认的 ${green}54321${plain} 端口访问面板"
    confirm_restart
}

check_config() {
    info=$(/usr/local/x-ui/x-ui setting -show true)
    if [[ $? != 0 ]]; then
        LOGE "get current settings error,please check logs"
        show_menu
    fi
    LOGI "${info}"
}

set_port() {
    echo && echo -n -e "输入端口号[1-65535]: " && read port
    if [[ -z "${port}" ]]; then
        LOGD "已取消"
        before_show_menu
    else
        /usr/local/x-ui/x-ui setting -port ${port}
        echo -e "设置端口完毕，现在请重启面板，并使用新设置的端口 ${green}${port}${plain} 访问面板"
        confirm_restart
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        LOGI "面板已运行，无需再次启动，如需重启请选择重启"
    else
        systemctl start x-ui
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            LOGI "x-ui 启动成功"
        else
            LOGE "面板启动失败，可能是因为启动时间超过了两秒，请稍后查看日志信息"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    check_status
    if [[ $? == 1 ]]; then
        echo ""
        LOGI "面板已停止，无需再次停止"
    else
        systemctl stop x-ui
        sleep 2
        check_status
        if [[ $? == 1 ]]; then
            LOGI "x-ui 与 xray 停止成功"
        else
            LOGE "面板停止失败，可能是因为停止时间超过了两秒，请稍后查看日志信息"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    systemctl restart x-ui
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        LOGI "x-ui 与 xray 重启成功"
    else
        LOGE "面板重启失败，可能是因为启动时间超过了两秒，请稍后查看日志信息"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    systemctl status x-ui -l
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    systemctl enable x-ui
    if [[ $? == 0 ]]; then
        LOGI "x-ui 设置开机自启成功"
    else
        LOGE "x-ui 设置开机自启失败"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    systemctl disable x-ui
    if [[ $? == 0 ]]; then
        LOGI "x-ui 取消开机自启成功"
    else
        LOGE "x-ui 取消开机自启失败"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    journalctl -u x-ui.service -e --no-pager -f
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

migrate_v2_ui() {
    /usr/local/x-ui/x-ui v2-ui

    before_show_menu
}

install_bbr() {
    # Armbian 使用定制内核 + u-boot 引导，换通用内核极易变砖，改为仅写 sysctl 开启 BBR
    if [[ "${release}" == "debian" ]] && grep -Eqi "armbian" /etc/issue /etc/os-release /proc/version 2>/dev/null; then
        LOGE "检测到 Armbian：跳过换内核操作（会破坏 u-boot 引导）。\n"
        LOGE "如当前内核已支持 BBR，可直接写 sysctl 开启；否则请用 armbian-config 升级内核。\n"
        local m=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
        if [[ "${m}" == "bbr" ]]; then
            LOGI "当前内核已启用 BBR。"
        else
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p
            LOGI "已写入 sysctl，若未生效说明内核不支持，请用 armbian-config 升级内核后重试。"
        fi
        echo ""
        before_show_menu
        return 0
    fi
    # temporary workaround for installing bbr
    bash <(curl -L -s https://raw.githubusercontent.com/teddysun/across/master/bbr.sh)
    echo ""
    before_show_menu
}

update_shell() {
    wget -O /usr/bin/x-ui -N --no-check-certificate https://github.com/FranzKafkaYu/x-ui/raw/master/x-ui.sh
    if [[ $? != 0 ]]; then
        echo ""
        LOGE "下载脚本失败，请检查本机能否连接 Github"
        before_show_menu
    else
        chmod +x /usr/bin/x-ui
        LOGI "升级脚本成功，请重新运行脚本" && exit 0
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /etc/systemd/system/x-ui.service ]]; then
        return 2
    fi
    temp=$(systemctl status x-ui | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
    if [[ x"${temp}" == x"running" ]]; then
        return 0
    else
        return 1
    fi
}

check_enabled() {
    temp=$(systemctl is-enabled x-ui)
    if [[ x"${temp}" == x"enabled" ]]; then
        return 0
    else
        return 1
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        LOGE "面板已安装，请不要重复安装"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        LOGE "请先安装面板"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
    0)
        echo -e "面板状态: ${green}已运行${plain}"
        show_enable_status
        ;;
    1)
        echo -e "面板状态: ${yellow}未运行${plain}"
        show_enable_status
        ;;
    2)
        echo -e "面板状态: ${red}未安装${plain}"
        ;;
    esac
    show_xray_status
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "是否开机自启: ${green}是${plain}"
    else
        echo -e "是否开机自启: ${red}否${plain}"
    fi
}

check_xray_status() {
    count=$(ps -ef | grep "xray-linux" | grep -v "grep" | wc -l)
    if [[ count -ne 0 ]]; then
        return 0
    else
        return 1
    fi
}

show_xray_status() {
    check_xray_status
    if [[ $? == 0 ]]; then
        echo -e "xray 状态: ${green}运行${plain}"
    else
        echo -e "xray 状态: ${red}未运行${plain}"
    fi
}

#this will be an entrance for ssl cert issue
#here we can provide two different methods to issue cert
#first.standalone mode second.DNS API mode
ssl_cert_issue() {
    local method=""
    echo -E ""
    LOGD "******使用说明******"
    LOGI "该脚本提供两种方式实现证书签发,证书安装路径均为/root/cert"
    LOGI "方式1:acme standalone mode,需要保持端口开放"
    LOGI "方式2:acme DNS API mode,需要提供Cloudflare Global API Key"
    LOGI "如域名属于免费域名,则推荐使用方式1进行申请"
    LOGI "如域名非免费域名且使用Cloudflare进行解析使用方式2进行申请"
    read -p "请选择你想使用的方式,输入数字1或者2后回车": method
    LOGI "你所使用的方式为${method}"

    if [ "${method}" == "1" ]; then
        ssl_cert_issue_standalone
    elif [ "${method}" == "2" ]; then
        ssl_cert_issue_by_cloudflare
    else
        LOGE "输入无效,请检查你的输入,脚本将退出..."
        exit 1
    fi
}

install_acme() {
    cd ~
    LOGI "开始安装acme脚本..."
    curl https://get.acme.sh | sh
    if [ $? -ne 0 ]; then
        LOGE "acme安装失败"
        return 1
    else
        LOGI "acme安装成功"
    fi
    return 0
}

#method for standalone mode
ssl_cert_issue_standalone() {
    #check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "安装 acme 失败，请检查日志"
            exit 1
        fi
    fi
    #install socat second
    if [[ x"${release}" == x"centos" ]]; then
        yum install socat -y
    else
        apt install socat -y
    fi
    if [ $? -ne 0 ]; then
        LOGE "无法安装socat,请检查错误日志"
        exit 1
    else
        LOGI "socat安装成功..."
    fi
    #creat a directory for install cert
    certPath=/root/cert
    if [ ! -d "$certPath" ]; then
        mkdir $certPath
    fi
    #get the domain here,and we need verify it
    local domain=""
    read -p "请输入你的域名:" domain
    LOGD "你输入的域名为:${domain},正在进行域名合法性校验..."
    #here we need to judge whether there exists cert already
    local currentCert=$(~/.acme.sh/acme.sh --list | grep ${domain} | wc -l)
    if [ ${currentCert} -ne 0 ]; then
        local certInfo=$(~/.acme.sh/acme.sh --list)
        LOGE "域名合法性校验失败,当前环境已有对应域名证书,不可重复申请,当前证书详情:"
        LOGI "$certInfo"
        exit 1
    else
        LOGI "域名合法性校验通过..."
    fi
    #get needed port here
    local WebPort=80
    read -p "请输入你所希望使用的端口,如回车将使用默认80端口:" WebPort
    if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        LOGE "你所选择的端口${WebPort}为无效值,将使用默认80端口进行申请"
    fi
    LOGI "将会使用${WebPort}进行证书申请,请确保端口处于开放状态..."
    #NOTE:This should be handled by user
    #open the port and kill the occupied progress
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d ${domain} --standalone --httpport ${WebPort}
    if [ $? -ne 0 ]; then
        LOGE "证书申请失败,原因请参见报错信息"
        rm -rf ~/.acme.sh/${domain}
        exit 1
    else
        LOGI "证书申请成功,开始安装证书..."
    fi
    #install cert
    ~/.acme.sh/acme.sh --installcert -d ${domain} --ca-file /root/cert/ca.cer \
        --cert-file /root/cert/${domain}.cer --key-file /root/cert/${domain}.key \
        --fullchain-file /root/cert/fullchain.cer

    if [ $? -ne 0 ]; then
        LOGE "证书安装失败,脚本退出"
        rm -rf ~/.acme.sh/${domain}
        exit 1
    else
        LOGI "证书安装成功,开启自动更新..."
    fi
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        LOGE "自动更新设置失败,脚本退出"
        ls -lah cert
        chmod 755 $certPath
        exit 1
    else
        LOGI "证书已安装且已开启自动更新,具体信息如下"
        ls -lah cert
        chmod 755 $certPath
    fi

}

#method for DNS API mode
ssl_cert_issue_by_cloudflare() {
    echo -E ""
    LOGD "******使用说明******"
    LOGI "该脚本将使用Acme脚本申请证书,使用时需保证:"
    LOGI "1.知晓Cloudflare 注册邮箱"
    LOGI "2.知晓Cloudflare Global API Key"
    LOGI "3.域名已通过Cloudflare进行解析到当前服务器"
    LOGI "4.该脚本申请证书默认安装路径为/root/cert目录"
    confirm "我已确认以上内容[y/n]" "y"
    if [ $? -eq 0 ]; then
        install_acme
        if [ $? -ne 0 ]; then
            LOGE "无法安装acme,请检查错误日志"
            exit 1
        fi
        CF_Domain=""
        CF_GlobalKey=""
        CF_AccountEmail=""
        certPath=/root/cert
        if [ ! -d "$certPath" ]; then
            mkdir $certPath
        fi
        LOGD "请设置域名:"
        read -p "Input your domain here:" CF_Domain
        LOGD "你的域名设置为:${CF_Domain},正在进行域名合法性校验..."
        #here we need to judge whether there exists cert already
        local currentCert=$(~/.acme.sh/acme.sh --list | grep ${CF_Domain} | wc -l)
        if [ ${currentCert} -ne 0 ]; then
            local certInfo=$(~/.acme.sh/acme.sh --list)
            LOGE "域名合法性校验失败,当前环境已有对应域名证书,不可重复申请,当前证书详情:"
            LOGI "$certInfo"
            exit 1
        else
            LOGI "域名合法性校验通过..."
        fi
        LOGD "请设置API密钥:"
        read -p "Input your key here:" CF_GlobalKey
        LOGD "你的API密钥为:${CF_GlobalKey}"
        LOGD "请设置注册邮箱:"
        read -p "Input your email here:" CF_AccountEmail
        LOGD "你的注册邮箱为:${CF_AccountEmail}"
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        if [ $? -ne 0 ]; then
            LOGE "修改默认CA为Lets'Encrypt失败,脚本退出"
            exit 1
        fi
        export CF_Key="${CF_GlobalKey}"
        export CF_Email=${CF_AccountEmail}
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${CF_Domain} -d *.${CF_Domain} --log
        if [ $? -ne 0 ]; then
            LOGE "证书签发失败,脚本退出"
            rm -rf ~/.acme.sh/${CF_Domain}
            exit 1
        else
            LOGI "证书签发成功,安装中..."
        fi
        ~/.acme.sh/acme.sh --installcert -d ${CF_Domain} -d *.${CF_Domain} --ca-file /root/cert/ca.cer \
            --cert-file /root/cert/${CF_Domain}.cer --key-file /root/cert/${CF_Domain}.key \
            --fullchain-file /root/cert/fullchain.cer
        if [ $? -ne 0 ]; then
            LOGE "证书安装失败,脚本退出"
            rm -rf ~/.acme.sh/${CF_Domain}
            exit 1
        else
            LOGI "证书安装成功,开启自动更新..."
        fi
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        if [ $? -ne 0 ]; then
            LOGE "自动更新设置失败,脚本退出"
            ls -lah cert
            chmod 755 $certPath
            exit 1
        else
            LOGI "证书已安装且已开启自动更新,具体信息如下"
            ls -lah cert
            chmod 755 $certPath
        fi
    else
        show_menu
    fi
}

#add for cron jobs,including sync geo data,check logs and restart x-ui
cron_jobs() {
    clear
    echo -e "
  ${green}定时任务管理${plain}
  ${green}0.${plain}  返回主菜单
  ${green}1.${plain}  开启定时更新geo
  ${green}2.${plain}  关闭定时更新geo
  ${green}3.${plain}  开启定时删除xray日志
  ${green}4.${plain}  关闭定时删除xray日志
  "
    echo && read -p "请输入选择 [0-4]: " num
    case "${num}" in
    0)
        show_menu
        ;;
    1)
        enable_auto_update_geo
        ;;
    2)
        disable_auto_update_geo
        ;;
    3)
        enable_auto_clear_log
        ;;
    4)
        disable_auto_clear_log
        ;;
    *)
        LOGE "请输入正确的数字 [0-4]"
        ;;
    esac
}

#update geo data
update_geo() {
    #back up first
    mv ${PATH_FOR_GEO_IP} ${PATH_FOR_GEO_IP}.bak
    #update data
    curl -s -L -o ${PATH_FOR_GEO_IP} ${URL_FOR_GEO_IP}
    if [[ $? -ne 0 ]]; then
        echo "update geoip.dat failed"
        mv ${PATH_FOR_GEO_IP}.bak ${PATH_FOR_GEO_IP}
    else
        echo "update geoip.dat succeed"
        rm -f ${PATH_FOR_GEO_IP}.bak
    fi
    mv ${PATH_FOR_GEO_SITE} ${PATH_FOR_GEO_SITE}.bak
    curl -s -L -o ${PATH_FOR_GEO_SITE} ${URL_FOR_GEO_SITE}
    if [[ $? -ne 0 ]]; then
        echo "update geosite.dat failed"
        mv ${PATH_FOR_GEO_SITE}.bak ${PATH_FOR_GEO_SITE}
    else
        echo "update geosite.dat succeed"
        rm -f ${PATH_FOR_GEO_SITE}.bak
    fi
    #restart x-ui
    systemctl restart x-ui
}

enable_auto_update_geo() {
    LOGI "正在开启自动更新geo数据..."
    crontab -l >/tmp/crontabTask.tmp
    echo "00 4 */2 * * x-ui geo > /dev/null" >>/tmp/crontabTask.tmp
    crontab /tmp/crontabTask.tmp
    rm /tmp/crontabTask.tmp
    LOGI "开启自动更新geo数据成功"
}

disable_auto_update_geo() {
    crontab -l | grep -v "x-ui geo" | crontab -
    if [[ $? -ne 0 ]]; then
        LOGI "取消x-ui 自动更新geo数据失败"
    else
        LOGI "取消x-ui 自动更新geo数据成功"
    fi
}

#clear xray log,need enable log in config template
#here we need input an absolute path for log
clear_log() {
    LOGI "清除xray日志中..."
    local filePath=''
    if [[ $# -gt 0 ]]; then
        filePath=$1
    else
        LOGE "未输入有效文件路径,脚本退出"
        exit 1
    fi
    LOGI "日志路径为:${filePath}"
    if [[ ! -f ${filePath} ]]; then
        LOGE "清除xray日志文件失败,${filePath}不存在,请确认"
        exit 1
    fi
    fileSize=$(ls -la ${filePath} --block-size=M | awk '{print $5}' | awk -F 'M' '{print$1}')
    if [[ ${fileSize} -gt ${DEFAULT_LOG_FILE_DELETE_TRIGGER} ]]; then
        rm $1
        if [[ $? -ne 0 ]]; then
            LOGE "清除xray日志文件:${filePath}失败"
        else
            LOGI "清除xray日志文件:${filePath}成功"
            systemctl restart x-ui
        fi
    else
        LOGI "当前日志大小为${fileSize}M,小于${DEFAULT_LOG_FILE_DELETE_TRIGGER}M,将不会清除"
    fi
}

#enable auto delete log，need file path as
enable_auto_clear_log() {
    LOGI "设置定时清除xray日志..."
    local accessfilePath=''
    local errorfilePath=''
    accessfilePath=$(cat ${PATH_FOR_CONFIG} | jq .log.access | tr -d '"')
    errorfilePath=$(cat ${PATH_FOR_CONFIG} | jq .log.error | tr -d '"')
    if [[ ! -n ${accessfilePath} && ! -n ${errorfilePath} ]]; then
        LOGI "配置文件中的日志文件路径无效,脚本退出"
        exit 1
    fi
    if [[ -f ${accessfilePath} ]]; then
        crontab -l >/tmp/crontabTask.tmp
        echo "30 4 */2 * * x-ui clear ${accessfilePath} > /dev/null" >>/tmp/crontabTask.tmp
        crontab /tmp/crontabTask.tmp
        rm /tmp/crontabTask.tmp
        LOGI "设置定时清除xray日志:${accessfilePath}成功"
    else
        LOGE "accesslog不存在,将不会为其设置定时清除"
    fi

    if [[ -f ${errorfilePath} ]]; then
        crontab -l >/tmp/crontabTask.tmp
        echo "30 4 */2 * * x-ui clear ${errorfilePath} > /dev/null" >>/tmp/crontabTask.tmp
        crontab /tmp/crontabTask.tmp
        rm /tmp/crontabTask.tmp
        LOGI "设置定时清除xray日志:${errorfilePath}成功"
    else
        LOGE "errorlog不存在,将不会为其设置定时清除"
    fi
}

#disable auto dlete log
disable_auto_clear_log() {
    crontab -l | grep -v "x-ui clear" | crontab -
    if [[ $? -ne 0 ]]; then
        LOGI "取消 定时清除xray日志失败"
    else
        LOGI "取消 定时清除xray日志成功"
    fi
}

show_usage() {
    echo "x-ui 管理脚本使用方法: "
    echo "------------------------------------------"
    echo "x-ui              - 显示管理菜单 (功能更多)"
    echo "x-ui start        - 启动 x-ui 面板"
    echo "x-ui stop         - 停止 x-ui 面板"
    echo "x-ui restart      - 重启 x-ui 面板"
    echo "x-ui status       - 查看 x-ui 状态"
    echo "x-ui enable       - 设置 x-ui 开机自启"
    echo "x-ui disable      - 取消 x-ui 开机自启"
    echo "x-ui log          - 查看 x-ui 日志"
    echo "x-ui v2-ui        - 迁移本机器的 v2-ui 账号数据至 x-ui"
    echo "x-ui update       - 更新 x-ui 面板"
    echo "x-ui install      - 安装 x-ui 面板"
    echo "x-ui uninstall    - 卸载 x-ui 面板"
    echo "x-ui clear        - 清除 x-ui 日志"
    echo "x-ui geo          - 更新 x-ui geo数据"
    echo "x-ui cron         - 配置 x-ui 定时任务"
    echo "------------------------------------------"
}

show_menu() {
    echo -e "
  ${green}x-ui 面板管理脚本${plain}
  ${green}0.${plain} 退出脚本
————————————————
  ${green}1.${plain} 安装 x-ui
  ${green}2.${plain} 更新 x-ui
  ${green}3.${plain} 卸载 x-ui
————————————————
  ${green}4.${plain} 重置用户名密码
  ${green}5.${plain} 重置面板设置
  ${green}6.${plain} 设置面板端口
  ${green}7.${plain} 查看当前面板信息
————————————————
  ${green}8.${plain} 启动 x-ui
  ${green}9.${plain} 停止 x-ui
  ${green}10.${plain} 重启 x-ui
  ${green}11.${plain} 查看 x-ui 状态
  ${green}12.${plain} 查看 x-ui 日志
————————————————
  ${green}13.${plain} 设置 x-ui 开机自启
  ${green}14.${plain} 取消 x-ui 开机自启
————————————————
  ${green}15.${plain} 一键安装 bbr (最新内核)
  ${green}16.${plain} 一键申请SSL证书(acme申请)
  ${green}17.${plain} 配置x-ui定时任务
 "
    show_status
    echo && read -p "请输入选择 [0-17],查看面板登录信息请输入数字7:" num

    case "${num}" in
    0)
        exit 0
        ;;
    1)
        check_uninstall && install
        ;;
    2)
        check_install && update
        ;;
    3)
        check_install && uninstall
        ;;
    4)
        check_install && reset_user
        ;;
    5)
        check_install && reset_config
        ;;
    6)
        check_install && set_port
        ;;
    7)
        check_install && check_config
        ;;
    8)
        check_install && start
        ;;
    9)
        check_install && stop
        ;;
    10)
        check_install && restart
        ;;
    11)
        check_install && status
        ;;
    12)
        check_install && show_log
        ;;
    13)
        check_install && enable
        ;;
    14)
        check_install && disable
        ;;
    15)
        install_bbr
        ;;
    16)
        ssl_cert_issue
        ;;
    17)
        check_install && cron_jobs
        ;;
    *)
        LOGE "请输入正确的数字 [0-17],查看面板登录信息请输入数字7"
        ;;
    esac
}

if [[ $# > 0 ]]; then
    case $1 in
    "start")
        check_install 0 && start 0
        ;;
    "stop")
        check_install 0 && stop 0
        ;;
    "restart")
        check_install 0 && restart 0
        ;;
    "status")
        check_install 0 && status 0
        ;;
    "enable")
        check_install 0 && enable 0
        ;;
    "disable")
        check_install 0 && disable 0
        ;;
    "log")
        check_install 0 && show_log 0
        ;;
    "v2-ui")
        check_install 0 && migrate_v2_ui 0
        ;;
    "update")
        check_install 0 && update 0
        ;;
    "install")
        check_uninstall 0 && install 0
        ;;
    "uninstall")
        check_install 0 && uninstall 0
        ;;
    "geo")
        check_install 0 && update_geo
        ;;
    "clear")
        check_install 0 && clear_log $2
        ;;
    "cron")
        check_install && cron_jobs
        ;;
    *) show_usage ;;
    esac
else
    show_menu
fi
