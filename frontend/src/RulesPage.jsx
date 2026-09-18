// GitBook-style rules page (subpage at /rules), fully localized
import { useEffect } from 'react'
import LangSwitcher from './LangSwitcher.jsx'
import { useI18n } from './i18n.js'
import { JACKPOT_ADDRESS } from './config.js'

const SECTION_KEYS = [
  { id: 'overview', key: 'overviewTitle' },
  { id: 'how-to-play', key: 'howtoTitle' },
  { id: 'prize-tiers', key: 'tiersTitle' },
  { id: 'schedule', key: 'scheduleTitle' },
  { id: 'gifting', key: 'giftingTitle' },
  { id: 'randomness', key: 'randTitle' },
  { id: 'buyback', key: 'buybackTitle' },
  { id: 'referral', key: 'referralTitle' },
  { id: 'security', key: 'securityTitle' },
]

const TIER_SHARES = ['40%', '25%', '15%', '12%', '5%', '3%']
const EXPLORER = 'https://explorer.testnet.chain.robinhood.com/address/'

export default function RulesPage() {
  const { t, tr, lang } = useI18n()

  useEffect(() => {
    document.title = t('siteTitle')
  }, [lang, t])

  const tierRows = tr('tiersRows') || []

  return (
    <div className="gitbook">
      <header className="gb-topbar"><div className="gb-topbar-inner">
        <a className="gb-brand" href="/">{t('rulesBack')}</a>
        <span className="gb-tag">{t('rulesTag')}</span>
        <span style={{ flex: 1 }} />
        <a className="tg-link gb-tg" href="https://t.me/jackpothood" target="_blank" rel="noreferrer">✈️ Telegram</a>
        <LangSwitcher />
      </div></header>
      <div className="gb-layout">
        <nav className="gb-sidebar">
          {SECTION_KEYS.map((s) => (
            <a key={s.id} href={`#${s.id}`}>{t(s.key)}</a>
          ))}
        </nav>
        <main className="gb-content">
          <h1>{t('rulesTitle')}</h1>
          <p className="gb-lead">{t('rulesLead')}</p>

          <section id="overview">
            <h2>{t('overviewTitle')}</h2>
            <p>{t('overviewP')}</p>
            <ul>
              {(tr('overviewB') || []).map((b, i) => <li key={i}>{b}</li>)}
            </ul>
          </section>

          <section id="how-to-play">
            <h2>{t('howtoTitle')}</h2>
            <ol>
              {(tr('howtoSteps') || []).map((s, i) => <li key={i}>{s}</li>)}
            </ol>
            <div className="gb-callout gb-callout-tip">
              <b>{t('howtoTip')}</b>
            </div>
          </section>

          <section id="prize-tiers">
            <h2>{t('tiersTitle')}</h2>
            <p>{t('tiersP')}</p>
            <table className="gb-table">
              <thead>
                <tr>{(tr('tiersTh') || []).map((h, i) => <th key={i}>{h}</th>)}</tr>
              </thead>
              <tbody>
                {tierRows.map((row, i) => (
                  <tr key={i}>
                    <td><b>{row[0]}</b></td>
                    <td>{row[1]}</td>
                    <td>{TIER_SHARES[i]}</td>
                    <td>{row[3]}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <p>{t('tiersP2')}</p>
            <p>{t('tiersCapNote')}</p>
            <div className="gb-callout gb-callout-warn">
              <b>{t('tiersWarn')}</b>
            </div>
          </section>

          <section id="schedule">
            <h2>{t('scheduleTitle')}</h2>
            <ul>
              {(tr('schedB') || []).map((b, i) => <li key={i}>{b}</li>)}
            </ul>
          </section>

          <section id="gifting">
            <h2>{t('giftingTitle')}</h2>
            <p>{t('giftingP')}</p>
            <ul>
              {(tr('giftingB') || []).map((b, i) => <li key={i}>{b}</li>)}
            </ul>
            <div className="gb-callout gb-callout-tip">
              <b>{t('giftingTip')}</b>
            </div>
          </section>

          <section id="randomness">
            <h2>{t('randTitle')}</h2>
            <p>{t('randP')}</p>
            <ol>
              {(tr('randSteps') || []).map((s, i) => <li key={i}>{s}</li>)}
            </ol>
            <p>{t('randP2')}</p>
            <div className="gb-callout gb-callout-tip">
              <b>{t('randTip')}</b>
            </div>
          </section>

          <section id="buyback">
            <h2>{t('buybackTitle')}</h2>
            <p>{t('buybackP')}</p>
            <ol>
              {(tr('buybackSteps') || []).map((s, i) => <li key={i}>{s}</li>)}
            </ol>
            <p>{t('buybackP2')}</p>
          </section>

          <section id="referral">
            <h2>{t('referralTitle')}</h2>
            <p>{t('referralP')}</p>
            <ul>
              {(tr('referralB') || []).map((b, i) => <li key={i}>{b}</li>)}
            </ul>
          </section>

          <section id="security">
            <h2>{t('securityTitle')}</h2>
            <ul>
              {(tr('securityB') || []).map((b, i) => <li key={i}>{b}</li>)}
            </ul>
            <div className="gb-callout gb-callout-warn">
              <b>{t('securityWarn')}</b>
            </div>
          </section>

          <p className="gb-foot">
            {t('contractWord')}: <a href={`${EXPLORER}${JACKPOT_ADDRESS}`} target="_blank" rel="noreferrer">{JACKPOT_ADDRESS.slice(0, 10)}…{JACKPOT_ADDRESS.slice(-6)}</a> ·
            Robinhood Chain Testnet (46630) · <a href="/">{t('backToLottery')}</a>
          </p>
        </main>
      </div>
    </div>
  )
}
