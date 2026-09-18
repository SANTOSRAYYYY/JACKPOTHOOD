// 代币页 /token —— 代币合约地址 + 链上 Swap 事件实时重建的 K 线
import { useEffect, useMemo, useRef, useState } from 'react'
import { createPublicClient, http, parseAbi } from 'viem'
import LangSwitcher from './LangSwitcher.jsx'
import { useI18n } from './i18n.js'
import { rhChain, TOKEN_ADDRESS, DEX_PAIR, DEX_ROUTER, DEX_WETH, DEX_PAIR_CREATED } from './config.js'

const EXPLORER = 'https://explorer.testnet.chain.robinhood.com'
const TIMEFRAMES = [15, 60, 240, 1440] // 分钟

const pairAbi = parseAbi([
  'event Mint(uint256 amount0, uint256 amount1)',
  'event Swap(address indexed caller, address indexed to, uint256 amount0Out, uint256 amount1Out, uint256 taxOut)',
  'function token0() view returns (address)',
  'function token1() view returns (address)',
  'function getReserves() view returns (uint256, uint256)',
  'function sellTaxBps() view returns (uint256)',
  'function feeTo() view returns (address)',
])

const WAD = 10n ** 18n

// ---- K 线加载优化：事件增量缓存（短TTL）+ 区块时间戳永久缓存（区块时间戳不可变） ----
const EV_CACHE_KEY = 'jh_token_events_v2'
const TS_CACHE_KEY = 'jh_token_ts_v2'

function readJSON(key) {
  try {
    const raw = localStorage.getItem(key)
    return raw ? JSON.parse(raw) : null
  } catch { return null }
}
function writeJSON(key, val) {
  try { localStorage.setItem(key, JSON.stringify(val)) } catch { /* ignore */ }
}

// 事件与 BigInt 的序列化（JSON 不支持 BigInt）
function evOut(e) {
  return {
    type: e.type,
    amount0: e.amount0 ? e.amount0.toString() : undefined,
    amount1: e.amount1 ? e.amount1.toString() : undefined,
    amount0Out: e.amount0Out ? e.amount0Out.toString() : undefined,
    amount1Out: e.amount1Out ? e.amount1Out.toString() : undefined,
    blockNumber: e.blockNumber.toString(),
    logIndex: e.logIndex,
    ts: e.ts,
  }
}
function evIn(o) {
  return {
    type: o.type,
    amount0: o.amount0 ? BigInt(o.amount0) : undefined,
    amount1: o.amount1 ? BigInt(o.amount1) : undefined,
    amount0Out: o.amount0Out ? BigInt(o.amount0Out) : undefined,
    amount1Out: o.amount1Out ? BigInt(o.amount1Out) : undefined,
    blockNumber: BigInt(o.blockNumber),
    logIndex: o.logIndex,
    ts: o.ts,
  }
}

// 受限并发 map：避免公共 RPC 被串行等待拖慢、也避免并发过高被限流
async function mapLimit(items, limit, fn) {
  const out = new Array(items.length)
  let i = 0
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (i < items.length) {
      const idx = i++
      out[idx] = await fn(items[idx], idx)
    }
  })
  await Promise.all(workers)
  return out
}

function fmtAddr(a) {
  return `${a.slice(0, 10)}…${a.slice(-6)}`
}

function fmtPrice(tokensPerEth) {
  if (!isFinite(tokensPerEth) || tokensPerEth <= 0) return '—'
  if (tokensPerEth >= 1e6) return `${(tokensPerEth / 1e6).toLocaleString('en-US', { maximumFractionDigits: 2 })}M`
  if (tokensPerEth >= 1e3) return `${(tokensPerEth / 1e3).toLocaleString('en-US', { maximumFractionDigits: 1 })}K`
  return tokensPerEth.toLocaleString('en-US', { maximumFractionDigits: 2 })
}

