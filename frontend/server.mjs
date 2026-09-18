// JackpotHood 自托管服务器（Google Cloud Run 用）
// - 托管前端静态文件（dist）
// - keeper 每 15 秒自驱动（不依赖外部 cron）
// - /__keeper 手动触发 + /health 健康检查（/healthz 被 GFE 拦截，勿用）
import http from 'node:http'
import { readFile, writeFile, mkdir, readdir, stat } from 'node:fs/promises'
import { join, extname, normalize } from 'node:path'
import { randomInt, randomUUID, createHash } from 'node:crypto'
import { createPublicClient, createWalletClient, http as vhttp, defineChain, parseAbi, verifyMessage, recoverMessageAddress } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

// ---------- 配置（环境变量） ----------
const CONTRACT = process.env.CONTRACT_ADDRESS || ''
const RPC_URL = process.env.RPC_URL || 'https://rpc.testnet.chain.robinhood.com'
const CHAIN_ID = Number(process.env.CHAIN_ID || 46630)
const CHAIN_NAME = process.env.CHAIN_NAME || 'Robinhood Chain Testnet'
const KEEPER_PK = process.env.KEEPER_PK || ''
const DIST = process.env.DIST_DIR || join(process.cwd(), 'dist')
const KEEPER_INTERVAL = Number(process.env.KEEPER_INTERVAL_MS || 15000)

const ZERO = '0x0000000000000000000000000000000000000000000000000000000000000000'
const chain = defineChain({
  id: CHAIN_ID,
  name: CHAIN_NAME,
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
})

const jackpotAbi = parseAbi([
  'function currentRoundId() view returns (uint256)',
  'function getRound(uint256 roundId) view returns ((uint64 salesEnd, uint64 drawAt, uint64 randomBlock, uint64 claimDeadline, uint256 prizePool, uint256 totalTickets, uint256 ticketRevenue, uint256 ticketFee, uint48 winningPacked, bytes32 commitHash, bytes32 seedHash, uint256[6] tierPots, uint256[6] tierUnits, uint256[6] tierClaimed, bool swept, uint8 status) round)',
  'function commitDraw(uint256 roundId)',
  'function snapshotCommitHash(uint256 roundId)',
  'function settleDraw(uint256 roundId)',
  'function startRound()',
  'function paused() view returns (bool)',
  'function admin() view returns (address)',
  'function totalPoolAssets() view returns (uint256 prizePoolNow, uint256 stakeReserve)',
  'function TICKET_PRICE() view returns (uint256)',
  'function pendingRollover() view returns (uint256)',
  'function stakingPool() view returns (uint256)',
  'function ticketBank() view returns (uint256)',
  'function ethStaked(address) view returns (uint256)',
  'function pendingStakeRewards(address) view returns (uint256)',
  'function getUserTickets(uint256 roundId, address user) view returns ((uint48 numbersPacked, uint64 count, address gifter, bool claimed, bool refunded)[] tickets)',
  'function previewClaim(uint256 roundId, address user) view returns (uint256 due, uint256[] indices)',
])

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.jpg': 'image/jpeg', '.ico': 'image/x-icon', '.webp': 'image/webp', '.woff2': 'font/woff2',
}

async function sendFile(res, filePath) {
  const data = await readFile(filePath)
  const ext = extname(filePath).toLowerCase()
  // HTML 每次回源校验（避免旧页面缓存指向旧合约地址导致奖池数字新旧交替）；
  // 带 hash 的静态资源可长缓存（内容变了文件名必变）
  const cc = ext === '.html' ? 'no-cache' : 'public, max-age=3600'
  res.writeHead(200, { 'content-type': MIME[ext] || 'application/octet-stream', 'cache-control': cc })
  res.end(data)
}

async function serveStatic(req, res, pathname) {
  try {
    let p = normalize(join(DIST, pathname === '/' ? 'index.html' : pathname))
    if (!p.startsWith(normalize(DIST))) { res.writeHead(403); return res.end() }
    try {
      const st = await stat(p)
      if (st.isDirectory()) p = join(p, 'index.html')
    } catch { /* fallthrough */ }
    await sendFile(res, p)
  } catch {
    // SPA fallback
    try { await sendFile(res, join(DIST, 'index.html')) } catch { res.writeHead(404); res.end('not found') }
  }
}

// ---------- keeper ----------
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
async function readRound(c, addr, rid) {
  return c.readContract({ address: addr, abi: jackpotAbi, functionName: 'getRound', args: [rid] })
}
async function sendAndWait(wc, c, call) {
  const hash = await wc.writeContract(call)
  const receipt = await c.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error('tx reverted ' + hash)
  return receipt
}

let jobRunning = false
let lastRun = null
let lastResult = 'never'

async function runDrawJob() {
  if (!CONTRACT || CONTRACT === ZERO || !KEEPER_PK) return 'not-configured'
  if (jobRunning) return 'busy'
  jobRunning = true
  const account = privateKeyToAccount(KEEPER_PK)
  const pc = createPublicClient({ chain, transport: vhttp(RPC_URL) })
  const wc = createWalletClient({ chain, account, transport: vhttp(RPC_URL) })
  const summary = { action: 'none' }
  try {
    const nowSec = BigInt(Math.floor(Date.now() / 1000))
    const rid = await pc.readContract({ address: CONTRACT, abi: jackpotAbi, functionName: 'currentRoundId' })
    const scanFloor = Math.max(1, Number(rid) - 4)
    for (let id = Number(rid); id >= scanFloor; id--) {
      let rr = await readRound(pc, CONTRACT, BigInt(id))
      if (rr.drawAt === 0n) continue
      if (Number(rr.status) === 0 && nowSec >= rr.drawAt) {
        await sendAndWait(wc, pc, { address: CONTRACT, abi: jackpotAbi, functionName: 'commitDraw', args: [BigInt(id)] })
        summary.action = 'committed'
        rr = await readRound(pc, CONTRACT, BigInt(id))
      }
      if (Number(rr.status) === 1) {
        let snaps = 0
        while (rr.commitHash === ZERO && snaps < 6) {
          const bn = await pc.getBlockNumber()
          if (bn <= rr.randomBlock) { await sleep(2000); snaps++; continue }
          try {
            await sendAndWait(wc, pc, { address: CONTRACT, abi: jackpotAbi, functionName: 'snapshotCommitHash', args: [BigInt(id)] })
            rr = await readRound(pc, CONTRACT, BigInt(id))
            break
          } catch (e) {
            const msg = String(e.shortMessage || e.message || '')
            if (msg.includes('hash window passed')) {
              await sendAndWait(wc, pc, { address: CONTRACT, abi: jackpotAbi, functionName: 'commitDraw', args: [BigInt(id)] })
              rr = await readRound(pc, CONTRACT, BigInt(id))
            } else throw e
          }
          snaps++
        }
        if (rr.commitHash !== ZERO) {
          await sendAndWait(wc, pc, { address: CONTRACT, abi: jackpotAbi, functionName: 'settleDraw', args: [BigInt(id)] })
          summary.action = summary.action === 'none' ? 'settled' : summary.action + '+settled'
        }
      }
    }
    const cur = await readRound(pc, CONTRACT, rid)
    if (Number(cur.status) === 2 || Number(cur.status) === 3) {
      const next = await readRound(pc, CONTRACT, rid + 1n)
      if (next.drawAt === 0n) {
        await sendAndWait(wc, pc, { address: CONTRACT, abi: jackpotAbi, functionName: 'startRound', args: [] })
        summary.action = summary.action === 'none' ? 'started' : summary.action + '+started'
      }
    }
    lastResult = summary.action
  } catch (e) {
    lastResult = 'error: ' + (e.shortMessage || e.message || String(e))
  } finally {
    jobRunning = false
    lastRun = new Date().toISOString()
  }
  return lastResult
}

