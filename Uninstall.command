#!/bin/bash
set -euo pipefail

agent="$HOME/Library/LaunchAgents/io.github.whaoo0.wechat-download-sync.plist"
app="$HOME/Applications/WeChatDownloadSync.app"
domain="gui/$(id -u)"

if [ -f "$agent" ]; then
    launchctl bootout "$domain" "$agent" 2>/dev/null || true
    rm -f "$agent"
fi
if [ -d "$app" ] && [ ! -L "$app" ]; then
    rm -rf "$app"
fi
echo "后台程序已卸载。已下载的文件、微信中的链接和程序配置数据予以保留。"
