// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Test fixture: verbatim copy of the live observer's published source (MIT), deployed on Ethereum
// mainnet at 0x626517225096671868609c1bBF9c1B416A4eFd9a. Source:
// https://github.com/identity-md-launches/launch-1213-src-quantumcanary-sol/blob/main/src/QuantumCanary.sol
// Tests deploy it to (1) recompute the destination the hook falls back to when the observer has no
// code, and (2) exercise its LIVE, non-latching isTripped() predicate against the hook's payout.

/// @title QuantumCanary
/// @notice Ownerless observer of an ETH bounty at a deterministically derived secp256k1 address.
/// @dev Funds go directly to canaryAddress. Only observations are mutable; no key is generated or held here.
contract QuantumCanary {
    string public constant SEED_PHRASE =
        "IMD Quantum Canary #1 warns that if this balance ever drops, a quantum computer has broken secp256k1.";

    uint256 private constant FIELD_PRIME = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    uint256 private constant SQRT_EXPONENT = (FIELD_PRIME + 1) / 4;

    bytes32 public immutable seedHash;
    address public immutable canaryAddress;
    uint256 public immutable pubKeyX;
    uint256 public immutable pubKeyY;
    uint256 public immutable counter;
    uint256 public immutable thresholdWei;

    /// @notice Highest canary balance observed by the constructor or a successful poke.
    uint256 public highWaterMark;
    /// @notice Timestamp of the first poke that observed a trip; zero until recorded on mainnet.
    uint256 public trippedAt;
    /// @notice Block number of the first poke that observed a trip; zero until recorded on mainnet.
    uint256 public trippedBlock;
    // A separate flag also makes the first observation final at timestamp/block zero in local chains.
    bool private tripRecorded;

    error InvalidThreshold();
    error ModExpFailed();

    event CanaryDerived(
        bytes32 indexed seedHash,
        address indexed canaryAddress,
        uint256 pubKeyX,
        uint256 pubKeyY,
        uint256 counter,
        uint256 thresholdWei
    );
    event HighWaterMarkUpdated(uint256 previousMark, uint256 newMark);
    event CanaryTripped(uint256 balance, uint256 highWaterMark, uint256 trippedAt, uint256 trippedBlock);

    /// @param thresholdWei_ Positive alarm threshold; the Ethereum mainnet launch uses 1 ether.
    constructor(uint256 thresholdWei_) {
        if (thresholdWei_ == 0) revert InvalidThreshold();

        bytes32 hash = keccak256(bytes(SEED_PHRASE));
        (uint256 x, uint256 y, uint256 i) = derivePoint(hash);
        address canary = address(uint160(uint256(keccak256(abi.encodePacked(x, y)))));

        seedHash = hash;
        pubKeyX = x;
        pubKeyY = y;
        counter = i;
        canaryAddress = canary;
        thresholdWei = thresholdWei_;
        // The deterministic address can be funded before this observer is deployed.
        highWaterMark = canary.balance;

        emit CanaryDerived(hash, canary, x, y, i, thresholdWei_);
        if (highWaterMark != 0) emit HighWaterMarkUpdated(0, highWaterMark);
    }

    function seedPhrase() external pure returns (string memory) {
        return SEED_PHRASE;
    }

    /// @notice Live threshold alarm, including a drop not yet recorded by poke().
    /// @dev Deliberately not latched: a refill can clear the live alarm, but cannot erase a recorded trip.
    function isTripped() external view returns (bool) {
        return canaryAddress.balance < thresholdWei && highWaterMark >= thresholdWei;
    }

    /// @notice Permissionlessly record funding and the first observed drop below the threshold.
    /// @dev Does not move ETH, call the canary, or reward the caller. Unobserved balances cannot be recovered.
    function poke() external {
        uint256 balance = canaryAddress.balance;
        uint256 mark = highWaterMark;
        if (balance > mark) {
            highWaterMark = balance;
            emit HighWaterMarkUpdated(mark, balance);
            mark = balance;
        }

        if (!tripRecorded && balance < thresholdWei && mark >= thresholdWei) {
            tripRecorded = true;
            trippedAt = block.timestamp;
            trippedBlock = block.number;
            emit CanaryTripped(balance, mark, block.timestamp, block.number);
        }
    }

    function derivePoint(bytes32 hash) private view returns (uint256 x, uint256 y, uint256 i) {
        for (i = 0;; ++i) {
            x = uint256(keccak256(abi.encode(hash, i))) % FIELD_PRIME;
            uint256 rhs = addmod(mulmod(mulmod(x, x, FIELD_PRIME), x, FIELD_PRIME), 7, FIELD_PRIME);
            y = sqrtCandidate(rhs);
            if (mulmod(y, y, FIELD_PRIME) == rhs) {
                if (y % 2 == 1) y = FIELD_PRIME - y;
                return (x, y, i);
            }
        }
    }

    function sqrtCandidate(uint256 rhs) private view returns (uint256) {
        // EIP-198: three 32-byte lengths followed by base, exponent and modulus, each 32 bytes.
        (bool success, bytes memory result) =
            address(0x05).staticcall(abi.encode(uint256(32), uint256(32), uint256(32), rhs, SQRT_EXPONENT, FIELD_PRIME));
        if (!success || result.length != 32) revert ModExpFailed();
        return abi.decode(result, (uint256));
    }
}