if (CONTRACT && CONTRACT !== ZERO) {
  setInterval(() => { runDrawJob().catch(() => {}) }, KEEPER_INTERVAL)
  setTimeout(() => runDrawJob().catch(() => {}), 3000) // 启动后先跑一次
  console.log('keeper enabled ->', CONTRACT)
} else {
  console.log('keeper disabled (no CONTRACT_ADDRESS)')
}

// ---------- 读聚合 API（并发优化：1000 用户轮询收敛为服务器一次 RPC 查询） ----------
const ZERO_ADDR = '0x0000000000000000000000000000000000000000'
const cache = new Map()
const TTL = { state: 5000, mytickets: 8000, feed: 60000, board: 60000 }

function cached(key, ttlMs, fn) {
  const hit = cache.get(key)
  if (hit && Date.now() - hit.at < ttlMs) return hit.val
  return fn().then((val) => { cache.set(key, { at: Date.now(), val }); return val })
}

function roundJson(r) {
  return {
    salesEnd: Number(r.salesEnd), drawAt: Number(r.drawAt), randomBlock: Number(r.randomBlock),
    claimDeadline: Number(r.claimDeadline), prizePool: r.prizePool.toString(),
    totalTickets: Number(r.totalTickets), ticketRevenue: r.ticketRevenue.toString(),
    ticketFee: r.ticketFee.toString(), winningPacked: r.winningPacked.toString(),
    commitHash: r.commitHash, seedHash: r.seedHash,
    tierPots: r.tierPots.map(String), tierUnits: r.tierUnits.map(Number),
    tierClaimed: r.tierClaimed.map(String), swept: r.swept, status: Number(r.status),
  }
}

const prizeAbi = parseAbi([
  'event PrizeClaimed(uint256 indexed roundId, address indexed user, uint256 ticketCount, uint256 amount)',
])

async function buildState(pc) {
  if (!CONTRACT || CONTRACT === ZERO_ADDR) return { ok: false, reason: 'not-configured' }
  const rid = await pc.readContract({ address: CONTRACT, abi: jackpotAbi, functionName: 'currentRoundId' })
  // 往回多扫几期，凑满 4 期已结算的再停（否则开奖过渡期列表在 3/4/5 条间跳动、视觉闪烁）
  const histIds = []
  for (let id = Number(rid) - 1; id >= Math.max(1, Number(rid) - 8); id--) histIds.push(BigInt(id))
  // 全并发：单次 RPC ~0.3-0.6s，串行会让冷缓存响应拖到 2s+
  const [cur, paused, assets, ticketPrice, rollover, stakePool, bank, feed, ...histRounds] = await Promise.all([
    readRound(pc, CONTRACT, rid),
    pc.readContract({ address: CONTRACT, abi: jackpotAbi, functionName: 'paused' }),
    pc.readContract({ address: CONTRACT, abi: jackpotAbi, functionName: 'totalPoolAssets' }).catch(() => [0n, 0n]),
    pc.readContract({ address: CONTRACT, abi: jackpotAbi, functionName: 'TICKET_PRICE' }).catch(() => 0n),
    pc.readContract({ address: CONTRACT, abi: jackpotAbi, functionName: 'pendingRollover' }).catch(() => 0n),
    pc.readContract({ address: CONTRACT, abi: jackpotAbi, functionName: 'stakingPool' }).catch(() => 0n),
    pc.readContract({ address: CONTRACT, abi: jackpotAbi, functionName: 'ticketBank' }).catch(() => 0n),
    cached('feed', TTL.feed, () => withFailover((pc2) => buildFeed(pc2))),
    ...histIds.map((id) => readRound(pc, CONTRACT, id).catch(() => null)),
  ])
  // 近 5 期已开
  const history = []
  histIds.forEach((id, i) => {
    const r = histRounds[i]
    if (r && r.drawAt !== 0n && Number(r.status) === 2 && history.length < 4) history.push({ id: Number(id), round: roundJson(r) })
  })
  return {
    ok: true, roundId: rid.toString(), round: roundJson(cur), paused,
    assets: { prize: assets[0].toString(), stake: assets[1].toString() },
    ticketPrice: ticketPrice.toString(), rollover: rollover.toString(), stakePool: stakePool.toString(),
    ticketBank: bank.toString(),
    history, feed, ts: Date.now(),
  }
}

// 中奖播报：全历史兑奖事件扫描（独立 60s 缓存，不再随 state 冷缓存每次重扫）
async function buildFeed(pc) {
  try {
    const created = BigInt(process.env.CONTRACT_CREATED || '115109533') // 合约创建块（主网部署时改）
    const logs = await pc.getLogs({ address: CONTRACT, event: prizeAbi[0], fromBlock: created, toBlock: 'latest' })
    return logs.slice(-10).map((lg) => ({
      roundId: Number(lg.args.roundId), user: lg.args.user,
      amount: lg.args.amount.toString(),
    }))
  } catch { return [] }
}

// 用户票据相关的三类事件（覆盖自购/获赠/免费票全部来源）
const ticketEventAbi = parseAbi([
  'event TicketPurchased(uint256 indexed roundId, address indexed buyer, uint256 indexed ticketIndex, uint8[6] numbers, uint64 count, uint256 pricePaid)',
  'event TicketGifted(uint256 indexed roundId, address indexed gifter, address indexed recipient, uint256 ticketIndex, uint8[6] numbers, uint64 count, uint256 pricePaid)',
  'event FreeTicketIssued(uint256 indexed roundId, address indexed recipient, uint256 ticketIndex, uint8[6] numbers, uint64 count)',
])

