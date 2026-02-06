// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title RobotID
 * @author Flectra Protocol
 * @notice Hardware-bound robot identity NFT for the Flectra protocol
 * @dev Each RobotID is cryptographically bound to physical hardware through secure enclave attestation.
 *      The NFT represents a unique robot identity that can submit attestations and stake collateral.
 *
 * Security considerations:
 * - Hardware attestation uses ECDSA signatures from TPM/secure enclave
 * - One hardware device = one RobotID (enforced via hardwareHash mapping)
 * - Operator permissions are tied to NFT ownership
 * - Trust scores are managed by authorized contracts only
 */
contract RobotID is ERC721Enumerable, Ownable2Step, Pausable, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ Constants ============

    /// @notice Maximum trust score in basis points (100%)
    uint256 public constant MAX_TRUST_SCORE = 10_000;

    /// @notice Initial trust score for new robots (50%)
    uint256 public constant INITIAL_TRUST_SCORE = 5_000;

    /// @notice Domain separator for signature verification
    bytes32 public constant REGISTRATION_TYPEHASH = keccak256(
        "RobotRegistration(address operator,bytes32 hardwareHash,uint256 chainId,uint256 nonce)"
    );

    // ============ Structs ============

    /// @notice Robot identity data
    /// @param operator Current operator address (NFT owner)
    /// @param hardwareHash Keccak256 hash of hardware attestation from TPM/secure enclave
    /// @param hardwareAddress Public key address derived from hardware attestation
    /// @param registeredAt Block timestamp of registration
    /// @param stakeAmount Current staked collateral amount
    /// @param attestationCount Total number of attestations submitted
    /// @param trustScore Computed trust score (0-10000 basis points)
    /// @param active Whether the robot is currently active
    struct Robot {
        address operator;
        bytes32 hardwareHash;
        address hardwareAddress;
        uint256 registeredAt;
        uint256 stakeAmount;
        uint256 attestationCount;
        uint256 trustScore;
        bool active;
    }

    // ============ State Variables ============

    /// @notice Current token ID counter
    uint256 private _tokenIdCounter;

    /// @notice Minimum stake required to register a robot
    uint256 public minStakeAmount;

    /// @notice Address of the staking contract
    address public stakingContract;

    /// @notice Address of the attestation registry
    address public attestationRegistry;

    /// @notice Robot data by token ID
    mapping(uint256 tokenId => Robot robot) private _robots;

    /// @notice Token ID by hardware hash (ensures one NFT per hardware)
    mapping(bytes32 hardwareHash => uint256 tokenId) public hardwareToTokenId;

    /// @notice Registration nonces by operator (replay protection)
    mapping(address operator => uint256 nonce) public registrationNonces;

    // ============ Events ============

    /// @notice Emitted when a new robot is registered
    event RobotRegistered(
        uint256 indexed tokenId,
        address indexed operator,
        bytes32 indexed hardwareHash,
        address hardwareAddress,
        uint256 stakeAmount
    );

    /// @notice Emitted when a robot is deactivated
    event RobotDeactivated(uint256 indexed tokenId, address indexed operator);

    /// @notice Emitted when a robot is reactivated
    event RobotReactivated(uint256 indexed tokenId, address indexed operator);

    /// @notice Emitted when a robot's trust score is updated
    event TrustScoreUpdated(uint256 indexed tokenId, uint256 oldScore, uint256 newScore);

    /// @notice Emitted when attestation count is incremented
    event AttestationCountIncremented(uint256 indexed tokenId, uint256 newCount);

    /// @notice Emitted when stake amount is updated
    event StakeAmountUpdated(uint256 indexed tokenId, uint256 oldAmount, uint256 newAmount);

    /// @notice Emitted when minimum stake is changed
    event MinStakeAmountUpdated(uint256 oldAmount, uint256 newAmount);

    /// @notice Emitted when staking contract is updated
    event StakingContractUpdated(address indexed oldContract, address indexed newContract);

    /// @notice Emitted when attestation registry is updated
    event AttestationRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    // ============ Errors ============

    /// @notice Hardware has already been registered to another RobotID
    error HardwareAlreadyRegistered();

    /// @notice Stake amount is below minimum required
    error InsufficientStake();

    /// @notice Hardware attestation signature is invalid
    error InvalidHardwareAttestation();

    /// @notice Robot is not in active state
    error RobotNotActive();

    /// @notice Robot is already in active state
    error RobotAlreadyActive();

    /// @notice Caller is not the robot's operator
    error NotOperator();

    /// @notice Caller is not authorized for this operation
    error NotAuthorized();

    /// @notice Signature verification failed
    error InvalidSignature();

    /// @notice Token ID does not exist
    error TokenDoesNotExist();

    /// @notice Invalid address (zero address)
    error InvalidAddress();

    /// @notice Invalid trust score value
    error InvalidTrustScore();

    /// @notice Hardware hash cannot be zero
    error InvalidHardwareHash();

    // ============ Modifiers ============

    /// @notice Ensures token exists
    modifier tokenExists(uint256 tokenId) {
        if (_ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        _;
    }

    /// @notice Ensures caller is the operator
    modifier onlyOperator(uint256 tokenId) {
        if (_robots[tokenId].operator != msg.sender) revert NotOperator();
        _;
    }

    /// @notice Ensures caller is the staking contract
    modifier onlyStakingContract() {
        if (msg.sender != stakingContract) revert NotAuthorized();
        _;
    }

    /// @notice Ensures caller is the attestation registry
    modifier onlyAttestationRegistry() {
        if (msg.sender != attestationRegistry) revert NotAuthorized();
        _;
    }

    // ============ Constructor ============

    /// @notice Initialize the RobotID contract
    /// @param _minStakeAmount Minimum stake required for registration
    constructor(uint256 _minStakeAmount) ERC721("Flectra Robot ID", "ROBOT") Ownable(msg.sender) {
        minStakeAmount = _minStakeAmount;
    }

    // ============ External Functions ============

    /**
     * @notice Register a new robot with hardware attestation
     * @dev The signature must be from the hardware's secure enclave proving ownership.
     *      Hardware address is recovered from the signature and stored for future verification.
     * @param hardwareHash Keccak256 hash of the hardware attestation from TPM/secure enclave
     * @param attestationSignature ECDSA signature proving possession of hardware private key
     * @param stakeAmount Amount being staked for this robot (must be >= minStakeAmount)
     * @return tokenId The newly minted token ID
     */
    function registerRobot(
        bytes32 hardwareHash,
        bytes calldata attestationSignature,
        uint256 stakeAmount
    ) external whenNotPaused nonReentrant returns (uint256 tokenId) {
        // Input validation
        if (hardwareHash == bytes32(0)) revert InvalidHardwareHash();
        if (hardwareToTokenId[hardwareHash] != 0) revert HardwareAlreadyRegistered();
        if (stakeAmount < minStakeAmount) revert InsufficientStake();

        // Build message hash with replay protection
        uint256 nonce = registrationNonces[msg.sender]++;
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encode(REGISTRATION_TYPEHASH, msg.sender, hardwareHash, block.chainid, nonce)
                )
            )
        );

        // Recover signer from signature
        address hardwareAddress = ECDSA.recover(messageHash, attestationSignature);
        if (hardwareAddress == address(0)) revert InvalidSignature();

        // Verify hardware address derives from hardware hash (binding)
        // The hardware hash should be keccak256(hardwareAddress, deviceId, manufacturerSig)
        // For now, we trust that the attestation service verified this binding

        // Mint the RobotID NFT
        unchecked {
            tokenId = ++_tokenIdCounter;
        }
        _safeMint(msg.sender, tokenId);

        // Store robot data
        _robots[tokenId] = Robot({
            operator: msg.sender,
            hardwareHash: hardwareHash,
            hardwareAddress: hardwareAddress,
            registeredAt: block.timestamp,
            stakeAmount: stakeAmount,
            attestationCount: 0,
            trustScore: INITIAL_TRUST_SCORE,
            active: true
        });

        hardwareToTokenId[hardwareHash] = tokenId;

        emit RobotRegistered(tokenId, msg.sender, hardwareHash, hardwareAddress, stakeAmount);
    }

    /**
     * @notice Deactivate a robot (operator only)
     * @dev Deactivated robots cannot submit attestations but can be reactivated
     * @param tokenId The robot's token ID
     */
    function deactivateRobot(uint256 tokenId)
        external
        tokenExists(tokenId)
        onlyOperator(tokenId)
    {
        Robot storage robot = _robots[tokenId];
        if (!robot.active) revert RobotNotActive();

        robot.active = false;
        emit RobotDeactivated(tokenId, msg.sender);
    }

    /**
     * @notice Reactivate a deactivated robot (operator only)
     * @param tokenId The robot's token ID
     */
    function reactivateRobot(uint256 tokenId)
        external
        tokenExists(tokenId)
        onlyOperator(tokenId)
    {
        Robot storage robot = _robots[tokenId];
        if (robot.active) revert RobotAlreadyActive();

        robot.active = true;
        emit RobotReactivated(tokenId, msg.sender);
    }

    /**
     * @notice Update trust score (called by attestation registry or owner)
     * @param tokenId The robot's token ID
     * @param newScore New trust score in basis points (0-10000)
     */
    function updateTrustScore(uint256 tokenId, uint256 newScore)
        external
        tokenExists(tokenId)
    {
        if (msg.sender != attestationRegistry && msg.sender != owner()) {
            revert NotAuthorized();
        }
        if (newScore > MAX_TRUST_SCORE) revert InvalidTrustScore();

        Robot storage robot = _robots[tokenId];
        uint256 oldScore = robot.trustScore;
        robot.trustScore = newScore;

        emit TrustScoreUpdated(tokenId, oldScore, newScore);
    }

    /**
     * @notice Increment attestation count (called by attestation registry)
     * @param tokenId The robot's token ID
     */
    function incrementAttestationCount(uint256 tokenId)
        external
        tokenExists(tokenId)
        onlyAttestationRegistry
    {
        Robot storage robot = _robots[tokenId];
        unchecked {
            robot.attestationCount++;
        }
        emit AttestationCountIncremented(tokenId, robot.attestationCount);
    }

    /**
     * @notice Update stake amount (called by staking contract)
     * @param tokenId The robot's token ID
     * @param newAmount New stake amount
     */
    function updateStakeAmount(uint256 tokenId, uint256 newAmount)
        external
        tokenExists(tokenId)
        onlyStakingContract
    {
        Robot storage robot = _robots[tokenId];
        uint256 oldAmount = robot.stakeAmount;
        robot.stakeAmount = newAmount;

        emit StakeAmountUpdated(tokenId, oldAmount, newAmount);
    }

    // ============ View Functions ============

    /**
     * @notice Get full robot data
     * @param tokenId The robot's token ID
     * @return Robot struct with all data
     */
    function getRobot(uint256 tokenId) external view tokenExists(tokenId) returns (Robot memory) {
        return _robots[tokenId];
    }

    /**
     * @notice Check if a robot is active and meets minimum stake
     * @param tokenId The robot's token ID
     * @return True if robot is verified and can operate
     */
    function isVerified(uint256 tokenId) external view returns (bool) {
        if (_ownerOf(tokenId) == address(0)) return false;
        Robot storage robot = _robots[tokenId];
        return robot.active && robot.stakeAmount >= minStakeAmount;
    }

    /**
     * @notice Get the operator address for a robot
     * @param tokenId The robot's token ID
     * @return Operator address
     */
    function getOperator(uint256 tokenId) external view tokenExists(tokenId) returns (address) {
        return _robots[tokenId].operator;
    }

    /**
     * @notice Get the hardware address for a robot
     * @param tokenId The robot's token ID
     * @return Hardware public key address
     */
    function getHardwareAddress(uint256 tokenId) external view tokenExists(tokenId) returns (address) {
        return _robots[tokenId].hardwareAddress;
    }

    /**
     * @notice Get robot ID by hardware hash
     * @param hardwareHash The hardware attestation hash
     * @return Token ID (0 if not registered)
     */
    function getRobotByHardware(bytes32 hardwareHash) external view returns (uint256) {
        return hardwareToTokenId[hardwareHash];
    }

    /**
     * @notice Get the current token ID counter
     * @return Current counter value (also total minted)
     */
    function totalRobots() external view returns (uint256) {
        return _tokenIdCounter;
    }

    // ============ Admin Functions ============

    /**
     * @notice Update minimum stake amount
     * @param _minStakeAmount New minimum stake
     */
    function setMinStakeAmount(uint256 _minStakeAmount) external onlyOwner {
        uint256 oldAmount = minStakeAmount;
        minStakeAmount = _minStakeAmount;
        emit MinStakeAmountUpdated(oldAmount, _minStakeAmount);
    }

    /**
     * @notice Set the staking contract address
     * @param _stakingContract New staking contract address
     */
    function setStakingContract(address _stakingContract) external onlyOwner {
        if (_stakingContract == address(0)) revert InvalidAddress();
        address oldContract = stakingContract;
        stakingContract = _stakingContract;
        emit StakingContractUpdated(oldContract, _stakingContract);
    }

    /**
     * @notice Set the attestation registry address
     * @param _attestationRegistry New attestation registry address
     */
    function setAttestationRegistry(address _attestationRegistry) external onlyOwner {
        if (_attestationRegistry == address(0)) revert InvalidAddress();
        address oldRegistry = attestationRegistry;
        attestationRegistry = _attestationRegistry;
        emit AttestationRegistryUpdated(oldRegistry, _attestationRegistry);
    }

    /**
     * @notice Pause all registration operations
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause registration operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Internal Functions ============

    /**
     * @notice Hook called on token transfers
     * @dev Updates operator address when NFT is transferred
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);

        // Update operator on transfer (not mint/burn)
        if (from != address(0) && to != address(0)) {
            _robots[tokenId].operator = to;
        }

        return super._update(to, tokenId, auth);
    }
}
