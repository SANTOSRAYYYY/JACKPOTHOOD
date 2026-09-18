// 社区轮预售页 /presale —— 阶梯价认购 + 附赠 JPH + 创世 NFT2 领取 + 结束后兑换免费票
import { useEffect, useMemo, useState } from 'react'
import { createPublicClient, createWalletClient, custom, http, formatUnits, isAddress } from 'viem'
import { usePrivy, useWallets } from '@privy-io/react-auth'
import LangSwitcher from './LangSwitcher.jsx'
import { useI18n } from './i18n.js'
import { rhChain, EXPLORER_URL, PRESALE_ADDRESS, NFT2_ADDRESS } from './config.js'
import { presaleAbi, nft2Abi } from './abi.js'

const NO_ADDRESS = '0x0000000000000000000000000000000000000000'

// 与合约一致的阶梯价常量（JackpotHoodPresale：PRICE1/2/3、TIER1_END/TIER2_END、CAP）
const CAP = 100000
const TIER1_END = 20000
const TIER2_END = 50000
const PRICE1 = 800000000000000n // 0.0008 ETH
const PRICE2 = 900000000000000n // 0.0009 ETH
const PRICE3 = 1000000000000000n // 0.001 ETH
const NFT_THRESHOLD = 500

// 本地镜像合约 _priceFrom：从 sold 起算购买 n 张的总价（跨档分段求和）
function priceOfLocal(sold, n) {
  let from = BigInt(sold)
  let remaining = BigInt(n)
  let total = 0n
  if (from < BigInt(TIER1_END) && remaining > 0n) {
    const inTier = remaining < BigInt(TIER1_END) - from ? remaining : BigInt(TIER1_END) - from
    total += inTier * PRICE1
    from += inTier
    remaining -= inTier
  }
  if (from < BigInt(TIER2_END) && remaining > 0n) {
    const inTier = remaining < BigInt(TIER2_END) - from ? remaining : BigInt(TIER2_END) - from
    total += inTier * PRICE2
    from += inTier
    remaining -= inTier
  }
  if (remaining > 0n) total += remaining * PRICE3
  return total
}

function fmtCountdown(sec) {
  if (sec <= 0) return '00:00:00'
  const d = Math.floor(sec / 86400)
  const h = Math.floor((sec % 86400) / 3600)
  const m = Math.floor((sec % 3600) / 60)
  const s = Math.floor(sec % 60)
  const hms = [h, m, s].map((x) => String(x).padStart(2, '0')).join(':')
  return d > 0 ? `${d}d ${hms}` : hms
}

// 小额 ETH 展示：trim 尾部零，最多 6 位小数
function fmtEthTiny(wei) {
  const n = Number(formatUnits(BigInt(wei || 0), 18))
  return String(Math.round(n * 1e6) / 1e6)
}

function fmtAddr(a) {
  return a ? `${a.slice(0, 10)}…${a.slice(-6)}` : '—'
}

