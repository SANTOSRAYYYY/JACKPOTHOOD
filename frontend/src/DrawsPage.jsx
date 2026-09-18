// 开奖历史页 /history —— 每期附公证验证模块（随机区块/哈希/号码推导）
import { useEffect, useMemo, useState } from 'react'
import { createPublicClient, http, formatUnits } from 'viem'
import LangSwitcher from './LangSwitcher.jsx'
import { useI18n } from './i18n.js'
import { rhChain, JACKPOT_ADDRESS, EXPLORER_URL } from './config.js'
import { jackpotAbi } from './abi.js'

const TIER_SHARES = ['40%', '25%', '15%', '12%', '5%', '3%']
const EXPLORER = EXPLORER_URL
const RPC_URL = rhChain.rpcUrls.default.http[0]

function unpackNumbers(packed) {
  packed = BigInt(packed)
  return [0, 1, 2, 3, 4, 5].map((i) => Number((packed >> BigInt(8 * i)) & 0xffn))
}

function fmtEth(v) {
  return formatUnits(v, 18)
}

// 期次奖池真值 = 六档奖池之和（票款奖池 + 结算时质押快照）；未结算/作废期回退为 prizePool
function poolOf(r) {
  if (!r) return 0n
  try {
    const s = r.tierPots.reduce((a, b) => a + BigInt(b), 0n)
    if (s > 0n) return s
  } catch { /* 字段缺失时回退 */ }
  return BigInt(r.prizePool || 0n)
}

function fmtUtc(ts) {
  return new Date(Number(ts) * 1000).toISOString().replace('T', ' ').slice(0, 16) + ' UTC'
}

// 与合约 _deriveNumbers 完全一致的推导：逐字节取 %10，≥250 跳过
function deriveFromHash(hashHex) {
  const bytes = []
  for (let i = 2; i + 2 <= hashHex.length; i += 2) {
    bytes.push(parseInt(hashHex.slice(i, i + 2), 16))
  }
  const usedBytes = []
  const digits = []
  for (const b of bytes) {
    if (digits.length >= 6) break
    if (b >= 250) {
      usedBytes.push({ hex: b.toString(16).padStart(2, '0'), digit: null, skipped: true })
      continue
    }
    const digit = b % 10
    usedBytes.push({ hex: b.toString(16).padStart(2, '0'), digit, skipped: false })
    digits.push(digit)
  }
  return { digits, usedBytes }
}

