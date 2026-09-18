# JackpotHood 全链路部署手册（Google Cloud + jackpothood.com）

> 目标：把「前端网站 + 自动开奖 keeper」完整部署到 Google Cloud Run，
> 绑定域名 jackpothood.com（GoDaddy 注册），支持测试网/主网一键切换。

## 架构总览

```
用户浏览器 → jackpothood.com（Cloud Run 免费 HTTPS）
                 └─ Node 服务器（容器内）
                      ├─ 静态前端（购票/质押/历史/规则…）
                      └─ keeper 每 60 秒自驱动：
                           到点 → 承诺区块 → 公证快照 → 结算 → 开下一轮
                                 （不再依赖外部 cron）
                 ↓ 链上交互
            Robinhood Chain RPC（测试网 46630 / 主网 4663）
```

| 组件 | 位置 | 说明 |
|---|---|---|
| 前端 | `frontend/`（Vite/React） | `npm run build` 产出 `dist` |
| 自托管服务器 | `frontend/server.mjs` | 静态托管 + keeper 自驱动 + `/__keeper` + `/healthz` |
| 部署镜像 | 根目录 `Dockerfile` | 装依赖 → 构建前端 → 启动 server |
| 合约 | Robinhood Chain | 测试网：`0xa1fcd034d663f2d08832eb947c495d2e2345e3e0`（6 档版） |

---

## 第 0 步：本地准备与前置清单

- [ ] 域名：`jackpothood.com`（GoDaddy，DNS 面板可登录）
- [ ] Google Cloud 账号（可先领 $300 试用额度）
- [ ] Keeper 私钥（测试网用现有那把即可；主网建议新建一把并预存 gas）
- [ ] 本机安装：git、Docker（可选）、gcloud CLI

## 第 1 步：GCP 项目初始化（一次性，约 5 分钟）

```bash
# 1) 创建项目（或在控制台建好）
gcloud projects create jackpothood --name=JackpotHood

# 2) 设置默认项目
gcloud config set project jackpothood

# 3) 登录
gcloud auth login

# 4) 启用所需服务
gcloud services enable run.googleapis.com artifactregistry.googleapis.com \
  cloudbuild.googleapis.com secretmanager.googleapis.com
```

## 第 2 步：Keeper 私钥入 Secret Manager（约 3 分钟）

> 私钥只进 Secret Manager，绝不写进代码/镜像。

```bash
echo -n "你的keeper私钥(0x开头)" > /tmp/kp.txt
gcloud secrets create keeper-pk --data-file=/tmp/kp.txt
rm /tmp/kp.txt   # 用完即删
```

## 第 3 步：构建并部署到 Cloud Run（约 5-10 分钟）

在仓库根目录（含 Dockerfile）执行：

```bash
# 构建镜像（Cloud Build 自动上传）
gcloud builds submit --tag gcr.io/jackpothood/jackpothood-testnet .

# 部署（测试网）
gcloud run deploy jackpothood \
  --image gcr.io/jackpothood/jackpothood-testnet \
  --region asia-east1 \
  --allow-unauthenticated \
  --memory 512Mi \
  --min-instances 1 \
  --set-env-vars "CONTRACT_ADDRESS=0xa1fcd034d663f2d08832eb947c495d2e2345e3e0,RPC_URL=https://rpc.testnet.chain.robinhood.com,CHAIN_ID=46630,CHAIN_NAME=Robinhood Chain Testnet" \
  --set-secrets "KEEPER_PK=keeper-pk:latest"
```

要点：
- **`--min-instances 1` 必须加**：保证每 10 分钟一轮的开奖不被冷启动拖慢
- `--region` 可选 asia-east1（台湾）或 asia-southeast1（新加坡），按目标用户就近选

## 第 4 步：验证部署（约 2 分钟）

部署完成输出临时网址，例如 `https://jackpothood-xxxx-asia-east1.run.app`：

1. 打开首页：确认奖池/轮次正常显示（读到链上数据）
2. 访问 `https://你的网址/healthz` → 应返回 `{"ok":true,"lastRun":...,"lastResult":...}`
   - `lastResult` 每轮会显示 `settled`/`started`/`committed` 等；`error:...` 说明有问题
3. 访问 `https://你的网址/__keeper` → 手动触发一次 keeper，看返回

## 第 5 步：绑定域名 jackpothood.com（约 15 分钟 + 证书等待）

### 5a. Cloud Run 添加域名映射
控制台 → Cloud Run → 服务 `jackpothood` → **域名** → **添加域名映射**
- 先加 `jackpothood.com`，再加 `www.jackpothood.com`
- 页面会显示需要添加的 DNS 记录（以面板显示为准）

### 5b. GoDaddy 添加 DNS 记录
GoDaddy → 我的产品 → jackpothood.com → **DNS** → **DNS Records**：

