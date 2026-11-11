#!/bin/bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
source_app="$here/WeChatDownloadSync.app"
target_app="$HOME/Applications/WeChatDownloadSync.app"
agent="$HOME/Library/LaunchAgents/io.github.whaoo0.wechat-download-sync.plist"
label="io.github.whaoo0.wechat-download-sync"
domain="gui/$(id -u)"
log="$HOME/Library/Logs/WeChatDownloadSync.log"
created_app=0
created_agent=0
temporary_plist=""

cleanup_on_error() {
    status=$?
    if [ "$status" -ne 0 ]; then
        if [ "$created_agent" -eq 1 ]; then
            launchctl bootout "$domain" "$agent" 2>/dev/null || true
            rm -f "$agent"
        fi
        if [ "$created_app" -eq 1 ]; then
            rm -rf "$target_app"
        fi
        if [ -n "$temporary_plist" ]; then
            rm -f "$temporary_plist"
        fi
        echo "安装未完成。已有微信文件和已授权的配置数据均已保留。" >&2
    fi
}
trap cleanup_on_error EXIT

if [ ! -d "$source_app" ]; then
    echo "找不到 WeChatDownloadSync.app，请保留解压后的完整文件夹。" >&2
    exit 1
fi
if [ -e "$target_app" ] || [ -e "$agent" ] || launchctl print "$domain/$label" >/dev/null 2>&1; then
    echo "检测到已安装的版本，请先运行卸载脚本。" >&2
    exit 1
fi
if launchctl print "$domain/local.wechat-download-sync" >/dev/null 2>&1; then
    echo "检测到旧版同步服务，请先停用旧版，避免同时处理相同的文件。" >&2
    exit 1
fi
codesign --verify --strict "$source_app"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
mkdir "$target_app"
created_app=1
ditto "$source_app" "$target_app"

executable="$target_app/Contents/MacOS/WeChatDownloadSync"
echo "请依次选择微信账号的 msg/file 文件夹和系统下载文件夹。"
"$executable" --configure
"$executable" --check

temporary_plist="$(mktemp "$HOME/Library/LaunchAgents/.wechat-sync.XXXXXX")"
plutil -create xml1 "$temporary_plist"
plutil -insert Label -string "$label" "$temporary_plist"
plutil -insert ProgramArguments -array "$temporary_plist"
plutil -insert ProgramArguments.0 -string "$executable" "$temporary_plist"
plutil -insert RunAtLoad -bool YES "$temporary_plist"
plutil -insert KeepAlive -bool YES "$temporary_plist"
plutil -insert ThrottleInterval -integer 10 "$temporary_plist"
plutil -insert ProcessType -string Background "$temporary_plist"
plutil -insert StandardOutPath -string "$log" "$temporary_plist"
plutil -insert StandardErrorPath -string "$log" "$temporary_plist"
plutil -lint "$temporary_plist" >/dev/null
ln "$temporary_plist" "$agent"
created_agent=1
rm -f "$temporary_plist"
temporary_plist=""
launchctl bootstrap "$domain" "$agent"
trap - EXIT
echo "安装完成，同步程序将在登录后自动启动。"
