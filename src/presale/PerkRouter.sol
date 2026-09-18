// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IJackpotCore {
    function redeemPerkExternal(address recipient, uint8[6] calldata numbers, uint64 count) external;
    function paused() external view returns (bool);
}

/// @title PerkRouter —— 占据 core.perkContract 单槽位的白名单转发器
/// @notice core 只允许一个 perkContract 地址；本合约占据该槽位，把 onlyPerk 能力
///         按白名单分发给多个来源（JackpotHoodPerks、JackpotHoodPresale 等）。
///         本合约不持有资金、不做记账，仅转发调用与 paused() 查询。
contract PerkRouter {
    address public immutable core;
    address public admin;
    address public pendingAdmin;

    mapping(address => bool) public allowed; // 允许代发免费票的调用方（Perks / Presale）

    event AllowedSet(address indexed caller, bool ok);
    event AdminTransferStarted(address indexed currentAdmin, address indexed newAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Router: not admin");
        _;
    }

    constructor(address core_) {
        require(core_ != address(0), "Router: zero core");
        core = core_;
        admin = msg.sender;
    }

    function setAllowed(address caller, bool ok) external onlyAdmin {
        allowed[caller] = ok;
        emit AllowedSet(caller, ok);
    }

    /// @notice 白名单转发：调用方须在白名单内，其余校验（暂停/每轮免费上限）由 core 兜底
    function redeemPerkExternal(address recipient, uint8[6] calldata numbers, uint64 count) external {
        require(allowed[msg.sender], "Router: not allowed");
        IJackpotCore(core).redeemPerkExternal(recipient, numbers, count);
    }

    /// @notice 透传 core 暂停状态（Perks 等下游按 IJackpotBridge 接口查询）
    function paused() external view returns (bool) {
        return IJackpotCore(core).paused();
    }

    // ---------------------------------------------------------------
    // 管理（两步转移）
    // ---------------------------------------------------------------

    function proposeAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Router: zero admin");
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "Router: not pending admin");
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        pendingAdmin = address(0);
    }
}
