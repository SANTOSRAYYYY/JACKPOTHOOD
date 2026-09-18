// JackpotHood V3 keeper — Cloudflare Worker
// 1) Serves the static frontend (assets binding)
// 2) Runs the daily draw job on a cron trigger (every 2 minutes, UTC)
//
// Secrets/vars:
//   KEEPER_PK       keeper private key (secret, no special privileges needed)
//   CONTRACT_ADDRESS deployed JackpotHood address (var)
//   RPC_URL         Robinhood Chain RPC (var)

import { createPublicClient, createWalletClient, http, defineChain, parseAbi } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'

const rhChain = defineChain({
  id: 46630,
  name: 'Robinhood Chain Testnet',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['https://rpc.testnet.chain.robinhood.com'] } },
})

// V3: ETH 奖池、6 位号码、5 奖级、无回购（keeper 只负责开奖与开启下一期）
const jackpotAbi = parseAbi([
  'function currentRoundId() view returns (uint256)',
  'function getRound(uint256 roundId) view returns ((uint64 salesEnd, uint64 drawAt, uint64 randomBlock, uint64 claimDeadline, uint256 prizePool, uint256 totalTickets, uint256 ticketRevenue, uint256 ticketFee, uint48 winningPacked, bytes32 commitHash, bytes32 seedHash, uint256[6] tierPots, uint256[6] tierUnits, uint256[6] tierClaimed, bool swept, uint8 status) round)',
  'function commitDraw(uint256 roundId)',
  'function snapshotCommitHash(uint256 roundId)',
  'function settleDraw(uint256 roundId)',
  'function startRound()',
])

async function readRound(publicClient, address, roundId) {
  return publicClient.readContract({
    address,
    abi: jackpotAbi,
    functionName: 'getRound',
    args: [roundId],
  })
}

async function sendAndWait(walletClient, publicClient, call) {
  const hash = await walletClient.writeContract(call)
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`tx reverted: ${hash}`)
  return receipt
}