async function buildMyTickets(pc, addr) {
  if (!/^0x[0-9a-fA-F]{40}$/.test(addr)) return { ok: false, reason: 'bad-address' }
  const created = BigInt(process.env.CONTRACT_CREATED || '115109533')
  // 全历史事件扫描 → 用户有票据的全部期次（不再限最近 5 期；领奖不再漏老期次）
  const [purchased, gifted, free] = await Promise.all([
    pc.getLogs({ address: CONTRACT, event: ticketEventAbi[0], args: { buyer: addr }, fromBlock: created, toBlock: 'latest' }),
    pc.getLogs({ address: CONTRACT, event: ticketEventAbi[1], args: { recipient: addr }, fromBlock: created, toBlock: 'latest' }),
    pc.getLogs({ address: CONTRACT, event: ticketEventAbi[2], args: { recipient: addr }, fromBlock: created, toBlock: 'latest' }),
  ])
  const idSet = new Set()
  for (const lg of [...purchased, ...gifted, ...free]) idSet.add(Number(lg.args.roundId))
  const ids = [...idSet].sort((a, b) => b - a)
  // 每期的轮次+用户票据并发拉取（串行 11 次 RPC 曾需 ~2.7s）
  const nowSec = Math.floor(Date.now() / 1000)
  const rows = await Promise.all(ids.map(async (rid) => {
    const id = BigInt(rid)
    const [r, t] = await Promise.all([
      readRound(pc, CONTRACT, id).catch(() => null),
      pc.readContract({
        address: CONTRACT, abi: jackpotAbi, functionName: 'getUserTickets',
        args: [id, addr],
      }).catch(() => []),
    ])
    if (!r || r.drawAt === 0n || t.length === 0) return null
    // 已结算且在兑奖期内：顺带算出可领金额与中奖票序号（前端开奖后即时展示用）
    let claimDue = 0n
    let claimIndices = []
    if (Number(r.status) === 2 && Number(r.claimDeadline) >= nowSec) {
      try {
        const [due, indices] = await pc.readContract({
          address: CONTRACT, abi: jackpotAbi, functionName: 'previewClaim', args: [id, addr],
        })
        claimDue = due
        claimIndices = indices.map((x) => Number(x))
      } catch { /* 忽略单点失败 */ }
    }
    return {
      roundId: Number(id), status: Number(r.status),
      winningPacked: r.winningPacked.toString(), seedHash: r.seedHash,
      claimDue: claimDue.toString(), claimIndices,
      tickets: t.map((x) => ({
        numbersPacked: x.numbersPacked.toString(), count: Number(x.count),
        gifter: x.gifter, claimed: x.claimed, refunded: x.refunded,
      })),
    }
  }))
  return { ok: true, rounds: rows.filter(Boolean) }
}

// ---------- 聚合接口（/api/leaderboard、/api/me） ----------
const referrerAbi = parseAbi([
  'event ReferrerSet(address indexed user, address indexed referrer)',
])
// V4.4 购票推荐立付：有推荐人时票款 5% 即时打给推荐人
const refPurchaseAbi = parseAbi([
  'event ReferralPurchasePaid(address indexed buyer, address indexed referrer, uint256 amount)',
])
// JackpotHoodPerks 合约（JPH 质押/每日收益），地址写死
const PERKS = '0x0959fF76cb5dccC2A403b3c255f4126b70f1bC2b' // V4.4 perks（与 config.js 同步）
const perksAbi = parseAbi([
  'function jphStaked(address) view returns (uint256)',
  'function jphPerkPerDay(address) view returns (uint256)',
  'function perkBalance(address) view returns (uint256)',
])
// JackpotHoodNFT 合约，地址写死
const NFT = '0xB51cE45F61E2E387a3b663a7bA0F51207834c38e'
const nftAbi = parseAbi(['function balanceOf(address) view returns (uint256)'])

const bigDesc = (a, b) => (a > b ? -1 : a < b ? 1 : 0)

// 三路全历史事件扫描 → 购票/邀请/中奖三榜（扫描失败必须向上抛错走 500，不得静默返回空榜）
async function buildLeaderboard(pc) {
  if (!CONTRACT || CONTRACT === ZERO_ADDR) return { ok: false, reason: 'not-configured' }
  const created = BigInt(process.env.CONTRACT_CREATED || '115109533')
  const [refLogs, claimLogs, buyLogs, refPaidLogs] = await Promise.all([
    pc.getLogs({ address: CONTRACT, event: referrerAbi[0], fromBlock: created, toBlock: 'latest' }),
    pc.getLogs({ address: CONTRACT, event: prizeAbi[0], fromBlock: created, toBlock: 'latest' }),
    pc.getLogs({ address: CONTRACT, event: ticketEventAbi[0], fromBlock: created, toBlock: 'latest' }),
    pc.getLogs({ address: CONTRACT, event: refPurchaseAbi[0], fromBlock: created, toBlock: 'latest' }),
  ])
  // 购票榜：按 buyer 累加 count
  const bought = new Map()
  for (const lg of buyLogs) {
    const k = lg.args.buyer.toLowerCase()
    const e = bought.get(k) || { addr: lg.args.buyer, count: 0n }
    e.count += lg.args.count
    bought.set(k, e)
  }
  const tickets = [...bought.values()]
    .sort((a, b) => bigDesc(a.count, b.count))
    .slice(0, 10)
    .map((e) => ({ addr: e.addr, count: Number(e.count) }))
  // 中奖榜：按 user 累加 amount（到账净额）
  const won = new Map()
  for (const lg of claimLogs) {
    const k = lg.args.user.toLowerCase()
    const e = won.get(k) || { addr: lg.args.user, amount: 0n }
    e.amount += lg.args.amount
    won.set(k, e)
  }
  const winners = [...won.values()]
    .sort((a, b) => bigDesc(a.amount, b.amount))
    .slice(0, 10)
    .map((e) => ({ addr: e.addr, won: e.amount.toString() }))
  // 邀请榜：ReferrerSet 建 user→referrer 最新映射（日志按时间升序，后写覆盖）；
  // 推荐人收益 = 受邀者中奖净额 × 5/88（毛额扣 12%：赢家 88%，其中 5% 归推荐人）
  const refOf = new Map()
  const invites = new Map()
  const refAddr = new Map()
  for (const lg of refLogs) {
    const u = lg.args.user.toLowerCase()
    const r = lg.args.referrer.toLowerCase()
    refOf.set(u, r)
    refAddr.set(r, lg.args.referrer)
    invites.set(r, (invites.get(r) || 0) + 1)
  }
  const earned = new Map()
  for (const lg of claimLogs) {
    const r = refOf.get(lg.args.user.toLowerCase())
    if (r) earned.set(r, (earned.get(r) || 0n) + (lg.args.amount * 5n) / 88n)
  }
  // 购票侧推荐立付（V4.4）：按事件实付金额直接累加，与中奖侧 5/88 并列
  for (const lg of refPaidLogs) {
    const r = lg.args.referrer.toLowerCase()
    refAddr.set(r, lg.args.referrer)
    earned.set(r, (earned.get(r) || 0n) + lg.args.amount)
  }
  const inviters = [...new Set([...invites.keys(), ...earned.keys()])]
    .map((k) => ({ addr: refAddr.get(k) || k, invites: invites.get(k) || 0, amount: earned.get(k) || 0n }))
    .sort((a, b) => bigDesc(a.amount, b.amount))
    .slice(0, 10)
    .map((e) => ({ addr: e.addr, invites: e.invites, earned: e.amount.toString() }))
  return { ok: true, updatedAt: Date.now(), boards: { tickets, inviters, winners } }
}

