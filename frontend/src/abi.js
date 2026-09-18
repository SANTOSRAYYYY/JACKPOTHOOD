// JackpotHood minimal ABI (frontend subset)
import { parseAbi } from 'viem'

const roundTuple = '(uint64 salesEnd, uint64 drawAt, uint64 randomBlock, uint64 claimDeadline, uint256 prizePool, uint256 totalTickets, uint256 ticketRevenue, uint256 ticketFee, uint48 winningPacked, bytes32 commitHash, bytes32 seedHash, uint256[6] tierPots, uint256[6] tierUnits, uint256[6] tierClaimed, bool swept, uint8 status)'

export const jackpotAbi = parseAbi([
  'function currentRoundId() view returns (uint256)',
  'function pendingRollover() view returns (uint256)',
  'function TICKET_PRICE() view returns (uint256)',
  'function freeMinted(uint256 roundId) view returns (uint64)',
  'function freeCredits(address) view returns (uint256)',
          'function totalEthStaked() view returns (uint256)',
  'function ethStaked(address) view returns (uint256)',
  'function stakingPool() view returns (uint256)',
  'function ticketBank() view returns (uint256)',
  'function stakeCash() view returns (uint256)',
  'function totalPoolAssets() view returns (uint256 prizePoolNow, uint256 stakeReserve)',
  'function pendingStakeRewards(address) view returns (uint256)',
  'function admin() view returns (address)',
  'function paused() view returns (bool)',
  'function getReferrer(address user) view returns (address)',
  'function getCurrentRound() view returns (' + roundTuple + ' round)',
  'function getRound(uint256 roundId) view returns (' + roundTuple + ' round)',
  'function getUserTickets(uint256 roundId, address user) view returns ((uint48 numbersPacked, uint64 count, address gifter, bool claimed, bool refunded)[] tickets)',
  'function previewClaim(uint256 roundId, address user) view returns (uint256 due, uint256[] indices)',
  'function buyTicket(uint8[6] numbers, uint64 count) payable',
  'function buyTickets(uint8[6][] numbersList, uint64[] counts) payable',
  'function giftTicket(address recipient, uint8[6] numbers, uint64 count) payable',
  'function giftTickets(address recipient, uint8[6][] numbersList, uint64[] counts) payable',
  'function freeTicket(address recipient, uint8[6] numbers, uint64 count) payable',
  'function grantFreeCredits(address recipient, uint64 amount)',
  'function redeemFreeTicket(uint8[6] numbers, uint64 count)',
  'function redeemFreeTickets(uint8[6][] numbersList, uint64[] counts)',
    'function stakeEth() payable',
  'function requestUnstake(uint256 amount)',
  'function finalizeUnstake()',
  'function unstakeReqOf(address) view returns (uint256 amount, uint64 roundId)',
  'function claimStakeRewards()',
  'function referralPaidPerRound(uint256) view returns (uint256)',
      'function commitDraw(uint256 roundId)',
  'function snapshotCommitHash(uint256 roundId)',
  'function settleDraw(uint256 roundId)',
  'function startRound()',
  'function claim(uint256 roundId, uint256[] ticketIndices)',
  'function setReferrer(address referrer)',
  'event PrizeClaimed(uint256 indexed roundId, address indexed user, uint256 ticketCount, uint256 amount)',
  'event FreeTicketIssued(uint256 indexed roundId, address indexed recipient, uint256 ticketIndex, uint8[6] numbers, uint64 count)',
  'event UnstakeRequested(address indexed user, uint256 amount, uint64 roundId)',
  'event UnstakeFinalized(address indexed user, uint256 amount)',
  'event ReferralPurchasePaid(address indexed buyer, address indexed referrer, uint256 amount)',
])

export const nftAbi = parseAbi([
  'function maxSupply() view returns (uint256)',
  'function totalMinted() view returns (uint256)',
  'function mintPrice() view returns (uint256)',
  'function quotaPerNft() view returns (uint256)',
  'function mintOpen() view returns (bool)',
  'function balanceOf(address account) view returns (uint256)',
  'function ownerOf(uint256 tokenId) view returns (address)',
  'function totalSupply() view returns (uint256)',
  'function tokenOfOwnerByIndex(address account, uint256 index) view returns (uint256)',
  'function quotaOf(uint256 tokenId) view returns (uint256)',
  'function claimed(uint256 tokenId) view returns (bool)',
  'function claimableOf(address account) view returns (uint256 total, uint256[] tokenIds)',
  'function mint() payable',
  'function claim(uint256 tokenId)',
])

export const perksAbi = parseAbi([
  'function jphStaked(address) view returns (uint256)',
  'function jphPerkPerDay(address) view returns (uint64)',
  'function perkBalance(address) view returns (uint64)',
  'function stakeJph(uint256 amount)',
  'function unstakeJph(uint256 amount)',
  'function redeemPerkTicket(uint8[6] numbers, uint64 count)',
  'function redeemPerkTickets(uint8[6][] numbersList, uint64[] counts)',
])

// 社区轮预售（JackpotHoodPresale）
export const presaleAbi = parseAbi([
  'function CAP() view returns (uint64)',
  'function NFT_THRESHOLD() view returns (uint64)',
  'function sold() view returns (uint64)',
  'function credits(address) view returns (uint64)',
  'function purchased(address) view returns (uint64)',
  'function startTime() view returns (uint64)',
  'function endTime() view returns (uint64)',
  'function isOpen() view returns (bool)',
  'function priceOf(uint64 n) view returns (uint256)',
  'function buy(uint64 n, address referrer) payable',
  'function redeem(uint8[6] numbers, uint64 count)',
])

// 预售创世 NFT（GenesisNFT2）
export const nft2Abi = parseAbi([
  'function MAX_SUPPLY() view returns (uint256)',
  'function CLAIM_THRESHOLD() view returns (uint64)',
  'function totalMinted() view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function minted(address) view returns (bool)',
  'function balanceOf(address account) view returns (uint256)',
  'function claim() returns (uint256 tokenId)',
])
