#!/bin/sh

function match_multiline() {
    escaped_regex=$(echo "$1" |sed 's#/#\\\/#g')
    result=$(echo "$2" |perl -0777 -ne "print if /${escaped_regex}/s")

    if [[ "$result" ]]; then
        return 0
    else
        return 1
    fi
}

function perl_replace() {
    local regexp=$1
    # 注意：$1 在 perl 里面是一个矢量, 因此它有 $[ 会出错，因为 perl 会认为在通过 []
    # 方法读取矢量的元素，所以记得在 placement 中 [ 也要转义。
    # 写完一定测试一下，perl 变量引用: http://www.perlmonks.org/?node_id=353259
    local replace=$2
    local escaped_replace=$(echo "$replace" |sed 's#"#\\"#g')

    # 和 sed 类似，就是 g, 表示是否全局替换，不加只替换第一个
    local replace_all_matched=$3
    # 就是 s, 新增的话, . 也匹配 new_line
    local match_newline=$4

    if [ -z "$replace_all_matched" ]; then
        globally=''
    else
        globally=' globally'
    fi

    perl -i -ne "s$regexp$replace${replace_all_matched}${match_newline}; print \$_; unless ($& eq \"\") {print STDERR \"\`\033[0;33m$&\033[0m' was replaced with \`\033[0;34m${escaped_replace}\033[0m'${globally} for \`\033[0;33m$6\033[0m'!\n\"};" "$5" "$6"
}

# 为了支持多行匹配，使用 perl 正则, 比 sed 好用一百倍！
function replace_multiline () {
    local regexp=$1
    local replace=$2
    local file=$3

    # 这个 -0 必须的，-0 表示，将空白字符作为 input record separators ($/)
    # 这也意味着，它会将文件内的所有内容整体作为一个字符串一次性读取。
    # 感觉类似于 -0777 (file slurp mode) ?
    perl_replace "$regexp" "$replace" "g" "s" -0777 "$file"
}

function replace_multiline1 () {
    local regexp=$1
    local replace=$2
    local file=$3

    perl_replace "$regexp" "$replace" "" "s" -0777 "$file"
}

config=${v2ray_config-/opt/etc/config.json}

if cat $config |grep -qs '"protocol": "vless"'; then
    service_name=xray
else
    service_name=v2ray
fi


function disable_proxy () {
    echo '[0m[0;33m => Disabling proxy ...[0m'

    if [ -e /opt/etc/init.d/S22${service_name} ]; then
        chmod -x /opt/etc/init.d/S22${service_name} && sh /opt/etc/init.d/S22${service_name} stop
    #     # disalbe_proxy 并没有停止 v2ray 服务.
    #     # 因为即使关闭透明代理，仍可以通过浏览器插件使用 v2ray 的 socks 代理或 http 代理服务。
    # else
    #     systemctl disable ${service_name} && systemctl stop ${service_name}
    fi
    /opt/etc/clean_iptables_rule.sh && chmod -x /opt/etc/apply_iptables_rule.sh

    if which dnsmasq &>/dev/null; then
        dnsmasq_dir=/opt/etc/dnsmasq.d

        [ -d "$dnsmasq_dir" ] && rm -f $dnsmasq_dir/${service_name}.conf

        chmod +x /opt/etc/restart_dnsmasq.sh && /opt/etc/restart_dnsmasq.sh
    fi

    echo '[0m[0;33m => Proxy is disabled.[0m'
}

function enable_proxy () {
    echo '[0m[0;33m => Enabling proxy ...[0m'

    if ! opkg --version &>/dev/null; then
        # 旁路由
        alias modprobe='sudo modprobe'
    fi

    if modprobe xt_TPROXY &>/dev/null; then
        sed -i 's#"tproxy": ".*"#"tproxy": "tproxy"#' $config

        if [ -e /opt/etc/use_fakedns ]; then
            echo 'Apply fakeDNS config ...'
            # 将 destOverride 选项替换为 ["fakedns"]
            replace_multiline1 '("tag":\s*"transparent",.+?)"destOverride": \[.+?\]' '$1"destOverride": ["fakedns"]' $config
            if ! match_multiline '"servers":\s*\[.*?"fakedns",.*?"8.8.4.4",' "$(cat $config)"; then
                # DNS 的第一项增加 "fakedns", 在 ""8.8.8.4" 之前。
                replace_multiline1 '("servers":\s*\[)(.*?)(\s*)"8.8.4.4",' '$1$3"fakedns",$2$3"8.8.4.4",' $config
            fi
        else
            echo 'Apply TProxy config ...'
            # 将 destOverride 选项替换为 ["http", "tls"]
            replace_multiline1 '("tag":\s*"transparent",.+?)"destOverride": \[.+?\]' '$1"destOverride": ["http", "tls"]' $config
            # 将路由中 "8.8.4.4" 之前的配置都清除掉。
            replace_multiline1 '("servers":\s*\[).*?(\s*)"8.8.4.4",' '$1$2"8.8.4.4",' $config
        fi
    else
        echo 'Not support tproxy, exit ...'
    fi

    if grep '"loglevel":\s*"debug"' $config; then
        replace_multiline '"loglevel":\s*"debug"' '"loglevel": "warning"' $config
    fi

    chmod +x /opt/etc/apply_iptables_rule.sh && /opt/etc/apply_iptables_rule.sh

    if [ -e /opt/etc/init.d/S22${service_name} ]; then
        chmod +x /opt/etc/init.d/S22${service_name} && sh /opt/etc/init.d/S22${service_name} start
    else
        systemctl restart ${service_name} && systemctl enable ${service_name}
    fi

    echo '[0m[0;33m => Proxy is enabled.[0m'
}

echo "Using config file ${config}."

if [ "$1" == 'disable' ]; then
    disable_proxy
elif [ "$1" == 'enable' ]; then
    enable_proxy
elif [ -x /opt/etc/apply_iptables_rule.sh ]; then
    disable_proxy
else
    enable_proxy
fi
