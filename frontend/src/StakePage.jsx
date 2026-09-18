// 质押页 /stake —— ETH 质押瓜分抽水分红（快照机制）+ JPH 质押换每日免费票（分档）
import { useEffect, useMemo, useState } from 'react'
import { createPublicClient, createWalletClient, custom, http, formatUnits } from 'viem'
import { usePrivy, useWallets } from '@privy-io/react-auth'
import LangSwitcher from './LangSwitcher.jsx'
import { useI18n } from './i18n.js'
import { rhChain, EXPLORER_URL, JACKPOT_ADDRESS, PERKS_ADDRESS, JPH_DECIMALS } from './config.js'
import { jackpotAbi, perksAbi } from './abi.js'

function fmtEth(v) {
  return formatUnits(v || 0n, 18)
}
function fmtJph(v) {
  const s = formatUnits(v || 0n, JPH_DECIMALS)
  const [a, b = ''] = s.split('.')
  return `${Number(a).toLocaleString('en-US')}.${(b + '0000').slice(0, 2)}`
}
function fmtAddr(a) {
  return a ? `${a.slice(0, 10)}…${a.slice(-6)}` : '—'
}

export default function StakePage() {
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

  const [state, setState] = useState(null)
  const [ethAmt, setEthAmt] = useState('0.1')
  const [jphAmt, setJphAmt] = useState('1000')
  const [busy, setBusy] = useState('')
  const [msg, setMsg] = useState(null)

  useEffect(() => {
    document.title = t('stakeTitle')
  }, [lang, t])

  const load = async () => {
    if (!JACKPOT_ADDRESS) return
    try {
      const [totalEth, pool, myEth, myPending, myJph, myPerkRate, myPerkStored, myReq] = await Promise.all([
        publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'totalEthStaked' }),
        publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'stakingPool' }),
        account ? publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'ethStaked', args: [account] }) : 0n,
        account ? publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'pendingStakeRewards', args: [account] }) : 0n,
        account ? publicClient.readContract({ address: PERKS_ADDRESS, abi: perksAbi, functionName: 'jphStaked', args: [account] }) : 0n,
        account ? publicClient.readContract({ address: PERKS_ADDRESS, abi: perksAbi, functionName: 'jphPerkPerDay', args: [account] }) : 0n,
        account ? publicClient.readContract({ address: PERKS_ADDRESS, abi: perksAbi, functionName: 'perkBalance', args: [account] }) : 0n,
        account ? publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'unstakeReqOf', args: [account] }).catch(() => [0n, 0n]) : [0n, 0n],
      ])
      // 挂单成熟判定：申请所记轮次到达终态（2=已开奖 / 3=作废）才可领取
      let reqSettled = false
      if (myReq[0] > 0n) {
        const rr = await publicClient.readContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'getRound', args: [myReq[1]] }).catch(() => null)
        reqSettled = rr ? Number(rr.status) >= 2 : false
      }
      setState({ totalEth, pool, myEth, myPending, myJph, myPerkRate, myPerkStored, reqAmount: myReq[0], reqRoundId: myReq[1], reqSettled })
    } catch { /* ignore */ }
  }

  useEffect(() => {
    load()
    const timer = setInterval(load, 10000)
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
      const receipt = await publicClient.waitForTransactionReceipt({ hash })
      setMsg({ type: receipt.status === 'success' ? 'ok' : 'error', text: receipt.status === 'success' ? t('txConfirmed', { name }) : t('txReverted', { name }) })
      await load()
    } catch (e) {
      setMsg({ type: 'error', text: t('txFailed', { name, msg: e.shortMessage || e.message }) })
    } finally {
      setBusy('')
    }
  }

  const stakeEth = () => {
    const v = Number(ethAmt)
    if (!(v > 0)) return
    sendTx(t('actionStakeEth'), (wc) => wc.writeContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'stakeEth', value: BigInt(Math.floor(v * 1e18)), account, chain: rhChain }))
  }
  const requestUnstake = () => {
    if (!state?.myEth) return
    sendTx(t('actionUnstakeEth'), (wc) => wc.writeContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'requestUnstake', args: [state.myEth], account, chain: rhChain }))
  }
  const finalizeUnstake = () => {
    sendTx(t('actionUnstakeEth'), (wc) => wc.writeContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'finalizeUnstake', account, chain: rhChain }))
  }
  const claimRewards = () => sendTx(t('actionClaimRewards'), (wc) => wc.writeContract({ address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'claimStakeRewards', account, chain: rhChain }))
  const stakeJph = () => {
    const v = Number(jphAmt)
    if (!(v > 0)) return
    sendTx(t('actionStakeJph'), (wc) => wc.writeContract({ address: PERKS_ADDRESS, abi: perksAbi, functionName: 'stakeJph', args: [BigInt(Math.floor(v * 1e18))], account, chain: rhChain }))
  }
  const unstakeJph = () => {
    if (!state?.myJph) return
    sendTx(t('actionUnstakeJph'), (wc) => wc.writeContract({ address: PERKS_ADDRESS, abi: perksAbi, functionName: 'unstakeJph', args: [state.myJph], account, chain: rhChain }))
  }

  return (
    <div className="gitbook">
      <header className="gb-topbar"><div className="gb-topbar-inner">
        <a className="gb-brand" href="/">{t('rulesBack')}</a>
        <span className="gb-tag">{t('stakeTitle')}</span>
        <span style={{ flex: 1 }} />
        <a className="tg-link gb-tg" href="https://t.me/jackpothood" target="_blank" rel="noreferrer">✈️ Telegram</a>
        <LangSwitcher />
      </div></header>
      <div className="gb-layout">
        <main className="gb-content stake-content">
          <h1>💎 {t('stakeTitle')}</h1>
          <p className="gb-lead">{t('stakeLead')}</p>

          {/* 全局池状态 */}
          {state && (
            <div className="card ops-grid">
              <div className="ops-item"><span className="ops-k">{t('stakeTotalLabel')}</span><span className="ops-v">{fmtEth(state.totalEth)} ETH</span></div>
              <div className="ops-item"><span className="ops-k">{t('stakePoolLabel')}</span><span className="ops-v">{fmtEth(state.pool)} ETH</span></div>
              <div className="ops-item"><span className="ops-k">{t('stakeHow')}</span><span className="ops-v">{t('stakeHowValue')}</span></div>
            </div>
          )}

          {!authenticated || !account ? (
            <div className="card"><button className="primary" onClick={login}>{t('login')}</button></div>
          ) : (
            <>
              {/* ETH 质押 */}
              <div className="card">
                <h3>🟢 {t('ethStakeTitle')}</h3>
                <p className="ref-text">{t('ethStakeBody')}</p>
                <div className="air-row">
                  <label className="air-field">
                    <span>ETH</span>
                    <input type="number" min="0" step="0.01" value={ethAmt} onChange={(e) => setEthAmt(e.target.value)} />
                  </label>
                  <button className="primary" disabled={busy} onClick={stakeEth}>
                    {busy === t('actionStakeEth') ? t('submitting') : t('stakeEthBtn')}
                  </button>
                </div>
                {state && (state.myEth > 0n || state.reqAmount > 0n) && (
                  <div className="stake-my">
                    {state.myEth > 0n && <span>{t('myStaked', { n: fmtEth(state.myEth) })}</span>}
                    {state.myPending > 0n && (
                      <button className="ghost" disabled={busy} onClick={claimRewards}>
                        {busy === t('actionClaimRewards') ? t('submitting') : t('claimRewardsBtn', { n: fmtEth(state.myPending) })}
                      </button>
                    )}
                    {state.reqAmount > 0n ? (
                      state.reqSettled ? (
                        <button className="primary" disabled={busy} onClick={finalizeUnstake}>
                          {busy === t('actionUnstakeEth') ? t('submitting') : t('unstakeClaim')}
                        </button>
                      ) : (
                        <span className="verify-note">{t('unstakePending', { n: fmtEth(state.reqAmount), r: Number(state.reqRoundId) })}</span>
                      )
                    ) : (
                      state.myEth > 0n && (
                        <>
                          <button className="ghost" disabled={busy} onClick={requestUnstake}>
                            {busy === t('actionUnstakeEth') ? t('submitting') : t('unstakeRequest')}
                          </button>
                          <span className="verify-note">{t('unstakeMatureNote')}</span>
                        </>
                      )
                    )}
                  </div>
                )}
              </div>

              {/* JPH 质押 */}
              <div className="card">
                <h3>🟡 {t('jphStakeTitle')}</h3>
                <p className="ref-text">{t('jphStakeBody')}</p>
                <div className="air-row">
                  <label className="air-field">
                    <span>JACKPOTHOOD</span>
                    <input type="number" min="0" value={jphAmt} onChange={(e) => setJphAmt(e.target.value)} />
                  </label>
                  <button className="primary" disabled={busy} onClick={stakeJph}>
                    {busy === t('actionStakeJph') ? t('submitting') : t('stakeJphBtn')}
                  </button>
                </div>
                {state && state.myJph > 0n && (
                  <div className="stake-my">
                    <span>{t('myStakedJph', { n: fmtJph(state.myJph) })} · {t('perkBalanceLabel', { n: Number(state.myPerkStored), perDay: Number(state.myPerkRate) })}</span>
                    <button className="ghost" disabled={busy} onClick={unstakeJph}>{t('unstakeBtn')}</button>
                  </div>
                )}
                <table className="gb-table stake-tiers">
                  <thead><tr><th>JPH {t('stakedWord')}</th><th>{t('freePerDay')}（{t('storableWord')}）</th></tr></thead>
                  <tbody>
                    <tr className={state && state.myJph >= 100_000n * 10n ** 18n ? 'tier-on' : ''}>
                      <td>100,000</td><td>1</td>
                    </tr>
                    <tr className={state && state.myJph >= 1_000_000n * 10n ** 18n ? 'tier-on' : ''}>
                      <td>1,000,000</td><td>10</td>
                    </tr>
                    <tr className={state && state.myJph >= 10_000_000n * 10n ** 18n ? 'tier-on' : ''}>
                      <td>10,000,000</td><td>100</td>
                    </tr>
                  </tbody>
                </table>
                <p className="verify-note">⚡ {t('perkLinearNote')}</p>
              </div>

              <div className="card">
                <h3>📖 {t('stakeMechanicsTitle')}</h3>
                <ul className="nft-perks">
                  {(t('stakeMechanics') || '').split('|').map((p, i) => <li key={i}>{p}</li>)}
                </ul>
              </div>

              <div className="addr-row">
                <span className="addr-label">{t('opsAdmin')}</span>
                <code className="verify-hash">{fmtAddr(JACKPOT_ADDRESS)}</code>
                <a href={`${EXPLORER_URL}/address/${JACKPOT_ADDRESS}`} target="_blank" rel="noreferrer" className="addr-link">↗</a>
              </div>
            </>
          )}
          {msg && <div className={`toast ${msg.type}`}>{msg.text}</div>}
        </main>
      </div>
    </div>
  )
}
