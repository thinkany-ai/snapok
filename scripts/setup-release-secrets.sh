#!/bin/bash
# 把发布所需的签名/公证凭据设置为 GitHub Actions Secrets（维护者运行一次即可）。
# 值通过管道直接交给 gh，不会打印到终端或写入文件。
#
#   ./scripts/setup-release-secrets.sh path/to/DeveloperID.p12
#
# 前提：
#   - 已设置环境变量 APPLE_SIGNING_IDENTITY / APPLE_ID / APPLE_PASSWORD / APPLE_TEAM_ID
#   - .p12 为「Developer ID Application」证书连同私钥导出（钥匙串访问 › 导出），会提示输入导出时设置的密码
#   - gh 已登录且对仓库有 admin 权限
set -euo pipefail

REPO="${REPO:-thinkany-ai/snapok}"
P12="${1:?usage: $0 path/to/DeveloperID.p12}"
[ -f "$P12" ] || { echo "not found: $P12" >&2; exit 1; }

for name in APPLE_SIGNING_IDENTITY APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID; do
  : "${!name:?set $name}"
done

P12_PASSWORD="${APPLE_CERTIFICATE_PASSWORD:-}"
if [[ -z "$P12_PASSWORD" ]]; then
  read -rsp "Password of $P12: " P12_PASSWORD
  echo
fi

base64 -i "$P12" | gh secret set APPLE_CERTIFICATE --repo "$REPO"
printf '%s' "$P12_PASSWORD" | gh secret set APPLE_CERTIFICATE_PASSWORD --repo "$REPO"
for name in APPLE_SIGNING_IDENTITY APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID; do
  printf '%s' "${!name}" | gh secret set "$name" --repo "$REPO"
done

echo "Secrets set on $REPO:"
gh secret list --repo "$REPO"
