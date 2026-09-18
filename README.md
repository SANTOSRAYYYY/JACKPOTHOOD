# JackpotHood

**A fully on-chain lottery protocol + the first on-chain-verifiable VRF on Robinhood Chain.**

Live testnet app: https://www.jackpothood.com · Docs: [`docs/`](docs/)

---

## What's inside

| Component | Contract (Robinhood testnet, chain id 46630) | What it does |
|---|---|---|
| **JackpotHood core** | `0x9fCB876196586B828A5c42e4287fFCB3BAACc806` | 6-digit lottery: rounds, prize pool, shared staking reserve, claims, referrals, free tickets |
| **HoodVRF** | `0xBA8c0e39183BCD209caAFaE986D50cDD7E2Abb09` | **On-chain-verifiable randomness**: drand beacon + BLS12-381 signature verified *inside the contract* (EIP-2537) |
| **PerkRouter / Perks** | `0x9f63Cfc9e7cE76efFd0209504d8842c913B26D87` / `0x6baefD034328A827F1bd08D6F1DaAed1c5A0e098` | Free-ticket bridge: JPH staking → daily free tickets |
| **Presale (community round)** | `0xa29c858E6d48b1d39a82E7009776c5D9f96b63D8` | 100k-ticket presale, tiered price, JPH bonus, hardcoded proceeds split (60% permanently staked into the prize reserve) |
| **Genesis NFT** | `0xB9E8311a105C92b0fcEDe203F95f1DFe050335d2` | Genesis badge for presale buyers (500+ tickets) |

The lottery currently draws with blockhash commit-reveal; **HoodVRF becomes the draw randomness source in the V5 core** (see `docs/vrf-design.md`).

---

## HoodVRF — call verifiable randomness from your contract

HoodVRF is a public good for the Robinhood Chain ecosystem. Flow:

```
yourContract ──request()──▶ HoodVRF locks a future drand round (commitment on-chain)
   anyone ──fulfill(id, sigX, sigY)──▶ contract verifies the drand BLS signature
                                       on-chain (EIP-2537 pairing), stores randomness,
                                       calls back your onRandom(id, rnd)
```

- **Permissionless fulfillment** — your keeper, your users, or anyone can deliver; liveness does not depend on us.
- **Trustless**: randomness derives from the League of Entropy drand beacon (`quicknet`, 3 s rounds); the BLS signature is verified by the contract itself, not by any off-chain party.
- ~216k gas per fulfill. Fee per request: `0.0002 ETH` (free for whitelisted ecosystem contracts).

Integrate in 3 steps:

```solidity
// 1) implement the consumer callback
function onRandom(uint256 id, bytes32 rnd) external { /* use the randomness */ }

// 2) request (pay the fee, or ask to be whitelisted)
uint256 id = hoodVRF.requestFor(address(this));

// 3) anyone fulfills once the drand round is out — see examples/vrf-quickstart.mjs
hoodVRF.fulfill(id, sigX, sigY);
```

A complete end-to-end integration example (request → fetch drand signature → decompress off-chain → fulfill) lives in **[`examples/vrf-quickstart.mjs`](examples/vrf-quickstart.mjs)** (MIT).

Design doc: [`docs/vrf-design.md`](docs/vrf-design.md) — including how the BLS12-381 precompiles on Robinhood Chain were probed and the drand test vectors used.

---

## Lottery economics (current testnet parameters)

- Ticket: 6 digits (0-9 each), `0.001 ETH`, matched from the **last digit backwards**
- 90% of sales → round prize pool; 10% fee → staking reserve dividends
- 6 prize tiers (share of pool): jackpot 40 / 5-match 25 / 4-match 15 / 3-match 12 / 2-match 5 / 1-match 3
- Fair-odds caps per ticket: 10× (1-match) up to 100,000× (5-match); jackpot uncapped
- Wins carry a 12% fee: 5% referrer (if any) + 7% staking reserve
- **Shared staking reserve**: ETH stakers back the jackpots (two-phase exit: request → ride out the round → finalize) and earn the fees
- Randomness today: blockhash commit-reveal with notarized snapshot (upgrade path = HoodVRF)

## Repository layout

```
src/                 # contracts (BUSL-1.1)
  JackpotHood.sol    # core lottery
  JackpotHoodPerks.sol, JackpotHoodNFT.sol
  presale/           # PerkRouter, JackpotHoodPresale, GenesisNFT2
  vrf/               # HoodVRF, HoodBLS, IVrfConsumer
  dex/, mocks/       # testnet AMM & demo token
script/              # Deploy*.s.sol (Foundry scripts)
test/                # 144 forge tests (incl. invariants)
frontend/            # React + viem + Privy web app & Cloud Run keeper server
examples/            # integration examples (MIT)
docs/                # design docs, audits, ops handbooks
```

## Build & test

```bash
forge build
forge test            # 144 tests incl. invariant suite
cd frontend && npm ci && npm run dev
```

Deploy (testnet):

```bash
cp .env.example .env   # fill DEPLOYER_PRIVATE_KEY
forge script script/Deploy.s.sol --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast
```

## Security

- Audit reports & mainnet checklist: `docs/audit-report-2026-09-11.md`, `docs/HANDOFF.md`
- HoodVRF: real drand vectors verified on-chain (see `script/VerifyDrand.s.sol`), `forge test` includes hash-to-curve and pairing vectors
- Found a vulnerability? Please open a private security advisory / contact us before disclosing.

## License

- Smart contracts (`src/`, `script/`, `test/`): **BUSL-1.1** — free to read, audit and integrate against deployed instances; no competing commercial deployment before 2028-09-18, then converts to **MIT**. See [`LICENSE`](LICENSE).
- Everything else (`docs/`, `examples/`, `frontend/`): **MIT**. See [`LICENSE-MIT`](LICENSE-MIT).
