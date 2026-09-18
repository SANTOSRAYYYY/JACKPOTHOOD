// SPDX-License-Identifier: MIT
// HoodVRF 集成示例（Robinhood Chain 测试网）
// 依赖：npm i viem @noble/curves @noble/hashes
//
// 流程：request() 锁定一个未来 drand 轮次 → 该轮产出后从公开信标取签名 →
//       离线解压成 (x, y) 坐标 → fulfill(id, x, y) 提交 → 合约内链上验签 → 读 randomnessOf(id)。
// 任何人都可以履约（免许可），本示例自己履约自己的请求。

import { createPublicClient, createWalletClient, http, parseAbi } from 'viem'
import { bls12_381 } from '@noble/curves/bls12-381.js'
import { keccak_256 } from '@noble/hashes/sha3.js'

const RPC = 'https://rpc.testnet.chain.robinhood.com'
const VRF = '0xBA8c0e39183BCD209caAFaE986D50cDD7E2Abb09' // HoodVRF 测试网
const DRAND = 'https://api.drand.sh/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971'
const DRAND_GENESIS = 1692803367, DRAND_PERIOD = 3

const vrfAbi = parseAbi([
  'function request() payable returns (uint256)',
  'function fulfill(uint256 id, bytes sigX, bytes sigY)',
  'function randomnessOf(uint256) view returns (bytes32)',
  'function timeOfRound(uint64) view returns (uint64)',
  'event Requested(uint256 indexed id, address indexed consumer, uint64 drandRound, bool paid, bool fallbackMode)',
])

const hex48 = (n) => '0x' + n.toString(16).padStart(96, '0')

export async function requestAndFulfill(walletClient, account) {
  const pub = createPublicClient({ transport: http(RPC) })
  // 1) 请求（外部调用付 0.0002 ETH；白名单 consumer 免费）
  const hash = await walletClient.writeContract({
    address: VRF, abi: vrfAbi, functionName: 'request',
    value: 200000000000000n, account,
  })
  const receipt = await pub.waitForTransactionReceipt({ hash })
  const log = receipt.logs.find((l) => l.address.toLowerCase() === VRF.toLowerCase() && l.topics.length >= 3)
  const id = BigInt(log.topics[1])
  const drandRound = Number(BigInt('0x' + log.data.slice(2, 66)))
  console.log('request id =', id, ' drandRound =', drandRound)

  // 2) 等该轮产出
  const at = DRAND_GENESIS + (drandRound - 1) * DRAND_PERIOD
  const wait = at * 1000 - Date.now() + 3000
  if (wait > 0) await new Promise((r) => setTimeout(r, wait))

  // 3) 取信标签名并离线解压成坐标
  const { signature } = await fetch(`${DRAND}/public/${drandRound}`).then((r) => r.json())
  const G1 = bls12_381.G1.ProjectivePoint
  const sig = G1.fromHex(signature).toAffine()
  const sigX = hex48(sig.x), sigY = hex48(sig.y)
  const expected = '0x' + Buffer.from(keccak_256(Buffer.from(signature, 'hex'))).toString('hex')

  // 4) 履约（合约内完成 BLS 配对验签）
  const fh = await walletClient.writeContract({
    address: VRF, abi: vrfAbi, functionName: 'fulfill', args: [id, sigX, sigY], account,
  })
  await pub.waitForTransactionReceipt({ hash: fh })

  // 5) 读结果并与本地预期对照
  const rnd = await pub.readContract({ address: VRF, abi: vrfAbi, functionName: 'randomnessOf', args: [id] })
  console.log('randomness =', rnd, ' 本地一致:', rnd === expected)
  return rnd
}