// 单用户全维度聚合：事件扫描失败向上抛（500），合约直读单点失败回退 0
async function buildMe(pc, addr) {
  if (!/^0x[0-9a-fA-F]{40}$/.test(addr)) return { ok: false, reason: 'bad-address' }
  addr = addr.toLowerCase()
  const created = BigInt(process.env.CONTRACT_CREATED || '115109533')
  const zero = () => 0n
  const [purchased, gifted, free, claimLogs, refLogs, refPaidLogs, mt,
    ethStaked, pendingStake, jphStaked, jphPerk, perkBal, nftCount] = await Promise.all([
    pc.getLogs({ address: CONTRACT, event: ticketEventAbi[0], args: { buyer: addr }, fromBlock: created, toBlock: 'latest' }),
    pc.getLogs({ address: CONTRACT, event: ticketEventAbi[1], args: { recipient: addr }, fromBlock: created, toBlock: 'latest' }),
    pc.getLogs({ address: CONTRACT, event: ticketEventAbi[2], args: { recipient: addr }, fromBlock: created, toBlock: 'latest' }),
    pc.getLogs({ address: CONTRACT, event: prizeAbi[0], fromBlock: created, toBlock: 'latest' }),
    pc.getLogs({ address: CONTRACT, event: referrerAbi[0], fromBlock: created, toBlock: 'latest' }),
    pc.getLogs({ address: CONTRACT, event: refPurchaseAbi[0], args: { referrer: addr }, fromBlock: created, toBlock: 'latest' }),
    buildMyTickets(pc, addr),
    pc.readContract({ address: CONTRACT, abi: jackpotAbi, functionName: 'ethStaked', args: [addr] }).catch(zero),
    pc.readContract({ address: CONTRACT, abi: jackpotAbi, functionName: 'pendingStakeRewards', args: [addr] }).catch(zero),
    pc.readContract({ address: PERKS, abi: perksAbi, functionName: 'jphStaked', args: [addr] }).catch(zero),
    pc.readContract({ address: PERKS, abi: perksAbi, functionName: 'jphPerkPerDay', args: [addr] }).catch(zero),
    pc.readContract({ address: PERKS, abi: perksAbi, functionName: 'perkBalance', args: [addr] }).catch(zero),
    pc.readContract({ address: NFT, abi: nftAbi, functionName: 'balanceOf', args: [addr] }).catch(zero),
  ])
  // 自购/获赠/免费票统计
  const ticketsBought = purchased.reduce((s, lg) => s + Number(lg.args.count), 0)
  const spentEth = purchased.reduce((s, lg) => s + lg.args.pricePaid, 0n).toString()
  const freeTickets = free.reduce((s, lg) => s + Number(lg.args.count), 0)
  const giftedCount = gifted.reduce((s, lg) => s + Number(lg.args.count), 0)
  // 推荐关系：我的推荐人（最新一条）、我邀请的人数、推荐收益（受邀者净额 × 5/88）
  const refOf = new Map()
  let referrer = null
  let invitees = 0
  for (const lg of refLogs) {
    const u = lg.args.user.toLowerCase()
    const r = lg.args.referrer
    refOf.set(u, r.toLowerCase())
    if (u === addr) referrer = r
    if (r.toLowerCase() === addr) invitees++
  }
  // 中奖统计 + 推荐收益共用同一份全历史 PrizeClaimed 扫描
  let wonTotal = 0n
  let winTickets = 0
  let earned = 0n
  const winRoundSet = new Set()
  for (const lg of claimLogs) {
    const u = lg.args.user.toLowerCase()
    if (u === addr) {
      wonTotal += lg.args.amount
      winTickets += Number(lg.args.ticketCount)
      winRoundSet.add(Number(lg.args.roundId))
    }
    if (refOf.get(u) === addr) earned += (lg.args.amount * 5n) / 88n
  }
  // 购票侧推荐立付（V4.4）：事件实付金额直接累加
  for (const lg of refPaidLogs) earned += lg.args.amount
  // 待领：复用 mytickets 聚合，挑 claimDue>0 的期次（due 原样透传）
  const pending = (mt.rounds || [])
    .filter((r) => BigInt(r.claimDue) > 0n)
    .map((r) => ({ roundId: r.roundId, due: r.claimDue, count: r.claimIndices.length }))
  return {
    ok: true, addr, ticketsBought, spentEth, freeTickets, giftedCount,
    wonTotalEth: wonTotal.toString(), winRounds: winRoundSet.size, winTickets,
    pending, referrer, invitees, earnedEth: earned.toString(),
    ethStaked: ethStaked.toString(), pendingStakeRewards: pendingStake.toString(),
    jphStaked: jphStaked.toString(), jphPerkPerDay: jphPerk.toString(),
    perkBalance: perkBal.toString(), nftCount: nftCount.toString(),
  }
}

// 多 RPC：primary + fallbacks（逗号分隔）
const RPC_FALLBACKS = (process.env.RPC_FALLBACKS || '').split(',').map((s) => s.trim()).filter(Boolean)
function makePublic() {
  const urls = [RPC_URL, ...RPC_FALLBACKS]
  return urls.map((u) => createPublicClient({ chain, transport: vhttp(u, { retryCount: 1, timeout: 8000 }) }))
}
let publicPool = makePublic()
let poolIdx = 0
function nextClient() {
  const c = publicPool[poolIdx % publicPool.length]
  poolIdx++
  return c
}
async function withFailover(fn) {
  let lastErr
  for (let i = 0; i < publicPool.length; i++) {
    try { return await fn(publicPool[i]) } catch (e) { lastErr = e }
  }
  throw lastErr
}

// ---------- 持久化存储（GCS JSON + 本地兜底） ----------
// PRIZE_BUCKET 有值 → GCS 模式；无值或 metadata server 不可达（本地开发）→ 写 .devdata/
const PRIZE_BUCKET = process.env.PRIZE_BUCKET || ''
const DEVDATA = join(process.cwd(), '.devdata')
const DEFAULT_PRIZES = {
  small: [
    { name: 'JPH 定制周边', weight: 30 }, { name: '手机支架', weight: 25 }, { name: '保温杯', weight: 20 },
    { name: '蓝牙耳机', weight: 12 }, { name: '机械键盘', weight: 8 }, { name: 'Switch 2', weight: 5 },
  ],
  big: [
    { name: '京东卡 500', weight: 30 }, { name: 'AirPods Pro', weight: 25 }, { name: 'PS5', weight: 20 },
    { name: 'iPad', weight: 12 }, { name: 'iPhone 17 Pro', weight: 8 }, { name: 'MacBook Pro', weight: 5 },
  ],
}

let gcsToken = null // { token, exp }：metadata server 令牌缓存（提前 60s 刷新）
let gcsOk = null    // null=未探测 / true=GCS / false=本地兜底

