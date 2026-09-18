// 质押盈亏平衡点计算器 /calc —— 纯前端精确期望计算（64 种命中组合枚举 + 二项封顶期望 + 二分求平衡点）
import { useEffect, useMemo, useState } from 'react'
import LangSwitcher from './LangSwitcher.jsx'
import { useI18n } from './i18n.js'

const SHARES = [0.40, 0.25, 0.15, 0.12, 0.05, 0.03]
const PROBS = [1e-6, 9e-6, 9e-5, 9e-4, 9e-3, 9e-2]
// 小奖项公平赔率封顶（ETH/中奖注）= 封顶倍数 × 0.001：头奖不限，末5→末1 为 100000×~10×
const CAPS = [Infinity, 100, 10, 1, 0.1, 0.01]
const T_MAX = 1e7

function lgamma(x) { // Lanczos 近似，供 log C(T,k) 使用（T 可达 1e6+）
  const c = [0.99999999999980993, 676.5203681218851, -1259.1392167224028, 771.32342877765313,
    -176.61502916214059, 12.507343278686905, -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7]
  if (x < 0.5) return Math.log(Math.PI / Math.sin(Math.PI * x)) - lgamma(1 - x)
  x -= 1
  let a = c[0]
  const t = x + 7.5
  for (let i = 1; i < 9; i++) a += c[i] / (x + i)
  return 0.5 * Math.log(2 * Math.PI) + (x + 0.5) * Math.log(t) - t + Math.log(a)
}

// E[min(pot, cap·U)]，U ~ Binomial(T, p)：log 空间起手 + pmf 递推，均值 ±6σ 截断（小均值右尾兜底 30 项）
function expectedCappedPayout(pot, cap, T, p) {
  if (pot <= 0 || T <= 0 || p <= 0) return 0
  const hit = 1 - Math.pow(1 - p, T)
  if (cap === Infinity) return pot * hit // 头奖不限：命中即派整档
  if (hit < 1e-12) return 0
  const mean = T * p
  const sd = Math.sqrt(T * p * (1 - p))
  const kLo = Math.max(1, Math.floor(mean - 6 * sd)) // k=0 时 min(pot,0)=0，跳过
  const kHi = Math.min(T, Math.max(Math.ceil(mean + 6 * sd), kLo + 30))
  const logP = Math.log(p), logQ = Math.log(1 - p)
  let w = Math.exp(lgamma(T + 1) - lgamma(kLo + 1) - lgamma(T - kLo + 1) + kLo * logP + (T - kLo) * logQ)
  const ratio = p / (1 - p)
  let e = Math.min(pot, cap * kLo) * w
  for (let k = kLo + 1; k <= kHi; k++) {
    w *= ((T - k + 1) / k) * ratio
    e += Math.min(pot, cap * k) * w
  }
  return e
}

// 经济模型（与 JackpotHood core 一致）：售票 90% 进票款银行、10% 抽水给质押者；
// 派彩基数 P = 滚存 R + 本期售票 90% + 质押储备 S；
// 结算时 ticketBank 含本期售票 90%（购票时即时入账），故兑付/共担基准 bankEff = 当前 bank + sales90
function analyze(R, bank, S, T, feeRate) { // feeRate: 0.12 或 0.07
  const sales90 = 0.0009 * T, feeBuy = 0.0001 * T
  const bankEff = bank + sales90
  const P = R + sales90 + S
  const pots = SHARES.map((s) => P * s)
  const hits = PROBS.map((p) => 1 - Math.pow(1 - p, T))
  // 封顶后派彩依赖中奖注数：命中条件下的条件期望派彩 = ePot_i / hit_i（hit_i=0 时贡献 0）
  const condPots = pots.map((pot, i) => {
    const e = expectedCappedPayout(pot, CAPS[i], T, PROBS[i])
    return hits[i] > 0 ? e / hits[i] : 0
  })
  let eLoss = 0, eClaimed = 0
  for (let mask = 0; mask < 64; mask++) { // 64 种命中组合精确枚举
    let prob = 1, reserve = 0
    for (let i = 0; i < 6; i++) {
      if (mask & (1 << i)) { prob *= hits[i]; reserve += condPots[i] }
      else prob *= 1 - hits[i]
    }
    const eff = Math.min(reserve, bankEff + S)
    eClaimed += prob * eff
    eLoss += prob * Math.max(0, eff - bankEff)
  }
  const income = feeBuy + feeRate * eClaimed
  return { P, eClaimed, eLoss, income, net: income - eLoss }
}