1. **删除占位记录**（停放页）：类型 `A` 主机 `@`、类型 `CNAME` 主机 `www`（如存在）
2. **新增记录**（典型值，以 Cloud Run 面板为准）：

| 类型 | 主机 | 值 |
|---|---|---|
| CNAME | `www` | `ghs.googlehosted.com` |
| AAAA | `@` | `2001:4860:4802:32::15`（面板可能给 4 条，都加） |

3. 保存。TTL 生效后回 Cloud Run 域名页：`Pending` → 自动签 HTTPS 证书 → `Active`

### 5c. 验证
```bash
nslookup -type=CNAME www.jackpothood.com
nslookup -type=AAAA jackpothood.com
```
看到 `ghs.googlehosted.com` / `2001:4860:...` 即生效。

## 第 6 步（可选）：大陆访问加速

Cloud Run 对大陆直连质量一般。若主要用户在国内：
1. 注册 Cloudflare（免费），把 `jackpothood.com` 的 nameserver 改成 Cloudflare 提供的两个
2. Cloudflare DNS 中加 CNAME `www`→`ghs.googlehosted.com`、AAAA `@`→上述地址，开启橙色云（代理）
3. 大陆用户走 Cloudflare 边缘节点，明显更稳

> 改动 nameserver 前确认 Cloud Run 证书已 Active，避免切换期断站。

## 第 7 步：主网切换

### 前端
编辑 `frontend/src/config.js`：
- 填 `MAINNET_CONFIG`：合约地址、代币、DEX 地址、创建区块等（mainnet TODO 处）
- `USE_MAINNET = true`

### 服务
```bash
gcloud run deploy jackpothood-mainnet \
  --image gcr.io/jackpothood/jackpothood-testnet \
  --region asia-east1 --allow-unauthenticated --memory 512Mi --min-instances 1 \
  --set-env-vars "CONTRACT_ADDRESS=主网合约地址,RPC_URL=https://rpc.mainnet.chain.robinhood.com,CHAIN_ID=4663,CHAIN_NAME=Robinhood Chain" \
  --set-secrets "KEEPER_PK=keeper-pk:latest"
```
给主网服务另绑域名（如 `app.jackpothood.com`）即可并行灰度。

> 主网 keeper 私钥建议单独一把，部署前先给该地址转少量 ETH 作 gas。

---

## 日常运维小抄

| 操作 | 命令 |
|---|---|
| 看日志 | `gcloud run services logs read jackpothood --region asia-east1 --limit 50` |
| 手动触发开奖 | 访问 `https://你的域名/__keeper` |
| 健康检查 | 访问 `https://你的域名/healthz` |
| 更新部署（改代码后） | 重新 `gcloud builds submit` + `gcloud run deploy`（同参数） |
| 暂停服务 | `gcloud run services update-traffic jackpothood --to-latest=0` |
| 恢复服务 | `--to-latest=100` |
| 查看费用 | 控制台 Billing → 预算提醒（建议设 $20/月提醒） |

## 常见故障排查

| 症状 | 原因/处理 |
|---|---|
| 首页一直 Loading/读不到链 | 合约地址 env 写错或 RPC 不可达；检查 `/healthz` 与日志 |
| `/healthz` 显示 `error:...` | 多为 RPC 抖动：确认 `RPC_URL` 可用；日志里看具体错误 |
| keeper 某轮卡住 | 手动访问 `/__keeper` 触发；快照机制下 30 秒窗口已不再是问题 |
| 域名一直 Pending | DNS 记录没生效：核对记录值、等 TTL；用 nslookup 自查 |
| 证书超 2 小时未签发 | 确认域名映射的两条记录（根域 AAAA 别漏） |
| 冷启动慢/开奖延迟 | 确认部署带 `--min-instances 1` |

## 安全清单（上线前核对）

- [ ] KEEPER_PK 只在 Secret Manager，代码/镜像/日志无泄漏
- [ ] 合约 admin 已从部署私钥迁到 Safe 多签（主网）
- [ ] 规则页/条款/风险披露已在站内
- [ ] 前端 USE_MAINNET 指向正确合约，JACKPOT_CREATED 创建区块正确（播报条扫描用）
- [ ] Telegram 群、分享链接等外链更新为新域名

---

## 仓库部署文件清单

| 文件 | 作用 |
|---|---|
| `Dockerfile` | 构建镜像（npm ci → build → node server.mjs） |
| `.dockerignore` | 排除 node_modules/dist/.env |
| `frontend/server.mjs` | 静态托管 + keeper 自驱动（60s）+ `/__keeper` + `/healthz` |
| `frontend/src/config.js` | 测试网/主网配置开关 |
| `docs/legacy-contracts.md` | 历史合约归档 |
