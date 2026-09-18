// 个人中心 /me —— 当前钱包的购票、中奖、邀请、质押与 NFT 总览（/api/me 聚合，10s 轮询）
import { useEffect, useState } from 'react'
import { formatUnits } from 'viem'
import { usePrivy, useWallets } from '@privy-io/react-auth'
import LangSwitcher from './LangSwitcher.jsx'
import { useI18n } from './i18n.js'
import { EXPLORER_URL } from './config.js'

function fmtEthShort(v) {
  return (Math.round(Number(formatUnits(BigInt(v || 0), 18)) * 100) / 100).toString()
}
function fmtJph(v) {
  return Number(formatUnits(BigInt(v || 0), 18)).toLocaleString('en-US', { maximumFractionDigits: 2 })
}
function shortAddr(a) {
  return a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '—'
}

export default function ProfilePage() {
  const { t, lang } = useI18n()
  const { authenticated, login } = usePrivy()
  const { wallets } = useWallets()

  // 钱包选择与 StakePage 一致：优先 localStorage 记住的地址，否则取最近连接
  const ethWallets = wallets.filter((w) => w.type === 'ethereum')
  const [activeAddr] = useState(() => {
    try { return localStorage.getItem('jh_wallet') || '' } catch { return '' }
  })
  const savedWallet = ethWallets.find((w) => w.address.toLowerCase() === activeAddr.toLowerCase())
  const wallet = savedWallet
    || [...ethWallets].sort((a, b) => Number(b.connectedAt) - Number(a.connectedAt))[0]
    || null
  const account = wallet?.address ?? null

  const [me, setMe] = useState(null)
  const [msg, setMsg] = useState(null)

  useEffect(() => {
    document.title = t('siteTitle')
  }, [lang, t])

  useEffect(() => {
    setMe(null)
    if (!account) return undefined
    let stop = false
    const load = async () => {
      try {
        const res = await fetch(`/api/me?addr=${account}`, { headers: { accept: 'application/json' } })
        const j = await res.json()
        if (!stop && j && j.ok) setMe(j)
      } catch { /* ignore */ }
    }
    load()
    const timer = setInterval(load, 10000)
    return () => { stop = true; clearInterval(timer) }
  }, [account])

  const copyText = async (text, okKey) => {
    try {
      await navigator.clipboard.writeText(text)
      setMsg({ type: 'ok', text: t(okKey) })
    } catch {
      setMsg({ type: 'info', text })
    }
  }
  const copyAddress = () => account && copyText(account, 'addrCopied')
  const copyReferralLink = () => account && copyText(`${window.location.origin}/?ref=${account}`, 'linkCopied')

  // pending[].due 为毛额，实收净额 = due × 88%
  const pendingNet = (me?.pending || []).reduce((s, p) => s + (BigInt(p.due) * 88n) / 100n, 0n)

  return (
    <div className="gitbook">
      <header className="gb-topbar"><div className="gb-topbar-inner">
        <a className="gb-brand" href="/">{t('rulesBack')}</a>
        <span className="gb-tag">{t('navMe')}</span>
        <span style={{ flex: 1 }} />
        <a className="tg-link gb-tg" href="https://t.me/jackpothood" target="_blank" rel="noreferrer">✈️ Telegram</a>
        <LangSwitcher />
      </div></header>
      <div className="gb-layout">
        <main className="gb-content stake-content">
          <h1>👤 {t('navMe')}</h1>
          <p className="gb-lead">{t('meLead')}</p>

          {!authenticated || !account ? (
            <div className="card me-login-card">
              <h3>👛 {t('loginGuideTitle')}</h3>
              <p className="ref-text">{t('loginGuideBody')}</p>
              <div className="air-row">
                <button className="primary" onClick={login}>{t('login')}</button>
                <a className="me-link-btn" href="/">{t('goBuyTickets')}</a>
              </div>
            </div>
          ) : !me ? (
            <div className="card"><p className="ref-text">{t('loading')}</p></div>
          ) : (
            <div className="me-grid">
              {/* 概览 */}
              <div className="card me-card">
                <h3>📊 {t('meOverview')}</h3>
                <div className="ops-grid">
                  <div className="ops-item">
                    <span className="ops-k">{t('myAddress')}</span>
                    <span className="ops-v addr-line">
                      <a href={`${EXPLORER_URL}/address/${account}`} target="_blank" rel="noreferrer"><code>{shortAddr(account)}</code></a>
                      <button className="ghost-mini" onClick={copyAddress}>{t('copyWord')}</button>
                    </span>
                  </div>
                  <div className="ops-item"><span className="ops-k">{t('ticketsBoughtLabel')}</span><span className="ops-v">{Number(me.ticketsBought).toLocaleString('en-US')}</span></div>
                  <div className="ops-item"><span className="ops-k">{t('spentLabel')}</span><span className="ops-v">{fmtEthShort(me.spentEth)} ETH</span></div>
                </div>
              </div>

              {/* 中奖 */}
              <div className="card me-card">
                <h3>🏆 {t('winsCard')}</h3>
                <div className="ops-grid">
                  <div className="ops-item"><span className="ops-k">{t('winRoundsLabel')}</span><span className="ops-v">{Number(me.winRounds).toLocaleString('en-US')}</span></div>
                  <div className="ops-item"><span className="ops-k">{t('winTicketsLabel')}</span><span className="ops-v">{Number(me.winTickets).toLocaleString('en-US')}</span></div>
                  <div className="ops-item"><span className="ops-k">{t('wonTotalLabel')}</span><span className="ops-v">{fmtEthShort(me.wonTotalEth)} ETH</span></div>
                  <div className="ops-item">
                    <span className="ops-k">{t('pendingNetLabel')}</span>
                    <span className="ops-v">
                      {fmtEthShort(pendingNet)} ETH
                      {pendingNet > 0n && <a className="me-go-claim" href="/">{t('goClaim')}</a>}
                    </span>
                  </div>
                </div>
              </div>

              {/* 邀请 */}
              <div className="card me-card">
                <h3>🤝 {t('inviteCard')}</h3>
                <div className="ops-grid">
                  <div className="ops-item"><span className="ops-k">{t('myReferrerLabel')}</span><span className="ops-v">{me.referrer ? shortAddr(me.referrer) : t('noneWord')}</span></div>
                  <div className="ops-item"><span className="ops-k">{t('inviteesLabel')}</span><span className="ops-v">{Number(me.invitees).toLocaleString('en-US')}</span></div>
                  <div className="ops-item"><span className="ops-k">{t('refEarnedLabel')}</span><span className="ops-v">{fmtEthShort(me.earnedEth)} ETH</span></div>
                </div>
                <div className="ref-row">
                  <span className="ref-earnings">{t('refHint')}</span>
                  <button className="ghost" onClick={copyReferralLink}>{t('copyLink')}</button>
                </div>
              </div>

              {/* 质押 */}
              <div className="card me-card">
                <h3>💎 {t('stakeCard')}</h3>
                <div className="ops-grid">
                  <div className="ops-item"><span className="ops-k">{t('ethStakedLabel')}</span><span className="ops-v">{fmtEthShort(me.ethStaked)} ETH</span></div>
                  <div className="ops-item"><span className="ops-k">{t('pendingRewardsLabel')}</span><span className="ops-v">{fmtEthShort(me.pendingStakeRewards)} ETH</span></div>
                  <div className="ops-item"><span className="ops-k">{t('jphStakedLabel')}</span><span className="ops-v">{fmtJph(me.jphStaked)} JPH</span></div>
                  <div className="ops-item"><span className="ops-k">{t('perkRateLabel')}</span><span className="ops-v">{Number(me.jphPerkPerDay).toLocaleString('en-US')}</span></div>
                  <div className="ops-item"><span className="ops-k">{t('freeTixBalanceLabel')}</span><span className="ops-v">{Number(me.perkBalance).toLocaleString('en-US')}</span></div>
                </div>
              </div>

              {/* NFT */}
              <div className="card me-card">
                <h3>🎖️ {t('nftCard')}</h3>
                <div className="ops-grid">
                  <div className="ops-item"><span className="ops-k">{t('nftCountLabel')}</span><span className="ops-v">{Number(me.nftCount).toLocaleString('en-US')}</span></div>
                </div>
              </div>
            </div>
          )}
          {msg && <div className={`toast ${msg.type}`}>{msg.text}</div>}
        </main>
      </div>
    </div>
  )
}
