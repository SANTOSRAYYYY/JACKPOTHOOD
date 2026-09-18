import { useEffect, useMemo, useRef, useState } from 'react'
import {
  createPublicClient,
  createWalletClient,
  custom,
  http,
  formatUnits,
  isAddress,
  toHex,
} from 'viem'
import { usePrivy, useWallets, useCreateWallet, useConnectWallet } from '@privy-io/react-auth'
import { rhChain, JACKPOT_ADDRESS, PERKS_ADDRESS, JACKPOT_CREATED, JPH_DECIMALS, IS_TESTNET, FAUCET_URL } from './config.js'
import { jackpotAbi, perksAbi } from './abi.js'
import RulesPage from './RulesPage.jsx'
import DrawsPage from './DrawsPage.jsx'
import TokenPage from './TokenPage.jsx'
import AdminPage from './AdminPage.jsx'
import NftPage from './NftPage.jsx'
import StakePage from './StakePage.jsx'
import ProfilePage from './ProfilePage.jsx'
import RanksPage from './RanksPage.jsx'
import CalcPage from './CalcPage.jsx'
import PresalePage from './PresalePage.jsx'
import LangSwitcher from './LangSwitcher.jsx'
import WalletMenu from './WalletMenu.jsx'
import { useI18n } from './i18n.js'

const TIER_SHARES = ['40%', '25%', '15%', '12%', '5%', '3%']
const NO_ADDRESS = '0x0000000000000000000000000000000000000000'
// 合约免费票哨兵：gifter 为此值时表示管理员零成本出票
const FREE_SENTINEL = '0x000000000000000000000000000000000000dEaD'
// 实物奖领奖客服入口（与页脚 Telegram 同一链接）
const TG_URL = 'https://t.me/jackpothood'

function unpackNumbers(packed) {
  packed = BigInt(packed)
  return [0, 1, 2, 3, 4, 5].map((i) => Number((packed >> BigInt(8 * i)) & 0xffn))
}

function tierOf(ticketNumbers, winningNumbers) {
  let matched = 0
  for (let i = 5; i >= 0; i--) {
    if (ticketNumbers[i] !== winningNumbers[i]) break
    matched++
  }
  return matched >= 1 ? 6 - matched : 6
}

// 连续后缀命中位数（中奖判定从末位向前；只有这个后缀段才该高亮，中间零散命中不算）
function suffixMatches(nums, win) {
  let k = 0
  for (let i = 5; i >= 0 && nums[i] === win[i]; i--) k++
  return k
}

function fmtJph(v) {
  const s = formatUnits(v, JPH_DECIMALS)
  const [a, b = ''] = s.split('.')
  return `${Number(a).toLocaleString('en-US')}.${(b + '0000').slice(0, 2)}`
}

function fmtEth(v) {
  return formatUnits(v, 18)
}

// 展示用小数（常规 2 位；非零小额自动升到 4 位，避免把 0.0003 显示成 "0"）
function fmtEthShort(v) {
  const n = Number(formatUnits(v, 18))
  const n2 = Math.round(n * 100) / 100
  if (n === 0 || Math.abs(n2) >= 0.01) return n2.toString()
  return (Math.round(n * 10000) / 10000).toString()
}

// 期次奖池真值 = 六档奖池之和（= 票款奖池 + 结算时质押快照，与用户口径「滚存+质押」一致）；
// 未结算/已作废期回退为 prizePool
function poolOf(r) {
  if (!r) return 0n
  try {
    const s = r.tierPots.reduce((a, b) => a + BigInt(b), 0n)
    if (s > 0n) return s
  } catch { /* 字段缺失时回退 */ }
  return BigInt(r.prizePool || 0n)
}

function fmtCountdown(sec) {
  if (sec <= 0) return '00:00:00'
  const h = Math.floor(sec / 3600)
  const m = Math.floor((sec % 3600) / 60)
  const s = Math.floor(sec % 60)
  return [h, m, s].map((x) => String(x).padStart(2, '0')).join(':')
}

function fmtUtc(ts) {
  return new Date(Number(ts) * 1000).toISOString().replace('T', ' ').slice(0, 16) + ' UTC'
}

function quickPick() {
  return Array.from({ length: 6 }, () => Math.floor(Math.random() * 10))
}

export default function App() {
  const [path, setPath] = useState(() => window.location.pathname)

  useEffect(() => {
    const onNav = () => setPath(window.location.pathname)
    window.addEventListener('popstate', onNav)
    return () => window.removeEventListener('popstate', onNav)
  }, [])

  if (path.startsWith('/rules')) return <RulesPage />
  if (path.startsWith('/history')) return <DrawsPage />
  if (path.startsWith('/token')) return <TokenPage />
  if (path.startsWith('/me')) return <ProfilePage />
  if (path.startsWith('/calc')) return <CalcPage />
  if (path.startsWith('/ranks')) return <RanksPage />
  if (path.startsWith('/admin')) return <AdminPage />
  if (path.startsWith('/nft')) return <NftPage />
  if (path.startsWith('/presale')) return <PresalePage />
  if (path.startsWith('/stake')) return <StakePage />

  return <MainApp />
}

