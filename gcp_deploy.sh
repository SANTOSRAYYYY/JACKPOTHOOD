#!/usr/bin/env bash
# JackpotHood → Google Cloud Run 一键部署（测试网）
# 用法：
#   1) 安装 gcloud：https://cloud.google.com/sdk/docs/install （Windows 也可: winget install Google.CloudSDK）
#   2) 把下面 PROJECT_ID 改成你的 GCP 项目 ID
#   3) 在仓库根目录执行: bash gcp_deploy.sh
set -e

# ============ 改这里 ============
PROJECT_ID="jackpothood-app"                  # ← 你的 GCP 项目 ID
REGION="asia-east1"                           # 或 asia-southeast1
SERVICE="jackpothood"
IMAGE="gcr.io/${PROJECT_ID}/jackpothood"
# 测试网合约（V4 core）；主网部署改下面三项
CONTRACT_ADDRESS="0xDD2F8d1A8aefE837BFc22912ca2DFE073ccC7a02"
RPC_URL="https://rpc.testnet.chain.robinhood.com"
CHAIN_ID="46630"
CONTRACT_CREATED="115715866"
# ================================

echo "==> 1/5 登录 Google Cloud（会打开浏览器确认）"
gcloud auth login

echo "==> 2/5 设置项目并启用服务"
gcloud config set project ${PROJECT_ID}
gcloud services enable run.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com secretmanager.googleapis.com

echo "==> 3/5 保存 Keeper 私钥到 Secret Manager"
if ! gcloud secrets describe keeper-pk --project=${PROJECT_ID} >/dev/null 2>&1; then
  read -s -p "粘贴 keeper 私钥（0x 开头，输入不回显）: " KP
  echo
  echo -n "$KP" > /tmp/kp.txt
  gcloud secrets create keeper-pk --data-file=/tmp/kp.txt
  rm -f /tmp/kp.txt
else
  echo "    keeper-pk 已存在，跳过"
fi

echo "==> 4/5 Cloud Build 构建镜像（首次约 5-10 分钟）"
gcloud builds submit --tag ${IMAGE} .

echo "==> 5/5 部署到 Cloud Run"
gcloud run deploy ${SERVICE} \
  --image ${IMAGE} \
  --region ${REGION} \
  --allow-unauthenticated \
  --memory 512Mi \
  --min-instances 1 \
  --no-cpu-throttling \
  --set-env-vars "CONTRACT_ADDRESS=${CONTRACT_ADDRESS},RPC_URL=${RPC_URL},CHAIN_ID=${CHAIN_ID},CONTRACT_CREATED=${CONTRACT_CREATED}" \
  --set-secrets "KEEPER_PK=keeper-pk:latest"

echo "==> 完成！部署输出里有你的临时网址，先访问 /health 确认 keeper 状态（注意：/healthz 会被 Google 前端拦截返回 404，用 /health）"
