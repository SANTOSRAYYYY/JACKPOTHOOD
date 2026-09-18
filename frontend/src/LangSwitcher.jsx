import { useEffect, useRef, useState } from 'react'
import { LANGS, useI18n } from './i18n.js'

/// 语言切换器（🌐 下拉菜单）
export default function LangSwitcher() {
  const { lang, setLang } = useI18n()
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
    <div className="lang-switcher" ref={ref}>
      <button className="lang-btn" onClick={() => setOpen(!open)} aria-label="Language" title="Language">🌐</button>
      {open && (
        <div className="lang-menu">
          {LANGS.map((l) => (
            <button
              key={l.code}
              className={l.code === lang ? 'lang-active' : ''}
              onClick={() => { setLang(l.code); setOpen(false) }}
            >
              {l.label}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