async function gcsAccessToken() {
  if (gcsToken && Date.now() < gcsToken.exp) return gcsToken.token
  const r = await fetch('http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token', {
    headers: { 'Metadata-Flavor': 'Google' },
    signal: AbortSignal.timeout(3000),
  })
  if (!r.ok) throw new Error('metadata token ' + r.status)
  const data = await r.json()
  gcsToken = { token: data.access_token, exp: Date.now() + (Number(data.expires_in) - 60) * 1000 }
  return gcsToken.token
}

async function useGcs() {
  if (!PRIZE_BUCKET) return false
  if (gcsOk !== null) return gcsOk
  try { await gcsAccessToken(); gcsOk = true } catch { gcsOk = false }
  return gcsOk
}

async function gcsGet(name) {
  const token = await gcsAccessToken()
  const r = await fetch(`https://storage.googleapis.com/storage/v1/b/${PRIZE_BUCKET}/o/${encodeURIComponent(name)}?alt=media`, {
    headers: { authorization: 'Bearer ' + token },
  })
  if (r.status === 404) return null
  if (!r.ok) throw new Error('gcs read ' + r.status)
  return r.json()
}

// 条件写：先取 generation 再 ifGenerationMatch，412 说明有并发写 → 重读重写（最多 3 次）
async function gcsPut(name, obj) {
  const token = await gcsAccessToken()
  const body = JSON.stringify(obj)
  for (let attempt = 0; attempt < 3; attempt++) {
    const meta = await fetch(`https://storage.googleapis.com/storage/v1/b/${PRIZE_BUCKET}/o/${encodeURIComponent(name)}`, {
      headers: { authorization: 'Bearer ' + token },
    })
    let gen = '0'
    if (meta.ok) gen = String((await meta.json()).generation)
    else if (meta.status !== 404) throw new Error('gcs meta ' + meta.status)
    const r = await fetch(`https://storage.googleapis.com/upload/storage/v1/b/${PRIZE_BUCKET}/o?uploadType=media&name=${encodeURIComponent(name)}&ifGenerationMatch=${gen}`, {
      method: 'POST',
      headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' },
      body,
    })
    if (r.ok) return
    if (r.status === 412) continue
    throw new Error('gcs write ' + r.status)
  }
  throw new Error('gcs write conflict')
}