// 平衡点 T*：net(T)=0 在 T∈[0, 1e7] 二分求解；net(1e7)<0 → 现实不可达（null）。
// 注意 net(0) 恒为 0（无售票即无命中、无损益），故「net(0)≥0 则 T*=0」按其实际意图实现为：
// 净亏区间不存在（任意销量净损益均 ≥0）→ T*=0；否则在净亏点与 1e7 之间二分“由负转正”的保本点
function breakeven(R, bank, S, feeRate) {
  const f = (T) => analyze(R, bank, S, T, feeRate).net
  if (f(T_MAX) < 0) return null
  let tNeg = -1
  const N = 400
  for (let i = 0; i <= N; i++) {
    const tt = Math.round(Math.pow(T_MAX, i / N)) // 对数网格 1..1e7
    if (f(tt) < 0) tNeg = tt
  }
  if (tNeg < 0) return 0
  let lo = tNeg, hi = T_MAX
  for (let i = 0; i < 60; i++) {
    const mid = (lo + hi) / 2
    if (f(mid) >= 0) hi = mid
    else lo = mid
  }
  return hi
}

const num = (s) => Math.max(0, Number(s) || 0)
const fmt4 = (x) => x.toFixed(4)
const fmtInt = (x) => Math.round(x).toLocaleString('en-US')

