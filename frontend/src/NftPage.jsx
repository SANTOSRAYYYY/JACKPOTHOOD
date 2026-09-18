// 创世 NFT 页 /nft —— 铸造式代币产出凭证：铸造 → 持 NFT 领取代币配额 + 持有者权益
import { useEffect, useMemo, useState } from 'react'
import { createPublicClient, createWalletClient, custom, http, formatUnits } from 'viem'
import { usePrivy, useWallets } from '@privy-io/react-auth'
import LangSwitcher from './LangSwitcher.jsx'
import { useI18n } from './i18n.js'
import { rhChain, EXPLORER_URL, NFT_ADDRESS, TOKEN_ADDRESS, JPH_DECIMALS, IS_TESTNET } from './config.js'
import { nftAbi } from './abi.js'

function fmtJph(v) {
  const s = formatUnits(v || 0n, JPH_DECIMALS)
  const [a, b = ''] = s.split('.')
  return `${Number(a).toLocaleString('en-US')}.${(b + '0000').slice(0, 2)}`
}
function fmtEth(v) {
  return formatUnits(v || 0n, 18)
}
function fmtAddr(a) {
  return a ? `${a.slice(0, 10)}…${a.slice(-6)}` : '—'
}

export default function NftPage() {
  const { t, lang } = useI18n()
  const { authenticated, login } = usePrivy()
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

  const [meta, setMeta] = useState(null) // 总量/已铸/价格/配额/开关
  const [myNfts, setMyNfts] = useState([]) // { tokenId, quota, claimed }
  const [claimable, setClaimable] = useState({ total: 0n, ids: [] })
  const [busy, setBusy] = useState('')
  const [msg, setMsg] = useState(null)

  useEffect(() => {
    document.title = t('nftTitle')
  }, [lang, t])

  const load = async () => {
    if (!NFT_ADDRESS) return
    try {
      // balanceOf(0x0) 会 revert：未登录时不查持仓
      const [maxSupply, totalMinted, mintPrice, quotaPerNft, mintOpen] = await Promise.all([
        publicClient.readContract({ address: NFT_ADDRESS, abi: nftAbi, functionName: 'maxSupply' }),
        publicClient.readContract({ address: NFT_ADDRESS, abi: nftAbi, functionName: 'totalMinted' }),
        publicClient.readContract({ address: NFT_ADDRESS, abi: nftAbi, functionName: 'mintPrice' }),
        publicClient.readContract({ address: NFT_ADDRESS, abi: nftAbi, functionName: 'quotaPerNft' }),
        publicClient.readContract({ address: NFT_ADDRESS, abi: nftAbi, functionName: 'mintOpen' }),
      ])
      setMeta({ maxSupply, totalMinted, mintPrice, quotaPerNft, mintOpen })

      if (account) {
        const nftBal = await publicClient.readContract({ address: NFT_ADDRESS, abi: nftAbi, functionName: 'balanceOf', args: [account] })
        const count = Number(nftBal)
        const ids = []
        for (let i = 0; i < count; i++) {
          ids.push(publicClient.readContract({ address: NFT_ADDRESS, abi: nftAbi, functionName: 'tokenOfOwnerByIndex', args: [account, BigInt(i)] }))
        }
        const tokenIds = await Promise.all(ids)
        const details = await Promise.all(tokenIds.map((tid) =>
          Promise.all([
            publicClient.readContract({ address: NFT_ADDRESS, abi: nftAbi, functionName: 'quotaOf', args: [tid] }),
            publicClient.readContract({ address: NFT_ADDRESS, abi: nftAbi, functionName: 'claimed', args: [tid] }),
          ]).then(([quota, claimed]) => ({ tokenId: tid, quota, claimed })),
        ))
        setMyNfts(details)
        const [total, ids2] = await publicClient.readContract({ address: NFT_ADDRESS, abi: nftAbi, functionName: 'claimableOf', args: [account] })
        setClaimable({ total, ids: ids2 })
      }
    } catch { /* ignore */ }
  }

  useEffect(() => {
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

  const doMint = () => sendTx(t('actionMintNft'), (wc) => wc.writeContract({
    address: NFT_ADDRESS,
    abi: nftAbi,
    functionName: 'mint',
    value: meta.mintPrice,
    account,
    chain: rhChain,
  }))

  const doClaim = () => {
    if (claimable.ids.length === 0) return
    // 逐张领取
    const run = async () => {
      setBusy(t('actionClaimNft'))
      setMsg(null)
      try {
        const wc = await getWalletClient()
        for (const tid of claimable.ids) {
          const hash = await wc.writeContract({ address: NFT_ADDRESS, abi: nftAbi, functionName: 'claim', args: [tid], account, chain: rhChain })
          await publicClient.waitForTransactionReceipt({ hash })
        }
        setMsg({ type: 'ok', text: t('nftClaimed', { n: fmtJph(claimable.total) }) })
        await load()
      } catch (e) {
        setMsg({ type: 'error', text: t('txFailed', { name: t('actionClaimNft'), msg: e.shortMessage || e.message }) })
      } finally {
        setBusy('')
      }
    }
    run()
  }

  const sold = meta ? Number(meta.totalMinted) : 0
  const remaining = meta ? Number(meta.maxSupply) - sold : 0

  return (
    <div className="gitbook">
      <header className="gb-topbar"><div className="gb-topbar-inner">
        <a className="gb-brand" href="/">{t('rulesBack')}</a>
        <span className="gb-tag">{t('nftTitle')}</span>
        <span style={{ flex: 1 }} />
        <a className="tg-link gb-tg" href="https://t.me/jackpothood" target="_blank" rel="noreferrer">✈️ Telegram</a>
        <LangSwitcher />
      </div></header>
      <div className="gb-layout">
        <main className="gb-content nft-content">
          <h1>🎴 {t('nftTitle')}</h1>
          <p className="gb-lead">{t('nftLead')}</p>

          <div className="gb-callout gb-callout-tip nft-moved-banner">
            🚀 {t('nftMoved')} → <a href="/presale">{t('navPresale')}</a>
          </div>

          {!NFT_ADDRESS && (
            <div className="card"><p className="verify-note">{t('configNotice')}</p></div>
          )}

          {NFT_ADDRESS && meta && (
            <>
              {/* 状态条 */}
              <div className="card ops-grid">
                <div className="ops-item"><span className="ops-k">{t('nftMinted')}</span><span className="ops-v">{sold} / {Number(meta.maxSupply)}</span></div>
                <div className="ops-item"><span className="ops-k">{t('nftRemaining')}</span><span className="ops-v">{remaining}</span></div>
                <div className="ops-item"><span className="ops-k">{t('nftPrice')}</span><span className="ops-v">{fmtEth(meta.mintPrice)} ETH</span></div>
                <div className="ops-item"><span className="ops-k">{t('nftQuota')}</span><span className="ops-v">{fmtJph(meta.quotaPerNft)} JPH</span></div>
                <div className="ops-item"><span className="ops-k">{t('nftStatus')}</span><span className="ops-v">{meta.mintOpen ? t('nftOpen') : t('nftClosed')}</span></div>
              </div>

              {/* 铸造卡片 */}
              <div className="card">
                <h3>{t('nftMintTitle')}</h3>
                <p className="ref-text">{t('nftMintBody', { n: fmtEth(meta.mintPrice), q: fmtJph(meta.quotaPerNft) })}</p>
                {!authenticated || !account ? (
                  <button className="primary" onClick={login}>{t('login')}</button>
                ) : meta.mintOpen && remaining > 0 ? (
                  <button className="primary big" onClick={doMint} disabled={busy}>
                    {busy === t('actionMintNft') ? t('submitting') : t('nftMintBtn', { n: fmtEth(meta.mintPrice) })}
                  </button>
                ) : (
                  <div className="verify-note">{remaining === 0 ? t('nftSoldOut') : t('nftClosed')}</div>
                )}
              </div>

              {/* 我的 NFT */}
              {account && myNfts.length > 0 && (
                <div className="card">
                  <h3>{t('nftMy')}</h3>
                  {myNfts.map((n) => (
                    <div key={n.tokenId.toString()} className="nft-row">
                      <span className="nft-id">#{n.tokenId.toString()}</span>
                      <span className="balls small">
                        <i className="nft-ball">🎴</i>
                      </span>
                      <span className="nft-quota">{t('nftQuotaLabel', { n: fmtJph(n.quota) })}</span>
                      {n.claimed ? (
                        <span className="claimed-badge">{t('claimedLabel')}</span>
                      ) : (
                        <span className="win-badge">{t('nftUnclaimed')}</span>
                      )}
                    </div>
                  ))}
                  {claimable.total > 0n && (
                    <button className="primary big nft-claim-btn" onClick={doClaim} disabled={busy}>
                      {busy === t('actionClaimNft') ? t('submitting') : t('nftClaimBtn', { n: fmtJph(claimable.total) })}
                    </button>
                  )}
                </div>
              )}

              {/* 权益说明 */}
              <div className="card">
                <h3>{t('nftPerksTitle')}</h3>
                <ul className="nft-perks">
                  {(t('nftPerks') || '').split('|').map((p, i) => <li key={i}>{p}</li>)}
                </ul>
              </div>

              {/* 资金去向公示 */}
              <div className="card">
                <h3>{t('nftFundsTitle')}</h3>
                <p className="ref-text">{t('nftFundsBody')}</p>
                <div className="addr-row">
                  <span className="addr-label">NFT</span>
                  <code className="verify-hash">{fmtAddr(NFT_ADDRESS)}</code>
                  <a href={`${EXPLORER_URL}/address/${NFT_ADDRESS}`} target="_blank" rel="noreferrer" className="addr-link">↗</a>
                </div>
                <div className="addr-row">
                  <span className="addr-label">{t('tokenAddressLabel')}</span>
                  <code className="verify-hash">{fmtAddr(TOKEN_ADDRESS)}</code>
                  <a href={`${EXPLORER_URL}/address/${TOKEN_ADDRESS}`} target="_blank" rel="noreferrer" className="addr-link">↗</a>
                </div>
              </div>
            </>
          )}

          {msg && <div className={`toast ${msg.type}`}>{msg.text}</div>}
        </main>
      </div>
    </div>
  )
}
