// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title HoodBLS —— BLS12-381 签名链上验签库（EIP-2537 预编译 + RFC 9380 hash-to-curve）
/// @dev drand quicknet 方案（bls-unchained-g1-rfc9380）：签名在 G1（48B 压缩）、公钥在 G2、
///      消息 = sha256(round:uint64 大端)、DST = BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_。
///      坐标一律走非压缩编码（解压链下做）：Fp 元素 48 字节大端（381 位，放不进 uint256，需 384 位运算）。
///      EIP-2537 编码约定（eips.ethereum.org/EIPS/eip-2537）：
///        Fp = 64 字节（高 16 字节恒零 + 48 字节值，值必须 < p）；G1 点 128 字节 x||y；
///        G2 点 256 字节 x_c0||x_c1||y_c0||y_c1；配对输入 384 字节/对（G1 128 + G2 256）；
///        无穷远 = 全零；配对预编译自带「在曲线上 + 在正确子群」校验，非法输入会报错并烧光本次 call 的 gas
///        （故所有预编译调用都设了 gas 上限兜底）。
///      预编译地址经 Precompiles 结构注入，便于跨链/测试替换。
library HoodBLS {
    // ---------------------------------------------------------------
    // 常量
    // ---------------------------------------------------------------

    /// @dev EIP-2537 预编译地址集合（本库仅用 G1ADD / PAIRING / MAP_FP_TO_G1）
    struct Precompiles {
        address g1Add;   // 0x0b
        address pairing; // 0x0f
        address mapG1;   // 0x10
    }

    /// @dev EIP-198 大数模幂预编译（381 位 Fp 运算全靠它，单次约 200 gas）
    address internal constant MODEXP = address(0x05);

    /// @dev BLS12-381 基域模数 p（48 字节）及其高/低 256 位拆分
    bytes internal constant P_BYTES = hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
    uint256 internal constant P_HI = 0x1a0111ea397fe69a4b1ba7b6434bacd7; // p >> 256
    uint256 internal constant P_LO = 0x64774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab; // p 低 256 位
    /// @dev (p-1)/2 —— 压缩编码 y 符号位判据（y > (p-1)/2 则置 a_flag）
    uint256 internal constant HALF_HI = 0x0d0088f51cbff34d258dd3db21a5d66b;
    uint256 internal constant HALF_LO = 0xb23ba5c279c2895fb39869507b587b120f55ffff58a9ffffdcff7fffffffd555;

    /// @dev RFC 9380 ciphersuite 的 DST（drand quicknet，43 字节）
    bytes internal constant DST = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_";

    /// @dev G2 生成元（EIP-2537 编码 256 字节：x_c0||x_c1||y_c0||y_c1，每个 Fp 高 16 字节为零）
    bytes internal constant G2_GEN =
        hex"00000000000000000000000000000000024aa2b2f08f0a91260805272dc51051c6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb8"
        hex"0000000000000000000000000000000013e02b6052719f607dacd3a088274f65596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e"
        hex"000000000000000000000000000000000ce5d527727d6e118cc9cdc6da2e351aadfd9baa8cbdd3a76d429a695160d12c923ac9cc3baca289e193548608b82801"
        hex"000000000000000000000000000000000606c4a02ea734cc32acd2b02bc28b99cb3e287e85a763af267492ab572e99ab3f370d275cec1da1aaa9075ff05f79be";

    // 预编译调用 gas 上限（错误输入会烧掉全部转发 gas，这里封顶保护履约方）
    uint32 internal constant GAS_MAP = 20_000;    // MAP_FP_TO_G1 定价 5_500
    uint32 internal constant GAS_G1ADD = 5_000;   // G1ADD 定价 375
    uint32 internal constant GAS_PAIRING = 200_000; // 2 对配对定价 32_600*2+37_700 = 102_900
    uint32 internal constant GAS_MODEXP = 10_000; // 实际约 200

    error BadLength();
    error OutOfField();
    error NotOnCurve();
    error PrecompileError();
    error SignatureInvalid();

    function defaultPrecompiles() internal pure returns (Precompiles memory) {
        return Precompiles(address(0x0b), address(0x0f), address(0x10));
    }

    // ---------------------------------------------------------------
    // 对外主流程
    // ---------------------------------------------------------------

    /// @notice BLS 验签：σ 在 G1 曲线上 且 e(-σ, G2生成元) · e(H(m), pk) == 1
    /// @param pkG2 256 字节 EIP-2537 编码的 G2 公钥（合法性由部署方离线/部署时校验）
    /// @param message 原始消息（32 字节，drand 场景 = sha256(round)）
    /// @param sigX / sigY σ 的非压缩坐标（各 48 字节大端）
    function verify(
        Precompiles memory pc,
        bytes memory pkG2,
        bytes32 message,
        bytes memory sigX,
        bytes memory sigY
    ) internal view {
        checkFp48(sigX);
        checkFp48(sigY);
        if (!isOnCurveG1(sigX, sigY)) revert NotOnCurve();
        bytes memory h = hashToG1(pc, message); // 128 字节 G1 编码
        bytes memory input = abi.encodePacked(bytes16(0), sigX, bytes16(0), _negFp48(sigY), G2_GEN, h, pkG2);
        (bool ok, bytes memory out) = pc.pairing.staticcall{gas: GAS_PAIRING}(input);
        if (!ok || out.length != 32) revert PrecompileError();
        if (abi.decode(out, (uint256)) != 1) revert SignatureInvalid();
    }

    /// @notice G1 点 48 字节压缩编码（Zcash 格式：首字节 = 0x80 | 符号位 | x 高 5 位）
    /// @dev 与 drand 返回的压缩签名逐字节一致（已用真实向量离线验证）
    function compressG1(bytes memory sigX, bytes memory sigY) internal pure returns (bytes memory) {
        (uint256 xHi, uint256 xLo) = split48(sigX);
        (uint256 yHi, uint256 yLo) = split48(sigY);
        uint8 b0 = uint8(xHi >> 120) | 0x80;
        if (yHi > HALF_HI || (yHi == HALF_HI && yLo > HALF_LO)) b0 |= 0x20;
        return abi.encodePacked(bytes1(b0), bytes15(uint120(xHi)), bytes32(xLo));
    }

    /// @notice RFC 9380 hash_to_G1：hash_to_field(count=2) → MAP_FP_TO_G1(u0)+MAP_FP_TO_G1(u1)
    /// @return 128 字节 EIP-2537 G1 编码
    function hashToG1(Precompiles memory pc, bytes32 message) internal view returns (bytes memory) {
        (bytes memory u0, bytes memory u1) = hashToField2(message);
        bytes memory p0 = _mapG1(pc, u0);
        bytes memory p1 = _mapG1(pc, u1);
        (bool ok, bytes memory out) = pc.g1Add.staticcall{gas: GAS_G1ADD}(abi.encodePacked(p0, p1));
        if (!ok || out.length != 128) revert PrecompileError();
        return out;
    }

    /// @notice RFC 9380 hash_to_field：expand_message_xmd(sha256, L=64, count=2) → 两 chunk 各 mod p
    /// @return u0 / u1 各 48 字节大端
    function hashToField2(bytes32 message) internal view returns (bytes memory u0, bytes memory u1) {
        bytes memory uni = _expandXmd(message); // 128 字节
        bytes memory t0 = new bytes(64);
        bytes memory t1 = new bytes(64);
        assembly {
            mcopy(add(t0, 32), add(uni, 32), 64)
            mcopy(add(t1, 32), add(uni, 96), 64)
        }
        u0 = _modexp(t0, 1); // 512 位大数 mod p
        u1 = _modexp(t1, 1);
    }

    /// @notice Fp 合法性：48 字节且值 < p（用于部署时校验公钥分量）
    function checkFp48(bytes memory v) internal pure {
        (uint256 hi, uint256 lo) = split48(v);
        if (!_ltP(hi, lo)) revert OutOfField();
    }

    /// @notice G1 点完整校验：长度、坐标 < p、非无穷远、y² ≡ x³+4 (mod p)
    function isOnCurveG1(bytes memory x, bytes memory y) internal view returns (bool) {
        (uint256 xHi, uint256 xLo) = split48(x);
        (uint256 yHi, uint256 yLo) = split48(y);
        if (!_ltP(xHi, xLo) || !_ltP(yHi, yLo)) return false;
        return _onCurveG1(x, y, xHi, xLo, yHi, yLo);
    }

    /// @dev 48 字节大端 → (hi, lo) 拆分：value = hi*2^256 + lo，hi < 2^128
    function split48(bytes memory v) internal pure returns (uint256 hi, uint256 lo) {
        if (v.length != 48) revert BadLength();
        assembly {
            hi := shr(128, mload(add(v, 32))) // 前 16 字节
            lo := mload(add(v, 48))           // 后 32 字节
        }
    }

    // ---------------------------------------------------------------
    // 内部实现
    // ---------------------------------------------------------------

    /// @dev RFC 9380 §5.3.1 expand_message_xmd：H=sha256(b=32,r=64)，len_in_bytes=128，ell=4
    function _expandXmd(bytes32 message) private pure returns (bytes memory) {
        bytes memory dstPrime = abi.encodePacked(DST, uint8(DST.length)); // DST || I2OSP(len,1)
        // msg_prime = Z_pad(64 零) || msg || I2OSP(128,2) || I2OSP(0,1) || DST_prime
        bytes32 b0 = sha256(abi.encodePacked(new bytes(64), message, uint16(128), uint8(0), dstPrime));
        bytes32 b1 = sha256(abi.encodePacked(b0, uint8(1), dstPrime));
        bytes32 b2 = sha256(abi.encodePacked(b0 ^ b1, uint8(2), dstPrime));
        bytes32 b3 = sha256(abi.encodePacked(b0 ^ b2, uint8(3), dstPrime));
        bytes32 b4 = sha256(abi.encodePacked(b0 ^ b3, uint8(4), dstPrime));
        return abi.encodePacked(b1, b2, b3, b4);
    }

    /// @dev MAP_FP_TO_G1 预编译：输入 64 字节 FP（16 零 + 48 字节值），输出 128 字节 G1
    function _mapG1(Precompiles memory pc, bytes memory u) private view returns (bytes memory) {
        (bool ok, bytes memory out) = pc.mapG1.staticcall{gas: GAS_MAP}(abi.encodePacked(bytes16(0), u));
        if (!ok || out.length != 128) revert PrecompileError();
        return out;
    }

    /// @dev modexp 预编译：base^exp mod p（base 任意长度，p 固定 48 字节）
    function _modexp(bytes memory base, uint256 exp) private view returns (bytes memory) {
        bytes memory input = abi.encodePacked(base.length, uint256(32), uint256(48), base, exp, P_BYTES);
        (bool ok, bytes memory out) = MODEXP.staticcall{gas: GAS_MODEXP}(input);
        if (!ok || out.length != 48) revert PrecompileError();
        return out;
    }

    /// @dev 曲线上校验 y² ≡ x³+4 (mod p)；假定坐标已 < p；拒绝无穷远 (0,0)
    function _onCurveG1(
        bytes memory x,
        bytes memory y,
        uint256 xHi,
        uint256 xLo,
        uint256 yHi,
        uint256 yLo
    ) private view returns (bool) {
        if (xHi == 0 && xLo == 0 && yHi == 0 && yLo == 0) return false; // 无穷远不是有效 σ
        bytes memory y2 = _modexp(y, 2);
        bytes memory x3 = _modexp(x, 3);
        (uint256 rHi, uint256 rLo) = split48(x3);
        unchecked {
            rLo += 4;
            if (rLo < 4) rHi += 1; // 进位
        }
        if (rHi > P_HI || (rHi == P_HI && rLo >= P_LO)) (rHi, rLo) = _subPr(rHi, rLo); // mod p 归约
        return keccak256(y2) == keccak256(abi.encodePacked(bytes16(uint128(rHi)), bytes32(rLo)));
    }

    /// @dev (hi,lo) < p ?
    function _ltP(uint256 hi, uint256 lo) private pure returns (bool) {
        return hi < P_HI || (hi == P_HI && lo < P_LO);
    }

    /// @dev p - v（假定 v < p）；v=0 时返回 0（避免编码出 p 本身）
    function _negP(uint256 hi, uint256 lo) private pure returns (uint256 nHi, uint256 nLo) {
        if (hi == 0 && lo == 0) return (0, 0);
        return _subPr(hi, lo);
    }

    /// @dev 384 位减法 p - v（假定 0 < v ≤ p）
    function _subPr(uint256 hi, uint256 lo) private pure returns (uint256 nHi, uint256 nLo) {
        uint256 borrow = lo > P_LO ? 1 : 0;
        unchecked {
            nLo = P_LO - lo; // 借位时自然环绕
        }
        nHi = P_HI - hi - borrow;
    }

    /// @dev (hi,lo) → 48 字节大端（假定 hi < 2^128）
    function _encodeFp(uint256 hi, uint256 lo) private pure returns (bytes memory) {
        return abi.encodePacked(bytes16(uint128(hi)), bytes32(lo));
    }

    /// @dev 48 字节坐标 y → p - y 的 48 字节编码（-σ 的 y 分量）
    function _negFp48(bytes memory y) private pure returns (bytes memory) {
        (uint256 hi, uint256 lo) = split48(y);
        (uint256 nHi, uint256 nLo) = _negP(hi, lo);
        return _encodeFp(nHi, nLo);
    }
}
