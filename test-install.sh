#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd -P)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
pack="$test_root/package"
mocks="$test_root/mocks"
mkdir -p "$pack/WeChatDownloadSync.app/Contents/MacOS" "$mocks"
cp "$root/Install.command" "$root/Uninstall.command" "$pack/"

cat > "$pack/WeChatDownloadSync.app/Contents/MacOS/WeChatDownloadSync" <<'EOF'
#!/bin/bash
if [ "${MOCK_CONFIG_FAIL:-0}" = 1 ] && [ "$1" = --configure ]; then exit 1; fi
exit 0
EOF
cat > "$mocks/codesign" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$mocks/ditto" <<'EOF'
#!/bin/bash
cp -R "$1/." "$2/"
EOF
cat > "$mocks/launchctl" <<'EOF'
#!/bin/bash
case "$1" in
    print) exit 1 ;;
    bootstrap) [ "${MOCK_BOOTSTRAP_FAIL:-0}" != 1 ] ;;
    bootout) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$pack/WeChatDownloadSync.app/Contents/MacOS/WeChatDownloadSync" "$mocks/"*

export PATH="$mocks:$PATH"
export HOME="$test_root/success home"
mkdir -p "$HOME"
bash "$pack/Install.command"
agent="$HOME/Library/LaunchAgents/io.github.whaoo0.wechat-download-sync.plist"
app="$HOME/Applications/WeChatDownloadSync.app"
test -f "$agent"
test -x "$app/Contents/MacOS/WeChatDownloadSync"
plutil -lint "$agent" >/dev/null
test "$(plutil -extract ProgramArguments.0 raw -o - "$agent")" = "$app/Contents/MacOS/WeChatDownloadSync"
bash "$pack/Uninstall.command"
test ! -e "$agent"
test ! -e "$app"

export HOME="$test_root/config-failure"
export MOCK_CONFIG_FAIL=1
mkdir -p "$HOME"
if bash "$pack/Install.command"; then
    echo "取消授权后安装不应成功" >&2
    exit 1
fi
test ! -e "$HOME/Applications/WeChatDownloadSync.app"
test ! -e "$HOME/Library/LaunchAgents/io.github.whaoo0.wechat-download-sync.plist"
unset MOCK_CONFIG_FAIL

export HOME="$test_root/bootstrap-failure"
export MOCK_BOOTSTRAP_FAIL=1
mkdir -p "$HOME"
if bash "$pack/Install.command"; then
    echo "后台服务启动失败时安装不应成功" >&2
    exit 1
fi
test ! -e "$HOME/Applications/WeChatDownloadSync.app"
test ! -e "$HOME/Library/LaunchAgents/io.github.whaoo0.wechat-download-sync.plist"
unset MOCK_BOOTSTRAP_FAIL

export HOME="$test_root/existing"
mkdir -p "$HOME/Applications/WeChatDownloadSync.app"
echo preserve > "$HOME/Applications/WeChatDownloadSync.app/existing.txt"
if bash "$pack/Install.command"; then
    echo "已有应用时安装不应覆盖它" >&2
    exit 1
fi
test "$(cat "$HOME/Applications/WeChatDownloadSync.app/existing.txt")" = preserve
echo "安装和卸载模拟测试通过"
