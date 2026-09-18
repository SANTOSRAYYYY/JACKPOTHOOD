import { defineChain } from 'viem'

// ═══════════════════════════════════════════════════════════════
// 【主网上线】只改下面这个 MAINNET_CONFIG 对象，其余代码零改动
// 填好后把 USE_MAINNET 改为 true，并把 wrangler.toml 的
// AUTO_BUYBACK 改为 "false"（主网走 Safe 多签手动回购）
// ═══════════════════════════════════════════════════════════════
export const MAINNET_CONFIG = {
  chainId: 4663,
  chainName: 'Robinhood Chain',
  rpcUrl: 'https://rpc.mainnet.chain.robinhood.com',
  explorerUrl: 'https://explorer.chain.robinhood.com',
  jackpot: '', // TODO: 主网部署后填写合约地址
  token: '',   // TODO: 真实 JACKPOTHOOD 代币地址
  dexPair: '', // TODO: 主网 DEX 交易对（token/WETH）
  dexRouter: '', // TODO: 主网 DEX 路由
  dexWeth: '',   // TODO: 主网 WETH 地址
  dexPairCreated: 0, // TODO: 主网交易对创建区块（K 线扫描起点）
  jackpotCreated: 115715866, // V4 core+perks 重建（拆分版，首轮即时开）
  nft: '', // TODO: 主网创世 NFT 合约
  nftCreated: 0, // TODO: 主网创世 NFT 创建区块
}
export const USE_MAINNET = false

// ═══════════════════════════════════════════════════════════════
// 测试网配置（当前生效，无需改动）
// ═══════════════════════════════════════════════════════════════
const TESTNET = {
  chainId: 46630,
  chainName: 'Robinhood Chain Testnet',
  rpcUrl: 'https://rpc.testnet.chain.robinhood.com',
  explorerUrl: 'https://explorer.testnet.chain.robinhood.com',
  jackpot: '0x9fCB876196586B828A5c42e4287fFCB3BAACc806',
  token: '0xa4c7CC40653Db4af3E2b3642D992088De94Be427',
  dexPair: '0xff8EA0BfBe62f55e0A317814Be7e5817912794cb',
  dexRouter: '0x802EbEc5A32A8B70D0f84630B33B6728F7EeE18c',
  dexWeth: '0x9eB818e23E02f23dfD7e6b34f26A5E5Ebd698B99',
  dexPairCreated: 115712152, // 交易对创建区块（K 线扫描起点）
  jackpotCreated: 118940651, // V4.4 core+perks（质押两段式退出 + 购票推荐 5% 立付；字节码 24279B 贴近 EIP-170 上限）
  nft: '0xB51cE45F61E2E387a3b663a7bA0F51207834c38e', // 创世 NFT 合约
  nftCreated: 115712152, // 创世 NFT 合约创建区块
}

const ACTIVE = USE_MAINNET
  ? {
      chainId: MAINNET_CONFIG.chainId,
      chainName: MAINNET_CONFIG.chainName,
      rpcUrl: MAINNET_CONFIG.rpcUrl,
      explorerUrl: MAINNET_CONFIG.explorerUrl,
      jackpot: MAINNET_CONFIG.jackpot,
      token: MAINNET_CONFIG.token,
      dexPair: MAINNET_CONFIG.dexPair,
      dexRouter: MAINNET_CONFIG.dexRouter,
      dexWeth: MAINNET_CONFIG.dexWeth,
      dexPairCreated: MAINNET_CONFIG.dexPairCreated,
      jackpotCreated: MAINNET_CONFIG.jackpotCreated,
      nft: MAINNET_CONFIG.nft,
      nftCreated: MAINNET_CONFIG.nftCreated,
      isTestnet: false,
    }
  : { ...TESTNET, isTestnet: true }

export const IS_TESTNET = ACTIVE.isTestnet

export const rhChain = defineChain({
  id: ACTIVE.chainId,
  name: ACTIVE.chainName,
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [ACTIVE.rpcUrl] } },
  blockExplorers: { default: { name: 'Explorer', url: ACTIVE.explorerUrl } },
})

export const EXPLORER_URL = ACTIVE.explorerUrl

// Deployed contract address. Set VITE_JACKPOT_ADDRESS at build time
// (e.g. `VITE_JACKPOT_ADDRESS=0x... npm run build`) or hardcode it here.
export const JACKPOT_ADDRESS = import.meta.env.VITE_JACKPOT_ADDRESS || ACTIVE.jackpot

// Prize token decimals (JACKPOTHOOD uses 18).
export const JPH_DECIMALS = 18

// 平台代币与 DEX
export const TOKEN_ADDRESS = ACTIVE.token
export const DEX_PAIR = ACTIVE.dexPair
export const DEX_ROUTER = ACTIVE.dexRouter
export const DEX_WETH = ACTIVE.dexWeth
export const DEX_PAIR_CREATED = BigInt(ACTIVE.dexPairCreated || 0)
export const JACKPOT_CREATED = BigInt(ACTIVE.jackpotCreated || 0)
export const PERKS_ADDRESS = '0x6baefD034328A827F1bd08D6F1DaAed1c5A0e098' // V4.4 新 Perks（指向 PerkRouter）

// 社区轮预售 + 创世 NFT2 + PerkRouter（2026-09-14 测试网部署）
export const PERK_ROUTER = '0x9f63Cfc9e7cE76efFd0209504d8842c913B26D87'
export const PRESALE_ADDRESS = '0xa29c858E6d48b1d39a82E7009776c5D9f96b63D8'
export const NFT2_ADDRESS = '0xB9E8311a105C92b0fcEDe203F95f1DFe050335d2'

export const NFT_ADDRESS = ACTIVE.nft
export const NFT_CREATED = BigInt(ACTIVE.nftCreated || 0)

// 测试网官方水龙头（主网自动隐藏领水入口）
export const FAUCET_URL = 'https://faucet.testnet.chain.robinhood.com'

// Privy app ID — https://dashboard.privy.io
export const PRIVY_APP_ID = import.meta.env.VITE_PRIVY_APP_ID || 'cmt2qzizc00fi0cl9c95fy7zk'
