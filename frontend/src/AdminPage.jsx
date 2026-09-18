// 管理员后台 /admin —— 仅链上 admin 钱包可进入
// 功能：批量地址批量免费票（直发 / 发额度 / 项目付费赠票）+ 实时运维 + NFT 权益 + 主网清单
import { useEffect, useMemo, useState } from 'react'
import { createPublicClient, createWalletClient, custom, http, formatUnits, isAddress, toHex } from 'viem'
import { usePrivy, useWallets } from '@privy-io/react-auth'
import LangSwitcher from './LangSwitcher.jsx'
import WalletMenu from './WalletMenu.jsx'
import { useI18n } from './i18n.js'
import { rhChain, EXPLORER_URL, JACKPOT_ADDRESS, TOKEN_ADDRESS, DEX_PAIR, IS_TESTNET, NFT_ADDRESS } from './config.js'
import { jackpotAbi, nftAbi } from './abi.js'

const NO_ADDRESS = '0x0000000000000000000000000000000000000000'

function fmtAddr(a) {
  return a ? `${a.slice(0, 10)}…${a.slice(-6)}` : '—'
}
function fmtEth(v) {
  return formatUnits(v || 0n, 18)
}
function quickPick6() {
  return Array.from({ length: 6 }, () => Math.floor(Math.random() * 10))
}
function parseAddressList(text) {
  const seen = new Set()
  const out = []
  for (const tok of (text || '').split(/[\s,;]+/)) {
    const a = (tok || '').trim()
    if (isAddress(a)) {
      const low = a.toLowerCase()
      if (!seen.has(low)) { seen.add(low); out.push(a) }
    }
  }
  return out
}

const PRIZE_TIERS = ['small', 'big']
function freshPrizeRows() {
  return Array.from({ length: 6 }, () => ({ name: '', pct: '' }))
}
async function sha256Hex(text) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, '0')).join('')
}
function fmtTs(ts) {
  const n = Number(ts)
  const ms = Number.isFinite(n) ? (n < 1e12 ? n * 1000 : n) : Date.parse(ts)
  return Number.isFinite(ms) ? new Date(ms).toLocaleString() : String(ts ?? '—')
}
const thStyle = { textAlign: 'left', padding: '6px 8px', fontSize: 11.5, color: 'var(--muted)', fontWeight: 700, whiteSpace: 'nowrap' }
const tdStyle = { padding: '7px 8px', verticalAlign: 'middle' }