function MainApp() {
  const { t, tr, lang } = useI18n()
  const { ready, authenticated, login, logout, user } = usePrivy()
  const { createWallet } = useCreateWallet()
  const { connectWallet } = useConnectWallet()
  const { wallets } = useWallets()
  // 用户显式选择钱包：默认「最近连接」的以太坊钱包，选择结果存 localStorage
  const ethWallets = wallets.filter((w) => w.type === 'ethereum')
  const [activeAddr, setActiveAddr] = useState(() => {
    try { return localStorage.getItem('jh_wallet') || '' } catch { return '' }
  })
  const savedWallet = ethWallets.find((w) => w.address.toLowerCase() === activeAddr.toLowerCase())
  const wallet = savedWallet
    || [...ethWallets].sort((a, b) => Number(b.connectedAt) - Number(a.connectedAt))[0]
    || null
  const account = wallet?.address ?? null

  const selectWallet = (addr) => {
    setActiveAddr(addr)
    try { localStorage.setItem('jh_wallet', addr) } catch { /* ignore */ }
    setMyTickets([])
    setClaimable([])
    myTicketsRef.current = []
    refresh()
  }

  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000))
  const [round, setRound] = useState(null)
  const [roundId, setRoundId] = useState(0n)
  const [ticketPrice, setTicketPrice] = useState(0n)
  const [paused, setPaused] = useState(false)
  const [pendingRollover, setPendingRollover] = useState(0n)
  const [history, setHistory] = useState([])
  const [myTickets, setMyTickets] = useState([])
  const [claimable, setClaimable] = useState([])
  const [myCredits, setMyCredits] = useState(0n) // 免费票额度余额
  const [roundFreeMinted, setRoundFreeMinted] = useState(0n) // 当期已免费出票注数（限额提示用）
  const [jphStakedAmt, setJphStakedAmt] = useState(0n) // 已质押 JPH
  const [perkToday, setPerkToday] = useState(0n) // JPH 质押每日增速（张/天）
  const [perkBanked, setPerkBanked] = useState(0n) // JPH 质押已存免费票余额
  const [stakingPoolAmt, setStakingPoolAmt] = useState(0n) // 质押分红池未分配余额
  const [poolAssets, setPoolAssets] = useState({ prize: 0n, stake: 0n }) // 票款池 + 质押储备
  const [freeNums, setFreeNums] = useState(() => quickPick()) // 免费额度领用时自选号码
  const [freeCount, setFreeCount] = useState(1)
  const makeTicket = () => ({ nums: quickPick(), id: 't' + Math.random().toString(36).slice(2, 8) })
  const [tickets, setTickets] = useState(() => [makeTicket()])
  const [enterId, setEnterId] = useState(null) // 单行新增购票行的入场动画目标（票 id）
  const [bulkSeq, setBulkSeq] = useState(0) // 一键快买批次号：变化时 ticket-list 整体淡入（不给每行加动画）
  const [perTicket, setPerTicket] = useState(1)
  const [bulkN, setBulkN] = useState(10)
  const [editingId, setEditingId] = useState(null) // 正在编辑号码的票（⋮ 展开）
  const [showAllTickets, setShowAllTickets] = useState(false) // 大批量购票时默认只渲染前 30 行防卡顿
  const [giftMode, setGiftMode] = useState(false)
  const [giftRecipient, setGiftRecipient] = useState('')
  const [busy, setBusy] = useState('')
  const [msg, setMsg] = useState(null)
  const [pendingRef, setPendingRef] = useState(null) // ?ref= from URL
  const [onchainReferrer, setOnchainReferrer] = useState(null)
  const [scanFloor, setScanFloor] = useState(0) // 已扫描的最老期次（0=未初始化；翻页水位）
  const [watchdog, setWatchdog] = useState(null) // 到点未开/已承诺未结算的期次：{ id, action }（免许可一键开奖）
  const [winFeed, setWinFeed] = useState([]) // 中奖播报条：链上 PrizeClaimed 事件（真实中奖人）
  const [readyTimeout, setReadyTimeout] = useState(false)
  const myTicketsRef = useRef([])
  const initializedRef = useRef(false)
  const apiOkAtRef = useRef(0) // /api/state 最近成功时刻；健康时直连链兜底让路
  const accountRef = useRef(null) // 供 8s 轮询读取当前钱包（规避闭包过期）
  const mtKeyRef = useRef('') // 我的票据刷新水位："轮次:状态"
  const mtPollRef = useRef(0) // 轮询计数（每 4 次心跳强制刷一次票据）
  const [expandedTickets, setExpandedTickets] = useState({}) // 我的彩票：按期折叠/展开
  const [viewOffset, setViewOffset] = useState(0) // hero 翻页：0=当前期，负数=历史期，+1=下一期（预售）
  const [viewRoundData, setViewRoundData] = useState(null) // 翻页目标期链上数据（/api/round，已 BigInt 化）
  const [stkTick, setStkTick] = useState(0) // 购票成功后 +1：充能电池卡立即刷新一次

  const configured = JACKPOT_ADDRESS !== NO_ADDRESS
  const tierNames = tr('tierNames')
  const chipLabel = (status) => t(['chipOpen', 'chipDrawing', 'chipSettled', 'chipCancelled'][status])

  useEffect(() => {
    document.title = t('siteTitle')
  }, [lang, t])

  const publicClient = useMemo(
    () => createPublicClient({ chain: rhChain, transport: http() }),
    [],
  )

  useEffect(() => {
    const timer = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000)
    return () => clearInterval(timer)
  }, [])

  // Capture ?ref= from the share link once.
  useEffect(() => {
    const ref = new URLSearchParams(window.location.search).get('ref')
    if (ref && isAddress(ref)) {
      localStorage.setItem('jh_referrer', ref)
      setPendingRef(ref)
      window.history.replaceState({}, '', window.location.pathname)
    } else if (localStorage.getItem('jh_referrer')) {
      setPendingRef(localStorage.getItem('jh_referrer'))
    }
  }, [])

  // 扫描一段期次区间：开奖历史 + 我的票据 + 可兑奖（仅限兑奖期内）
  const scanRounds = async (fromId, count, accountAddr) => {
    const hist = []
    const mine = []
    const claims = []
    for (let id = fromId; id >= Math.max(1, fromId - count + 1); id--) {
      const r = await publicClient.readContract({
        address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'getRound', args: [BigInt(id)],
      })
      if (r.drawAt === 0n) continue
      const isDrawn = Number(r.status) === 2
      if (isDrawn) hist.push({ id, round: r, winning: unpackNumbers(r.winningPacked) })
      if (accountAddr) {
        const tickets = await publicClient.readContract({
          address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'getUserTickets',
          args: [BigInt(id), accountAddr],
        })
        if (tickets.length > 0) {
          mine.push({ roundId: id, status: Number(r.status), winning: isDrawn ? unpackNumbers(r.winningPacked) : null, tickets })
          if (isDrawn && Number(r.claimDeadline) >= Math.floor(Date.now() / 1000)) {
            const [due, indices] = await publicClient.readContract({
              address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'previewClaim',
              args: [BigInt(id), accountAddr],
            })
            if (due > 0n) claims.push({ roundId: id, due, indices })
          }
        }
      }
    }
    return { hist, mine, claims }
  }

  const loadMore = async () => {
    if (scanFloor <= 1) return
    const from = scanFloor - 1
    const count = Math.min(10, from)
    const res = await scanRounds(from, count, account)
    // 只翻历史开奖（去重追加）；我的票据/可兑奖由 /api/mytickets 全历史拥有，不在此追加
    if (res.hist.length > 0) {
      setHistory((prev) => {
        const ids = new Set(prev.map((h) => h.id))
        return [...prev, ...res.hist.filter((h) => !ids.has(h.id))]
      })
    }
    setScanFloor(Math.max(1, from - count + 1))
  }


  // 高频公共数据走服务端聚合 API（并发优化：同源 /api/state，服务端 5s 缓存 + 多 RPC）
  useEffect(() => {
    if (!configured) return
    const load = async () => {
      try {
        const res = await fetch('/api/state', { headers: { accept: 'application/json' } })
        if (!res.ok) return
        const d = await res.json()
        if (!d.ok) return
        apiOkAtRef.current = Date.now()
        // 历史翻页水位初始化（API 模式下 refresh 的直连初扫不再执行，需在此建水位）
        setScanFloor((prev) => (prev === 0 ? Math.max(1, Number(d.roundId) - 4) : prev))
        const rb = apiRoundToBig(d.round)
        setRoundId(BigInt(d.roundId))
        setRound(rb)
        setPaused(d.paused)
        setPoolAssets({ prize: BigInt(d.assets.prize), stake: BigInt(d.assets.stake) })
        if (d.ticketPrice) setTicketPrice(BigInt(d.ticketPrice))
        if (d.rollover) setPendingRollover(BigInt(d.rollover))
        if (d.stakePool) setStakingPoolAmt(BigInt(d.stakePool))
        if (d.history && d.history.length > 0) {
          // 合并而非整体替换：保留「加载更多」翻出来的更早期次（修复每 8s 被覆盖回 4 条的闪烁/错乱）
          const fresh = d.history.map((h) => ({ id: h.id, round: apiRoundToBig(h.round), winning: unpackNumbers(h.round.winningPacked) }))
          setHistory((prev) => {
            const ids = new Set(fresh.map((h) => h.id))
            return [...fresh, ...prev.filter((h) => !ids.has(h.id))]
          })
        }
        if (d.feed && d.feed.length > 0) {
          setWinFeed(d.feed.map((f) => ({ id: f.roundId + '-' + f.user, roundId: f.roundId, user: f.user, amount: BigInt(f.amount) })))
        }
        // 看门狗：当前轮到点未开时提示（settle 由 keeper/快照自动完成；已承诺超 3 分钟未结算也提示）
        const nowS = Math.floor(Date.now() / 1000)
        if (Number(rb.status) === 0 && nowS >= Number(rb.drawAt)) {
          setWatchdog({ id: Number(d.roundId), action: 'commit' })
        } else if (Number(rb.status) === 1 && Number(rb.randomBlock) > 0 && nowS >= Number(rb.drawAt) + 180) {
          setWatchdog({ id: Number(d.roundId), action: 'settle' })
        } else {
          setWatchdog(null)
        }
        // 账号票据/中奖结果自动刷新：轮次或状态变化时立即拉，外加每 4 次轮询一次心跳
        const acc = accountRef.current
        if (acc) {
          const key = `${d.roundId}:${rb.status}`
          mtPollRef.current += 1
          if (key !== mtKeyRef.current || mtPollRef.current % 4 === 0) {
            mtKeyRef.current = key
            loadMyTickets(acc).catch(() => {})
          }
        }
      } catch { /* API 不可用（本地开发/旧部署）→ 保持直连轮询 */ }
    }
    load()
    const timer = setInterval(load, 8000)
    return () => clearInterval(timer)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [configured])

  useEffect(() => {
    myTicketsRef.current = myTickets
  }, [myTickets])

  useEffect(() => {
    accountRef.current = account
  }, [account])

  // 期号前进时回到当前期视图（注意：依赖用 Number 化后的值，BigInt 每次轮询都是新对象）
  const roundNum = Number(roundId)
  useEffect(() => {
    setViewOffset(0)
  }, [roundNum])

  // hero 翻页：拉取目标期数据（/api/round；未来期未创建时 drawAt=0，前端按周期估算展示）
  useEffect(() => {
    if (!configured || viewOffset === 0) { setViewRoundData(null); return }
    const id = roundNum + viewOffset
    if (id < 1) { setViewRoundData(null); return }
    let cancelled = false
    setViewRoundData(null)
    fetch(`/api/round?id=${id}`, { headers: { accept: 'application/json' } })
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => { if (!cancelled) setViewRoundData(d && d.ok ? apiRoundToBig(d.round) : null) })
      .catch(() => { if (!cancelled) setViewRoundData(null) })
    return () => { cancelled = true }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [viewOffset, roundNum, configured])

  // 从服务端聚合接口拉取我的票据 + 可兑奖（浏览器不再直连 RPC 逐轮扫）；
  // 开奖后轮次状态一变即触发，中奖结果自动出现，无需手动刷新
  const loadMyTickets = async (acc) => {
    const res = await fetch(`/api/mytickets?addr=${acc}`, { headers: { accept: 'application/json' } })
    if (!res.ok) return
    const d = await res.json()
    if (!d.ok) return
    const rows = d.rounds.map((r) => ({
      roundId: r.roundId,
      status: r.status,
      winning: r.status === 2 ? unpackNumbers(r.winningPacked) : null,
      claimDue: r.claimDue, // 可领金额必须带入映射——否则下方 filter 永远为空（领奖横幅不显示的根因）
      claimIndices: r.claimIndices,
      tickets: r.tickets.map((x) => ({
        numbersPacked: BigInt(x.numbersPacked), count: BigInt(x.count),
        gifter: x.gifter, claimed: x.claimed, refunded: x.refunded,
      })),
    }))
    // 服务端返回全历史（事件扫描），直接替换；可领列表同样全量覆盖——老期次中奖不再漏
    setMyTickets(rows)
    setClaimable(rows.filter((r) => r.claimDue && BigInt(r.claimDue) > 0n)
      .map((r) => ({ roundId: r.roundId, due: BigInt(r.claimDue), indices: r.claimIndices })))
  }



// 将 /api/state 返回的轮次对象（字符串字段）转为大整数结构
function apiRoundToBig(r) {
  return {
    salesEnd: BigInt(r.salesEnd), drawAt: BigInt(r.drawAt), randomBlock: BigInt(r.randomBlock),
    claimDeadline: BigInt(r.claimDeadline), prizePool: BigInt(r.prizePool),
    totalTickets: BigInt(r.totalTickets), ticketRevenue: BigInt(r.ticketRevenue),
    ticketFee: BigInt(r.ticketFee), winningPacked: BigInt(r.winningPacked),
    commitHash: r.commitHash, seedHash: r.seedHash,
    tierPots: r.tierPots.map((x) => BigInt(x)), tierUnits: r.tierUnits.map((x) => BigInt(x)),
    tierClaimed: r.tierClaimed.map((x) => BigInt(x)), swept: r.swept, status: Number(r.status),
  }
}

  const refresh = async () => {
    if (!configured) return
    try {
      // /api/state 健康（30s 内有成功响应）时，公共数据由服务端聚合+缓存提供，
      // 跳过直连链的重复读取（看门狗扫描与全历史日志扫描对远端 RPC 尤其慢）
      const apiFresh = Date.now() - apiOkAtRef.current < 30000
      let rid = roundId
      let cur = round
      if (!apiFresh) {
        const [rid0, price, rollover, stakePool, cur0, isPaused, assets] = await Promise.all([
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'currentRoundId' }),
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'TICKET_PRICE' }),
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'pendingRollover' }),
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'stakingPool' }).catch(() => 0n),
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'getCurrentRound' }),
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'paused' }),
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'totalPoolAssets' }).catch(() => [0n, 0n]),
        ])
        rid = rid0
        cur = cur0
        setRoundId(rid0)
        setTicketPrice(price)
        setPendingRollover(rollover)
        setStakingPoolAmt(stakePool)
        setPaused(isPaused)
        setRound(cur0)
        setPoolAssets({ prize: assets[0] || 0n, stake: assets[1] || 0n })

        // 开奖看门狗：扫描近期期次，找出「到点未开 / 已承诺未结算」的期次（免许可，任何用户可一键触发）
        const bn = await publicClient.getBlockNumber()
        const nowS = Math.floor(Date.now() / 1000)
        let wd = null
        for (let id = Number(rid0); id >= Math.max(1, Number(rid0) - 4); id--) {
          const rr = await publicClient.readContract({
            address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'getRound', args: [BigInt(id)],
          })
          if (rr.drawAt === 0n) continue
          if (Number(rr.status) === 0 && nowS >= Number(rr.drawAt)) { wd = { id, action: 'commit' }; break }
          if (Number(rr.status) === 1 && bn > rr.randomBlock) { wd = { id, action: 'settle' }; break }
        }
        setWatchdog(wd)

        // 中奖播报：扫描链上兑奖事件（真实中奖人 + 金额，公示透明）
        try {
          const claimEvent = jackpotAbi.find((a) => a.type === 'event' && a.name === 'PrizeClaimed')
          const claimLogs = await publicClient.getLogs({
            address: JACKPOT_ADDRESS,
            event: claimEvent,
            fromBlock: JACKPOT_CREATED,
            toBlock: 'latest',
          })
          const feed = claimLogs
            .filter((lg) => lg.args && lg.args.amount > 0n)
            .map((lg) => ({
              id: `${lg.blockNumber}-${lg.logIndex}`,
              roundId: Number(lg.args.roundId),
              user: lg.args.user,
              amount: lg.args.amount,
            }))
            .sort((a, b) => b.roundId - a.roundId || Number(b.id.split('-')[0]) - Number(a.id.split('-')[0]))
          setWinFeed(feed)
        } catch { /* 播报条拉取失败不影响主流程 */ }
      }
      if (!rid || !cur) return

      if (!apiFresh && scanFloor === 0) {
        // 初次加载（仅直连兜底模式）：扫描最近 5 期 + 建立翻页水位
        const from = Number(rid) - 1
        const res = await scanRounds(from, 5, account)
        setHistory(res.hist)
        setMyTickets(res.mine)
        setClaimable(res.claims)
        setScanFloor(Math.max(1, from - 4))
      }
      if (account) {
        // 当前期票据即时同步（买票/领票/领奖后立刻可见）
        const curTickets = await publicClient.readContract({
          address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'getUserTickets',
          args: [rid, account],
        }).catch(() => null)
        let combined = null
        if (curTickets) {
          const others = myTicketsRef.current.filter((m) => m.roundId !== Number(rid))
          combined = curTickets.length > 0
            ? [{ roundId: Number(rid), status: Number(cur.status), winning: null, tickets: curTickets }, ...others]
            : others
          setMyTickets(combined)
        }
        if (!apiFresh && combined) {
          // API 不可用时直连重算可兑奖；API 健康时由 loadMyTickets（全历史事件扫描）拥有，不在此覆盖
          const claims = []
          for (const m of combined) {
            if (m.status === 2) {
              try {
                const [due, indices] = await publicClient.readContract({
                  address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'previewClaim',
                  args: [BigInt(m.roundId), account],
                })
                if (due > 0n) claims.push({ roundId: m.roundId, due, indices })
              } catch { /* 单期失败跳过 */ }
            }
          }
          setClaimable(claims)
        }
      }

      if (account) {
        const [referrer, credits, freeMintedNow, jphStakedAmt, perkToday, perkBanked] = await Promise.all([
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'getReferrer', args: [account] }),
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'freeCredits', args: [account] }),
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'freeMinted', args: [rid] }),
          publicClient.readContract({ address: PERKS_ADDRESS, abi: perksAbi, functionName: 'jphStaked', args: [account] }).catch(() => 0n),
          publicClient.readContract({ address: PERKS_ADDRESS, abi: perksAbi, functionName: 'jphPerkPerDay', args: [account] }).catch(() => 0n),
          publicClient.readContract({ address: PERKS_ADDRESS, abi: perksAbi, functionName: 'perkBalance', args: [account] }).catch(() => 0n),
        ])
        setOnchainReferrer(referrer)
        setMyCredits(credits)
        setRoundFreeMinted(freeMintedNow)
        setJphStakedAmt(jphStakedAmt)
        setPerkToday(perkToday)
        setPerkBanked(perkBanked)
      }
    } catch (e) {
      setMsg({ type: 'error', text: t('readFailed', { msg: e.shortMessage || e.message }) })
    }
  }

  useEffect(() => {
    if (ready) return
    const timer = setTimeout(() => setReadyTimeout(true), 15000)
    return () => clearTimeout(timer)
  }, [ready])

  useEffect(() => {
    if (ready && !initializedRef.current) {
      initializedRef.current = true
      refresh()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, authenticated, wallet?.address])

  // 15s 兜底直连轮询：经 ref 始终调最新 refresh（旧写法闭包过期——interval 里 account/期号/水位永远停在初始值，
  // 导致扫描结果覆盖掉 API 全历史的可兑奖列表，领奖横幅被误清空）
  const refreshRef = useRef(refresh)
  useEffect(() => { refreshRef.current = refresh })
  useEffect(() => {
    if (!ready) return
    const timer = setInterval(() => refreshRef.current(), 15000)
    return () => clearInterval(timer)
  }, [ready])

  async function getWalletClient() {
    if (!wallet || typeof wallet.getEthereumProvider !== 'function') {
      throw new Error(t('walletUnavailable'))
    }
    const provider = await wallet.getEthereumProvider()
    return createWalletClient({ chain: rhChain, transport: custom(provider) })
  }

  async function sendTx(name, write) {
    setBusy(name)
    setMsg(null)
    try {
      const walletClient = await getWalletClient()
      const hash = await write(walletClient)
      setMsg({ type: 'info', text: t('txSubmitted', { name }) })
      const receipt = await publicClient.waitForTransactionReceipt({ hash })
      if (receipt.status === 'success') {
        setMsg({ type: 'ok', text: t('txConfirmed', { name }) })
      } else {
        setMsg({ type: 'error', text: t('txReverted', { name }) })
      }
      await refresh()
      // 交易后立刻同步票据/可兑奖（服务端缓存 8s 内反映最新链上状态）
      if (accountRef.current) loadMyTickets(accountRef.current).catch(() => {})
      setStkTick((x) => x + 1) // 充能电池卡立即刷新
    } catch (e) {
      setMsg({ type: 'error', text: t('txFailed', { name, msg: e.shortMessage || e.message }) })
    } finally {
      setBusy('')
    }
  }

  // 批量提交：票行打包提交，合约内逐行记账；超 400 组自动拆多笔（RPC 节点 ~100KB raw tx 大小硬上限：
  // 实测 400 组通过、450 组必报 oversized data；此前 741 的 gas 上限已先被大小上限覆盖）
  const submitBatch = async (name, fn) => {
    if (tickets.length === 0) return
    setBusy(name)
    setMsg(null)
    try {
      const walletClient = await getWalletClient()
      const GAS_CHUNK = 400
      const chunks = []
      for (let i = 0; i < tickets.length; i += GAS_CHUNK) chunks.push(tickets.slice(i, i + GAS_CHUNK))
      for (let ci = 0; ci < chunks.length; ci++) {
        const part = chunks[ci]
        if (chunks.length > 1) setMsg({ type: 'info', text: t('airdropProgress', { done: ci, total: chunks.length }) })
        const numsList = part.map((tk) => tk.nums.map((n) => BigInt(n)))
        const counts = part.map(() => BigInt(perTicket))
        const call = fn(numsList, counts) // { functionName, args, value }（value 已按本分片计算）
        // 预估算 gas 并显式传入：让钱包跳过自身估算/模拟（OKX 等在大批量 tx 上估算会卡住）
        let gas
        try {
          const est = await publicClient.estimateContractGas({
            address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: call.functionName,
            args: call.args, value: call.value, account,
          })
          gas = (est * 120n) / 100n
        } catch { gas = undefined }
        const hash = await walletClient.writeContract({
          address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: call.functionName,
          args: call.args, value: call.value, account, chain: rhChain,
          ...(gas ? { gas } : {}),
        })
        const receipt = await publicClient.waitForTransactionReceipt({ hash })
        if (receipt.status !== 'success') {
          setMsg({ type: 'error', text: t('txReverted', { name }) })
          return
        }
      }
      setMsg({ type: 'ok', text: t('txConfirmed', { name }) })
      await refresh()
      if (accountRef.current) loadMyTickets(accountRef.current).catch(() => {})
      setStkTick((x) => x + 1) // 充能电池卡立即刷新
    } catch (e) {
      setMsg({ type: 'error', text: t('txFailed', { name, msg: e.shortMessage || e.message }) })
    } finally {
      setBusy('')
    }
  }

  const gift = () => submitBatch(t('actionGift'), (numsList, counts) => ({
    functionName: giftRecipient && tickets.length > 1 ? 'giftTickets' : 'giftTicket',
    args: giftRecipient && tickets.length > 1
      ? [giftRecipient, numsList, counts]
      : [giftRecipient, numsList[0], counts[0]],
    value: ticketPrice * BigInt(counts.length) * BigInt(perTicket),
  }))

  const buy = () => submitBatch(t('actionPurchase'), (numsList, counts) => ({
    functionName: tickets.length > 1 ? 'buyTickets' : 'buyTicket',
    args: tickets.length > 1 ? [numsList, counts] : [numsList[0], counts[0]],
    value: ticketPrice * BigInt(counts.length) * BigInt(perTicket),
  }))

  const addTicket = () => {
    // 单行新增：记录新票 id，仅该行播放入场动画
    const tk = makeTicket()
    setTickets((prev) => (prev.length >= 1000 ? prev : [...prev, tk]))
    setEnterId(tk.id)
  }
  // 一键快买：直接生成 N 行机选（覆盖当前列表），大多数人的购票路径一步到位
  const quickBuyN = (n) => {
    setPerTicket(1)
    setShowAllTickets(false)
    setEnterId(null)
    setBulkSeq((s) => s + 1) // 批次号变化 → 列表容器整体淡入一次
    setTickets(Array.from({ length: n }, () => makeTicket()))
  }
  const addBulk = () => {
    const n = Math.min(1000, Math.max(1, Number(bulkN) || 10))
    setBulkN(n)
    setTickets((prev) => {
      const room = Math.max(0, 1000 - prev.length)
      return room > 0 ? [...prev, ...Array.from({ length: Math.min(room, n) }, () => makeTicket())] : prev
    })
  }
  const removeTicket = (id) => setTickets((prev) => (prev.length > 1 ? prev.filter((t) => t.id !== id) : prev))
  const shuffleAll = () => setTickets((prev) => prev.map((tk) => ({ ...tk, nums: quickPick() })))
  const clearAll = () => setTickets([makeTicket()])
  const setDigit = (id, idx, v) => setTickets((prev) => prev.map((tk) => (tk.id === id ? { ...tk, nums: tk.nums.map((d, i) => (i === idx ? v : d)) } : tk)))
  const toggleEdit = (id) => setEditingId((prev) => (prev === id ? null : id))

  const claim = (rid, indices) => sendTx(t('actionClaim'), (wc) => wc.writeContract({
    address: JACKPOT_ADDRESS,
    abi: jackpotAbi,
    functionName: 'claim',
    args: [BigInt(rid), indices],
    account,
    chain: rhChain,
  }))

  // 一键领取全部中奖期次：合约一次 tx 只能领一期，前端自动逐期串行发送（每期需钱包各签一次）
  const claimAll = async () => {
    for (const c of claimable) {
      await claim(c.roundId, c.indices)
    }
  }

  const activateReferral = () => sendTx(t('actionReferral'), (wc) => wc.writeContract({
    address: JACKPOT_ADDRESS,
    abi: jackpotAbi,
    functionName: 'setReferrer',
    args: [pendingRef],
    account,
    chain: rhChain,
  })).then(() => {
    localStorage.removeItem('jh_referrer')
    setPendingRef(null)
  })

  const redeemFree = () => sendTx(t('actionRedeemFree'), (wc) => wc.writeContract({
    address: JACKPOT_ADDRESS,
    abi: jackpotAbi,
    functionName: 'redeemFreeTicket',
    args: [freeNums.map((n) => BigInt(n)), BigInt(Math.min(freeCount, Number(myCredits)))],
    account,
    chain: rhChain,
  }))

  // JPH 质押 perk：用当日免费额度领取（JPH 质押者权益）
  const redeemPerk = () => sendTx(t('actionRedeemPerk'), (wc) => wc.writeContract({
    address: PERKS_ADDRESS,
    abi: perksAbi,
    functionName: 'redeemPerkTicket',
    args: [freeNums.map((n) => BigInt(n)), BigInt(Math.min(freeCount, Number(perkBanked)))],
    account,
    chain: rhChain,
  }))

  // 开奖看门狗：一键触发到点未开的期次（commit → 自动快照 → 结算，全自动）
  const watchdogRun = async () => {
    if (!watchdog) return
    setBusy('watchdog')
    setMsg(null)
    const name = t('actionCommitDraw')
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
    try {
      const wc = await getWalletClient()
      const send = async (fn, quiet) => {
        try {
          const hash = await wc.writeContract({
            address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: fn,
            args: [BigInt(watchdog.id)], account, chain: rhChain,
          })
          const receipt = await publicClient.waitForTransactionReceipt({ hash })
          if (receipt.status !== 'success') throw new Error('reverted')
          return true
        } catch (e) {
          if (quiet) return false
          throw e
        }
      }
      if (watchdog.action === 'commit') {
        // 到点未开：承诺 → 等承诺块出块 → 公证快照 → 结算（全自动）
        await send('commitDraw')
        await sleep(2500)
        let done = false
        for (let i = 0; i < 4 && !done; i++) {
          const snapped = await send('snapshotCommitHash', true) // 已快照/窗口内静默跳过
          if (snapped) {
            await sleep(500)
            const settled = await send('settleDraw', true)
            done = settled || snapped
          } else {
            await sleep(2500) // 承诺块未出或已快照：再等一拍后试结算
            if (await send('settleDraw', true)) done = true
          }
        }
      } else {
        // 已承诺未结算：快照（已存则跳过）→ 结算
        await send('snapshotCommitHash', true)
        await send('settleDraw')
      }
      setMsg({ type: 'ok', text: t('txConfirmed', { name }) })
      setWatchdog(null)
      await refresh()
    } catch (e) {
      setMsg({ type: 'error', text: t('txFailed', { name, msg: e.shortMessage || e.message }) })
    } finally {
      setBusy('')
    }
  }

  const handleLogout = async () => {
    setMyTickets([])
    setClaimable([])
    setMyCredits(0n)
    setPerkToday(0n)
    setPerkBanked(0n)
    setOnchainReferrer(null)
    myTicketsRef.current = []
    try { await logout() } catch { /* ignore */ }
  }

  const copyReferralLink = async () => {
    if (!account) return
    const link = `${window.location.origin}${window.location.pathname}?ref=${account}`
    try {
      await navigator.clipboard.writeText(link)
      setMsg({ type: 'ok', text: t('linkCopied') })
    } catch {
      setMsg({ type: 'info', text: link })
    }
  }

  // ---- derived UI state ----
  const status = round ? Number(round.status) : 0
  const salesEnd = round ? Number(round.salesEnd) : 0
  const drawAt = round ? Number(round.drawAt) : 0
  const rollingToNext = (status === 0 && now >= salesEnd) || status === 1 || status === 2 || status === 3
  const inLockWindow = status === 0 && now >= salesEnd && now < drawAt
  const target = status === 0
    ? (now < salesEnd
        ? { label: t('salesCloseIn'), t: salesEnd }
        : { label: t('nextDrawIn'), t: drawAt })
    : null
  const buyEnabled = configured && authenticated && !!account && !!round && !paused && !busy
  const totalUnits = tickets.length * perTicket
  const totalCost = ticketPrice * BigInt(totalUnits)
  const canActivateRef = account && pendingRef && onchainReferrer === NO_ADDRESS
    && pendingRef.toLowerCase() !== account.toLowerCase()
  const lastDraw = history[0] || null
  const poolTotalStr = fmtEthShort(poolAssets.prize + poolAssets.stake) // 奖池总额展示串（兼作 poolPulse 重挂载 key）
  const rolloverStr = fmtEthShort(pendingRollover)

  // ---- hero 翻页（◁ 历史期回顾 / ▷ 下一期预售） ----
  const viewNum = roundNum + viewOffset
  const viewIsCurrent = viewOffset === 0
  const viewIsPast = viewOffset < 0
  const viewIsNext = viewOffset === 1
  const cadence = history.length > 0 ? salesEnd - Number(history[0].round.salesEnd) : 600
  const lockSpan = drawAt - salesEnd
  const nextEstDrawAt = drawAt + cadence // 合约规则：下一期 drawAt = 本期 drawAt + roundDuration
  const vRound = viewIsCurrent ? round : viewRoundData
  const vExists = !!vRound && vRound.drawAt !== 0n
  const vStatus = vRound ? Number(vRound.status) : -1
  const vWinning = viewIsPast && vStatus === 2 ? unpackNumbers(vRound.winningPacked) : null
  // 当前期不在售（停售/开奖中/已结算）时，购票会被合约自动计入下一期
  const nextBuyable = status !== 0 || now >= salesEnd

  if (!ready) {
    return (
      <div className="app">
        {readyTimeout ? (
          <div className="card notice">
            <p style={{ marginBottom: 12 }}>{t('privyTimeout')}</p>
            <button className="primary" onClick={() => window.location.reload()}>{t('retry')}</button>
          </div>
        ) : (
          <div className="card loading">{t('loading')}</div>
        )}
      </div>
    )
  }

  return (
    <div className="app">
      {/* ============ 顶部 ============ */}
      <header className="topbar">
        <div className="brand">Jackpot<span className="brand-dot">Hood</span></div>
        <div className="chain">{rhChain.name}</div>
        <nav className="topnav">
          <a href="/presale">{t('navPresale')}</a>
          <a href="/rules">{t('rules')}</a>
          <a href="/history">{t('navHistory')}</a>
          <a href="/token">{t('navToken')}</a>
          <a href="/stake">💎 {t('navStake')}</a>
          <a href="/nft">🎴 {t('navNft')}</a>
          <a href="/ranks">🏆 {t('navRanks')}</a>
          <a href="/me">👤 {t('navMe')}</a>
          <a href="/calc">🧮 {t('navCalc')}</a>
        </nav>
        <LangSwitcher />
        {!authenticated ? (
          <button className="primary" onClick={login} disabled={busy}>{t('login')}</button>
        ) : account ? (
          <WalletMenu
            wallets={ethWallets}
            wallet={wallet}
            onSelect={selectWallet}
            onConnect={() => { connectWallet().catch(() => {}) }}
            onLogout={handleLogout}
            t={t}
          />
        ) : (
          <button
            className="primary"
            disabled={busy}
            onClick={() => { createWallet().catch(() => {}) }}
          >
            {t('createWallet')}
          </button>
        )}
      </header>

      {/* 中奖播报条：链上真实兑奖事件滚动展示 */}
      {winFeed.length > 0 && (
        <div className="win-ticker">
          <div className="win-track">
            {[...winFeed, ...winFeed].map((w, i) => (
              <span key={i} className="win-item">
                🎉 {t('winFeed', { addr: `${w.user.slice(0, 6)}…${w.user.slice(-4)}`, amount: fmtEthShort(w.amount), n: w.roundId })}
              </span>
            ))}
          </div>
        </div>
      )}

      {!configured && (
        <div className="notice">{t('configNotice')}</div>
      )}

      {/* ============ 英雄区：奖池 + 倒计时（◁▷ 翻页：历史期回顾 / 下一期预售） ============ */}
      {round && (
        <section className={inLockWindow ? 'hero lock-dim' : 'hero'}>
          <div className="hero-left">
            <div className="hero-round">
              <button className="round-nav" disabled={viewNum <= 1} onClick={() => setViewOffset(viewOffset - 1)} title={t('prevRound')} aria-label={t('prevRound')}>◁</button>
              {t('roundNo', { n: viewNum })}
              {viewIsCurrent && <span className={`chip chip-${status}`}>{chipLabel(status)}</span>}
              {viewIsPast && <span className={`chip chip-${vStatus === 3 ? 3 : 2}`}>{chipLabel(vStatus === 3 ? 3 : 2)}</span>}
              {viewIsNext && <span className="chip chip-0">{t('chipPresale')}</span>}
              <button className="round-nav" disabled={viewOffset >= 1} onClick={() => setViewOffset(viewOffset + 1)} title={t('nextRound')} aria-label={t('nextRound')}>▷</button>
              {IS_TESTNET && (
                <a className="faucet-mini" href={FAUCET_URL} target="_blank" rel="noreferrer" title={t('faucetBody')}>💧 {t('faucetBtn')} ↗</a>
              )}
            </div>
            {viewIsCurrent && <div className="hero-tagline">{t('heroTagline')}</div>}
            <div className="hero-countdown">
              {viewIsCurrent ? (
                target ? (
                  <>
                    <div className="cd-label">{target.label}</div>
                    <div className={`cd-time${target.t - now < 60 ? ' pulse' : ''}`}>{fmtCountdown(target.t - now)}</div>
                  </>
                ) : status === 1 ? (
                  <div className="cd-label drawing-label">{t('revealing')}</div>
                ) : (
                  <div className="cd-label drawing-label">{chipLabel(status)}</div>
                )
              ) : viewIsPast ? (
                <div className="cd-label">{vExists ? t('drawAt', { t: fmtUtc(Number(vRound.drawAt)) }) : '…'}</div>
              ) : (
                <>
                  <div className="cd-label">{t('salesCloseIn')}（{t('estLabel')}）</div>
                  <div className="cd-time">{fmtCountdown(Math.max(0, nextEstDrawAt - lockSpan - now))}</div>
                </>
              )}
            </div>
            {viewIsCurrent && lastDraw && (
              <div className="hero-last" key={lastDraw.id}>
                <span className="hero-last-label">{t('lastDrawLabel')} #{lastDraw.id}</span>
                <span className="balls small reveal">
                  {lastDraw.winning.map((d, i) => <i key={i} style={{ '--i': i }}>{d}</i>)}
                </span>
              </div>
            )}
            {viewIsPast && vWinning && (
              <div className="hero-last">
                <span className="balls xl reveal" key={viewNum}>
                  {vWinning.map((d, i) => <i key={i} className="hit" style={{ '--i': i }}>{d}</i>)}
                </span>
              </div>
            )}
            {viewIsNext && (
              <div className="hero-last">
                <span className="hero-last-label">{t(nextBuyable ? 'presaleNow' : 'presaleWait', { n: viewNum })}</span>
              </div>
            )}
          </div>
          <div className="hero-right">
            {viewIsCurrent ? (
              <>
                <div className="hero-pool-label">{t('prizePoolLabel')} <span className="pool-assets">{t('poolAssetsHint')}</span></div>
                <div className="hero-pool-num pool-anim" key={poolTotalStr}>{poolTotalStr}</div>
                <div className="hero-pool-sym">ETH · {t('poolSplitHint', { a: fmtEthShort(poolAssets.prize), b: fmtEthShort(poolAssets.stake) })}</div>
                <div className="hero-stats">
                  <div className="hero-stat">
                    <b>{Number(round.totalTickets).toLocaleString('en-US')}</b>
                    <span>{t('ticketsLabel')}</span>
                  </div>
                  <div className="hero-stat">
                    <b>{fmtUtc(drawAt).slice(11)}</b>
                    <span>UTC</span>
                  </div>
                </div>
              </>
            ) : viewIsPast ? (
              <>
                <div className="hero-pool-label">{t('prizePoolLabel')}</div>
                <div className="hero-pool-num pool-anim" key={`p${viewNum}`}>{vExists ? fmtEthShort(poolOf(vRound)) : '—'}</div>
                <div className="hero-pool-sym">
                  {vExists
                    ? `ETH · ${t('rolloverLabel')} ${fmtEthShort(vRound.prizePool - (vRound.ticketRevenue * 9n) / 10n)} + ${t('revenueLabel')} ${fmtEthShort((vRound.ticketRevenue * 9n) / 10n)}${poolOf(vRound) > vRound.prizePool ? ` + ${t('navStake')} ${fmtEthShort(poolOf(vRound) - vRound.prizePool)}` : ''}`
                    : 'ETH'}
                </div>
                <div className="hero-stats">
                  <div className="hero-stat">
                    <b>{vExists ? Number(vRound.totalTickets).toLocaleString('en-US') : '—'}</b>
                    <span>{t('ticketsLabel')}</span>
                  </div>
                  <div className="hero-stat">
                    <b>{vExists ? fmtUtc(Number(vRound.drawAt)).slice(11) : '—'}</b>
                    <span>UTC</span>
                  </div>
                </div>
              </>
            ) : (
              <>
                <div className="hero-pool-label">{t('rolloverLabel')}（{t('estLabel')}）</div>
                <div className="hero-pool-num pool-anim" key={rolloverStr}>{rolloverStr}</div>
                <div className="hero-pool-sym">ETH</div>
                <div className="hero-stats">
                  <div className="hero-stat">
                    <b>{fmtUtc(nextEstDrawAt - lockSpan).slice(11)}</b>
                    <span>UTC（{t('estLabel')}）</span>
                  </div>
                </div>
              </>
            )}
          </div>
        </section>
      )}

      {/* ============ 兑奖提示（最高优先级） ============ */}
      {claimable.length > 0 && (
        <section className="card highlight-green claim-banner">
          <div className="claim-banner-inner">
            <div>
              <h3>{t('youWon')}</h3>
              {claimable.map(({ roundId: rid, due, indices }) => (
                <div key={rid} className="claim-row">
                  {/* previewClaim 返回毛额；链上实收 = 扣 12% 抽水后净额（88%），这里显示与到账一致的金额 */}
                  <span>{t('claimable', { n: rid, amount: fmtEthShort(due - (due * 1200n) / 10000n), m: indices.length })}</span>
                </div>
              ))}
            </div>
            <div className="claim-banner-actions">
              <button className="primary big" disabled={busy} onClick={claimAll}>
                {t('claimAll', {
                  n: fmtEthShort(claimable.reduce((s, c) => s + (c.due - (c.due * 1200n) / 10000n), 0n)),
                })}
              </button>
            </div>
          </div>
        </section>
      )}

      {/* 开奖看门狗：自动 keeper 延迟时，任何用户可一键触发（免许可设计） */}
      {watchdog && account && (
        <section className="card highlight-green watchdog-banner">
          <div className="claim-banner-inner">
            <div>
              <h3>🎲 {t('watchdogTitle')}</h3>
              <p className="ref-text">{t('watchdogBody', { n: watchdog.id })}</p>
            </div>
            <button className="primary big" onClick={watchdogRun} disabled={busy}>
              {busy === 'watchdog'
                ? t('submitting')
                : watchdog.action === 'commit' ? t('actionCommitDraw') : t('actionSettleDraw')}
            </button>
          </div>
        </section>
      )}

      {canActivateRef && (
        <section className="card highlight-green">
          <h3>{t('referralDetected')}</h3>
          <p className="ref-text">{t('referralBody')}</p>
          <button className="primary" disabled={busy} onClick={activateReferral}>
            {busy === t('actionReferral') ? t('submitting') : t('activate')}
          </button>
        </section>
      )}

      {/* ============ 双栏主体 ============ */}
      <div className="main-grid">
        <div className="main-col">
          {/* 购票面板 */}
          {round && (
            <section className="card buy-card">
              <div className="buy-head">
                <h3>{t('buyTickets')}</h3>
                <div className="seg">
                  <button className={!giftMode ? 'seg-on' : ''} onClick={() => setGiftMode(false)}>{t('tabBuy')}</button>
                  <button className={giftMode ? 'seg-on' : ''} onClick={() => setGiftMode(true)}>{t('tabGift')}</button>
                </div>
              </div>
              {giftMode && (
                <div className="gift-row">
                  <label className="gift-label">
                    {t('recipientLabel')}
                    <input
                      className={giftRecipient && !isAddress(giftRecipient) ? 'invalid' : ''}
                      placeholder={t('recipientPlaceholder')}
                      value={giftRecipient}
                      disabled={!buyEnabled}
                      onChange={(e) => setGiftRecipient(e.target.value)}
                    />
                  </label>
                  {giftRecipient && !isAddress(giftRecipient) && (
                    <span className="gift-hint invalid-hint">{t('invalidAddress')}</span>
                  )}
                  <span className="gift-hint">{t('giftHint')}</span>
                </div>
              )}
              <div className="ticket-toolbar">
                <span className="toolbar-count">{t('toolbarCount', { rows: tickets.length, units: totalUnits })}</span>
                <div className="toolbar-actions">
                  <button className="ghost mini" onClick={shuffleAll}>{t('shuffle')}</button>
                  <button className="ghost mini" onClick={clearAll}>{t('clearWord')}</button>
                </div>
              </div>
              <div className="quickgen-row">
                <div className="quickgen-left">
                  <span className="quickgen-label">🎲 {t('quickGen')}</span>
                  <input
                    type="number"
                    className="qty-input quickgen-input"
                    min="1"
                    max="1000"
                    value={bulkN}
                    onChange={(e) => setBulkN(Math.min(1000, Math.max(1, Number(e.target.value) || 1)))}
                    onKeyDown={(e) => { if (e.key === 'Enter') addBulk() }}
                  />
                  <button className="ghost mini" onClick={addBulk}>{t('generate')}</button>
                </div>
                <div className="quickgen-right">
                  <span className="quickgen-label">{t('quickPick')}</span>
                  {[10, 50, 200, 500].map((n) => (
                    <button key={n} className="quickgen-chip" onClick={() => quickBuyN(n)} disabled={!buyEnabled}>
                      {n}
                    </button>
                  ))}
                </div>
              </div>
              <div key={bulkSeq} className={bulkSeq > 0 ? 'ticket-list bulk-in' : 'ticket-list'}>
                {(showAllTickets || tickets.length <= 30 ? tickets : tickets.slice(0, 30)).map((tk, idx) => (
                  <div key={tk.id} className={`ticket-line${editingId === tk.id ? ' editing' : ''}${tk.id === enterId ? ' tk-enter' : ''}`} title={t('ticketLine', { n: idx + 1 })}>
                    <div className="ticket-balls">
                      {tk.nums.map((n, i) =>
                        editingId === tk.id ? (
                          <select key={i} className="t-ball editable" value={n}
                            onChange={(e) => setDigit(tk.id, i, Number(e.target.value))}>
                            {Array.from({ length: 10 }, (_, d) => <option key={d} value={d}>{d}</option>)}
                          </select>
                        ) : (
                          <span key={i} className="t-ball">{n}</span>
                        ),
                      )}
                    </div>
                    <div className="ticket-actions">
                      <button
                        className={`ticket-edit${editingId === tk.id ? ' on' : ''}`}
                        onClick={() => toggleEdit(tk.id)}
                        aria-label="edit"
                        title={t('editTicket')}
                      >
                        {editingId === tk.id ? '✓' : '⋮'}
                      </button>
                      <button className="ticket-minus" onClick={() => removeTicket(tk.id)} aria-label="delete" title={t('deleteTicket')}>−</button>
                    </div>
                  </div>
                ))}
                {!showAllTickets && tickets.length > 30 && (
                  <button className="ghost tk-show-all" onClick={() => setShowAllTickets(true)}>
                    {t('tkShowAll', { n: tickets.length })}
                  </button>
                )}
              </div>
              <div className="add-row">
                <button className="add-ticket" onClick={addTicket}>＋ {t('addTicket')}</button>
              </div>
              <div className="buy-summary">
                <div className="qty-chips">
                  <span className="qty-label">{t('perLine')}</span>
                  {[1, 10, 50, 100].map((q) => (
                    <button
                      key={q}
                      className={`qty-chip${perTicket === q ? ' seg-on' : ''}`}
                      disabled={!buyEnabled}
                      onClick={() => setPerTicket(q)}
                    >
                      {q}
                    </button>
                  ))}
                  <input
                    type="number"
                    className="qty-input"
                    min="1"
                    max="1000"
                    value={perTicket}
                    disabled={!buyEnabled}
                    onChange={(e) => setPerTicket(Math.min(1000, Math.max(1, Number(e.target.value) || 1)))}
                  />
                </div>
                <div className="cost">
                  <div className="cost-eth">{formatUnits(totalCost, 18)} ETH</div>
                  <div className="cost-sub">{t('perTicket', { n: formatUnits(ticketPrice, 18) })}</div>
                </div>
              </div>
              {authenticated ? (
                <button
                  className="primary cta"
                  onClick={giftMode ? gift : buy}
                  disabled={!buyEnabled || (giftMode && !isAddress(giftRecipient)) || tickets.length === 0 || (viewIsNext && !nextBuyable)}
                >
                  {busy === t('actionPurchase') || busy === t('actionGift')
                    ? t('submitting')
                    : rollingToNext
                      ? t('buySummaryNext', { n: totalUnits, amount: formatUnits(totalCost, 18), r: roundNum + 1 })
                      : t('buySummary', { n: totalUnits, amount: formatUnits(totalCost, 18) })}
                </button>
              ) : (
                <button className="primary cta" onClick={login}>{t('loginToBuy')}</button>
              )}
                            {paused && (
                <div className="rollover-hint paused-hint">{t('pausedHint')}</div>
              )}
              {!paused && inLockWindow && (
                <div className="rollover-hint">{t('lockHint', { n: Number(roundId) + 1 })}</div>
              )}
              {!paused && rollingToNext && !inLockWindow && (
                <div className="rollover-hint">{t('rollHint', { n: Number(roundId), n2: Number(roundId) + 1 })}</div>
              )}
              {viewIsNext && !nextBuyable && (
                <div className="rollover-hint">{t('presaleWait', { n: viewNum })}</div>
              )}
              {viewIsNext && nextBuyable && !paused && (
                <div className="rollover-hint">{t('presaleNow', { n: viewNum })}</div>
              )}
              <div className="tiers">
                {tierNames.map((name, i) => (
                  <span key={i}>{name} · {TIER_SHARES[i]}</span>
                ))}
              </div>
            </section>
          )}

          {/* 我的彩票：按期分组；已开奖的期中奖票置顶（按奖级从大到小）；超过 8 注默认收起，中奖注始终展示 */}
          {myTickets.length > 0 && (
            <section className="card">
              <h3>{t('myTickets')}</h3>
              {myTickets.map(({ roundId: rid, status: rs, winning, tickets }) => {
                const settled = rs === 2 && winning
                const rows = tickets.map((ticket, idx) => ({
                  ticket, idx,
                  nums: unpackNumbers(ticket.numbersPacked),
                  tier: settled ? tierOf(unpackNumbers(ticket.numbersPacked), winning) : -1,
                }))
                if (settled) rows.sort((a, b) => a.tier - b.tier || a.idx - b.idx)
                const winCount = rows.filter((r) => r.tier >= 0 && r.tier < 6).length
                const collapsible = rows.length > 8
                const expanded = !!expandedTickets[rid]
                const visible = !collapsible || expanded ? rows : rows.filter((r) => r.tier >= 0 && r.tier < 6)
                return (
                  <div key={rid} className="tk-group">
                    <div
                      className={collapsible ? 'tk-group-head clickable' : 'tk-group-head'}
                      onClick={() => collapsible && setExpandedTickets((p) => ({ ...p, [rid]: !p[rid] }))}
                    >
                      <span className="tk-sum">
                        {t('tkGroup', { r: rid, n: rows.length })}
                        {settled && winCount > 0 && <span className="tk-win-chip">{t('tkWins', { w: winCount })}</span>}
                      </span>
                      {collapsible && <span className="tk-toggle">{expanded ? t('hideDetails') : t('viewDetails')}</span>}
                    </div>
                    {visible.map(({ ticket, idx, nums, tier }) => (
                      <div key={`${rid}-${idx}`} className="ticket-row">
                        <span className="hist-no" title={t('ticketNo', { r: rid, n: idx + 1 })}>#{rid}-{idx + 1}</span>
                        <span className="balls small">
                          {(() => {
                            const k = winning ? suffixMatches(nums, winning) : 0
                            return nums.map((d, i) => <i key={i} className={i >= 6 - k ? 'hit' : ''}>{d}</i>)
                          })()}
                        </span>
                        <span>×{Number(ticket.count)}</span>
                        {ticket.gifter === FREE_SENTINEL ? (
                          <span className="free-badge">{t('freeBadge')}</span>
                        ) : ticket.gifter && ticket.gifter !== NO_ADDRESS && (
                          <span className="gift-badge" title={`${t('giftBadge')}: ${ticket.gifter}`}>{t('giftBadge')}</span>
                        )}
                        {tier >= 0 && tier < 6
                          ? <span className="win-badge">{tierNames[tier]}!</span>
                          : rs === 2 && !ticket.claimed && tier === 6
                            ? <span className="lose-badge">{t('noWin')}</span>
                            : ticket.claimed ? <span className="claimed-badge">{t('claimedLabel')}</span> : null}
                      </div>
                    ))}
                  </div>
                )
              })}
            </section>
          )}
        </div>

        <div className="side-col">
          {/* 连买充能电池卡（实物抽奖） */}
          <ChargeCard account={account} wallet={wallet} t={t} refreshTick={stkTick} />

          {/* 免费票（额度 + JPH 质押 perk）——自选号码 */}
          {account && (myCredits > 0n || perkBanked > 0n) && (
            <section className="card credits-card">
              <h3>🎁 {t('freeCreditsTitle')}</h3>
              <p className="ref-text">
                {myCredits > 0n && `${t('freeCreditsBody', { n: myCredits.toString() })} `}
                {perkBanked > 0n && t('perkBody', { n: perkBanked.toString(), jph: fmtJph(jphStakedAmt) })}
              </p>
              <div className="credit-selects">
                {freeNums.map((n, i) => (
                  <select key={i} className="t-ball editable" value={n}
                    onChange={(e) => setFreeNums(freeNums.map((v, j) => (j === i ? Number(e.target.value) : v)))}>
                    {Array.from({ length: 10 }, (_, d) => <option key={d} value={d}>{d}</option>)}
                  </select>
                ))}
              </div>
              <div className="credit-row">
                <label className="air-field">
                  <span>{t('freeCreditsCount')}</span>
                  <input
                    type="number"
                    min="1"
                    max={1000}
                    value={freeCount}
                    onChange={(e) => setFreeCount(Math.min(1000, Math.max(1, Number(e.target.value) || 1)))}
                  />
                </label>
                {myCredits > 0n && (
                  <button className="primary" disabled={busy} onClick={redeemFree}>
                    {busy === t('actionRedeemFree') ? t('submitting') : t('freeCreditsRedeem')}
                  </button>
                )}
                {perkBanked > 0n && (
                  <button className="primary ghost-mini" disabled={busy} onClick={redeemPerk}>
                    {busy === t('actionRedeemPerk') ? t('submitting') : t('perkRedeem')}
                  </button>
                )}
              </div>
              {roundFreeMinted >= 1000n && (
                <div className="rollover-hint">{t('freeCreditsCapHint')}</div>
              )}
            </section>
          )}

          {/* 邀请好友（瘦横幅） */}
          {account && (
            <div className="invite-slim">
              <span className="invite-slim-text">{t('inviteBody')}</span>
              <button className="ghost" onClick={copyReferralLink}>{t('copyLink')}</button>
            </div>
          )}

          {/* 近期开奖 */}
          {history.length > 0 && (
            <section className="card">
              <div className="hist-head">
                <h3>{t('recentDraws')}</h3>
                <a className="nav-link" href="/history">{t('viewAll')}</a>
              </div>
              {history.map(({ id, winning, round: r }) => (
                <div key={id} className="hist-row">
                  <span className="hist-no">#{id}</span>
                  <span className="balls small">
                    {winning.map((d, i) => <i key={i}>{d}</i>)}
                  </span>
                  <span className="hist-pool">
                    {BigInt(r.totalTickets) > 0n
                      ? `${fmtEthShort(poolOf(r))} ETH`
                      : <span className="rolled-tag">{t('rolledOnly')}</span>}
                  </span>
                </div>
              ))}
              {scanFloor > 1 && (
                <button className="ghost load-more" onClick={loadMore} disabled={busy}>{t('loadMore')} ↓</button>
              )}
            </section>
          )}
        </div>
      </div>

      {msg && <div className={`toast ${msg.type}`}>{msg.text}</div>}

      <footer>
        <div className="footer-main">{t('footer')}</div>
        <div className="footer-links">
          <a href="/presale">{t('navPresale')}</a>
          <a href="/rules">{t('rules')}</a>
          <a href="/history">{t('navHistory')}</a>
          <a href="/token">{t('navToken')}</a>
          <a href="/stake">💎 {t('navStake')}</a>
          <a href="/nft">🎴 {t('navNft')}</a>
          <a href="/ranks">🏆 {t('navRanks')}</a>
          <a href="/me">👤 {t('navMe')}</a>
          <a href="/calc">🧮 {t('navCalc')}</a>
          <a href="/admin">{t('navAdmin')}</a>
          <a className="tg-link" href="https://t.me/jackpothood" target="_blank" rel="noreferrer">✈️ Telegram</a>
        </div>
      </footer>
    </div>
  )
}