/// 从 Mint/Swap 事件重建成交序列与价格（常数乘积 AMM 精确反推）
function rebuildTrades(events) {
  const sorted = [...events].sort((a, b) =>
    a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : Number(a.blockNumber - b.blockNumber),
  )
  let r0 = 0n // JACKPOTHOOD
  let r1 = 0n // WETH
  const trades = []
  for (const ev of sorted) {
    if (ev.type === 'mint') {
      r0 += ev.amount0
      r1 += ev.amount1
      continue
    }
    const a0 = ev.amount0Out
    const a1 = ev.amount1Out
    if (r0 === 0n || r1 === 0n || (a0 === 0n && a1 === 0n)) continue
    if (a0 > 0n) {
      // ETH → 代币：a0 个代币出（常数乘积精确反推 ETH 入量）
      const ethIn = (r0 * r1) / (r0 - a0) - r1
      r0 -= a0
      r1 += ethIn
      trades.push({ ts: ev.ts, tokens: a0, tokensPerEth: Number(a0) / Number(ethIn) })
    } else if (a1 > 0n) {
      // 代币 → ETH：a1 个 ETH 出（毛额），税后实收 ethOut（价格按用户实际到手计算）
      const ethOut = a1 - (ev.taxOut || 0n)
      const tokenIn = (r0 * r1) / (r1 - a1) - r0
      r0 += tokenIn
      r1 -= a1
      trades.push({ ts: ev.ts, tokens: tokenIn, tokensPerEth: Number(tokenIn) / Number(ethOut) })
    }
  }
  return trades
}

function buildCandles(trades, tfMinutes) {
  const bucketMs = tfMinutes * 60 * 1000
  const map = new Map()
  for (const t of trades) {
    const key = Math.floor(t.ts / bucketMs)
    const p = t.tokensPerEth
    let c = map.get(key)
    if (!c) {
      c = { t: key * bucketMs, o: p, h: p, l: p, c: p, v: 0 }
      map.set(key, c)
    }
    c.h = Math.max(c.h, p)
    c.l = Math.min(c.l, p)
    c.c = p
    c.v += Number(t.tokens) / 1e18
  }
  return [...map.values()].sort((a, b) => a.t - b.t)
}

function CandleChart({ candles }) {
  if (!candles || candles.length === 0) return null
  const W = 800
  const H = 280
  const PAD = 8
  const min = Math.min(...candles.map((c) => c.l))
  const max = Math.max(...candles.map((c) => c.h))
  const range = max - min || 1
  const cw = Math.max(4, W / candles.length)
  const y = (p) => H - PAD - ((p - min) / range) * (H - PAD * 2)
  const last = candles[candles.length - 1].c
  const up = (c) => c.c >= c.o
  return (
    <svg viewBox={`0 0 ${W} ${H + 20}`} className="kline-svg" preserveAspectRatio="none">
      {/* 网格与价格线 */}
      {[0.25, 0.5, 0.75].map((f) => (
        <line key={f} x1="0" x2={W} y1={y(min + range * f)} y2={y(min + range * f)} className="kline-grid" />
      ))}
      {candles.map((c, i) => {
        const x = i * cw + cw / 2
        const bodyTop = y(Math.max(c.o, c.c))
        const bodyH = Math.max(1.5, Math.abs(y(c.o) - y(c.c)))
        return (
          <g key={i}>
            <line x1={x} x2={x} y1={y(c.h)} y2={y(c.l)} className={up(c) ? 'kline-up' : 'kline-down'} strokeWidth="1" />
            <rect x={x - cw * 0.32} y={bodyTop} width={cw * 0.64} height={bodyH} className={up(c) ? 'kline-up' : 'kline-down'} />
          </g>
        )
      })}
      {/* 最新价虚线 */}
      <line x1="0" x2={W} y1={y(last)} y2={y(last)} className="kline-last" strokeDasharray="4 4" />
      <text x={W - 4} y={y(last) - 6} textAnchor="end" className="kline-label">{fmtPrice(last)}</text>
      <text x="4" y={H + 14} className="kline-label">{fmtPrice(max)}</text>
      <text x="4" y={H - PAD + 2} className="kline-label">{fmtPrice(min)}</text>
    </svg>
  )
}