export default function CalcPage() {
  const { t, lang } = useI18n()
  const [R, setR] = useState('0')
  const [bank, setBank] = useState('0')
  const [S, setS] = useState('0')
  const [T, setT] = useState('200')
  const [feeRate, setFeeRate] = useState(0.12)

  useEffect(() => {
    document.title = t('siteTitle')
  }, [lang, t])

  // 预填链上参数：R = max(0, 奖池 − 本期售票×0.9)，bank = ticketBank，S = 质押储备
  useEffect(() => {
    let cancelled = false
    fetch('/api/state', { headers: { accept: 'application/json' } })
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => {
        if (cancelled || !d || !d.ok) return
        const eth = (x) => String(Number(x) / 1e18)
        const prize = BigInt(d.assets?.prize || 0)
        const rev = d.round ? BigInt(d.round.ticketRevenue || 0) : 0n
        const roll = prize - (rev * 9n) / 10n
        setR(eth(roll > 0n ? roll : 0n))
        setBank(eth(BigInt(d.ticketBank || 0)))
        setS(eth(BigInt(d.assets?.stake || 0)))
      })
      .catch(() => { /* API 不可用：保留手动默认值 */ })
    return () => { cancelled = true }
  }, [])

  // 输入变化 150ms 防抖后再算（T 大时二项求和 + 平衡点扫描较重）
  const [deb, setDeb] = useState(() => ({ R: 0, bank: 0, S: 0, T: 200, feeRate: 0.12 }))
  useEffect(() => {
    const id = setTimeout(() => {
      setDeb({ R: num(R), bank: num(bank), S: num(S), T: num(T), feeRate })
    }, 150)
    return () => clearTimeout(id)
  }, [R, bank, S, T, feeRate])

  const calc = useMemo(() => {
    const { R: vR, bank: vBank, S: vS, T: vT, feeRate: fee } = deb
    const res = analyze(vR, vBank, vS, vT, fee)
    const tStar = breakeven(vR, vBank, vS, fee)
    // 情景表：T 取 [当前 T, T*, 2×T*, 5×T*]；平衡点不可达时退化为当前 T 的倍数
    const raw = tStar === null ? [vT, vT * 2, vT * 5, vT * 10] : [vT, tStar, tStar * 2, tStar * 5]
    const rows = [...new Set(raw.map((x) => Math.round(x)))]
      .map((tt) => ({ T: tt, ...analyze(vR, vBank, vS, tt, fee) }))
    return { res, tStar, rows }
  }, [deb])

  const { res, tStar, rows } = calc

  return (
    <div className="gitbook">
      <header className="gb-topbar"><div className="gb-topbar-inner">
        <a className="gb-brand" href="/">{t('rulesBack')}</a>
        <span className="gb-tag">{t('navCalc')}</span>
        <span style={{ flex: 1 }} />
        <a className="tg-link gb-tg" href="https://t.me/jackpothood" target="_blank" rel="noreferrer">✈️ Telegram</a>
        <LangSwitcher />
      </div></header>
      <div className="gb-layout">
        <main className="gb-content">
          <h1>{t('calcTitle')}</h1>
          <p className="gb-lead">{t('calcLead')}</p>

          <section id="inputs">
            <h2>{t('calcInputs')}</h2>
            <div className="calc-grid">
              <label className="calc-field">
                <span>{t('calcPool')}</span>
                <input type="number" min="0" step="0.01" value={R} onChange={(e) => setR(e.target.value)} />
              </label>
              <label className="calc-field">
                <span>{t('calcBank')}</span>
                <input type="number" min="0" step="0.01" value={bank} onChange={(e) => setBank(e.target.value)} />
              </label>
              <label className="calc-field">
                <span>{t('calcStake')}</span>
                <input type="number" min="0" step="0.01" value={S} onChange={(e) => setS(e.target.value)} />
              </label>
              <label className="calc-field">
                <span>{t('calcTickets')}</span>
                <input type="number" min="0" step="1" value={T} onChange={(e) => setT(e.target.value)} />
              </label>
            </div>
            <div className="calc-fee">
              <span>{t('calcFeeRate')}</span>
              <label>
                <input type="radio" name="calcFee" checked={feeRate === 0.12} onChange={() => setFeeRate(0.12)} />
                {t('calcFeeNone')}
              </label>
              <label>
                <input type="radio" name="calcFee" checked={feeRate === 0.07} onChange={() => setFeeRate(0.07)} />
                {t('calcFeeRef')}
              </label>
            </div>
          </section>

          <section id="outputs">
            <h2>{t('calcOutputs')}</h2>
            <div className="calc-out-grid">
              <div className="calc-out"><span>{t('calcBase')}</span><b>{fmt4(res.P)}</b></div>
              <div className="calc-out"><span>{t('calcEClaimed')}</span><b>{fmt4(res.eClaimed)}</b></div>
              <div className="calc-out"><span>{t('calcELoss')}</span><b>{fmt4(res.eLoss)}</b></div>
              <div className="calc-out"><span>{t('calcIncome')}</span><b>{fmt4(res.income)}</b></div>
              <div className="calc-out">
                <span>{t('calcNet')}</span>
                <b className={res.net >= 0 ? 'calc-pos' : 'calc-neg'}>{fmt4(res.net)}</b>
              </div>
            </div>

            <div className="calc-tstar">
              <span>{t('calcBreakeven')}</span>
              {tStar === null ? (
                <div className="calc-tstar-num calc-neg">—</div>
              ) : (
                <div className="calc-tstar-num">
                  {Math.ceil(tStar).toLocaleString('en-US')}
                  <small>{t('calcPerRound')}</small>
                </div>
              )}
            </div>
            {tStar === null ? (
              <div className="gb-callout gb-callout-warn"><b>{t('calcUnreachable')}</b></div>
            ) : (
              <p className={`calc-note ${res.net >= 0 ? 'calc-pos' : 'calc-neg'}`}>
                {res.net >= 0
                  ? t('calcNetPos')
                  : t('calcNetNeg', { x: Math.ceil(tStar).toLocaleString('en-US') })}
              </p>
            )}
            <p className="calc-note">{t('calcCapNote')}</p>
          </section>

          <section id="scenarios">
            <h2>{t('calcTableTitle')}</h2>
            <table className="gb-table calc-table">
              <thead>
                <tr>
                  <th>{t('calcColT')}</th>
                  <th>{t('calcIncome')}</th>
                  <th>{t('calcELoss')}</th>
                  <th>{t('calcNet')}</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.T}>
                    <td>{fmtInt(r.T)}</td>
                    <td>{fmt4(r.income)}</td>
                    <td>{fmt4(r.eLoss)}</td>
                    <td className={r.net >= 0 ? 'calc-pos' : 'calc-neg'}>{fmt4(r.net)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </section>

          <p className="gb-foot">
            <a href="/">{t('backToLottery')}</a> · <a href="/rules">{t('rules')}</a>
          </p>
        </main>
      </div>
    </div>
  )
}
