#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
derived_data="${TOUCH_DERIVED_DATA_PATH:-$root_dir/.build/xcode-derived-data}"
app_path="$derived_data/Build/Products/Debug/一念.app"
extension_path="$app_path/Contents/PlugIns/FinderExtension.appex"
extension_id="me.touch.launcher.FinderExtension"
launch_services_register="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

resolve_signing_identity() {
  security find-identity -v -p codesigning \
    | awk '/"Apple Development:/ { print $2; exit }'
}

resolve_signing_team_identifier() {
  security find-certificate -c "Apple Development" -p \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -E 's/.*OU=([^, ]+).*/\1/'
}

print_usage() {
  cat <<'USAGE'
用法：Scripts/test-super-right.sh <命令>

  setup    首次构建、注册并启用 Finder Extension，然后重载 Finder
  reload   增量构建、注册最新产物并重载 Finder（默认）
  build    只执行稳定签名的 Debug 构建
  status   显示扩展注册状态并校验三个签名产物
  logs     持续查看 Finder Extension 与 FileActionService 日志
  help     显示帮助

可通过 TOUCH_DERIVED_DATA_PATH 覆盖固定构建目录。
USAGE
}

build_app() {
  local signing_identity
  local signing_team_identifier
  signing_identity="$(resolve_signing_identity)"
  if [[ -z "$signing_identity" ]]; then
    print -u2 "未找到有效的 Apple Development 签名身份"
    exit 1
  fi
  signing_team_identifier="$(resolve_signing_team_identifier)"
  if [[ -z "$signing_team_identifier" ]]; then
    print -u2 "无法从 Apple Development 证书读取 Team Identifier"
    exit 1
  fi

  print "==> 使用固定 DerivedData 执行 Debug 构建"
  print "    签名证书 SHA-1：$signing_identity（从钥匙串自动读取）"
  print "    应用身份 Team ID：$signing_team_identifier（从证书动态读取）"
  print "    使用 Xcode 自动签名生成系统 Translation 所需的开发描述文件"
  if ! xcodebuild \
      -project "$root_dir/Touch.xcodeproj" \
      -scheme Touch \
      -configuration Debug \
      -destination 'platform=macOS' \
      -derivedDataPath "$derived_data" \
      -allowProvisioningUpdates \
      CODE_SIGN_IDENTITY="Apple Development" \
      CODE_SIGN_STYLE=Automatic \
      DEVELOPMENT_TEAM="$signing_team_identifier" \
      build; then
    print -u2
    print -u2 "Debug 构建需要 Mac App Development 描述文件，系统 Translation 才能弹出语言包下载面板。"
    print -u2 "如果上方提示 No Accounts，请先在 Xcode → Settings → Accounts 登录开发者账号，再重新运行此命令。"
    exit 1
  fi

  if [[ ! -d "$app_path" ]]; then
    print -u2 "构建完成但未找到 App：$app_path"
    exit 1
  fi

  codesign --verify --strict --verbose=2 "$app_path"
}

remove_stale_extension_registrations() {
  local stale_extension_path
  local stale_app_path

  while IFS= read -r stale_extension_path; do
    [[ -z "$stale_extension_path" || "$stale_extension_path" == "$extension_path" ]] && continue

    print "==> 注销旧 Finder Extension：$stale_extension_path"
    pluginkit -r "$stale_extension_path" || true

    stale_app_path="${stale_extension_path%/Contents/PlugIns/FinderExtension.appex}"
    if [[ "$stale_app_path" != "$stale_extension_path" && -d "$stale_app_path" ]]; then
      print "==> 注销旧 App：$stale_app_path"
      "$launch_services_register" -u "$stale_app_path" || true
    fi
  done < <(
    pluginkit -m -A -D -v -i "$extension_id" 2>/dev/null \
      | awk -F '\t' '$NF ~ /FinderExtension\.appex$/ { print $NF }'
  )
}

is_stale_development_app_path() {
  local candidate_path="$1"

  [[ "$candidate_path" != "$app_path" ]] || return 1
  [[ "$candidate_path" == "$root_dir"/.build/* ]] && return 0
  [[ "$candidate_path" == /private/tmp/* ]] && return 0
  [[ "$candidate_path" == "$HOME"/Library/Developer/Xcode/DerivedData/Touch-* ]] && return 0
  return 1
}

remove_stale_development_app_registrations() {
  local stale_app_path

  while IFS= read -r stale_app_path; do
    if is_stale_development_app_path "$stale_app_path"; then
      print "==> 注销旧开发 App：$stale_app_path"
      "$launch_services_register" -u "$stale_app_path" || true
    fi
  done < <(
    "$launch_services_register" -dump | awk '
      /^path: / {
        path = $0
        sub(/^path:[[:space:]]*/, "", path)
        sub(/[[:space:]]+\(0x[0-9a-f]+\)$/, "", path)
      }
      /^identifier:[[:space:]]+me\.touch\.launcher$/ && path != "" { print path }
    '
  )
}

register_app() {
  if [[ ! -d "$extension_path" ]]; then
    print -u2 "未找到 Finder Extension：$extension_path"
    print -u2 "请先运行：Scripts/test-super-right.sh build"
    exit 1
  fi

  print "==> 在固定路径注册 App 与 Finder Extension"
  remove_stale_extension_registrations
  remove_stale_development_app_registrations
  "$launch_services_register" -f "$app_path"
  pluginkit -a "$extension_path"
}

stop_extension_processes() {
  pkill -x FinderExtension 2>/dev/null || true
  pkill -x FileActionService 2>/dev/null || true
}

reload_finder() {
  print "==> 重载 Finder（Xcode 无需退出）"
  stop_extension_processes
  killall Finder 2>/dev/null || true
}

show_status() {
  print "==> Finder Extension 注册状态（+ 表示已启用，- 表示已停用）"
  pluginkit -m -A -D -v -i "$extension_id" || true

  local file_action_service="$app_path/Contents/XPCServices/FileActionService.xpc"
  local artifacts=("$app_path" "$extension_path" "$file_action_service")
  local artifact
  for artifact in "${artifacts[@]}"; do
    if [[ ! -e "$artifact" ]]; then
      print -u2 "缺少产物：$artifact"
      continue
    fi
    print "==> 校验签名：$artifact"
    codesign --verify --strict --verbose=2 "$artifact"
    codesign -dv --verbose=2 "$artifact" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Authority)=' || true
  done
}

setup_extension() {
  build_app
  register_app
  print "==> 启用 Finder Extension（通常只需执行一次）"
  pluginkit -e use -i "$extension_id"
  reload_finder
  show_status
}

reload_extension() {
  build_app
  register_app
  reload_finder
  show_status
}

stream_logs() {
  exec /usr/bin/log stream \
    --style compact \
    --predicate 'subsystem == "me.touch.launcher.FinderExtension" OR process == "FileActionService"'
}

command="${1:-reload}"
case "$command" in
  setup)
    setup_extension
    ;;
  reload)
    reload_extension
    ;;
  build)
    build_app
    ;;
  status)
    show_status
    ;;
  logs)
    stream_logs
    ;;
  help|-h|--help)
    print_usage
    ;;
  *)
    print -u2 "未知命令：$command"
    print_usage >&2
    exit 2
    ;;
esac