export default function TokenPage() {
  const { t, lang } = useI18n()
  const publicClient = useMemo(() => createPublicClient({ chain: rhChain, transport: http() }), [])
  const [trades, setTrades] = useState([])
  const [reserves, setReserves] = useState({ r0: 0n, r1: 0n })
  const [taxInfo, setTaxInfo] = useState({ bps: 0n, feeTo: '' })
  const [tf, setTf] = useState(60)
  const [loading, setLoading] = useState(true)
  const [copied, setCopied] = useState('')
  const copyTimer = useRef(null)

  useEffect(() => {
    document.title = t('tokenTitle')
  }, [lang, t])

  useEffect(() => {
    let cancelled = false
    const load = async () => {
      try {
        const [token0, token1, res, bps, feeTo] = await Promise.all([
          publicClient.readContract({ address: DEX_PAIR, abi: pairAbi, functionName: 'token0' }),
          publicClient.readContract({ address: DEX_PAIR, abi: pairAbi, functionName: 'token1' }),
          publicClient.readContract({ address: DEX_PAIR, abi: pairAbi, functionName: 'getReserves' }),
          publicClient.readContract({ address: DEX_PAIR, abi: pairAbi, functionName: 'sellTaxBps' }).catch(() => 0n),
          publicClient.readContract({ address: DEX_PAIR, abi: pairAbi, functionName: 'feeTo' }).catch(() => ''),
        ])
        const tokenIs0 = token0.toLowerCase() === TOKEN_ADDRESS.toLowerCase()
        if (!cancelled) {
          setReserves({ r0: tokenIs0 ? res[0] : res[1], r1: tokenIs0 ? res[1] : res[0] })
          setTaxInfo({ bps: bps || 0n, feeTo: feeTo || '' })
        }

        // 1) 读缓存：上次已扫描水位之后的区块才需要补扫（增量）
        const cached = readJSON(EV_CACHE_KEY)
        let events = cached && Array.isArray(cached.events) ? cached.events.map(evIn) : []
        let startBlock = DEX_PAIR_CREATED
        if (cached && typeof cached.floor === 'string') {
          const floor = BigInt(cached.floor)
          if (floor >= DEX_PAIR_CREATED) startBlock = floor + 1n
        }

        const latest = await publicClient.getBlockNumber()
        if (startBlock <= latest) {
          // 2) 分块并发抓取（单次 getLogs 同时匹配 Mint+Swap 两个事件）
          const CHUNK = 100000n
          const ranges = []
          for (let s = startBlock; s <= latest; s += CHUNK) {
            ranges.push([s, s + CHUNK - 1n > latest ? latest : s + CHUNK - 1n])
          }
          const chunkLogs = await mapLimit(ranges, 4, ([from, to]) =>
            publicClient.getLogs({ address: DEX_PAIR, events: [pairAbi[0], pairAbi[1]], fromBlock: from, toBlock: to }),
          )

          const fresh = []
          for (const logs of chunkLogs) {
            for (const lg of logs) {
              if (lg.eventName === 'Mint') {
                fresh.push({ type: 'mint', amount0: lg.args.amount0, amount1: lg.args.amount1, blockNumber: lg.blockNumber, logIndex: lg.logIndex })
              } else {
                const amount0Out = tokenIs0 ? lg.args.amount0Out : lg.args.amount1Out
                const amount1Out = tokenIs0 ? lg.args.amount1Out : lg.args.amount0Out
                fresh.push({ type: 'swap', amount0Out, amount1Out, blockNumber: lg.blockNumber, logIndex: lg.logIndex })
              }
            }
          }

          if (fresh.length > 0) {
            // 3) 区块时间戳：已缓存直接复用；新区块并发补抓后永久缓存
            const tsMap = readJSON(TS_CACHE_KEY) || {}
            const need = [...new Set(fresh.map((e) => e.blockNumber))].filter((b) => tsMap[b] === undefined)
            await mapLimit(need, 8, async (n) => {
              const blk = await publicClient.getBlock({ blockNumber: n })
              tsMap[n] = Number(blk.timestamp) * 1000
            })
            writeJSON(TS_CACHE_KEY, tsMap)
            for (const e of fresh) if (e.ts === undefined) e.ts = tsMap[e.blockNumber]

            events = [...events, ...fresh].sort((a, b) =>
              a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : Number(a.blockNumber - b.blockNumber),
            )
          }
          writeJSON(EV_CACHE_KEY, { events: events.map(evOut), floor: latest.toString(), savedAt: Date.now() })
        }

        if (!cancelled && events.length > 0) setTrades(rebuildTrades(events))
      } catch (e) {
        console.error('token page load failed', e)
        // 网络失败时用缓存兜底渲染
        const cached = readJSON(EV_CACHE_KEY)
        if (!cancelled && cached && Array.isArray(cached.events)) {
          setTrades(rebuildTrades(cached.events.map(evIn)))
        }
      } finally {
        if (!cancelled) setLoading(false)
      }
    }
    load()
    const timer = setInterval(load, 60000) // 每分钟增量刷新（有缓存时极轻量）
    return () => {
      cancelled = true
      clearInterval(timer)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const candles = useMemo(() => buildCandles(trades, tf), [trades, tf])

  const last = trades.length > 0 ? trades[trades.length - 1] : null
  const dayAgo = Date.now() - 24 * 3600 * 1000
  const dayTrades = trades.filter((t) => t.ts >= dayAgo)
  const firstDay = dayTrades[0] || last
  const change24h = last && firstDay ? ((last.tokensPerEth - firstDay.tokensPerEth) / firstDay.tokensPerEth) * 100 : null
  const volume24h = dayTrades.reduce((acc, t) => acc + Number(t.tokens) / 1e18, 0)
  const livePrice = last ? last.tokensPerEth : Number(reserves.r0) / Number(reserves.r1)

  const copy = async (text, key) => {
    try {
      await navigator.clipboard.writeText(text)
      setCopied(key)
      clearTimeout(copyTimer.current)
      copyTimer.current = setTimeout(() => setCopied(''), 2000)
    } catch { /* ignore */ }
  }

  const addressRows = [
    { label: t('tokenAddressLabel'), value: TOKEN_ADDRESS, key: 'token' },
    { label: t('pairAddressLabel'), value: DEX_PAIR, key: 'pair' },
    { label: t('routerAddressLabel'), value: DEX_ROUTER, key: 'router' },
  ]

  return (
    <div className="gitbook">
      <header className="gb-topbar"><div className="gb-topbar-inner">
        <a className="gb-brand" href="/">{t('rulesBack')}</a>
        <span className="gb-tag">{t('tokenTitle')}</span>
        <span style={{ flex: 1 }} />
        <a className="tg-link gb-tg" href="https://t.me/jackpothood" target="_blank" rel="noreferrer">✈️ Telegram</a>
        <LangSwitcher />
      </div></header>
      <div className="gb-layout">
        <main className="gb-content token-content">
          <h1>{t('tokenTitle')}</h1>
          <p className="gb-lead">{t('tokenLead')}</p>

          <div className="card token-info">
            {addressRows.map((row) => (
              <div key={row.key} className="addr-row">
                <span className="addr-label">{row.label}</span>
                <code className="verify-hash">{fmtAddr(row.value)}</code>
                <a href={`${EXPLORER}/address/${row.value}`} target="_blank" rel="noreferrer" className="addr-link">↗</a>
                <button className="ghost addr-copy" onClick={() => copy(row.value, row.key)}>
                  {copied === row.key ? t('copied') : '📋'}
                </button>
              </div>
            ))}
          </div>

          <div className="card">
            <div className="addr-row">
              <span className="addr-label">{t('tokenTax')}</span>
              <code className="verify-hash">{taxInfo.bps > 0n ? `${Number(taxInfo.bps) / 100}%` : '0%'}</code>
            </div>
            <div className="addr-row">
              <span className="addr-label">{t('taxRewardsTo')}</span>
              <code className="verify-hash">{taxInfo.feeTo ? fmtAddr(taxInfo.feeTo) : '—'}</code>
              {taxInfo.feeTo && (
                <a href={`${EXPLORER}/address/${taxInfo.feeTo}`} target="_blank" rel="noreferrer" className="addr-link">↗</a>
              )}
            </div>
          </div>

          <div className="card">
            <div className="price-row">
              <div>
                <div className="price-big">{fmtPrice(livePrice)} <span className="price-unit">{t('perEth')}</span></div>
                <div className="price-sub">
                  {change24h !== null && (
                    <span className={change24h >= 0 ? 'price-up' : 'price-down'}>
                      {change24h >= 0 ? '+' : ''}{change24h.toFixed(2)}%
                    </span>
                  )}
                  {' · '}{t('volume24h')}: {volume24h.toLocaleString('en-US', { maximumFractionDigits: 0 })} JACKPOTHOOD
                </div>
              </div>
              <div className="seg">
                {TIMEFRAMES.map((m) => (
                  <button key={m} className={tf === m ? 'seg-on' : ''} onClick={() => setTf(m)}>
                    {m < 60 ? `${m}m` : m < 1440 ? `${m / 60}h` : '1d'}
                  </button>
                ))}
              </div>
            </div>

            {loading ? (
              <div className="card loading">{t('loading')}</div>
            ) : candles.length > 0 ? (
              <>
                <CandleChart candles={candles} />
                <div className="chart-note">{t('chartNote')}</div>
              </>
            ) : (
              <div className="verify-note">{t('noTrades')}</div>
            )}
          </div>
        </main>
      </div>
    </div>
  )
}
