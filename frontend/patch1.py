# -*- coding: utf-8 -*-
# 历史浏览功能（步骤 1/2）：i18n + App.jsx 状态与逻辑
from pathlib import Path

# 1) i18n: loadMore × 6
p = Path('src/i18n.js')
s = p.read_text(encoding='utf-8')
adds = {
    'en': "    loadMore: 'Load more',\n",
    'zh': "    loadMore: '加载更多',\n",
    'ja': "    loadMore: 'もっと見る',\n",
    'ko': "    loadMore: '더 보기',\n",
    'vi': "    loadMore: 'Xem thêm',\n",
    'la': "    loadMore: 'Plura videre',\n",
}
for lang, block in adds.items():
    anchor = f"  {lang}: {{\n"
    assert s.count(anchor) == 1, lang
    s = s.replace(anchor, anchor + block, 1)
p.write_text(s, encoding='utf-8')
print('OK: i18n loadMore')

# 2) App.jsx
p = Path('src/App.jsx')
s = p.read_text(encoding='utf-8')

s = s.replace("  const [onchainReferrer, setOnchainReferrer] = useState(null)\n  const initializedRef = useRef(false)",
              "  const [onchainReferrer, setOnchainReferrer] = useState(null)\n  const [scanFloor, setScanFloor] = useState(0) // 已扫描的最老期次（0=未初始化；翻页水位）\n  const myTicketsRef = useRef([])\n  const initializedRef = useRef(false)")

anchor_refresh = "  const refresh = async () => {"
assert anchor_refresh in s
s = s.replace(anchor_refresh, """  // 扫描一段期次区间：开奖历史 + 我的票据 + 可兑奖（仅限兑奖期内）
  const scanRounds = async (fromId, count, accountAddr) => {
    const hist = []
    const mine = []
    const claims = []
    for (let id = fromId; id >= Math.max(1, fromId - count + 1); id--) {
      const r = await publicClient.readContract({
        address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'getRound', args: [BigInt(id)],
      })
      if (r.drawAt === 0n) continue
      const isDrawn = Number(r.status) === 2
      if (isDrawn) hist.push({ id, round: r, winning: unpackNumbers(r.winningPacked) })
      if (accountAddr) {
        const tickets = await publicClient.readContract({
          address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'getUserTickets',
          args: [BigInt(id), accountAddr],
        })
        if (tickets.length > 0) {
          mine.push({ roundId: id, status: Number(r.status), winning: isDrawn ? unpackNumbers(r.winningPacked) : null, tickets })
          if (isDrawn && Number(r.claimDeadline) >= Math.floor(Date.now() / 1000)) {
            const [due, indices] = await publicClient.readContract({
              address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'previewClaim',
              args: [BigInt(id), accountAddr],
            })
            if (due > 0n) claims.push({ roundId: id, due, indices })
          }
        }
      }
    }
    return { hist, mine, claims }
  }

  const loadMore = async () => {
    if (scanFloor <= 1) return
    const from = scanFloor - 1
    const count = Math.min(10, from)
    const res = await scanRounds(from, count, account)
    if (res.hist.length > 0) setHistory((prev) => [...prev, ...res.hist])
    if (res.mine.length > 0) setMyTickets((prev) => [...prev, ...res.mine])
    if (res.claims.length > 0) setClaimable((prev) => [...prev, ...res.claims])
    setScanFloor(Math.max(1, from - count + 1))
  }

  useEffect(() => {
    myTicketsRef.current = myTickets
  }, [myTickets])

  const refresh = async () => {""", 1)

old_block = """      const hist = []
      for (let id = Number(rid) - 1; id >= Math.max(1, Number(rid) - 5); id--) {
        const r = await publicClient.readContract({
          address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'getRound', args: [BigInt(id)],
        })
        if (Number(r.status) === 2) hist.push({ id, round: r, winning: unpackNumbers(r.winningPacked) })
      }
      setHistory(hist)

      if (account) {
        const mine = []
        const claimList = []
        for (const { id, round: r, winning } of [{ id: Number(rid), round: cur, winning: null }, ...hist]) {
          const tickets = await publicClient.readContract({
            address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'getUserTickets',
            args: [BigInt(id), account],
          })
          if (tickets.length > 0) {
            mine.push({ roundId: id, status: Number(r.status), winning, tickets })
            if (Number(r.status) === 2) {
              const [due, indices] = await publicClient.readContract({
                address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'previewClaim',
                args: [BigInt(id), account],
              })
              if (due > 0n) claimList.push({ roundId: id, due, indices })
            }
          }
        }
        setMyTickets(mine)
        setClaimable(claimList)

        const [earnings, referrer] = await Promise.all(["""
new_block = """      if (scanFloor === 0) {
        // 初次加载：扫描最近 5 期 + 建立翻页水位
        const from = Number(rid) - 1
        const res = await scanRounds(from, 5, account)
        setHistory(res.hist)
        setMyTickets(res.mine)
        setClaimable(res.claims)
        setScanFloor(Math.max(1, from - 4))
        if (account) {
          const curTickets = await publicClient.readContract({
            address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'getUserTickets',
            args: [rid, account],
          })
          if (curTickets.length > 0) {
            setMyTickets((prev) => [{ roundId: Number(rid), status: Number(cur.status), winning: null, tickets: curTickets }, ...prev])
          }
        }
      } else if (account) {
        // 常规刷新：当前期票据 + 重算已加载各期的可兑奖（领取后自动消失）
        const curTickets = await publicClient.readContract({
          address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'getUserTickets',
          args: [rid, account],
        })
        const others = myTicketsRef.current.filter((m) => m.roundId !== Number(rid))
        let combined = others
        if (curTickets.length > 0) {
          combined = [{ roundId: Number(rid), status: Number(cur.status), winning: null, tickets: curTickets }, ...others]
        }
        setMyTickets(combined)
        const claims = []
        for (const m of combined) {
          if (m.status === 2) {
            const [due, indices] = await publicClient.readContract({
              address: JACKPOT_ADDRESS, abi: jackpotAbi, functionName: 'previewClaim',
              args: [BigInt(m.roundId), account],
            })
            if (due > 0n) claims.push({ roundId: m.roundId, due, indices })
          }
        }
        setClaimable(claims)
      }

      if (account) {
        const [earnings, referrer] = await Promise.all(["""
assert old_block in s, 'refresh block anchor missing'
s = s.replace(old_block, new_block, 1)
p.write_text(s, encoding='utf-8')
print('OK: App.jsx logic')