async function runDrawJob(env, address) {
  const pk = env.KEEPER_PK
  if (!pk) {
    console.log('keeper: KEEPER_PK secret not set, skipping')
    return { action: 'skipped-no-pk' }
  }
  const rpc = env.RPC_URL || rhChain.rpcUrls.default.http[0]
  const account = privateKeyToAccount(pk)
  const publicClient = createPublicClient({ chain: rhChain, transport: http(rpc) })
  const walletClient = createWalletClient({ chain: rhChain, account, transport: http(rpc) })

  const nowSec = BigInt(Math.floor(Date.now() / 1000))
  const summary = { contract: address, round: 0, status: -1, drawAt: 0, action: 'none' }

  try {
    const rid = await publicClient.readContract({ address, abi: jackpotAbi, functionName: 'currentRoundId' })
    const r = await readRound(publicClient, address, rid)
    summary.round = Number(rid)
    summary.status = Number(r.status)
    summary.drawAt = Number(r.drawAt)
    console.log('keeper tick', { round: rid.toString(), status: Number(r.status), drawAt: r.drawAt.toString(), now: nowSec.toString() })

    // 开奖扫描：近期 5 期窗口内每期都要处理（停售窗口购票会预创建下一期）
    const scanFloor = Math.max(1, Number(rid) - 4)
    for (let id = Number(rid); id >= scanFloor; id--) {
      let rr = await readRound(publicClient, address, BigInt(id))
      if (rr.drawAt === 0n) continue

      if (Number(rr.status) === 0 && nowSec >= rr.drawAt) {
        await sendAndWait(walletClient, publicClient, {
          address, abi: jackpotAbi, functionName: 'commitDraw', args: [BigInt(id)],
        })
        console.log('keeper: committed draw for round', id)
        summary.action = summary.action === 'none' ? 'committed' : summary.action + '+committed'
        rr = await readRound(publicClient, address, BigInt(id))
      }

      if (Number(rr.status) === 1) {
        // 公证快照：承诺块一出块（~0.2s）就永久存哈希 → settle 不再受 256 块窗口限制
        let snaps = 0
        while (rr.commitHash === '0x0000000000000000000000000000000000000000000000000000000000000000' && snaps < 6) {
          const bn = await publicClient.getBlockNumber()
          if (bn <= rr.randomBlock) {
            await new Promise((r) => setTimeout(r, 2000))
            snaps++
            continue
          }
          try {
            await sendAndWait(walletClient, publicClient, {
              address, abi: jackpotAbi, functionName: 'snapshotCommitHash', args: [BigInt(id)],
            })
            console.log('keeper: snapshotted hash for round', id)
            rr = await readRound(publicClient, address, BigInt(id))
            break
          } catch (e) {
            const msg = String(e.shortMessage || e.message || '')
            if (msg.includes('hash window passed')) {
              // 极端情况窗口错过：重新承诺新区块后继续
              await sendAndWait(walletClient, publicClient, {
                address, abi: jackpotAbi, functionName: 'commitDraw', args: [BigInt(id)],
              })
              console.log('keeper: re-committed draw for round', id)
              rr = await readRound(publicClient, address, BigInt(id))
            } else {
              throw e
            }
          }
          snaps++
        }
        if (rr.commitHash !== '0x0000000000000000000000000000000000000000000000000000000000000000') {
          await sendAndWait(walletClient, publicClient, {
            address, abi: jackpotAbi, functionName: 'settleDraw', args: [BigInt(id)],
          })
          console.log('keeper: settled round', id)
          summary.action = summary.action === 'none' ? 'settled' : summary.action + '+settled'
        }
      }
    }

    // 结算后开启下一期（若未被停售窗口购票预创建）
    const cur = await readRound(publicClient, address, rid)
    if (Number(cur.status) === 2 || Number(cur.status) === 3) {
      const nextId = rid + 1n
      const next = await readRound(publicClient, address, nextId)
      if (next.drawAt === 0n) {
        await sendAndWait(walletClient, publicClient, {
          address, abi: jackpotAbi, functionName: 'startRound', args: [],
        })
        console.log('keeper: started round', nextId.toString())
        summary.action = summary.action === 'none' ? 'started' : summary.action + '+started'
      } else {
        if (summary.action === 'none') summary.action = 'next-round-already-open'
      }
    }
  } catch (e) {
    console.error('keeper error:', e.shortMessage || e.message || e)
    summary.action = 'error: ' + (e.shortMessage || e.message || e)
  }
  return summary
}

async function runDrawJobAll(env) {
  const primary = (env.CONTRACT_ADDRESS || '').trim()
  if (!primary || primary === ZERO_ADDRESS) {
    console.log('keeper: CONTRACT_ADDRESS not configured, skipping')
    return { action: 'not-configured' }
  }
  try {
    const s = await runDrawJob(env, primary)
    console.log('keeper =>', s.action)
    return s
  } catch (e) {
    console.error('keeper error:', e.shortMessage || e.message || e)
    return { action: 'error', error: e.shortMessage || e.message || String(e) }
  }
}

let jobRunning = false // isolate 内互斥：避免 cron 重叠导致 nonce 冲突

async function handleKeeper(env) {
  if (jobRunning) return { ok: true, summary: { action: 'busy' } }
  jobRunning = true
  try {
    const summary = await runDrawJobAll(env)
    return { ok: true, summary }
  } catch (e) {
    return { ok: false, error: e.shortMessage || e.message || String(e) }
  } finally {
    jobRunning = false
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    if (url.pathname === '/__keeper') {
      const result = await handleKeeper(env)
      return new Response(JSON.stringify(result), {
        status: result.ok ? 200 : 500,
        headers: { 'content-type': 'application/json' },
      })
    }
    const res = await env.ASSETS.fetch(request)
    if (res.status === 404 && !url.pathname.includes('.')) {
      return env.ASSETS.fetch(new Request(url.origin + '/', request))
    }
    return res
  },

  async scheduled(event, env) {
    console.log('keeper: cron trigger', event.cron)
    const result = await handleKeeper(env)
    if (!result.ok) console.error('keeper failed:', result.error)
  },
}
