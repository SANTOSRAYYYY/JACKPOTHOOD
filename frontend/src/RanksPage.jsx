// 排行榜 /ranks —— 购票榜 / 邀请榜 / 获利榜（服务端聚合 /api/leaderboard，60s 轮询）
import { useEffect, useState } from 'react'
import { formatUnits } from 'viem'
import { useWallets } from '@privy-io/react-auth'
import LangSwitcher from './LangSwitcher.jsx'
import { useI18n } from './i18n.js'
import { EXPLORER_URL } from './config.js'

function fmtEthShort(v) {
  return (Math.round(Number(formatUnits(BigInt(v || 0), 18)) * 100) / 100).toString()
}
function shortAddr(a) {
  return a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '—'
}
const MEDALS = ['🥇', '🥈', '🥉']

export default function RanksPage() {
  const { t, lang } = useI18n()
  const { wallets } = useWallets()
  const [data, setData] = useState(null)

  // 高亮自己：与 StakePage 相同的钱包选择（localStorage 优先，否则最近连接）
  const ethWallets = wallets.filter((w) => w.type === 'ethereum')
  const [activeAddr] = useState(() => {
    try { return localStorage.getItem('jh_wallet') || '' } catch { return '' }
  })
  const savedWallet = ethWallets.find((w) => w.address.toLowerCase() === activeAddr.toLowerCase())
  const wallet = savedWallet
    || [...ethWallets].sort((a, b) => Number(b.connectedAt) - Number(a.connectedAt))[0]
    || null
  const me = (wallet?.address || '').toLowerCase()

  useEffect(() => {
    document.title = t('siteTitle')
  }, [lang, t])

  useEffect(() => {
    let stop = false
    const load = async () => {
      try {
        const res = await fetch('/api/leaderboard', { headers: { accept: 'application/json' } })
        const j = await res.json()
        if (!stop && j && j.ok) setData(j)
      } catch { /* ignore */ }
    }
    load()
    const timer = setInterval(load, 60000)
    return () => { stop = true; clearInterval(timer) }
  }, [])

  const boards = data?.boards || { tickets: [], inviters: [], winners: [] }

  const rankCell = (i) => <span className="rank-medal">{MEDALS[i] || i + 1}</span>
  const isMe = (addr) => me && addr.toLowerCase() === me
  const addrCell = (addr) => (
    <>
      <a className="rank-addr" href={`${EXPLORER_URL}/address/${addr}`} target="_blank" rel="noreferrer">
        {shortAddr(addr)}
      </a>
      {isMe(addr) && <span className="rank-you">{t('rankYouTag')}</span>}
    </>
  )
  const rowClass = (addr) => (isMe(addr) ? 'rank-me' : '')

  const boardDefs = [
    {
      key: 'tickets',
      title: `🎟️ ${t('boardTickets')}`,
      head: [t('rankCol'), t('addrCol'), t('ticketsCol')],
      rows: (boards.tickets || []).map((r, i) => (
        <tr key={r.addr} className={rowClass(r.addr)}>
          <td>{rankCell(i)}</td>
          <td>{addrCell(r.addr)}</td>
          <td>{Number(r.count).toLocaleString('en-US')}</td>
        </tr>
      )),
    },
    {
      key: 'inviters',
      title: `🤝 ${t('boardInviters')}`,
      head: [t('rankCol'), t('addrCol'), t('invitesCol'), t('earnedCol')],
      rows: (boards.inviters || []).map((r, i) => (
        <tr key={r.addr} className={rowClass(r.addr)}>
          <td>{rankCell(i)}</td>
          <td>{addrCell(r.addr)}</td>
          <td>{Number(r.invites).toLocaleString('en-US')}</td>
          <td>{fmtEthShort(r.earned)}</td>
        </tr>
      )),
    },
    {
      key: 'winners',
      title: `🏆 ${t('boardWinners')}`,
      head: [t('rankCol'), t('addrCol'), t('wonCol')],
      rows: (boards.winners || []).map((r, i) => (
        <tr key={r.addr} className={rowClass(r.addr)}>
          <td>{rankCell(i)}</td>
          <td>{addrCell(r.addr)}</td>
          <td>{fmtEthShort(r.won)}</td>
        </tr>
      )),
    },
  ]

  // updatedAt 为服务端 Date.now()（毫秒）；兼容秒级时间戳
  const updatedTs = data?.updatedAt ? (data.updatedAt > 1e12 ? data.updatedAt : data.updatedAt * 1000) : 0

  return (
    <div className="gitbook">
      <header className="gb-topbar"><div className="gb-topbar-inner">
        <a className="gb-brand" href="/">{t('rulesBack')}</a>
        <span className="gb-tag">{t('navRanks')}</span>
        <span style={{ flex: 1 }} />
        <a className="tg-link gb-tg" href="https://t.me/jackpothood" target="_blank" rel="noreferrer">✈️ Telegram</a>
        <LangSwitcher />
      </div></header>
      <div className="gb-layout">
        <main className="gb-content stake-content">
          <h1>📈 {t('navRanks')}</h1>
          <p className="gb-lead">{t('ranksLead')}</p>

          {!data ? (
            <div className="card"><p className="ref-text">{t('loading')}</p></div>
          ) : (
            <>
              <div className="ranks-grid">
                {boardDefs.map((b) => (
                  <div key={b.key} className="card rank-card">
                    <h3>{b.title}</h3>
                    {b.rows.length === 0 ? (
                      <p className="rank-empty">{t('emptyBoard')}</p>
                    ) : (
                      <table className="gb-table rank-table">
                        <thead><tr>{b.head.map((h, i) => <th key={i}>{h}</th>)}</tr></thead>
                        <tbody>{b.rows}</tbody>
                      </table>
                    )}
                  </div>
                ))}
              </div>
              {updatedTs > 0 && (
                <p className="rank-updated">{t('updatedAt', { time: new Date(updatedTs).toLocaleString() })}</p>
              )}
            </>
          )}
        </main>
      </div>
    </div>
  )
}
