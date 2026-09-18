import React from 'react'
import ReactDOM from 'react-dom/client'
import { PrivyProvider } from '@privy-io/react-auth'
import App from './App.jsx'
import { rhChain, PRIVY_APP_ID } from './config.js'
import { I18nProvider, useI18n } from './i18n.js'
import './styles.css'

// 运行时错误可见化：真正的站点错误以红色徽章显示在左下角（自动过滤浏览器插件噪音），
// 便于远程排障 —— 用户复现报错后把徽章内容发回即可精准定位。
;(function installErrorBadge() {
  if (typeof window === 'undefined') return
  const NOISE = ['inpage.js', 'contentscript.js', 'injected.js', 'webhook.js', 'chrome-extension', 'moz-extension']
  function isOurs(src) {
    if (!src) return false
    if (NOISE.some((n) => src.toLowerCase().includes(n))) return false
    return true
  }
  function show(msg, src, line) {
    let el = document.getElementById('jh-err')
    if (!el) {
      el = document.createElement('div')
      el.id = 'jh-err'
      el.style.cssText = 'position:fixed;left:8px;bottom:8px;z-index:999999;max-width:92vw;background:#3a1412;color:#ffb4b0;border:1px solid #ff4b45;border-radius:10px;padding:10px 14px;font-size:12px;font-family:Consolas,monospace;white-space:pre-wrap;cursor:pointer;box-shadow:0 6px 20px rgba(0,0,0,.5)'
      el.onclick = () => el.remove()
      document.body.appendChild(el)
    }
    const where = src ? `
(${(src.split('/').pop() || src)}${line ? ':' + line : ''})` : ''
    el.textContent = '⚠ ' + msg + where
  }
  window.addEventListener('error', (e) => {
    if (isOurs(e.filename)) show(e.message || '未知错误', e.filename, e.lineno)
  })
  window.addEventListener('unhandledrejection', (e) => {
    const reason = e.reason
    if (reason && typeof reason === 'object' && reason.message) show(reason.message, reason.filename || '')
    else if (reason) show(String(reason))
  })
  window.addEventListener('load', () => {
    const el = document.getElementById('jh-err')
    if (el) el.remove()
  })
})()

// 错误边界：运行时异常显示可读信息，而不是黑屏
// 注意：class 声明不会提升，必须位于首次引用（渲染调用）之前
class ErrorBoundary extends React.Component {
  constructor(props) {
    super(props)
    this.state = { error: null }
  }
  static getDerivedStateFromError(error) {
    return { error }
  }
  render() {
    if (this.state.error) {
      return <ErrorNotice message={String(this.state.error)} />
    }
    return this.props.children
  }
}

function ErrorNotice({ message }) {
  const { t } = useI18n()
  return (
    <div className="setup-notice">
      <div className="setup-logo">JackpotHood</div>
      <p>{t('errorTitle')}</p>
      <pre style={{ whiteSpace: 'pre-wrap', color: '#ff4b45', fontSize: 12 }}>{message}</pre>
    </div>
  )
}

function SetupNotice() {
  const { t } = useI18n()
  return (
    <div className="setup-notice">
      <div className="setup-logo">JackpotHood</div>
      <p>{t('setupAlmost')}</p>
      <ol>
        <li>{t('setupLi1')}</li>
        <li>{t('setupLi2')}</li>
      </ol>
    </div>
  )
}

// Privy wallet auth. Set PRIVY_APP_ID in src/config.js before going live.
if (!PRIVY_APP_ID) {
  ReactDOM.createRoot(document.getElementById('root')).render(
    <I18nProvider><SetupNotice /></I18nProvider>,
  )
} else {
  ReactDOM.createRoot(document.getElementById('root')).render(
    <React.StrictMode>
      <I18nProvider>
        <ErrorBoundary>
          <PrivyProvider
            appId={PRIVY_APP_ID}
            config={{
              loginMethods: ['email', 'google', 'wallet'],
              defaultChain: rhChain,
              supportedChains: [rhChain],
              embeddedWallets: { createOnLogin: 'users-without-wallets' },
              appearance: { theme: 'dark', accentColor: '#00C805' },
            }}
          >
            <App />
          </PrivyProvider>
        </ErrorBoundary>
      </I18nProvider>
    </React.StrictMode>,
  )
}