export default function AdminPage() {
  const { t, tr, lang } = useI18n()
  const { ready, authenticated, login, logout } = usePrivy()
  const { wallets } = useWallets()
  const publicClient = useMemo(() => createPublicClient({ chain: rhChain, transport: http() }), [])

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
  }

  const [ops, setOps] = useState(null) // { rid, round, ticketPrice, paused, admin, stakePool, totalStaked, bal }
  const [airList, setAirList] = useState('')
  const [airPer, setAirPer] = useState(1)
  const [airFixed, setAirFixed] = useState('')
  const [airMode, setAirMode] = useState('free') // free=freeTicket 直发 | credits=grantFreeCredits 额度 | paid=giftTicket 付费
  const [airSending, setAirSending] = useState(false)
  const [airProg, setAirProg] = useState(null)
  const [airMsg, setAirMsg] = useState(null)
  const [nftPer, setNftPer] = useState(1)
  const [nftGranting, setNftGranting] = useState(false)
  const [nftGrantMsg, setNftGrantMsg] = useState(null)
  const [prizeCfg, setPrizeCfg] = useState(null) // { small: [{name,weight}×6], big: [...×6] }，weight 以字符串暂存、保存时转数字
  const [prizeSaving, setPrizeSaving] = useState(false)
  const [prizeMsg, setPrizeMsg] = useState(null)
  const [draws, setDraws] = useState(null)
  const [drawsLoading, setDrawsLoading] = useState(false)
  const [drawsMsg, setDrawsMsg] = useState(null)
  const [fulfillBusy, setFulfillBusy] = useState('')
  const [grantAddr, setGrantAddr] = useState('')
  const [grantTier, setGrantTier] = useState('small')
  const [grantSending, setGrantSending] = useState(false)
  const [grantMsg, setGrantMsg] = useState(null)

  useEffect(() => {
    document.title = t('adminTitle')
  }, [lang, t])

  useEffect(() => {
    let cancelled = false
    const load = async () => {
      try {
        const [rid, round, ticketPrice, paused, admin, stakePool, totalStaked, bal] = await Promise.all([
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'currentRoundId' }),
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'getCurrentRound' }),
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'TICKET_PRICE' }),
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'paused' }),
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'admin' }),
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'stakingPool' }).catch(() => 0n),
          publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'totalEthStaked' }).catch(() => 0n),
          publicClient.getBalance({ address: JACKPOT_ADDRESS }),
        ])
        if (!cancelled) setOps({ rid, round, ticketPrice, paused, admin, stakePool, totalStaked, bal })
      } catch { /* ignore */ }
    }
    load()
    const timer = setInterval(load, 30000)
    return () => { cancelled = true; clearInterval(timer) }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const adminAddr = ops?.admin || ''
  const isAdmin = !!account && adminAddr !== '' && account.toLowerCase() === adminAddr.toLowerCase()
  const parsed = parseAddressList(airList)
  const fixedDigits = /^\d{6}$/.test(airFixed) ? airFixed.split('').map(Number) : null
  const airPerN = Math.min(1000, Math.max(1, Number(airPer) || 1))
  const airTotal = parsed.length * airPerN

  // ---- 批量发送：逐地址一笔交易，失败跳过并汇总 ----
  const sendAirdrop = async () => {
    if (airSending || !isAdmin) return
    if (parsed.length === 0) { setAirMsg({ type: 'error', text: t('airdropNoList') }); return }
    if (!wallet || typeof wallet.getEthereumProvider !== 'function') {
      setAirMsg({ type: 'error', text: t('walletUnavailable') }); return
    }
    setAirSending(true)
    setAirMsg(null)
    let ok = 0
    let fail = 0
    try {
      const provider = await wallet.getEthereumProvider()
      const wc = createWalletClient({ chain: rhChain, transport: custom(provider) })
      const count = BigInt(airPerN)
      const price = BigInt(ops.ticketPrice || 0n)
      for (let i = 0; i < parsed.length; i++) {
        const digits = fixedDigits || quickPick6()
        const cfg = airMode === 'paid'
          ? { fn: 'giftTicket', val: price * count, nums: true }
          : airMode === 'free'
            ? { fn: 'freeTicket', val: 0n, nums: true }
            : { fn: 'grantFreeCredits', val: 0n, nums: false }
        try {
          const hash = await wc.writeContract({
            address: JACKPOT_ADDRESS,
            abi: jackpotAbi,
            functionName: cfg.fn,
            args: cfg.nums ? [parsed[i], digits.map((n) => BigInt(n)), count] : [parsed[i], count],
            value: cfg.val,
            account,
            chain: rhChain,
          })
          const receipt = await publicClient.waitForTransactionReceipt({ hash })
          if (receipt.status === 'success') ok++
          else fail++
        } catch { fail++ }
        setAirProg({ done: ok + fail, total: parsed.length })
      }
      setAirMsg({ type: 'ok', text: t('airdropDone', { ok, fail }) })
    } catch (e) {
      setAirMsg({ type: 'error', text: e.shortMessage || e.message })
    } finally {
      setAirSending(false)
      setAirProg(null)
    }
  }

  // ---- NFT 持有者免费票权益 ----
  const grantNftPerks = async () => {
    if (nftGranting || !isAdmin || !NFT_ADDRESS) return
    setNftGranting(true)
    setNftGrantMsg(null)
    let okN = 0
    let failN = 0
    try {
      const provider = await wallet.getEthereumProvider()
      const wc = createWalletClient({ chain: rhChain, transport: custom(provider) })
      const supply = await publicClient.readContract({ address: NFT_ADDRESS, abi: nftAbi, functionName: 'totalSupply' })
      const holders = new Set()
      for (let i = 0; i < Number(supply); i++) {
        const tid = await publicClient.readContract({ address: NFT_ADDRESS, abi: nftAbi, functionName: 'tokenByIndex', args: [BigInt(i)] })
        const owner = await publicClient.readContract({ address: NFT_ADDRESS, abi: nftAbi, functionName: 'ownerOf', args: [tid] })
        holders.add(owner.toLowerCase())
      }
      const per = BigInt(Math.min(1000, Math.max(1, Number(nftPer) || 1)))
      for (const addr of holders) {
        try {
          const hash = await wc.writeContract({
            address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'grantFreeCredits',
            args: [addr, per], account, chain: rhChain,
          })
          const receipt = await publicClient.waitForTransactionReceipt({ hash })
          if (receipt.status === 'success') okN++
          else failN++
        } catch { failN++ }
        setAirProg({ done: okN + failN, total: holders.size })
      }
      setNftGrantMsg({ type: 'ok', text: t('airdropDone', { ok: okN, fail: failN }) })
    } catch (e) {
      setNftGrantMsg({ type: 'error', text: e.shortMessage || e.message })
    } finally {
      setNftGranting(false)
      setAirProg(null)
    }
  }

  // ---- 抽奖配置：后端签名接口（personal_sign + 相对路径 fetch） ----
  const signAdmin = async (msg) => {
    if (!wallet || typeof wallet.getEthereumProvider !== 'function') throw new Error(t('walletUnavailable'))
    const provider = await wallet.getEthereumProvider()
    return provider.request({ method: 'personal_sign', params: [toHex(msg), account] })
  }
  const postAdmin = async (path, body) => {
    const r = await fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    const j = await r.json().catch(() => null)
    if (!r.ok) throw new Error(j?.error || `HTTP ${r.status}`)
    return j
  }

  const loadPrizes = async () => {
    if (!account) return
    try {
      const r = await fetch(`/api/streaks?addr=${account}`)
      const j = await r.json().catch(() => null)
      if (!r.ok) throw new Error(j?.error || `HTTP ${r.status}`)
      const normTier = (arr) => {
        const ws = Array.from({ length: 6 }, (_, i) => {
          const w = Number(arr?.[i]?.weight)
          return Number.isFinite(w) ? Math.max(0, Math.trunc(w)) : 0
        })
        const sum = ws.reduce((a, b) => a + b, 0)
        return ws.map((w, i) => ({
          name: String(arr?.[i]?.name ?? ''),
          pct: sum > 0 ? String(Math.round((w / sum) * 10000) / 100) : '',
        }))
      }
      setPrizeCfg({ small: normTier(j?.prizes?.small), big: normTier(j?.prizes?.big) })
    } catch (e) {
      setPrizeCfg({ small: freshPrizeRows(), big: freshPrizeRows() })
      setPrizeMsg({ type: 'error', text: e.message || String(e) })
    }
  }

  useEffect(() => {
    if (isAdmin && account) loadPrizes()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isAdmin, account])

  const setPrize = (tier, i, field, val) => {
    setPrizeCfg((prev) => (prev
      ? { ...prev, [tier]: prev[tier].map((p, j) => (j === i ? { ...p, [field]: val } : p)) }
      : prev))
  }

  const savePrizes = async () => {
    if (prizeSaving || !prizeCfg || !isAdmin) return
    for (const tier of PRIZE_TIERS) {
      const tierLabel = tier === 'small' ? t('chargeSmall') : t('chargeBig')
      let sum = 0
      for (let i = 0; i < 6; i++) {
        const p = prizeCfg[tier][i]
        const name = (p.name || '').trim()
        const okName = name.length > 0 && name.length <= 40
        const okP = /^\d+(\.\d{1,2})?$/.test(String(p.pct).trim()) && Number(p.pct) <= 100
        if (!okName || !okP) {
          setPrizeMsg({ type: 'error', text: `${tierLabel} #${i + 1}: ${t('adminPrizeName')} ≠ ∅, ${t('adminPrizeWeight')} 0–100 (≤2dp)` })
          return
        }
        sum += Number(p.pct)
      }
      if (Math.abs(sum - 100) > 0.005) {
        setPrizeMsg({ type: 'error', text: `${tierLabel}: Σ = ${sum.toFixed(2)}% ≠ 100%` })
        return
      }
    }
    const toWeights = (rows) => {
      const ws = rows.map((p) => Math.round(Number(p.pct) * 100))
      const diff = 10000 - ws.reduce((a, b) => a + b, 0)
      let mi = 0
      ws.forEach((w, i) => { if (w > ws[mi]) mi = i })
      ws[mi] += diff
      return rows.map((p, i) => ({ name: p.name.trim(), weight: ws[i] }))
    }
    const config = { small: toWeights(prizeCfg.small), big: toWeights(prizeCfg.big) }
    setPrizeSaving(true)
    setPrizeMsg(null)
    try {
      const hex = await sha256Hex(JSON.stringify(config))
      const ts = Date.now()
      const sig = await signAdmin(`JackpotHood 管理操作\nprizes\n${hex}\n${ts}`)
      await postAdmin('/api/admin/prizes', { config, sig, ts })
      setPrizeMsg({ type: 'ok', text: t('adminPrizeSaved') })
      await loadPrizes()
    } catch (e) {
      setPrizeMsg({ type: 'error', text: e.shortMessage || e.message || String(e) })
    } finally {
      setPrizeSaving(false)
    }
  }

  const loadDraws = async () => {
    if (drawsLoading || !isAdmin) return
    setDrawsLoading(true)
    setDrawsMsg(null)
    try {
      const day = new Date().toISOString().slice(0, 10)
      const ts = Date.now()
      const sig = await signAdmin(`JackpotHood 管理操作\ndraws\n${day}\n${ts}`)
      const j = await postAdmin('/api/admin/draws', { sig, ts })
      setDraws(Array.isArray(j?.draws) ? j.draws : [])
    } catch (e) {
      setDrawsMsg({ type: 'error', text: e.shortMessage || e.message || String(e) })
    } finally {
      setDrawsLoading(false)
    }
  }

  const markFulfilled = async (d) => {
    if (fulfillBusy || !isAdmin) return
    setFulfillBusy(String(d.id))
    setDrawsMsg(null)
    try {
      const ts = Date.now()
      const sig = await signAdmin(`JackpotHood 管理操作\nfulfill\n${d.id}\n${ts}`)
      await postAdmin('/api/admin/fulfill', { id: d.id, addr: d.addr, sig, ts })
      setDraws((prev) => (prev || []).map((x) => (x.id === d.id ? { ...x, status: 'fulfilled' } : x)))
    } catch (e) {
      setDrawsMsg({ type: 'error', text: e.shortMessage || e.message || String(e) })
    } finally {
      setFulfillBusy('')
    }
  }

  const sendGrant = async () => {
    if (grantSending || !isAdmin) return
    const addr = (grantAddr || '').trim()
    if (!isAddress(addr)) { setGrantMsg({ type: 'error', text: t('invalidAddress') }); return }
    setGrantSending(true)
    setGrantMsg(null)
    try {
      const ts = Date.now()
      const sig = await signAdmin(`JackpotHood 管理操作\ngrant\n${addr.toLowerCase()}\n${grantTier}\n${ts}`)
      await postAdmin('/api/admin/grant', { addr, tier: grantTier, sig, ts })
      setGrantMsg({ type: 'ok', text: `✓ ${addr.slice(0, 10)}… · ${grantTier === 'small' ? t('chargeSmall') : t('chargeBig')}` })
    } catch (e) {
      setGrantMsg({ type: 'error', text: e.shortMessage || e.message || String(e) })
    } finally {
      setGrantSending(false)
    }
  }

  const configRows = [
    { label: 'Chain', value: `${rhChain.name} (${rhChain.id})` },
    { label: 'JackpotHood', value: JACKPOT_ADDRESS, link: `${EXPLORER_URL}/address/${JACKPOT_ADDRESS}` },
    { label: 'JACKPOTHOOD', value: TOKEN_ADDRESS, link: `${EXPLORER_URL}/address/${TOKEN_ADDRESS}` },
    { label: 'DEX pair', value: DEX_PAIR, link: `${EXPLORER_URL}/address/${DEX_PAIR}` },
  ]
  const steps = tr('mainnetSteps') || []

  return (
    <div className="gitbook">
      <header className="gb-topbar"><div className="gb-topbar-inner">
        <a className="gb-brand" href="/">{t('rulesBack')}</a>
        <span className="gb-tag">{t('adminTitle')}</span>
        <span style={{ flex: 1 }} />
        {authenticated && account ? (
          <WalletMenu
            wallets={ethWallets}
            wallet={wallet}
            onSelect={selectWallet}
            onConnect={() => {}}
            onLogout={async () => { try { await logout() } catch { /* ignore */ } }}
            t={t}
          />
        ) : (
          <button className="primary" onClick={login}>{t('login')}</button>
        )}
      </div></header>

      <div className="gb-layout">
        <main className="gb-content admin-content">
          {/* ===== 权限门禁：仅链上 admin 钱包 ===== */}
          {!ready ? (
            <div className="card loading">{t('loading')}</div>
          ) : !authenticated ? (
            <div className="card">
              <h2>🔐 {t('adminGateTitle')}</h2>
              <p className="gb-lead">{t('adminGateBody')}</p>
              <button className="primary" onClick={login}>{t('login')}</button>
            </div>
          ) : !account ? (
            <div className="card">
              <h2>🔐 {t('adminGateTitle')}</h2>
              <p className="gb-lead">{t('adminGateNoWallet')}</p>
            </div>
          ) : !ops || !adminAddr ? (
            <div className="card loading">{t('loading')}</div>
          ) : !isAdmin ? (
            <div className="card">
              <h2>⛔ {t('adminDeniedTitle')}</h2>
              <p className="gb-lead">{t('adminDeniedBody', { u: fmtAddr(account) })}</p>
              <div className="addr-row">
                <span className="addr-label">{t('opsAdmin')}</span>
                <code className="verify-hash">{fmtAddr(adminAddr)}</code>
              </div>
              {ethWallets.length > 1 && (
                <div className="air-row">
                  <label className="air-field">
                    <span>{t('adminSwitchWallet')}</span>
                    <select value={account} onChange={(e) => selectWallet(e.target.value)}>
                      {ethWallets.map((w) => <option key={w.address} value={w.address}>{w.address}</option>)}
                    </select>
                  </label>
                </div>
              )}
            </div>
          ) : (
            <>
              {/* ===== 实时运维 ===== */}
              <h1>🛠️ {t('adminTitle')}</h1>
              <section>
                <h2>{t('opsTitle')}</h2>
                <div className="card ops-grid">
                  <div className="ops-item"><span className="ops-k">{t('opsRound')}</span><span className="ops-v">#{Number(ops.rid)}</span></div>
                  <div className="ops-item"><span className="ops-k">{t('prizePoolLabel')}</span><span className="ops-v">{fmtEth(ops.round.prizePool)} ETH</span></div>
                  <div className="ops-item"><span className="ops-k">{t('ticketsSold', { n: Number(ops.round.totalTickets).toLocaleString('en-US') })}</span><span className="ops-v">{fmtEth(ops.round.ticketRevenue)} ETH</span></div>
                  <div className="ops-item"><span className="ops-k">{t('stakePoolLabel')}</span><span className="ops-v">{fmtEth(ops.stakePool)} ETH</span></div>
                  <div className="ops-item"><span className="ops-k">{t('stakeTotalLabel')}</span><span className="ops-v">{fmtEth(ops.totalStaked)} ETH</span></div>
                  <div className="ops-item"><span className="ops-k">{t('opsPaused')}</span><span className="ops-v">{ops.paused ? t('yesWord') : t('noWord')}</span></div>
                  <div className="ops-item"><span className="ops-k">{t('opsAdmin')}</span><span className="ops-v"><a href={`${EXPLORER_URL}/address/${ops.admin}`} target="_blank" rel="noreferrer">{fmtAddr(ops.admin)} ↗</a></span></div>
                  <div className="ops-item"><span className="ops-k">Contract balance</span><span className="ops-v">{fmtEth(ops.bal)} ETH</span></div>
                </div>
              </section>

              {/* ===== 批量免费票（核心工具） ===== */}
              <section>
                <h2>{t('airdropTitle')}</h2>
                <div className="card">
                  <p className="gb-lead">{t('airdropNote')}</p>
                  <div className="seg air-seg">
                    <button className={airMode === 'free' ? 'seg-on' : ''} onClick={() => setAirMode('free')}>{t('airFreeMode')}</button>
                    <button className={airMode === 'credits' ? 'seg-on' : ''} onClick={() => setAirMode('credits')}>{t('airCreditsMode')}</button>
                    <button className={airMode === 'paid' ? 'seg-on' : ''} onClick={() => setAirMode('paid')}>{t('airPaidMode')}</button>
                  </div>
                  {airMode === 'free' && <p className="gb-lead air-free-hint">{t('airFreeHint')}</p>}
                  {airMode === 'credits' && <p className="gb-lead air-free-hint">{t('airCreditsHint')}</p>}
                  <div className="air-wallet">
                    <span className="addr-label">Admin</span>
                    <code className="verify-hash">{fmtAddr(account)}</code>
                  </div>
                  <textarea
                    className="air-textarea"
                    rows={8}
                    placeholder={t('airdropPlaceholder')}
                    value={airList}
                    disabled={airSending}
                    onChange={(e) => setAirList(e.target.value)}
                  />
                  <div className="air-row">
                    <label className="air-field">
                      <span>{t('airdropPerAddr')}</span>
                      <input type="number" min="1" max="1000" value={airPer} disabled={airSending}
                        onChange={(e) => setAirPer(Math.min(1000, Math.max(1, Number(e.target.value) || 1)))} />
                    </label>
                    {airMode !== 'credits' && (
                      <label className="air-field">
                        <span>{t('airdropFixed')}</span>
                        <input className={airFixed && !/^\d{6}$/.test(airFixed) ? 'invalid' : ''} value={airFixed} maxLength={6}
                          placeholder="🎲" disabled={airSending}
                          onChange={(e) => setAirFixed(e.target.value.replace(/\D/g, '').slice(0, 6))} />
                      </label>
                    )}
                  </div>
                  <div className="air-summary">
                    <span>{t('airdropCount', { n: parsed.length, m: airTotal })}</span>
                    <span>{airMode === 'paid' && ops ? `${fmtEth(BigInt(ops.ticketPrice || 0n) * BigInt(airTotal))} ETH` : '0 ETH'}</span>
                  </div>
                  <button className="primary" disabled={airSending || parsed.length === 0} onClick={sendAirdrop}>
                    {airSending
                      ? t('airdropProgress', { done: airProg?.done || 0, total: airProg?.total || parsed.length })
                      : t('airdropSend')}
                  </button>
                  {airMsg && <div className={`toast ${airMsg.type}`}>{airMsg.text}</div>}
                </div>
              </section>

              {/* ===== NFT 持有者免费票权益 ===== */}
              {NFT_ADDRESS && (
                <section>
                  <h2>{t('nftPerksAdminTitle')}</h2>
                  <div className="card">
                    <p className="gb-lead">{t('nftPerksAdminBody')}</p>
                    <div className="air-row">
                      <label className="air-field">
                        <span>{t('nftPerksPerHolder')}</span>
                        <input type="number" min="1" max="1000" value={nftPer} disabled={nftGranting}
                          onChange={(e) => setNftPer(Math.min(1000, Math.max(1, Number(e.target.value) || 1)))} />
                      </label>
                    </div>
                    <button className="primary" disabled={nftGranting} onClick={grantNftPerks}>
                      {nftGranting
                        ? t('airdropProgress', { done: airProg?.done || 0, total: airProg?.total || 0 })
                        : t('nftPerksGrantBtn')}
                    </button>
                    {nftGrantMsg && <div className={`toast ${nftGrantMsg.type}`}>{nftGrantMsg.text}</div>}
                  </div>
                </section>
              )}

              {/* ===== 主网清单 / 配置 ===== */}
              <section>
                <h2>{t('mainnetTitle')}</h2>
                <div className="card"><ol className="checklist">{steps.map((st, i) => <li key={i}>{st}</li>)}</ol></div>
              </section>
              <section>
                <h2>{t('configTitle')}</h2>
                <p className="gb-lead">{t('configNote')}</p>
                <div className="card token-info">
                  {configRows.map((row) => (
                    <div key={row.label} className="addr-row">
                      <span className="addr-label">{row.label}</span>
                      <code className="verify-hash">{fmtAddr(row.value)}</code>
                      <a href={row.link} target="_blank" rel="noreferrer" className="addr-link">↗</a>
                    </div>
                  ))}
                  <div className="addr-row">
                    <span className="addr-label">Environment</span>
                    <code className="verify-hash">{IS_TESTNET ? 'Testnet' : 'Mainnet'}</code>
                  </div>
                </div>
              </section>

              {/* ===== 抽奖配置：奖品权重 / 抽奖记录 / 测试额度 ===== */}
              <section>
                <h2>🎁 {t('adminPrizes')}</h2>

                {/* 奖品配置编辑 */}
                <div className="card">
                  {!prizeCfg ? (
                    <div className="loading">{t('loading')}</div>
                  ) : (
                    PRIZE_TIERS.map((tier) => {
                      const rows = prizeCfg[tier]
                      const sum = rows.reduce((a, p) => a + (Number(p.pct) || 0), 0)
                      const sumOk = Math.abs(sum - 100) <= 0.005
                      return (
                        <div key={tier} style={{ marginBottom: 14 }}>
                          <span className={`chip ${tier === 'small' ? 'chip-1' : 'chip-0'}`} style={{ marginTop: 0, marginBottom: 6 }}>
                            {tier === 'small' ? t('chargeSmall') : t('chargeBig')}
                          </span>
                          <span className="ops-k" style={{ marginLeft: 8, color: sumOk ? 'var(--green)' : '#f0b90b' }}>Σ {sum.toFixed(2)}%</span>
                          {rows.map((p, i) => (
                            <div key={i} className="air-row" style={{ margin: '6px 0', alignItems: 'flex-end' }}>
                              <label className="air-field" style={{ flex: '1 1 200px', minWidth: 150 }}>
                                {i === 0 && <span>{t('adminPrizeName')}</span>}
                                <input value={p.name} maxLength={40} placeholder={`#${i + 1}`} disabled={prizeSaving}
                                  onChange={(e) => setPrize(tier, i, 'name', e.target.value)} />
                              </label>
                              <label className="air-field" style={{ flex: '0 0 auto', minWidth: 0 }}>
                                {i === 0 && <span>{t('adminPrizeWeight')}</span>}
                                <input className="qty-input" type="number" min="0" max="100" step="0.01" value={p.pct} disabled={prizeSaving}
                                  onChange={(e) => setPrize(tier, i, 'pct', e.target.value.replace(/[^\d.]/g, '').replace(/(\..*)\./g, '$1').slice(0, 6))} />
                              </label>
                            </div>
                          ))}
                        </div>
                      )
                    })
                  )}
                  <button className="primary" disabled={prizeSaving || !prizeCfg} onClick={savePrizes}>
                    {prizeSaving ? t('submitting') : t('adminPrizeSave')}
                  </button>
                  {prizeMsg && <div className={`toast ${prizeMsg.type}`}>{prizeMsg.text}</div>}
                </div>

                {/* 抽奖记录 */}
                <div className="card" style={{ marginTop: 14 }}>
                  <div className="air-row" style={{ marginTop: 0, alignItems: 'center', justifyContent: 'space-between' }}>
                    <span className="addr-label">{t('adminDraws')}</span>
                    <button className="ghost mini" disabled={drawsLoading} onClick={loadDraws}>
                      {drawsLoading ? t('loading') : '加载记录'}
                    </button>
                  </div>
                  {draws && (
                    <div style={{ overflowX: 'auto' }}>
                      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12.5 }}>
                        <thead>
                          <tr>
                            <th style={thStyle}>时间</th>
                            <th style={thStyle}>地址</th>
                            <th style={thStyle}>档位</th>
                            <th style={thStyle}>奖品</th>
                            <th style={thStyle}>状态</th>
                            <th style={thStyle}></th>
                          </tr>
                        </thead>
                        <tbody>
                          {draws.length === 0 && (
                            <tr><td colSpan={6} style={{ ...tdStyle, color: 'var(--muted)' }}>—</td></tr>
                          )}
                          {draws.map((d) => (
                            <tr key={`${d.tier}-${d.id}`} style={{ borderTop: '1px solid var(--border)' }}>
                              <td style={{ ...tdStyle, whiteSpace: 'nowrap' }}>{fmtTs(d.ts)}</td>
                              <td style={tdStyle}><code className="verify-hash">{fmtAddr(d.addr)}</code></td>
                              <td style={tdStyle}>
                                <span className={`chip ${d.tier === 'big' ? 'chip-0' : 'chip-1'}`} style={{ marginTop: 0 }}>
                                  {d.tier === 'big' ? t('chargeBig') : t('chargeSmall')}
                                </span>
                              </td>
                              <td style={tdStyle}>{d.name || '—'}</td>
                              <td style={tdStyle}>
                                {d.status === 'won' && (
                                  <span className="chip chip-0" style={{ marginTop: 0, animation: 'cdPulse 1.6s ease-in-out infinite' }}>{t('chargeStatusWon')}</span>
                                )}
                                {d.status === 'claimed' && (
                                  <span className="chip" style={{ marginTop: 0, background: '#3a3412', color: '#f0c23e' }}>{t('chargeStatusClaimed')}</span>
                                )}
                                {d.status === 'fulfilled' && (
                                  <span className="chip chip-2" style={{ marginTop: 0 }}>{t('chargeStatusFulfilled')}</span>
                                )}
                                {!['won', 'claimed', 'fulfilled'].includes(d.status) && (
                                  <span className="chip chip-2" style={{ marginTop: 0 }}>{d.status}</span>
                                )}
                              </td>
                              <td style={tdStyle}>
                                {d.status !== 'fulfilled' && (
                                  <button className="ghost mini" disabled={fulfillBusy === String(d.id)} onClick={() => markFulfilled(d)}>
                                    {t('adminMarkFulfilled')}
                                  </button>
                                )}
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  )}
                  {drawsMsg && <div className={`toast ${drawsMsg.type}`}>{drawsMsg.text}</div>}
                </div>

                {/* 测试额度（QA） */}
                <div className="card" style={{ marginTop: 14 }}>
                  <span className="addr-label">{t('adminGrant')}</span>
                  <div className="air-row">
                    <label className="air-field">
                      <span>地址</span>
                      <input value={grantAddr} placeholder="0x…" disabled={grantSending}
                        onChange={(e) => setGrantAddr(e.target.value)} />
                    </label>
                    <label className="air-field" style={{ flex: '0 0 170px', minWidth: 150 }}>
                      <span>档位</span>
                      <select value={grantTier} disabled={grantSending} onChange={(e) => setGrantTier(e.target.value)}
                        style={{ height: 38, borderRadius: 10, border: '1px solid var(--border)', background: '#0b120d', color: 'var(--text)', fontSize: 14, padding: '0 10px' }}>
                        <option value="small">{t('chargeSmall')}</option>
                        <option value="big">{t('chargeBig')}</option>
                      </select>
                    </label>
                  </div>
                  <button className="primary" disabled={grantSending} onClick={sendGrant}>
                    {grantSending ? t('submitting') : t('adminGrant')}
                  </button>
                  <p className="gb-lead" style={{ fontSize: 12, marginTop: 10, marginBottom: 0 }}>
                    测试网 QA 专用：给指定地址直接发放抽奖测试额度（不上链），用于验证抽奖流程。
                  </p>
                  {grantMsg && <div className={`toast ${grantMsg.type}`}>{grantMsg.text}</div>}
                </div>
              </section>
            </>
          )}
        </main>
      </div>
    </div>
  )
}