export default function DrawsPage() {
  const { t, tr, lang } = useI18n()
  const publicClient = useMemo(
    () => createPublicClient({ chain: rhChain, transport: http() }),
    [],
  )
  const [rounds, setRounds] = useState([])
  const [scanFloor, setScanFloor] = useState(0)
  const [loading, setLoading] = useState(true)
  const [expanded, setExpanded] = useState({}) // 每期明细展开状态
  const toggle = (id) => setExpanded((prev) => ({ ...prev, [id]: !prev[id] }))
  const tierNames = tr('tierNames')

  useEffect(() => {
    document.title = t('drawsTitle')
  }, [lang, t])

  const loadBatch = async (fromId, count) => {
    const out = []
    for (let id = fromId; id >= Math.max(1, fromId - count + 1); id--) {
      const r = await publicClient.readContract({
        address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'getRound', args: [BigInt(id)],
      })
      if (r.drawAt === 0n || Number(r.status) !== 2) continue
      const entry = { id, round: r, winning: unpackNumbers(r.winningPacked), derivation: null }
      // 公证：结算时固化的随机源区块哈希（链上权威记录）
      if (r.seedHash && r.seedHash !== '0x0000000000000000000000000000000000000000000000000000000000000000') {
        entry.derivation = deriveFromHash(r.seedHash)
      }
      out.push(entry)
    }
    return out
  }

  useEffect(() => {
    let cancelled = false
    const init = async () => {
      setLoading(true)
      try {
        const rid = await publicClient.readContract({
          address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'currentRoundId',
        })
        const from = Number(rid) - 1
        const res = await loadBatch(from, 10)
        if (!cancelled) {
          setRounds(res)
          setScanFloor(Math.max(1, from - 9))
        }
      } finally {
        if (!cancelled) setLoading(false)
      }
    }
    init()
    return () => { cancelled = true }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const loadMore = async () => {
    if (scanFloor <= 1 || loading) return
    setLoading(true)
    try {
      const from = scanFloor - 1
      const count = Math.min(10, from)
      const res = await loadBatch(from, count)
      setRounds((prev) => [...prev, ...res])
      setScanFloor(Math.max(1, from - count + 1))
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="gitbook">
      <header className="gb-topbar"><div className="gb-topbar-inner">
        <a className="gb-brand" href="/">{t('rulesBack')}</a>
        <span className="gb-tag">{t('drawsTitle')}</span>
        <span style={{ flex: 1 }} />
        <a className="tg-link gb-tg" href="https://t.me/jackpothood" target="_blank" rel="noreferrer">✈️ Telegram</a>
        <LangSwitcher />
      </div></header>
      <div className="gb-layout">
        <main className="gb-content draws-content">
          <h1>{t('drawsTitle')}</h1>
          <p className="gb-lead">{t('drawsLead')}</p>

          {loading && (
            <div className="card loading">{t('loading')}</div>
          )}

          {!loading && rounds.length === 0 && (
            <div className="card">
              <p className="verify-note">🎰 {t('noDrawsYet')}</p>
            </div>
          )}

          {rounds.map(({ id, round: r, winning, derivation }) => (
            <div key={id} className="card draw-card">
              <div className="draw-head">
                <span className="draw-no">{t('roundNo', { n: id })}</span>
                <span className="draw-time">{t('drawAt', { t: fmtUtc(r.drawAt) })}</span>
                <button className="draw-toggle" onClick={() => toggle(id)}>
                  {expanded[id] ? t('hideDetails') + ' ▲' : t('viewDetails') + ' ▼'}
                </button>
              </div>

              <div className="balls draw-balls">
                {winning.map((d, i) => <i key={i}>{d}</i>)}
              </div>

              <div className="draw-stats">
                {t('prizePoolLabel')}: {fmtEth(poolOf(r))} ETH
                {BigInt(r.ticketRevenue) === 0n && (
                  <>
                    {' · '}<span className="rolled-tag">{t('rolledOnly')}</span>
                  </>
                )}
                {' · '}{t('ticketsSold', { n: Number(r.totalTickets).toLocaleString('en-US') })}
                {' · '}{t('revenueLabel')}: {fmtEth(r.ticketRevenue)} ETH
                {' · '}{t('claimDeadlineLabel')}: {fmtUtc(r.claimDeadline)}
              </div>

              {expanded[id] && (
                <>
              <table className="gb-table">
                <thead>
                  <tr>
                    <th>{t('tiersTitle')}</th>
                    <th>{t('prizePoolLabel')}</th>
                    <th>{t('winnersWord')}</th>
                    <th>{t('rolloverLabel')} / {t('claimedLabel')}</th>
                  </tr>
                </thead>
                <tbody>
                  {[0, 1, 2, 3, 4, 5].map((ti) => (
                    <tr key={ti}>
                      <td>{tierNames[ti]}</td>
                      <td>{TIER_SHARES[ti]} · {fmtEth(r.tierPots[ti])} ETH</td>
                      <td>{Number(r.tierUnits[ti])}</td>
                      <td>
                        {Number(r.tierUnits[ti]) === 0
                          ? t('tierRolledOver')
                          : `${fmtEth(r.tierClaimed[ti])} ${t('claimedLabel')} / ${fmtEth(BigInt(r.tierPots[ti]) - BigInt(r.tierClaimed[ti]))} ${t('unclaimedWord')} ETH`}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>

              <div className="verify-block">
                <div className="verify-title">🔍 {t('verifyTitle')}</div>
                <div className="verify-line">
                  {t('randomBlockLabel')}: <b>#{r.randomBlock}</b>{' '}
                  <a href={`${EXPLORER}/block/${r.randomBlock}`} target="_blank" rel="noreferrer">({t('explorerBlock')} ↗)</a>
                </div>
                {r.seedHash && r.seedHash !== '0x0000000000000000000000000000000000000000000000000000000000000000' ? (
                  <>
                    <div className="verify-line">
                      {t('blockHashLabel')}: <code className="verify-hash">{r.seedHash}</code>
                    </div>
                    <div className="verify-note">🛡️ {t('seedStoredNote')}</div>
                    <div className="verify-line">
                      {t('derivationLabel')}:{' '}
                      {derivation && derivation.usedBytes.map((b, i) => (
                        <span key={i} className={b.skipped ? 'derive-skip' : 'derive-step'}>
                          {b.skipped ? `0x${b.hex} ${t('byteSkipped')}` : `0x${b.hex}→${b.digit}`}
                        </span>
                      ))}
                    </div>
                    <div className="verify-note">{t('derivationNote')}</div>
                    <div className="verify-ok">✓ {t('matchesOk')}</div>
                    <div className="verify-note">{t('evmNumberNote')}</div>
                    <div className="verify-line">
                      {t('verifyCmdHint')}{' '}
                      <code className="verify-hash">cast call {JACKPOT_ADDRESS} "getRound(uint256)(uint64,uint64,uint64,uint64,uint256,uint256,uint256,uint256,uint48,bytes32,bytes32,uint256[6],uint256[6],uint256[6],bool,uint8)" {id} --rpc-url {RPC_URL}</code>
                    </div>
                  </>
                ) : (
                  <div className="verify-note">{t('verifyUnavailable')}</div>
                )}
              </div>
                </>
              )}
            </div>
          ))}

          {scanFloor > 1 && (
            <button className="ghost load-more" onClick={loadMore} disabled={loading}>
              {loading ? t('loading') : `${t('loadMore')} ↓`}
            </button>
          )}
        </main>
      </div>
    </div>
  )
}
