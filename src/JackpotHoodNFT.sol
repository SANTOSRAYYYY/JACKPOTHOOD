// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice 最小 ERC20 接口（配额代币 JACKPOTHOOD）
interface IERC20Quota {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title JackpotHoodNFT —— 创世 NFT（代币铸造式产出的凭证）
/// @notice 铸造创世 NFT 获得 JACKPOTHOOD 代币配额领取权与持有者权益。
/// @dev 经济模型：
///      - 每个 NFT 在铸造时固化一笔代币配额（quotaPerNft），配额由 owner 预先注入合约锁定，
///        合约内有多少代币才能发多少，社区可审计，不会超发。
///      - 铸造价格 mintPrice（ETH）归项目方提取，作为初始流动性资金来源。
///      - 配额与权益跟随 NFT：未领取的配额在 NFT 转手后归新持有者。
///      - 每钱包限铸 1 个（防刷）。
contract JackpotHoodNFT {
    string public constant name = "JackpotHood Genesis";
    string public constant symbol = "JHNFT";

    uint256 public immutable maxSupply;   // 创世总量
    IERC20Quota public quotaToken;       // 配额代币（JACKPOTHOOD）
    uint256 public quotaPerNft;          // 每个 NFT 的代币配额（铸造时固化）
    uint256 public mintPrice;            // 铸造价（ETH，wei）
    bool public mintOpen;                // 铸造开关
    bool private _locked;                // 重入锁

    address public owner;

    mapping(uint256 => address) private _ownerOf;       // tokenId => owner
    mapping(address => uint256) private _balances;      // owner => NFT 数量
    mapping(uint256 => address) private _approved;      // tokenId => 授权地址
    mapping(uint256 => uint256) private _quotaOf;       // tokenId => 配额（铸造时固化）
    mapping(uint256 => bool) public claimed;            // tokenId => 是否已领取配额
    mapping(address => bool) public minted;             // address => 是否已铸造过（每钱包 1 个）
    uint256[] private _allTokens;                       // 枚举：tokenId 列表

    uint256 public totalMinted;
    uint256 public totalQuotaClaimed; // 已领取配额累计

    event Minted(address indexed minter, uint256 indexed tokenId, uint256 pricePaid);
    event QuotaClaimed(address indexed holder, uint256 indexed tokenId, uint256 amount);
    event QuotaDeposited(address indexed from, uint256 amount);
    event ProceedsWithdrawn(address indexed to, uint256 amount);
    event MintParamsUpdated(uint256 mintPrice, uint256 quotaPerNft, bool mintOpen);

    modifier onlyOwner() {
        require(msg.sender == owner, "JHNFT: not owner");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "JHNFT: reentrant");
        _locked = true;
        _;
        _locked = false;
    }

    constructor(IERC20Quota quotaToken_, uint256 quotaPerNft_, uint256 mintPrice_, uint256 maxSupply_) {
        require(address(quotaToken_) != address(0), "JHNFT: zero token");
        require(quotaPerNft_ > 0, "JHNFT: zero quota");
        require(maxSupply_ > 0, "JHNFT: zero supply");
        quotaToken = quotaToken_;
        quotaPerNft = quotaPerNft_;
        mintPrice = mintPrice_;
        maxSupply = maxSupply_;
        owner = msg.sender;
    }

    // ---------------------------------------------------------------
    // 铸造
    // ---------------------------------------------------------------

    /// @notice 铸造创世 NFT（每钱包 1 个，支付 mintPrice ETH）
    function mint() external payable nonReentrant returns (uint256 tokenId) {
        require(mintOpen, "JHNFT: mint closed");
        require(!minted[msg.sender], "JHNFT: already minted");
        require(totalMinted < maxSupply, "JHNFT: sold out");
        require(msg.value == mintPrice, "JHNFT: wrong ETH amount");

        tokenId = ++totalMinted;
        minted[msg.sender] = true;
        _ownerOf[tokenId] = msg.sender;
        _balances[msg.sender]++;
        _quotaOf[tokenId] = quotaPerNft;
        _allTokens.push(tokenId);

        emit Minted(msg.sender, tokenId, msg.value);
    }

    // ---------------------------------------------------------------
    // 代币配额领取（核心权益：铸造式产出的代币）
    // ---------------------------------------------------------------

    /// @notice 领取某张 NFT 绑定的代币配额（未领取的配额跟随 NFT 归属）
    function claim(uint256 tokenId) external nonReentrant {
        require(_ownerOf[tokenId] != address(0), "JHNFT: not exist");
        require(msg.sender == _ownerOf[tokenId], "JHNFT: not owner");
        require(!claimed[tokenId], "JHNFT: already claimed");

        uint256 amount = _quotaOf[tokenId];
        require(quotaToken.balanceOf(address(this)) >= amount, "JHNFT: quota not funded");

        claimed[tokenId] = true;
        totalQuotaClaimed += amount;
        require(quotaToken.transfer(msg.sender, amount), "JHNFT: transfer failed");
        emit QuotaClaimed(msg.sender, tokenId, amount);
    }

