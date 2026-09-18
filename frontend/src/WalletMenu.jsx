// 钱包选择菜单：切换已链接的以太坊钱包 / 链接新钱包 / 退出登录
import { useEffect, useRef, useState } from 'react'

function walletLabel(w, t) {
  const ct = (w.walletClientType || '').toLowerCase()
  if (ct === 'privy' || ct === 'privy-v2') return t('embeddedWalletLabel')
  if (ct === 'metamask') return 'MetaMask'
  if (ct === 'coinbase_wallet' || ct === 'coinbase') return 'Coinbase'
  if (ct.includes('okx')) return 'OKX'
  if (ct === 'bybit_wallet') return 'Bybit'
  if (ct === 'rabby_wallet') return 'Rabby'
  if (ct === 'brave_wallet') return 'Brave'
  return t('externalWalletLabel')
}

export default function WalletMenu({ wallets, wallet, onSelect, onConnect, onLogout, t }) {
  const [open, setOpen] = useState(false)
  const ref = useRef(null)

  useEffect(() => {
    const close = (e) => {
      if (ref.current && !ref.current.contains(e.target)) setOpen(false)
    }
    document.addEventListener('mousedown', close)
    return () => document.removeEventListener('mousedown', close)
  }, [])

  return (
    <div className="wallet-menu" ref={ref}>
      <button className="wallet-chip" onClick={() => setOpen(!open)}>
        <span className="addr">{wallet ? `${wallet.address.slice(0, 6)}…${wallet.address.slice(-4)}` : '…'}</span>
        {wallet && <span className="wallet-type">{walletLabel(wallet, t)}</span>}
        <span className="wallet-caret">▾</span>
      </button>
      {open && (
        <div className="wallet-dropdown">
          <div className="wallet-dropdown-title">{t('walletMenu')}</div>
          {wallets.map((w) => (
            <button
              key={w.address}
              className={wallet && w.address === wallet.address ? 'wallet-item active' : 'wallet-item'}
              onClick={() => { onSelect(w.address); setOpen(false) }}
            >
              <span className="wallet-item-main">
                <span className="wallet-item-addr" title={w.address}>
                  {w.address.slice(0, 10)}…{w.address.slice(-6)}
                </span>
                <span className="wallet-item-type">{walletLabel(w, t)}</span>
              </span>
              {wallet && w.address === wallet.address && <span className="wallet-check">✓</span>}
            </button>
          ))}
          <div className="wallet-divider" />
          <button className="wallet-item" onClick={() => { setOpen(false); window.location.href = '/me' }}><span className="wallet-item-main"><span className="wallet-item-addr">👤 {t('navMe')}</span></span></button>
          <button className="wallet-item" onClick={() => { setOpen(false); onConnect() }}>
            <span className="wallet-item-main"><span className="wallet-item-addr">➕ {t('linkWallet')}</span></span>
          </button>
          <button className="wallet-item danger" onClick={() => { setOpen(false); onLogout() }}>
            <span className="wallet-item-main"><span className="wallet-item-addr">⏻ {t('logout')}</span></span>
          </button>
        </div>
      )}
    </div>
  )
}
