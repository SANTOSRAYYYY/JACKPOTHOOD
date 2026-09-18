// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {JackpotHoodPresale} from "./JackpotHoodPresale.sol";

/// @title GenesisNFT2 —— 预售创世 NFT（最小 ERC721，无代币配额逻辑）
/// @notice 预售累计购入满 500 张的钱包可免费领取 1 个；总量 1000，每钱包限 1 个。
///         admin 可批量空投（跳过门槛，仍受总量与每钱包 1 个约束）。
contract GenesisNFT2 {
    string public constant name = "JackpotHood Genesis";
    string public constant symbol = "JHG";
    uint256 public constant MAX_SUPPLY = 1000;
    uint64 public constant CLAIM_THRESHOLD = 500; // 预售累计购入门槛（张）

    JackpotHoodPresale public immutable presale;
    address public admin;
    address public pendingAdmin;

    mapping(uint256 => address) private _ownerOf;   // tokenId => owner
    mapping(address => uint256) private _balances;  // owner => 数量
    mapping(uint256 => address) private _approved;  // tokenId => 授权地址
    mapping(address => bool) public minted;         // 是否已铸造过（每钱包 1 个）
    uint256 public totalMinted;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event Claimed(address indexed user, uint256 indexed tokenId);
    event Airdropped(address indexed to, uint256 indexed tokenId);
    event AdminTransferStarted(address indexed currentAdmin, address indexed newAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        require(msg.sender == admin, "JHG: not admin");
        _;
    }

    constructor(address presale_) {
        require(presale_ != address(0), "JHG: zero presale");
        presale = JackpotHoodPresale(payable(presale_));
        admin = msg.sender;
    }

    // ---------------------------------------------------------------
    // 铸造
    // ---------------------------------------------------------------

    /// @notice 预售买家领取：累计购入满 500 张、未铸造过、未超总量
    function claim() external returns (uint256 tokenId) {
        require(presale.purchased(msg.sender) >= CLAIM_THRESHOLD, "JHG: below threshold");
        tokenId = _mintTo(msg.sender);
        emit Claimed(msg.sender, tokenId);
    }

    /// @notice admin 批量空投（跳过购入门槛，仍受总量与每钱包 1 个约束）
    function adminAirdrop(address[] calldata to) external onlyAdmin {
        for (uint256 i = 0; i < to.length; i++) {
            require(to[i] != address(0), "JHG: zero to");
            uint256 tokenId = _mintTo(to[i]);
            emit Airdropped(to[i], tokenId);
        }
    }

    function _mintTo(address to) internal returns (uint256 tokenId) {
        require(!minted[to], "JHG: already minted");
        require(totalMinted < MAX_SUPPLY, "JHG: sold out");
        tokenId = ++totalMinted;
        minted[to] = true;
        _ownerOf[tokenId] = to;
        _balances[to]++;
        emit Transfer(address(0), to, tokenId);
    }

    // ---------------------------------------------------------------
    // ERC721 最小实现
    // ---------------------------------------------------------------

    function balanceOf(address account) external view returns (uint256) {
        require(account != address(0), "JHG: zero address");
        return _balances[account];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address o = _ownerOf[tokenId];
        require(o != address(0), "JHG: not exist");
        return o;
    }

    function approve(address to, uint256 tokenId) external {
        address o = ownerOf(tokenId);
        require(msg.sender == o || _approved[tokenId] == msg.sender, "JHG: not authorized");
        _approved[tokenId] = to;
        emit Approval(o, to, tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        address o = ownerOf(tokenId);
        require(o == from, "JHG: wrong from");
        require(to != address(0), "JHG: zero to");
        require(msg.sender == from || _approved[tokenId] == msg.sender, "JHG: not authorized");

        delete _approved[tokenId];
        _balances[from]--;
        _balances[to]++;
        _ownerOf[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function totalSupply() external view returns (uint256) {
        return totalMinted;
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        require(_ownerOf[tokenId] != address(0), "JHG: not exist");
        return string.concat(_baseURI(), _toString(tokenId));
    }

    /// @dev 测试网无元数据需求，baseURI 为空
    function _baseURI() internal pure returns (string memory) {
        return "";
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t > 0; t /= 10) len++;
        bytes memory s = new bytes(len);
        for (uint256 i = len; i > 0; i--) {
            s[i - 1] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(s);
    }

    // ---------------------------------------------------------------
    // 管理（两步转移）
    // ---------------------------------------------------------------

    function proposeAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "JHG: zero admin");
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "JHG: not pending admin");
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        pendingAdmin = address(0);
    }
}