export default function PresalePage() {
  const { t, lang } = useI18n()
  const { authenticated, login } = usePrivy()
  const { wallets } = useWallets()
  const publicClient = useMemo(() => createPublicClient({ chain: rhChain, transport: http() }), [])

  // 钱包选择与 ProfilePage 一致：优先 localStorage 记住的地址，否则取最近连接
  const ethWallets = wallets.filter((w) => w.type === 'ethereum')
  const [activeAddr] = useState(() => {
    try { return localStorage.getItem('jh_wallet') || '' } catch { return '' }
  })
  const savedWallet = ethWallets.find((w) => w.address.toLowerCase() === activeAddr.toLowerCase())
  const wallet = savedWallet
    || [...ethWallets].sort((a, b) => Number(b.connectedAt) - Number(a.connectedAt))[0]
    || null
  const account = wallet?.address ?? null

  const [data, setData] = useState(null) // { sold, endTime, isOpen, nftSupply }
  const [mine, setMine] = useState(null) // { purchased, credits, nftMinted }
  const [qty, setQty] = useState('1')
  const [redeemNums, setRedeemNums] = useState([0, 0, 0, 0, 0, 0])
  const [redeemCount, setRedeemCount] = useState('')
  const [referrer, setReferrer] = useState(null) // ?ref= 推荐人
  const [busy, setBusy] = useState('')
  const [msg, setMsg] = useState(null)
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000))

  useEffect(() => {
    document.title = t('siteTitle')
  }, [lang, t])

  useEffect(() => {
    const timer = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000)
    return () => clearInterval(timer)
  }, [])

  // 捕获 ?ref=（沿用首页推荐链接惯例），无则回退 localStorage
  useEffect(() => {
    try {
      const ref = new URLSearchParams(window.location.search).get('ref')
      if (ref && isAddress(ref)) {
        localStorage.setItem('jh_referrer', ref)
        setReferrer(ref)
      } else {
        const saved = localStorage.getItem('jh_referrer')
        if (saved && isAddress(saved)) setReferrer(saved)
      }
    } catch { /* ignore */ }
  }, [])

  const load = async () => {
    try {
      const [sold, endTime, isOpen, nftSupply] = await Promise.all([
        publicClient.readContract({ address: PRESALE_ADDRESS, abi: presaleAbi, functionName: 'sold' }),
        publicClient.readContract({ address: PRESALE_ADDRESS, abi: presaleAbi, functionName: 'endTime' }),
        publicClient.readContract({ address: PRESALE_ADDRESS, abi: presaleAbi, functionName: 'isOpen' }),
        publicClient.readContract({ address: NFT2_ADDRESS, abi: nft2Abi, functionName: 'totalSupply' }),
      ])
      setData({ sold: Number(sold), endTime: Number(endTime), isOpen: !!isOpen, nftSupply: Number(nftSupply) })
      if (account) {
        const [purchased, credits, nftMinted] = await Promise.all([
          publicClient.readContract({ address: PRESALE_ADDRESS, abi: presaleAbi, functionName: 'purchased', args: [account] }),
          publicClient.readContract({ address: PRESALE_ADDRESS, abi: presaleAbi, functionName: 'credits', args: [account] }),
          publicClient.readContract({ address: NFT2_ADDRESS, abi: nft2Abi, functionName: 'minted', args: [account] }),
        ])
        setMine({ purchased: Number(purchased), credits: Number(credits), nftMinted: !!nftMinted })
      } else {
        setMine(null)
      }
    } catch { /* ignore */ }
  }

  useEffect(() => {
    setData(null)
    setMine(null)
    load()
    const timer = setInterval(load, 15000)
    return () => clearInterval(timer)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [account])

  const getWalletClient = async () => {
    if (!wallet || typeof wallet.getEthereumProvider !== 'function') throw new Error(t('walletUnavailable'))
    const provider = await wallet.getEthereumProvider()
    return createWalletClient({ chain: rhChain, transport: custom(provider) })
  }

  const sendTx = async (name, write) => {
    setBusy(name)
    setMsg(null)
    try {
      const wc = await getWalletClient()
      const hash = await write(wc)
      setMsg({ type: 'info', text: t('txSubmitted', { name }) })
      const receipt = await publicClient.waitForTransactionReceipt({ hash })
      setMsg({ type: receipt.status === 'success' ? 'ok' : 'error', text: receipt.status === 'success' ? t('txConfirmed', { name }) : t('txReverted', { name }) })
      await load()
    } catch (e) {
      setMsg({ type: 'error', text: t('txFailed', { name, msg: e.shortMessage || e.message }) })
    } finally {
      setBusy('')
    }
  }

  const sold = data ? data.sold : 0
  const soldOut = data ? data.sold >= CAP : false
  const ended = data ? now >= data.endTime : false
  const remaining = Math.max(0, CAP - sold)
  const pct = Math.min(100, (sold / CAP) * 100)
  const tierPrice = sold < TIER1_END ? '0.0008' : sold < TIER2_END ? '0.0009' : '0.001'

  // 尾单自动截断：输入超过剩余量时按剩余量计（与合约 buy 一致）
  const qtyNum = Math.max(0, Math.min(Math.floor(Number(qty) || 0), remaining))
  const cost = qtyNum > 0 ? priceOfLocal(sold, qtyNum) : 0n

  const doBuy = () => {
    if (qtyNum <= 0) return
    const ref = referrer && account && referrer.toLowerCase() !== account.toLowerCase() ? referrer : NO_ADDRESS
    sendTx(t('preBuyBtn'), (wc) => wc.writeContract({
      address: PRESALE_ADDRESS,
      abi: presaleAbi,
      functionName: 'buy',
      args: [BigInt(qtyNum), ref],
      value: cost,
      account,
      chain: rhChain,
    }))
  }

  const doClaimNft = () => sendTx(t('preNftClaim'), (wc) => wc.writeContract({
    address: NFT2_ADDRESS,
    abi: nft2Abi,
    functionName: 'claim',
    account,
    chain: rhChain,
  }))

  const myCredits = mine ? mine.credits : 0
  const redeemCountNum = Math.max(0, Math.min(Math.floor(Number(redeemCount) || 0), myCredits))
  const doRedeem = () => {
    if (redeemCountNum <= 0) return
    sendTx(t('preRedeem'), (wc) => wc.writeContract({
      address: PRESALE_ADDRESS,
      abi: presaleAbi,
      functionName: 'redeem',
      args: [redeemNums.map((n) => BigInt(n)), BigInt(redeemCountNum)],
      account,
      chain: rhChain,
    }))
  }

  const nftProgress = mine ? Math.min(mine.purchased, NFT_THRESHOLD) : 0
  const nftReady = !!mine && mine.purchased >= NFT_THRESHOLD && !mine.nftMinted

  return (
    <div className="gitbook">
      <header className="gb-topbar"><div className="gb-topbar-inner">
        <a className="gb-brand" href="/">{t('rulesBack')}</a>
        <span className="gb-tag">{t('preTitle')}</span>
        <span style={{ flex: 1 }} />
        <a className="tg-link gb-tg" href="https://t.me/jackpothood" target="_blank" rel="noreferrer">✈️ Telegram</a>
        <LangSwitcher />
      </div></header>
      <div className="gb-layout">
        <main className="gb-content pre-content">
          <h1>🚀 {t('preTitle')}</h1>
          <p className="gb-lead">{t('preSub')}</p>

          {/* Hero：总进度 + 档位价 + 倒计时 */}
          <div className="card pre-hero">
            <div className="pre-bar">
              <div className="pre-bar-fill" style={{ width: `${Math.max(pct, sold > 0 ? 0.5 : 0)}%` }} />
            </div>
            <div className="pre-hero-row">
              <div className="pre-progress">
                <div className="pre-num">{t('preProgress', { sold: sold.toLocaleString('en-US'), cap: CAP.toLocaleString('en-US') })}</div>
                <div className="pre-tier">{t('preTier')} · {t('preTierPrice', { p: tierPrice })}</div>
              </div>
              {soldOut ? (
                <span className="pre-chip done">{t('preSoldOut')}</span>
              ) : ended ? (
                <span className="pre-chip done">{t('preEnded')}</span>
              ) : data ? (
                <div className="pre-cd">
                  <span className="pre-cd-label">{t('preEndsIn')}</span>
                  <span className="pre-cd-time">{fmtCountdown(data.endTime - now)}</span>
                </div>
              ) : (
                <span className="pre-chip">{t('loading')}</span>
              )}
            </div>
          </div>

          {/* 购买卡 */}
          <div className="card">
            <h3>🎟️ {t('preBuyBtn')}</h3>
            <div className="pre-buy-row">
              <label className="qty-label">{t('preQty')}</label>
              <input
                className="qty-input pre-qty-input"
                type="number"
                min="1"
                max={CAP}
                step="1"
                value={qty}
                onChange={(e) => setQty(e.target.value)}
                placeholder="1"
              />
              <span className="cost pre-cost">{t('preCost')}: <b>{fmtEthTiny(cost)} ETH</b></span>
            </div>
            {!authenticated || !account ? (
              <button className="primary big" onClick={login}>{t('preConnect')}</button>
            ) : (
              <button
                className="primary big"
                onClick={doBuy}
                disabled={!!busy || !data || ended || soldOut || qtyNum <= 0}
              >
                {busy === t('preBuyBtn') ? t('submitting') : t('preBuyBtn')}
              </button>
            )}
            {referrer && (
              <p className="verify-note">ref: <code>{fmtAddr(referrer)}</code></p>
            )}
          </div>

          {/* 我的预售 */}
          {account && (
            <div className="card">
              <h3>👤 {t('preMy')}</h3>
              <div className="ops-grid">
                <div className="ops-item"><span className="ops-k">{t('prePurchased')}</span><span className="ops-v">{mine ? mine.purchased.toLocaleString('en-US') : '—'}</span></div>
                <div className="ops-item"><span className="ops-k">{t('preCredits')}</span><span className="ops-v">{mine ? mine.credits.toLocaleString('en-US') : '—'}</span></div>
                <div className="ops-item"><span className="ops-k">{t('preBonus')}</span><span className="ops-v pre-bonus">{mine ? `${(mine.purchased * 10).toLocaleString('en-US')} JPH` : '—'}</span></div>
              </div>

              {/* 创世 NFT2 进度 / 领取 */}
              <h3 className="pre-nft-title">🎖️ {t('preNft')}{data ? ` · ${data.nftSupply}/1000` : ''}</h3>
              <div className="pre-bar small">
                <div className="pre-bar-fill" style={{ width: `${(nftProgress / NFT_THRESHOLD) * 100}%` }} />
              </div>
              <div className="pre-nft-row">
                <span className="pre-tier">{t('preNftProgress', { x: mine ? mine.purchased : 0 })}</span>
                {mine && mine.nftMinted ? (
                  <span className="pre-chip">{t('preNftClaimed')}</span>
                ) : nftReady ? (
                  <button className="primary" onClick={doClaimNft} disabled={!!busy}>
                    {busy === t('preNftClaim') ? t('submitting') : t('preNftClaim')}
                  </button>
                ) : null}
              </div>
              {nftReady && <p className="ref-text">{t('preNftReady')}</p>}
            </div>
          )}

          {/* 兑换区 */}
          <div className="card">
            <h3>🎫 {t('preRedeem')}</h3>
            {!data || !data.isOpen ? (
              <div className="pre-notopen">{t('preNotOpen')}</div>
            ) : (
              <>
                <p className="ref-text">{t('preOpen')} · {t('preRedeemHint')}</p>
                <div className="credit-selects">
                  {redeemNums.map((n, i) => (
                    <select key={i} className="t-ball editable" value={n}
                      onChange={(e) => setRedeemNums(redeemNums.map((v, j) => (j === i ? Number(e.target.value) : v)))}>
                      {Array.from({ length: 10 }, (_, d) => <option key={d} value={d}>{d}</option>)}
                    </select>
                  ))}
                </div>
                <div className="pre-buy-row">
                  <label className="qty-label">{t('preQty')}</label>
                  <input
                    className="qty-input pre-qty-input"
                    type="number"
                    min="1"
                    max={myCredits}
                    step="1"
                    value={redeemCount}
                    onChange={(e) => setRedeemCount(e.target.value)}
                    placeholder="1"
                  />
                  <span className="cost pre-cost">{t('preCredits')}: {myCredits.toLocaleString('en-US')}</span>
                </div>
                {!authenticated || !account ? (
                  <button className="primary" onClick={login}>{t('preConnect')}</button>
                ) : (
                  <button className="primary" onClick={doRedeem} disabled={!!busy || redeemCountNum <= 0}>
                    {busy === t('preRedeem') ? t('submitting') : t('preRedeem')}
                  </button>
                )}
              </>
            )}
          </div>

          {/* 规则 / 分账 */}
          <div className="card">
            <h3>📖 {t('preSplit')}</h3>
            <ul className="nft-perks">
              {(t('preSplitItems') || '').split('|').map((p, i) => <li key={i}>{p}</li>)}
            </ul>
            <p className="verify-note">{t('preBurnNote')}</p>
            <p className="ref-text">{t('preRefHint')}</p>
            <div className="addr-row">
              <span className="addr-label">Presale</span>
              <code className="verify-hash">{fmtAddr(PRESALE_ADDRESS)}</code>
              <a href={`${EXPLORER_URL}/address/${PRESALE_ADDRESS}`} target="_blank" rel="noreferrer" className="addr-link">↗</a>
            </div>
            <div className="addr-row">
              <span className="addr-label">NFT2</span>
              <code className="verify-hash">{fmtAddr(NFT2_ADDRESS)}</code>
              <a href={`${EXPLORER_URL}/address/${NFT2_ADDRESS}`} target="_blank" rel="noreferrer" className="addr-link">↗</a>
            </div>
          </div>

          {msg && <div className={`toast ${msg.type}`}>{msg.text}</div>}
        </main>
      </div>
    </div>
  )
}