// 本地模式：文件名把 / 换成 __（draws/0x….json → draws__0x….json）
const localFile = (name) => join(DEVDATA, name.replace(/\//g, '__'))

// export 便于本地 node -e 自测读写
export async function storeRead(name) {
  if (await useGcs()) return gcsGet(name)
  try { return JSON.parse(await readFile(localFile(name), 'utf8')) } catch { return null }
}

export async function storeWrite(name, obj) {
  if (await useGcs()) return gcsPut(name, obj)
  await mkdir(DEVDATA, { recursive: true })
  await writeFile(localFile(name), JSON.stringify(obj))
}

// 进程内互斥锁（按 key 串行化；GCS/本地模式都先过这把锁，把竞争压到最小）
const localLocks = new Map()
function withLock(key, fn) {
  const prev = localLocks.get(key) || Promise.resolve()
  const p = prev.then(fn, fn)
  localLocks.set(key, p.catch(() => {}))
  return p
}

// 原子变更：读 → fn(data) → 条件写。fn 返回 undefined = 放弃变更（调用方据此返回 409/401）；
// 写冲突（GCS 412）时重读并**重跑 fn**——fn 内必须重新校验业务条件（如额度），跨实例也安全。
async function mutateStore(name, fn) {
  return withLock('mut:' + name, async () => {
    if (await useGcs()) {
      const token = await gcsAccessToken()
      const enc = encodeURIComponent(name)
      for (let attempt = 0; attempt < 4; attempt++) {
        const meta = await fetch(`https://storage.googleapis.com/storage/v1/b/${PRIZE_BUCKET}/o/${enc}`, {
          headers: { authorization: 'Bearer ' + token },
        })
        let gen = '0'
        let data = null
        if (meta.ok) {
          gen = String((await meta.json()).generation)
          data = await gcsGet(name)
        } else if (meta.status !== 404) throw new Error('gcs meta ' + meta.status)
        const next = await fn(data)
        if (next === undefined) return { applied: false }
        const r = await fetch(`https://storage.googleapis.com/upload/storage/v1/b/${PRIZE_BUCKET}/o?uploadType=media&name=${enc}&ifGenerationMatch=${gen}`, {
          method: 'POST',
          headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' },
          body: JSON.stringify(next),
        })
        if (r.ok) return { applied: true, data: next }
        if (r.status === 412) continue
        throw new Error('gcs write ' + r.status)
      }
      throw new Error('gcs write conflict')
    }
    let data = null
    try { data = JSON.parse(await readFile(localFile(name), 'utf8')) } catch { /* 不存在视为空 */ }
    const next = await fn(data)
    if (next === undefined) return { applied: false }
    await mkdir(DEVDATA, { recursive: true })
    await writeFile(localFile(name), JSON.stringify(next))
    return { applied: true, data: next }
  })
}

// 奖品配置：不存在时用写死的默认配置
async function readPrizes() {
  const cfg = await storeRead('config/prizes.json').catch(() => null)
  if (cfg && Array.isArray(cfg.small) && Array.isArray(cfg.big)) return cfg
  return { ...DEFAULT_PRIZES, updatedAt: 0 }
}

// 钱包抽奖档案：{ draws: [...], bonus: { small, big } }（不存在视为空）
function normalizeDraws(raw) {
  const rec = raw && typeof raw === 'object' ? raw : {}
  if (!Array.isArray(rec.draws)) rec.draws = []
  if (!rec.bonus || typeof rec.bonus !== 'object') rec.bonus = {}
  return rec
}
async function readDraws(addr) {
  return normalizeDraws(await storeRead('draws/' + addr + '.json').catch(() => null))
}

// ---------- 连买 streak（从链上 TicketPurchased 事件推导） ----------
const STREAK_SMALL_DAYS = Number(process.env.STREAK_SMALL_DAYS || 7)
const STREAK_BIG_DAYS = Number(process.env.STREAK_BIG_DAYS || 14)
const STREAK_BIG_TICKETS = Number(process.env.STREAK_BIG_TICKETS || 500)
const blockTsCache = new Map() // 块时间戳缓存（块不可变，永久有效）
const DAY_MS = 86400000

async function computeStreak(pc, addrLower) {
  const created = BigInt(process.env.CONTRACT_CREATED || '115109533')
  const logs = await pc.getLogs({ address: CONTRACT, event: ticketEventAbi[0], args: { buyer: addrLower }, fromBlock: created, toBlock: 'latest' })
  // 同一批里相同块只取一次；分批并发（每批 20，避免 RPC 突发）
  const uniq = [...new Set(logs.map((lg) => lg.blockNumber))]
  const missing = uniq.filter((b) => !blockTsCache.has(b))
  for (let i = 0; i < missing.length; i += 20) {
    const batch = missing.slice(i, i + 20)
    const blocks = await Promise.all(batch.map((b) => pc.getBlock({ blockNumber: b })))
    blocks.forEach((blk, j) => blockTsCache.set(batch[j], Number(blk.timestamp)))
  }
  // 按 UTC 日聚合计票
  const byDay = new Map()
  for (const lg of logs) {
    const day = new Date(blockTsCache.get(lg.blockNumber) * 1000).toISOString().slice(0, 10)
    byDay.set(day, (byDay.get(day) || 0) + Number(lg.args.count))
  }
  // 从今天往前数连续有票的天数；今天没买从昨天起数（今天未结束不算断）
  const today = new Date().toISOString().slice(0, 10)
  let cursor = Date.parse(today + 'T00:00:00Z')
  if (!byDay.has(today)) cursor -= DAY_MS
  let streakDays = 0
  let streakStart = null
  while (byDay.has(new Date(cursor).toISOString().slice(0, 10))) {
    streakDays++
    streakStart = new Date(cursor).toISOString().slice(0, 10)
    cursor -= DAY_MS
  }
  return { streakDays, streakStart, ticketsByDay: byDay }
}

// small：每满 SMALL_DAYS 天 1 次；big：从 streakStart 起按 BIG_DAYS 分段，满段且段内票数达标 1 次
function computeEarned(streakDays, streakStart, ticketsByDay) {
  const small = Math.floor(streakDays / STREAK_SMALL_DAYS)
  let big = 0
  if (streakStart) {
    const startMs = Date.parse(streakStart + 'T00:00:00Z')
    const tomorrowMs = Date.parse(new Date().toISOString().slice(0, 10) + 'T00:00:00Z') + DAY_MS
    for (let seg = 0; ; seg++) {
      const segStart = startMs + seg * STREAK_BIG_DAYS * DAY_MS
      if (segStart + STREAK_BIG_DAYS * DAY_MS > tomorrowMs) break // 段未走满
      let tickets = 0
      for (let d = 0; d < STREAK_BIG_DAYS; d++) {
        const day = new Date(segStart + d * DAY_MS).toISOString().slice(0, 10)
        tickets += ticketsByDay.get(day) || 0
      }
      if (tickets >= STREAK_BIG_TICKETS) big++
    }
  }
  return { small, big }
}

// earned - used + bonus（used 只计本段 streakStart 内的抽取，下限 0）
function tierAvailable(earned, rec, tier, streakStart) {
  const used = rec.draws.filter((d) => d.tier === tier && d.streakStart === streakStart).length
  const available = Math.max(0, earned - used + (rec.bonus[tier] || 0))
  return { earned, used, available }
}

async function buildStreaks(addr) {
  const [st, rec, prizes] = await Promise.all([
    withFailover((pc) => computeStreak(pc, addr)),
    readDraws(addr),
    cached('prizes', 30000, () => readPrizes()),
  ])
  const earned = computeEarned(st.streakDays, st.streakStart, st.ticketsByDay)
  // 最近 BIG_DAYS 天（含今天往前）总票数
  let tickets14 = 0
  const todayMs = Date.parse(new Date().toISOString().slice(0, 10) + 'T00:00:00Z')
  for (let i = 0; i < STREAK_BIG_DAYS; i++) {
    const day = new Date(todayMs - i * DAY_MS).toISOString().slice(0, 10)
    tickets14 += st.ticketsByDay.get(day) || 0
  }
  const myDraws = [...rec.draws].sort((a, b) => b.ts - a.ts)
  return {
    streakDays: st.streakDays, streakStart: st.streakStart, tickets14,
    small: tierAvailable(earned.small, rec, 'small', st.streakStart),
    big: tierAvailable(earned.big, rec, 'big', st.streakStart),
    prizes: { small: prizes.small, big: prizes.big },
    myDraws,
    thresholds: { smallDays: STREAK_SMALL_DAYS, bigDays: STREAK_BIG_DAYS, bigTickets: STREAK_BIG_TICKETS },
  }
}

// 列出 draws/ 下全部对象名（GCS list / 本地 readdir），返回统一的对象名数组
async function listDrawNames() {
  if (await useGcs()) {
    const token = await gcsAccessToken()
    const r = await fetch(`https://storage.googleapis.com/storage/v1/b/${PRIZE_BUCKET}/o?prefix=draws/`, {
      headers: { authorization: 'Bearer ' + token },
    })
    if (!r.ok) throw new Error('gcs list ' + r.status)
    return ((await r.json()).items || []).map((it) => it.name)
  }
  await mkdir(DEVDATA, { recursive: true })
  return (await readdir(DEVDATA)).filter((f) => f.startsWith('draws__')).map((f) => 'draws/' + f.slice(7))
}

// 近期中奖播报：取最近修改的 20 个档案合并，按时间取前 10（地址短显、不带 id）
async function buildRecentDraws() {
  let names
  if (await useGcs()) {
    const token = await gcsAccessToken()
    const r = await fetch(`https://storage.googleapis.com/storage/v1/b/${PRIZE_BUCKET}/o?prefix=draws/`, {
      headers: { authorization: 'Bearer ' + token },
    })
    if (!r.ok) throw new Error('gcs list ' + r.status)
    // list 返回自带 updated 字段，取最近修改 top 20 再读内容
    names = ((await r.json()).items || [])
      .sort((a, b) => String(b.updated).localeCompare(String(a.updated)))
      .slice(0, 20)
      .map((it) => it.name)
  } else {
    const local = (await listDrawNames()).map((n) => localFile(n))
    const withM = await Promise.all(local.map(async (f) => ({ f, m: (await stat(f)).mtimeMs })))
    names = withM.sort((a, b) => b.m - a.m).slice(0, 20)
      .map((x) => 'draws/' + x.f.split(/[\\/]/).pop().slice(7))
  }
  const all = []
  for (const name of names) {
    const obj = await storeRead(name).catch(() => null)
    if (!obj || !Array.isArray(obj.draws)) continue
    const addr = name.replace(/^draws\//, '').replace(/\.json$/, '')
    for (const d of obj.draws) all.push({ addr, tier: d.tier, name: d.name, ts: d.ts })
  }
  return all
    .sort((a, b) => b.ts - a.ts)
    .slice(0, 10)
    .map((d) => ({ addr: d.addr.slice(0, 4) + '…' + d.addr.slice(-4), tier: d.tier, name: d.name, ts: d.ts }))
}

// 管理端全量 draws（含 addr、id、status，ts 倒序，上限 200）
async function listAllDraws() {
  const names = await listDrawNames()
  const all = []
  for (const name of names) {
    const obj = await storeRead(name).catch(() => null)
    if (!obj || !Array.isArray(obj.draws)) continue
    const addr = name.replace(/^draws\//, '').replace(/\.json$/, '')
    for (const d of obj.draws) all.push({ addr, ...d })
  }
  return all.sort((a, b) => b.ts - a.ts).slice(0, 200)
}

// POST body 解析（限 64KB；413/400 通过 err.http 传给外层统一响应）
function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0
    let tooLarge = false
    const chunks = []
    req.on('data', (c) => {
      size += c.length
      if (size > 65536) { tooLarge = true; chunks.length = 0; return }
      chunks.push(c)
    })
    req.on('end', () => {
      if (tooLarge) { const e = new Error('body too large'); e.http = 413; return reject(e) }
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')) } catch { const e = new Error('bad json'); e.http = 400; reject(e) }
    })
    req.on('error', reject)
  })
}

const ADDR_RE = /^0x[0-9a-f]{40}$/

// IP 滑动窗口限流（内存态，单实例足够；超限 429）
const rlBuckets = new Map()
function rateLimit(key, limit, windowMs) {
  const now = Date.now()
  const arr = (rlBuckets.get(key) || []).filter((t) => now - t < windowMs)
  if (arr.length >= limit) { rlBuckets.set(key, arr); return false }
  arr.push(now)
  rlBuckets.set(key, arr)
  if (rlBuckets.size > 10000) rlBuckets.clear() // 防内存膨胀（极端枚举时粗清）
  return true
}
const clientIp = (req) =>
  String(req.headers['x-forwarded-for'] || '').split(',')[0].trim() || req.socket.remoteAddress || 'unknown'

// 管理验签：恢复签名者 → 必须等于链上 admin()；ts 防陈旧（10 分钟窗口）+ 签名注册表防重放（48h 内同签名拒用）
async function checkAdmin(sig, message, ts) {
  const t = Number(ts)
  if (!Number.isFinite(t) || Math.abs(Date.now() - t) > 600000) return { code: 401, err: 'stale-sig' }
  let signer
  try { signer = await recoverMessageAddress({ message, signature: sig }) } catch { return { code: 401, err: 'bad-sig' } }
  const admin = await cached('admin', 300000, () => withFailover((pc) =>
    pc.readContract({ address: CONTRACT, abi: jackpotAbi, functionName: 'admin' })))
  if (signer.toLowerCase() !== String(admin).toLowerCase()) return { code: 403, err: 'not-admin' }
  const h = createHash('sha256').update(String(sig)).digest('hex')
  const res = await mutateStore('admin/used-sigs.json', (raw) => {
    const arr = raw && Array.isArray(raw.sigs) ? raw.sigs : []
    if (arr.some((x) => x && x.h === h)) return undefined
    const cutoff = Date.now() - 172800000
    return { sigs: [...arr.filter((x) => x && x.ts > cutoff), { h, ts: Date.now() }] }
  })
  if (!res.applied) return { code: 401, err: 'replay' }
  return { code: 200 }
}

// 加权抽取
function pickPrize(list) {
  const totalWeight = list.reduce((s, p) => s + p.weight, 0)
  if (totalWeight <= 0) return -1
  let roll = randomInt(0, totalWeight)
  for (let i = 0; i < list.length; i++) {
    roll -= list[i].weight
    if (roll < 0) return i
  }
  return list.length - 1
}

// ---------- HTTP ----------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost')
  // 裸域 → www（裸域仅 IPv6 解析，www 有 IPv4，统一入口）
  const host = (req.headers.host || '').toLowerCase()
  if (host === 'jackpothood.com' && url.pathname !== '/__keeper') {
    res.writeHead(301, { location: 'https://www.jackpothood.com' + url.pathname + url.search })
    return res.end()
  }
  const json = (code, obj) => { res.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store' }); res.end(JSON.stringify(obj)) }
  try {
    if (url.pathname === '/__keeper') {
      const result = await runDrawJob()
      return json(200, { ok: true, result, lastRun })
    }
    if (url.pathname === '/health' || url.pathname === '/healthz') {
      return json(200, { ok: true, lastRun, lastResult })
    }
    if (url.pathname === '/api/state') {
      const val = await cached('state', TTL.state, () => withFailover((pc) => buildState(pc)))
      return json(val.ok ? 200 : 503, val)
    }
    if (url.pathname === '/api/mytickets') {
      const addr = (url.searchParams.get('addr') || '').toLowerCase()
      const val = await cached('mt-' + addr, TTL.mytickets, () => withFailover((pc) => buildMyTickets(pc, addr)))
      return json(val.ok ? 200 : 400, val)
    }
    // 单轮查询（hero 前后翻页用）：已结算轮次不可变，5s 缓存即可
    if (url.pathname === '/api/round') {
      const id = url.searchParams.get('id') || ''
      if (!/^\d+$/.test(id) || Number(id) < 1) return json(400, { ok: false, reason: 'bad-id' })
      const val = await cached('r-' + id, TTL.state, () => withFailover(async (pc) => {
        const r = await readRound(pc, CONTRACT, BigInt(id))
        return { ok: true, round: roundJson(r) }
      }))
      return json(200, val)
    }
    // 三榜聚合：全历史事件扫描，60s 缓存；扫描失败抛错 → 500
    if (url.pathname === '/api/leaderboard') {
      const val = await cached('board', TTL.board, () => withFailover((pc) => buildLeaderboard(pc)))
      return json(val.ok ? 200 : 503, val)
    }
    // 单用户聚合：与 mytickets 同 TTL，按地址缓存
    if (url.pathname === '/api/me') {
      const addr = (url.searchParams.get('addr') || '').toLowerCase()
      if (!/^0x[0-9a-fA-F]{40}$/.test(addr)) return json(400, { ok: false, reason: 'bad-address' })
      const val = await cached('me-' + addr, TTL.mytickets, () => withFailover((pc) => buildMe(pc, addr)))
      return json(val.ok ? 200 : 400, val)
    }
    // ---------- 连买充能抽奖 ----------
    // 连买天数 / 可抽次数 / 奖品配置 / 我的战绩
    if (url.pathname === '/api/streaks') {
      const addr = (url.searchParams.get('addr') || '').toLowerCase()
      if (!ADDR_RE.test(addr)) return json(400, { error: 'bad-address' })
      if (!rateLimit('stk:' + clientIp(req), 30, 60000)) return json(429, { error: 'rate-limited' })
      const val = await cached('stk-' + addr, 8000, () => buildStreaks(addr))
      return json(200, val)
    }
    // 近期中奖播报（60s 缓存）
    if (url.pathname === '/api/draws/recent') {
      if (!rateLimit('rc:' + clientIp(req), 60, 60000)) return json(429, { error: 'rate-limited' })
      const val = await cached('recent-draws', 60000, () => buildRecentDraws())
      return json(200, val)
    }
    // 抽奖：限流 → 重算 streak（不信缓存）→ 验签 → 原子变更内重校额度 + 落档（写冲突重读重校，杜绝并发双抽）
    if (url.pathname === '/api/draw' && req.method === 'POST') {
      if (!rateLimit('draw:' + clientIp(req), 10, 60000)) return json(429, { error: 'rate-limited' })
      const body = await readBody(req)
      const addr = String(body.addr || '').toLowerCase()
      const tier = body.tier
      if (!ADDR_RE.test(addr) || (tier !== 'small' && tier !== 'big')) return json(400, { error: 'bad-request' })
      const st = await withFailover((pc) => computeStreak(pc, addr))
      const earned = computeEarned(st.streakDays, st.streakStart, st.ticketsByDay)
      const message = 'JackpotHood 抽奖授权\n地址:' + addr + '\n档位:' + tier + '\n周期:' + (st.streakStart || 'none')
      const okSig = await verifyMessage({ address: addr, message, signature: body.sig }).catch(() => false)
      if (!okSig) return json(401, { error: 'bad-sig' })
      const prizes = await readPrizes()
      let entry = null
      const res = await mutateStore('draws/' + addr + '.json', (raw) => {
        const rec = normalizeDraws(raw)
        const { available, used } = tierAvailable(earned[tier], rec, tier, st.streakStart)
        if (available < 1) return undefined // 额度没了（含并发写冲突重读后）→ 放弃
        if (earned[tier] - used < 1) rec.bonus[tier] = (rec.bonus[tier] || 0) - 1 // 本段产出已用尽 → 消耗 bonus（防跨周期复活）
        const prizeIndex = pickPrize(prizes[tier])
        if (prizeIndex < 0) throw new Error('no-prizes')
        entry = { id: randomUUID(), tier, prizeIndex, name: prizes[tier][prizeIndex].name, ts: Date.now(), streakStart: st.streakStart, status: 'won' }
        rec.draws.push(entry)
        return rec
      })
      if (!res.applied) return json(409, { error: 'sold_out' })
      cache.delete('stk-' + addr)
      return json(200, { ok: true, prize: { index: entry.prizeIndex, name: entry.name }, id: entry.id })
    }
    // 领奖登记：won → claimed
    if (url.pathname === '/api/draws/claim' && req.method === 'POST') {
      const body = await readBody(req)
      const addr = String(body.addr || '').toLowerCase()
      const id = String(body.id || '')
      if (!ADDR_RE.test(addr) || !id) return json(400, { error: 'bad-request' })
      const okSig = await verifyMessage({ address: addr, message: 'JackpotHood 领奖登记\n' + id, signature: body.sig }).catch(() => false)
      if (!okSig) return json(401, { error: 'bad-sig' })
      const rec = await readDraws(addr)
      const d = rec.draws.find((x) => x.id === id)
      if (!d) return json(404, { error: 'not-found' })
      if (d.status !== 'won') return json(409, { error: 'bad-status' })
      d.status = 'claimed'
      await storeWrite('draws/' + addr + '.json', rec)
      return json(200, { ok: true })
    }
    // ---------- 管理（签名者必须 == 链上 admin()） ----------
    // 更新奖品配置（消息带 ts：10 分钟有效 + 签名防重放）
    if (url.pathname === '/api/admin/prizes' && req.method === 'POST') {
      const body = await readBody(req)
      const sha = createHash('sha256').update(JSON.stringify(body.config)).digest('hex')
      const chk = await checkAdmin(body.sig, 'JackpotHood 管理操作\nprizes\n' + sha + '\n' + body.ts, body.ts)
      if (chk.code !== 200) return json(chk.code, { error: chk.err || 'denied' })
      const cfg = body.config
      const validTier = (arr) => Array.isArray(arr) && arr.length === 6 && arr.every((p) =>
        p && typeof p.name === 'string' && p.name.length > 0 && p.name.length <= 40 &&
        Number.isInteger(p.weight) && p.weight >= 0 && p.weight <= 10000)
      if (!cfg || !validTier(cfg.small) || !validTier(cfg.big)) return json(400, { error: 'bad-config' })
      await storeWrite('config/prizes.json', { small: cfg.small, big: cfg.big, updatedAt: Date.now() })
      cache.delete('prizes')
      return json(200, { ok: true })
    }
    // 全量抽奖记录（只读，消息按今日 UTC 日期，不入签名注册表）
    if (url.pathname === '/api/admin/draws' && req.method === 'POST') {
      const body = await readBody(req)
      const day = new Date().toISOString().slice(0, 10)
      const chk = await checkAdmin(body.sig, 'JackpotHood 管理操作\ndraws\n' + day + '\n' + body.ts, body.ts)
      if (chk.code !== 200) return json(chk.code, { error: chk.err || 'denied' })
      return json(200, { ok: true, draws: await listAllDraws() })
    }
    // 发货：claimed → fulfilled（won 也允许直接 fulfill）；原子变更内重找记录
    if (url.pathname === '/api/admin/fulfill' && req.method === 'POST') {
      const body = await readBody(req)
      const addr = String(body.addr || '').toLowerCase()
      const id = String(body.id || '')
      if (!ADDR_RE.test(addr) || !id) return json(400, { error: 'bad-request' })
      const chk = await checkAdmin(body.sig, 'JackpotHood 管理操作\nfulfill\n' + id + '\n' + body.ts, body.ts)
      if (chk.code !== 200) return json(chk.code, { error: chk.err || 'denied' })
      let status = 404
      const res = await mutateStore('draws/' + addr + '.json', (raw) => {
        const rec = normalizeDraws(raw)
        const d = rec.draws.find((x) => x.id === id)
        if (!d) return undefined
        if (d.status !== 'claimed' && d.status !== 'won') { status = 409; return undefined }
        d.status = 'fulfilled'
        return rec
      })
      if (!res.applied) return json(status, { error: status === 409 ? 'bad-status' : 'not-found' })
      return json(200, { ok: true })
    }
    // 补发次数：bonus[tier] += 1（原子变更，消息带 ts 防重放——同签名第二次直接 401）
    if (url.pathname === '/api/admin/grant' && req.method === 'POST') {
      const body = await readBody(req)
      const addr = String(body.addr || '').toLowerCase()
      const tier = body.tier
      if (!ADDR_RE.test(addr) || (tier !== 'small' && tier !== 'big')) return json(400, { error: 'bad-request' })
      const chk = await checkAdmin(body.sig, 'JackpotHood 管理操作\ngrant\n' + addr + '\n' + tier + '\n' + body.ts, body.ts)
      if (chk.code !== 200) return json(chk.code, { error: chk.err || 'denied' })
      const res = await mutateStore('draws/' + addr + '.json', (raw) => {
        const rec = normalizeDraws(raw)
        rec.bonus[tier] = (rec.bonus[tier] || 0) + 1
        return rec
      })
      cache.delete('stk-' + addr)
      return json(200, { ok: true, bonus: res.data.bonus })
    }
    await serveStatic(req, res, url.pathname)
  } catch (e) {
    json((e && e.http) || 500, { ok: false, error: String(e && e.message || e) })
  }
})

const PORT = Number(process.env.PORT || 8080)
server.listen(PORT, () => console.log('jackpothood server on :' + PORT))