// ============ 连买充能电池卡（侧栏顶部）：/api/streaks 驱动，抽奖走 /api/draw ============
function ChargeCard({ account, wallet, t, refreshTick }) {
  const [stk, setStk] = useState(null)
  const [recent, setRecent] = useState([])
  const [draw, setDraw] = useState(null) // { tier, phase:'idle'|'signing'|'spinning'|'result'|'error', hi, prize, drawId, claimed, err, claimErr }
  const [hint, setHint] = useState('')
  const [claimBusy, setClaimBusy] = useState(false)

  const loadStreaks = (acc) => fetch(`/api/streaks?addr=${acc}`, { headers: { accept: 'application/json' } })
    .then((r) => (r.ok ? r.json() : null))
    .then((d) => { if (d && typeof d === 'object') setStk(d) })
    .catch(() => { /* 失败静默保留旧值 */ })

  const loadRecent = () => fetch('/api/draws/recent', { headers: { accept: 'application/json' } })
    .then((r) => (r.ok ? r.json() : null))
    .then((d) => { if (Array.isArray(d)) setRecent(d) })
    .catch(() => {})

  // 有账号时 10s 轮询充能数据；refreshTick（购票成功）变化立即刷一次
  useEffect(() => {
    if (!account) { setStk(null); return undefined }
    let cancelled = false
    const load = () => fetch(`/api/streaks?addr=${account}`, { headers: { accept: 'application/json' } })
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => { if (!cancelled && d && typeof d === 'object') setStk(d) })
      .catch(() => {})
    load()
    const timer = setInterval(load, 10000)
    return () => { cancelled = true; clearInterval(timer) }
  }, [account, refreshTick])

  // 最近中奖播报：挂载一次 + 60s 轮询
  useEffect(() => {
    let cancelled = false
    const load = () => fetch('/api/draws/recent', { headers: { accept: 'application/json' } })
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => { if (!cancelled && Array.isArray(d)) setRecent(d) })
      .catch(() => {})
    load()
    const timer = setInterval(load, 60000)
    return () => { cancelled = true; clearInterval(timer) }
  }, [])

  // Esc 关闭（动画播放中禁关）
  useEffect(() => {
    if (!draw) return undefined
    const onKey = (e) => {
      if (e.key === 'Escape' && draw.phase !== 'signing' && draw.phase !== 'spinning') setDraw(null)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [draw])

  const showHint = (text) => {
    setHint(text)
    setTimeout(() => setHint((h) => (h === text ? '' : h)), 5000)
  }

  const getProvider = async () => {
    if (!wallet || typeof wallet.getEthereumProvider !== 'function') throw new Error('no-wallet')
    return wallet.getEthereumProvider()
  }

  const openDraw = (tier) => {
    if (!account) { showHint(t('chargeLoginFirst')); return }
    setDraw({ tier, phase: 'idle', hi: -1, prize: null, drawId: null, claimed: false, err: '', claimErr: false })
  }

  const spinTo = (target) => {
    // ~2.5s 轮播高亮、逐渐减速，定格在中奖格
    const total = 25 + target // 25..30 步，(total-1) % 6 === target
    let k = 0
    const tick = () => {
      k += 1
      const hi = (k - 1) % 6
      setDraw((d) => (d && d.phase === 'spinning' ? { ...d, hi } : d))
      if (k < total) {
        setTimeout(tick, 50 + k * 4)
      } else {
        setDraw((d) => (d && d.phase === 'spinning' ? { ...d, phase: 'result', hi: target } : d))
        if (account) loadStreaks(account)
        loadRecent()
      }
    }
    setTimeout(tick, 60)
  }

  const doDraw = async () => {
    if (!draw || draw.phase !== 'idle' || !account) return
    const tier = draw.tier
    setDraw((d) => (d ? { ...d, phase: 'signing', err: '' } : d))
    try {
      const provider = await getProvider()
      const streakStart = stk && typeof stk.streakStart === 'string' ? stk.streakStart : 'none'
      const msg = `JackpotHood 抽奖授权\n地址:${account.toLowerCase()}\n档位:${tier}\n周期:${streakStart}`
      const sig = await provider.request({ method: 'personal_sign', params: [toHex(msg), account] })
      const res = await fetch('/api/draw', {
        method: 'POST',
        headers: { 'content-type': 'application/json', accept: 'application/json' },
        body: JSON.stringify({ addr: account, tier, sig }),
      })
      if (res.status === 409) {
        setDraw(null)
        showHint(t('chargeSoldOut'))
        loadStreaks(account)
        return
      }
      if (!res.ok) throw new Error('draw-' + res.status)
      const d = await res.json()
      const idx = d && d.prize && Number.isInteger(d.prize.index) ? d.prize.index : 0
      setDraw((prev) => (prev ? { ...prev, phase: 'spinning', hi: -1, prize: d.prize, drawId: d.id } : prev))
      spinTo(idx)
    } catch {
      setDraw((d) => (d ? { ...d, phase: 'error', err: t('chargeDrawFail') } : d))
    }
  }

  const doClaim = async () => {
    if (!draw || !draw.drawId || draw.claimed || claimBusy || !account) return
    setClaimBusy(true)
    setDraw((d) => (d ? { ...d, claimErr: false } : d))
    try {
      const provider = await getProvider()
      const sig = await provider.request({ method: 'personal_sign', params: [toHex(`JackpotHood 领奖登记\n${draw.drawId}`), account] })
      const res = await fetch('/api/draws/claim', {
        method: 'POST',
        headers: { 'content-type': 'application/json', accept: 'application/json' },
        body: JSON.stringify({ id: draw.drawId, addr: account, sig }),
      })
      if (!res.ok && res.status !== 409) throw new Error('claim-' + res.status)
      // 成功（或 409 已登记）→ 打开 TG 客服，按钮变已登记禁用态
      window.open(TG_URL, '_blank', 'noopener')
      setDraw((d) => (d ? { ...d, claimed: true } : d))
      loadStreaks(account)
    } catch {
      setDraw((d) => (d ? { ...d, claimErr: true } : d))
    } finally {
      setClaimBusy(false)
    }
  }

  // ---- 防御式字段访问（接口未到/失败时绝不渲染 undefined） ----
  const th = { smallDays: 7, bigDays: 14, bigTickets: 500, ...((stk && stk.thresholds) || {}) }
  const streakDays = Number(stk && stk.streakDays) || 0
  const tickets14 = Number(stk && stk.tickets14) || 0
  const smallAvail = Number(stk && stk.small && stk.small.available) || 0
  const bigAvail = Number(stk && stk.big && stk.big.available) || 0
  const myDraws = stk && Array.isArray(stk.myDraws) ? stk.myDraws : []
  const modalPrizes = draw && stk && stk.prizes && Array.isArray(stk.prizes[draw.tier]) ? stk.prizes[draw.tier] : []
  const weightSum = modalPrizes.reduce((s, p) => s + (Number(p && p.weight) || 0), 0)
  const closable = draw && draw.phase !== 'signing' && draw.phase !== 'spinning'

  const battery = (n, filled, cls, full) => (
    <div className={`charge-batt ${cls}${full ? ' charge-full' : ''}`}>
      {Array.from({ length: n }, (_, i) => <i key={i} className={i < filled ? 'on' : ''} />)}
    </div>
  )

  return (
    <section className="card charge-card">
      <h3>🔋 {t('chargeTitle')}</h3>
      <p className="charge-sub">{t('chargeSub')}</p>
      {hint && <div className="charge-hint">{hint}</div>}
      {!account ? (
        <div className="charge-need">{t('chargeNeedLogin')}</div>
      ) : !stk ? (
        <div className="charge-skel">
          <div className="charge-skel-bar" />
          <div className="charge-skel-bar" />
        </div>
      ) : (
        <>
          <div className="charge-row">
            {battery(th.smallDays, Math.min(streakDays, th.smallDays), 'green', smallAvail > 0)}
            <div className="charge-meta">
              <span>{t('chargeSmall')}</span>
              <span className="charge-num">{t('chargeDays', { x: streakDays, n: th.smallDays })}</span>
            </div>
            {smallAvail > 0 && (
              <button className="charge-draw-btn green" onClick={() => openDraw('small')}>
                {t('chargeDrawSmall')}
                <span className="charge-badge">{smallAvail}</span>
              </button>
            )}
          </div>
          <div className="charge-rule">{t('chargeRuleSmall', { n: th.smallDays })}</div>

          <div className="charge-row">
            {battery(th.bigDays, Math.min(streakDays, th.bigDays), 'blue', bigAvail > 0)}
            <div className="charge-tickets-bar"><i style={{ width: `${Math.min(100, th.bigTickets > 0 ? (tickets14 / th.bigTickets) * 100 : 0)}%` }} /></div>
            <div className="charge-meta">
              <span>{t('chargeBig')}</span>
              <span className="charge-num">
                {t('chargeDays', { x: streakDays, n: th.bigDays })}
                <br />
                {t('chargeTickets', { x: tickets14, n: th.bigTickets })}
              </span>
            </div>
            {bigAvail > 0 && (
              <button className="charge-draw-btn blue" onClick={() => openDraw('big')}>
                {t('chargeDrawBig')}
                <span className="charge-badge">{bigAvail}</span>
              </button>
            )}
          </div>
          <div className="charge-rule">{t('chargeRuleBig', { n: th.bigDays, t: th.bigTickets })}</div>
        </>
      )}

      {recent.length > 0 && (
        <div className="charge-recent">
          <div className="charge-recent-title">{t('chargeRecent')}</div>
          {recent.slice(0, 5).map((r, i) => (
            <div key={i} className="charge-recent-row">
              <i className={`charge-dot ${r && r.tier === 'big' ? 'blue' : 'green'}`} />
              <span>{r && r.addr ? r.addr : ''} · {r && r.name ? r.name : ''}</span>
            </div>
          ))}
        </div>
      )}

      {draw && (
        <div className="charge-modal-mask" onClick={(e) => { if (closable && e.target === e.currentTarget) setDraw(null) }}>
          <div className="charge-modal">
            <button className="charge-modal-x" disabled={!closable} onClick={() => closable && setDraw(null)} aria-label="close">×</button>
            <h3>{t(draw.tier === 'big' ? 'chargeModalBig' : 'chargeModalSmall')}</h3>
            <div className="charge-prize-grid">
              {modalPrizes.map((p, i) => {
                const w = Number(p && p.weight) || 0
                const raw = weightSum > 0 ? (w / weightSum) * 100 : 0
                const odds = raw > 0 && raw < 1 ? raw.toFixed(2) : raw.toFixed(1)
                const hot = draw.hi === i && (draw.phase === 'spinning' || draw.phase === 'result')
                const hit = draw.phase === 'result' && draw.prize && draw.prize.index === i
                return (
                  <div key={i} className={`charge-prize${hot ? ' hot' : ''}${hit ? ' charge-hit' : ''}`}>
                    <div className="charge-prize-name">{p && p.name ? p.name : ''}</div>
                    <div className="charge-prize-odds">{t('chargeOdds', { p: odds })}</div>
                  </div>
                )
              })}
            </div>

            {draw.phase === 'idle' && (
              <button className={`charge-draw-btn wide ${draw.tier === 'big' ? 'blue' : 'green'}`} onClick={doDraw}>
                {t(draw.tier === 'big' ? 'chargeDrawBig' : 'chargeDrawSmall')}
              </button>
            )}
            {(draw.phase === 'signing' || draw.phase === 'spinning') && (
              <div className="charge-drawing">{t('chargeDrawing')}</div>
            )}
            {draw.phase === 'error' && <div className="charge-err">{draw.err || t('chargeDrawFail')}</div>}
            {draw.phase === 'result' && draw.prize && (
              <div className="charge-result">
                <div className="charge-win">{t('chargeWin')}：{draw.prize.name || ''}</div>
                <div className="charge-rule">{t('chargeClaimHint')}</div>
                {draw.claimErr && <div className="charge-err">{t('chargeDrawFail')}</div>}
                <button className="charge-draw-btn green wide" disabled={draw.claimed || claimBusy} onClick={doClaim}>
                  {draw.claimed ? t('chargeClaimed') : claimBusy ? t('chargeDrawing') : t('chargeGoClaim')}
                </button>
              </div>
            )}

            <div className="charge-history">
              <div className="charge-recent-title">{t('chargeHistory')}</div>
              {myDraws.length === 0 ? (
                <div className="charge-empty">{t('chargeEmpty')}</div>
              ) : (
                myDraws.slice(0, 5).map((d, i) => (
                  <div key={(d && d.id) || i} className="charge-recent-row">
                    <span className="charge-hist-name">{d && d.name ? d.name : ''}</span>
                    <span className={`charge-chip ${d && d.status === 'won' ? 'won' : d && d.status === 'claimed' ? 'claimed' : 'fulfilled'}`}>
                      {d && d.status === 'won' ? t('chargeStatusWon') : d && d.status === 'claimed' ? t('chargeStatusClaimed') : t('chargeStatusFulfilled')}
                    </span>
                  </div>
                ))
              )}
            </div>
          </div>
        </div>
      )}
    </section>
  )
}