    // ---------------------------------------------------------------
    // ERC721 最小实现（支持转移：配额与权益跟随 NFT）
    // ---------------------------------------------------------------

    function balanceOf(address account) external view returns (uint256) {
        require(account != address(0), "JHNFT: zero address");
        return _balances[account];
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = _ownerOf[tokenId];
        require(o != address(0), "JHNFT: not exist");
        return o;
    }

    function approve(address to, uint256 tokenId) external {
        address o = _ownerOf[tokenId];
        require(o != address(0), "JHNFT: not exist");
        require(msg.sender == o || _approved[tokenId] == msg.sender, "JHNFT: not authorized");
        _approved[tokenId] = to;
        emit Approval(o, to, tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        address o = _ownerOf[tokenId];
        require(o != address(0), "JHNFT: not exist");
        require(o == from, "JHNFT: wrong from");
        require(to != address(0), "JHNFT: zero to");
        require(msg.sender == from || _approved[tokenId] == msg.sender, "JHNFT: not authorized");

        delete _approved[tokenId];
        _balances[from]--;
        _balances[to]++;
        _ownerOf[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    // 枚举（后台工具：给 NFT 持有者发放权益用）
    function totalSupply() external view returns (uint256) {
        return _allTokens.length;
    }

    function tokenByIndex(uint256 index) external view returns (uint256) {
        require(index < _allTokens.length, "JHNFT: index out of bounds");
        return _allTokens[index];
    }

    function tokenOfOwnerByIndex(address account, uint256 index) external view returns (uint256) {
        uint256 count = _balances[account];
        require(index < count, "JHNFT: index out of bounds");
        uint256 found;
        for (uint256 i = 0; i < _allTokens.length; i++) {
            if (_ownerOf[_allTokens[i]] == account) {
                if (found == index) return _allTokens[i];
                found++;
            }
        }
        revert("JHNFT: index out of bounds");
    }

    // ---------------------------------------------------------------
    // 视图
    // ---------------------------------------------------------------

    function quotaOf(uint256 tokenId) external view returns (uint256) {
        require(_ownerOf[tokenId] != address(0), "JHNFT: not exist");
        return _quotaOf[tokenId];
    }

    /// @notice 某钱包全部未领取的配额总和（前端展示）
    function claimableOf(address account) external view returns (uint256 total, uint256[] memory tokenIds) {
        uint256 count = _balances[account];
        uint256[] memory tmp = new uint256[](count);
        uint256 n;
        for (uint256 i = 0; i < _allTokens.length; i++) {
            uint256 tid = _allTokens[i];
            if (_ownerOf[tid] == account && !claimed[tid]) {
                total += _quotaOf[tid];
                tmp[n++] = tid;
            }
        }
        tokenIds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) tokenIds[i] = tmp[i];
    }

    // ---------------------------------------------------------------
    // 管理
    // ---------------------------------------------------------------

    /// @notice 注入配额代币（铸造开启前由 owner 锁定初始供给，可审计）
    function depositQuotaTokens(uint256 amount) external onlyOwner {
        require(amount > 0, "JHNFT: zero amount");
        require(IERC20Quota(quotaToken).transferFrom(msg.sender, address(this), amount), "JHNFT: transferFrom failed");
        emit QuotaDeposited(msg.sender, amount);
    }

    /// @notice 提取铸造收入（ETH）—— 用于注入 DEX 流动性
    function withdrawProceeds() external onlyOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "JHNFT: no proceeds");
        (bool ok, ) = owner.call{value: bal}("");
        require(ok, "JHNFT: withdraw failed");
        emit ProceedsWithdrawn(owner, bal);
    }

    function setMintParams(uint256 mintPrice_, uint256 quotaPerNft_, bool mintOpen_) external onlyOwner {
        require(quotaPerNft_ > 0, "JHNFT: zero quota");
        mintPrice = mintPrice_;
        quotaPerNft = quotaPerNft_;
        mintOpen = mintOpen_;
        emit MintParamsUpdated(mintPrice_, quotaPerNft_, mintOpen_);
    }

    function proposeOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "JHNFT: zero owner");
        pendingOwner = newOwner;
    }

    address public pendingOwner;

    function acceptOwner() external {
        require(msg.sender == pendingOwner, "JHNFT: not pending owner");
        emit OwnerTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    event Approval(address indexed owner_, address indexed approved, uint256 indexed tokenId);
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
}
