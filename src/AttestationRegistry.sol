// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title IRobotID
 * @notice Interface for the RobotID contract
 */
interface IRobotID {
    function getRobot(uint256 tokenId)
        external
        view
        returns (
            address operator,
            bytes32 hardwareHash,
            address hardwareAddress,
            uint256 registeredAt,
            uint256 stakeAmount,
            uint256 attestationCount,
            uint256 trustScore,
            bool active
        );

    function isVerified(uint256 tokenId) external view returns (bool);
    function incrementAttestationCount(uint256 tokenId) external;
    function updateTrustScore(uint256 tokenId, uint256 newScore) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function getHardwareAddress(uint256 tokenId) external view returns (address);
}

/**
 * @title AttestationRegistry
 * @author Flectra Protocol
 * @notice On-chain registry for robot execution attestations
 * @dev Stores Merkle roots of attestation batches for gas-efficient verification.
 *      Individual attestations can be verified against stored Merkle roots.
 *
 * Key features:
 * - Batch attestation submission via Merkle trees (gas efficient)
 * - Single attestation submission for low-volume robots
 * - Hardware signature verification for authenticity
 * - Dynamic trust score computation
 * - Rate limiting to prevent spam
 *
 * Security considerations:
 * - Signatures verified against robot's hardware address
 * - Nonce-based replay protection
 * - Rate limiting per robot
 * - Pausable for emergencies
 */
contract AttestationRegistry is Ownable2Step, Pausable, ReentrancyGuard {
    using ECDSA for bytes32;

    // ============ Constants ============

    /// @notice Maximum trust score (100%)
    uint256 public constant MAX_TRUST_SCORE = 10_000;

    /// @notice Base trust score for new robots (50%)
    uint256 public constant BASE_TRUST_SCORE = 5_000;

    /// @notice Maximum attestations per batch
    uint256 public constant MAX_BATCH_SIZE = 10_000;

    /// @notice Minimum time between batches from same robot (1 minute)
    uint256 public constant MIN_BATCH_INTERVAL = 1 minutes;

    /// @notice Domain typehash for batch attestations
    bytes32 public constant BATCH_TYPEHASH = keccak256(
        "AttestationBatch(uint256 robotId,bytes32 merkleRoot,uint256 count,bytes32 metadataHash,uint256 nonce,uint256 chainId)"
    );

    /// @notice Domain typehash for single attestations
    bytes32 public constant SINGLE_TYPEHASH = keccak256(
        "SingleAttestation(uint256 robotId,bytes32 actionHash,bytes32 locationHash,bytes32 sensorHash,uint8 level,uint256 nonce,uint256 chainId)"
    );

    // ============ Structs ============

    /// @notice Batch attestation data
    /// @param robotId Robot that submitted the batch
    /// @param merkleRoot Root of attestation Merkle tree
    /// @param attestationCount Number of attestations in batch
    /// @param timestamp Submission block timestamp
    /// @param metadataHash Hash of off-chain metadata (IPFS CID, etc.)
    struct AttestationBatch {
        uint256 robotId;
        bytes32 merkleRoot;
        uint256 attestationCount;
        uint256 timestamp;
        bytes32 metadataHash;
    }

    /// @notice Single attestation data
    /// @param robotId Robot that submitted the attestation
    /// @param actionHash Hash of action descriptor
    /// @param locationHash Hash of GPS/location data
    /// @param timestamp Submission block timestamp
    /// @param sensorDataHash Hash of sensor readings
    /// @param assuranceLevel Verification depth (1-5)
    struct SingleAttestation {
        uint256 robotId;
        bytes32 actionHash;
        bytes32 locationHash;
        uint256 timestamp;
        bytes32 sensorDataHash;
        uint8 assuranceLevel;
    }

    /// @notice Trust score calculation weights
    /// @param longevityWeight Weight for time active
    /// @param activityWeight Weight for attestation count
    /// @param stakeWeight Weight for stake amount
    /// @param maxLongevityBonus Maximum bonus from longevity
    /// @param maxActivityBonus Maximum bonus from activity
    /// @param maxStakeBonus Maximum bonus from stake
    struct TrustScoreConfig {
        uint256 longevityWeight;
        uint256 activityWeight;
        uint256 stakeWeight;
        uint256 maxLongevityBonus;
        uint256 maxActivityBonus;
        uint256 maxStakeBonus;
    }

    // ============ State Variables ============

    /// @notice RobotID contract reference
    IRobotID public robotIdContract;

    /// @notice Counter for batch IDs
    uint256 public batchCounter;

    /// @notice Counter for single attestation IDs
    uint256 public singleAttestationCounter;

    /// @notice Trust score configuration
    TrustScoreConfig public trustScoreConfig;

    /// @notice Batches by ID
    mapping(uint256 batchId => AttestationBatch batch) private _batches;

    /// @notice Single attestations by ID
    mapping(uint256 attestationId => SingleAttestation attestation) private _singleAttestations;

    /// @notice Batch IDs by robot
    mapping(uint256 robotId => uint256[] batchIds) private _robotBatches;

    /// @notice Single attestation IDs by robot
    mapping(uint256 robotId => uint256[] attestationIds) private _robotAttestations;

    /// @notice Verified Merkle roots (for quick lookup)
    mapping(bytes32 merkleRoot => bool verified) public verifiedRoots;

    /// @notice Robot ID for each Merkle root
    mapping(bytes32 merkleRoot => uint256 robotId) public rootToRobotId;

    /// @notice Nonces for replay protection (per robot)
    mapping(uint256 robotId => uint256 nonce) public robotNonces;

    /// @notice Last batch submission time (for rate limiting)
    mapping(uint256 robotId => uint256 timestamp) public lastBatchTime;

    // ============ Events ============

    /// @notice Emitted when a batch is submitted
    event BatchSubmitted(
        uint256 indexed batchId,
        uint256 indexed robotId,
        bytes32 indexed merkleRoot,
        uint256 attestationCount,
        bytes32 metadataHash
    );

    /// @notice Emitted when a single attestation is submitted
    event SingleAttestationSubmitted(
        uint256 indexed attestationId,
        uint256 indexed robotId,
        bytes32 indexed actionHash,
        uint8 assuranceLevel
    );

    /// @notice Emitted when an attestation is verified against a batch
    event AttestationVerified(
        uint256 indexed batchId,
        bytes32 indexed attestationHash,
        uint256 indexed robotId
    );

    /// @notice Emitted when trust score is computed
    event TrustScoreComputed(
        uint256 indexed robotId,
        uint256 oldScore,
        uint256 newScore,
        uint256 longevityBonus,
        uint256 activityBonus,
        uint256 stakeBonus
    );

    /// @notice Emitted when trust score config is updated
    event TrustScoreConfigUpdated(TrustScoreConfig newConfig);

    // ============ Errors ============

    /// @notice Robot is not verified
    error RobotNotVerified();

    /// @notice Caller is not the robot operator
    error NotOperator();

    /// @notice Invalid signature
    error InvalidSignature();

    /// @notice Merkle root already registered
    error RootAlreadyExists();

    /// @notice Batch not found
    error BatchNotFound();

    /// @notice Attestation not found
    error AttestationNotFound();

    /// @notice Invalid Merkle proof
    error InvalidMerkleProof();

    /// @notice Invalid parameter
    error InvalidParameter();

    /// @notice Rate limit exceeded
    error RateLimitExceeded();

    /// @notice Zero address not allowed
    error ZeroAddress();

    /// @notice Batch size exceeds maximum
    error BatchTooLarge();

    /// @notice Invalid assurance level
    error InvalidAssuranceLevel();

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {
        // Default trust score configuration
        trustScoreConfig = TrustScoreConfig({
            longevityWeight: 100,      // 1% per week
            activityWeight: 50,        // 0.5% per 10 attestations
            stakeWeight: 100,          // 1% per 1000 USDC
            maxLongevityBonus: 2000,   // Max 20%
            maxActivityBonus: 1500,    // Max 15%
            maxStakeBonus: 1500        // Max 15%
        });
    }

    // ============ External Functions ============

    /**
     * @notice Submit a batch of attestations as a Merkle root
     * @dev Requires valid hardware signature. Rate limited.
     * @param robotId The robot's token ID
     * @param merkleRoot Root of the attestation Merkle tree
     * @param attestationCount Number of attestations in the batch
     * @param metadataHash Hash of off-chain metadata
     * @param signature Hardware signature over batch data
     * @return batchId The created batch's ID
     */
    function submitBatch(
        uint256 robotId,
        bytes32 merkleRoot,
        uint256 attestationCount,
        bytes32 metadataHash,
        bytes calldata signature
    ) external whenNotPaused nonReentrant returns (uint256 batchId) {
        // Validate inputs
        if (merkleRoot == bytes32(0)) revert InvalidParameter();
        if (attestationCount == 0 || attestationCount > MAX_BATCH_SIZE) {
            revert BatchTooLarge();
        }
        if (verifiedRoots[merkleRoot]) revert RootAlreadyExists();

        // Verify robot status
        if (!robotIdContract.isVerified(robotId)) revert RobotNotVerified();
        if (robotIdContract.ownerOf(robotId) != msg.sender) revert NotOperator();

        // Rate limiting
        if (block.timestamp < lastBatchTime[robotId] + MIN_BATCH_INTERVAL) {
            revert RateLimitExceeded();
        }

        // Verify hardware signature
        uint256 nonce = robotNonces[robotId]++;
        _verifyBatchSignature(robotId, merkleRoot, attestationCount, metadataHash, nonce, signature);

        // Create batch
        unchecked {
            batchId = ++batchCounter;
        }

        _batches[batchId] = AttestationBatch({
            robotId: robotId,
            merkleRoot: merkleRoot,
            attestationCount: attestationCount,
            timestamp: block.timestamp,
            metadataHash: metadataHash
        });

        _robotBatches[robotId].push(batchId);
        verifiedRoots[merkleRoot] = true;
        rootToRobotId[merkleRoot] = robotId;
        lastBatchTime[robotId] = block.timestamp;

        // Update robot stats
        robotIdContract.incrementAttestationCount(robotId);

        emit BatchSubmitted(batchId, robotId, merkleRoot, attestationCount, metadataHash);

        // Update trust score
        _updateTrustScore(robotId);
    }

    /**
     * @notice Submit a single attestation
     * @dev For low-volume robots. Requires valid hardware signature.
     * @param robotId The robot's token ID
     * @param actionHash Hash of the action performed
     * @param locationHash Hash of location data
     * @param sensorDataHash Hash of sensor readings
     * @param assuranceLevel Verification depth (1-5)
     * @param signature Hardware signature
     * @return attestationId The created attestation's ID
     */
    function submitSingleAttestation(
        uint256 robotId,
        bytes32 actionHash,
        bytes32 locationHash,
        bytes32 sensorDataHash,
        uint8 assuranceLevel,
        bytes calldata signature
    ) external whenNotPaused nonReentrant returns (uint256 attestationId) {
        // Validate inputs
        if (actionHash == bytes32(0)) revert InvalidParameter();
        if (assuranceLevel == 0 || assuranceLevel > 5) revert InvalidAssuranceLevel();

        // Verify robot status
        if (!robotIdContract.isVerified(robotId)) revert RobotNotVerified();
        if (robotIdContract.ownerOf(robotId) != msg.sender) revert NotOperator();

        // Verify hardware signature
        uint256 nonce = robotNonces[robotId]++;
        _verifySingleSignature(
            robotId,
            actionHash,
            locationHash,
            sensorDataHash,
            assuranceLevel,
            nonce,
            signature
        );

        // Create attestation
        unchecked {
            attestationId = ++singleAttestationCounter;
        }

        _singleAttestations[attestationId] = SingleAttestation({
            robotId: robotId,
            actionHash: actionHash,
            locationHash: locationHash,
            timestamp: block.timestamp,
            sensorDataHash: sensorDataHash,
            assuranceLevel: assuranceLevel
        });

        _robotAttestations[robotId].push(attestationId);

        // Update robot stats
        robotIdContract.incrementAttestationCount(robotId);

        emit SingleAttestationSubmitted(attestationId, robotId, actionHash, assuranceLevel);

        // Update trust score
        _updateTrustScore(robotId);
    }

    /**
     * @notice Verify an attestation exists in a batch using Merkle proof
     * @param batchId The batch ID
     * @param leaf The attestation hash (leaf)
     * @param proof Merkle proof
     * @return valid True if the proof is valid
     */
    function verifyAttestation(
        uint256 batchId,
        bytes32 leaf,
        bytes32[] calldata proof
    ) external view returns (bool valid) {
        AttestationBatch storage batch = _batches[batchId];
        if (batch.timestamp == 0) revert BatchNotFound();

        return MerkleProof.verify(proof, batch.merkleRoot, leaf);
    }

    /**
     * @notice Verify and emit event for verified attestation
     * @param batchId The batch ID
     * @param leaf The attestation hash (leaf)
     * @param proof Merkle proof
     */
    function verifyAndRecord(
        uint256 batchId,
        bytes32 leaf,
        bytes32[] calldata proof
    ) external {
        AttestationBatch storage batch = _batches[batchId];
        if (batch.timestamp == 0) revert BatchNotFound();

        if (!MerkleProof.verify(proof, batch.merkleRoot, leaf)) {
            revert InvalidMerkleProof();
        }

        emit AttestationVerified(batchId, leaf, batch.robotId);
    }

    // ============ View Functions ============

    /**
     * @notice Get batch data
     * @param batchId The batch ID
     * @return Batch struct
     */
    function getBatch(uint256 batchId) external view returns (AttestationBatch memory) {
        if (_batches[batchId].timestamp == 0) revert BatchNotFound();
        return _batches[batchId];
    }

    /**
     * @notice Get single attestation data
     * @param attestationId The attestation ID
     * @return Attestation struct
     */
    function getSingleAttestation(uint256 attestationId)
        external
        view
        returns (SingleAttestation memory)
    {
        if (_singleAttestations[attestationId].timestamp == 0) {
            revert AttestationNotFound();
        }
        return _singleAttestations[attestationId];
    }

    /**
     * @notice Get all batch IDs for a robot
     * @param robotId The robot's token ID
     * @return Array of batch IDs
     */
    function getRobotBatches(uint256 robotId) external view returns (uint256[] memory) {
        return _robotBatches[robotId];
    }

    /**
     * @notice Get all single attestation IDs for a robot
     * @param robotId The robot's token ID
     * @return Array of attestation IDs
     */
    function getRobotAttestations(uint256 robotId) external view returns (uint256[] memory) {
        return _robotAttestations[robotId];
    }

    /**
     * @notice Get total attestation count for a robot
     * @param robotId The robot's token ID
     * @return Total count (batches + singles)
     */
    function getRobotAttestationCount(uint256 robotId) external view returns (uint256) {
        return _robotBatches[robotId].length + _robotAttestations[robotId].length;
    }

    /**
     * @notice Check if a Merkle root is registered
     * @param merkleRoot The root to check
     * @return True if registered
     */
    function isValidRoot(bytes32 merkleRoot) external view returns (bool) {
        return verifiedRoots[merkleRoot];
    }

    /**
     * @notice Get robot ID for a Merkle root
     * @param merkleRoot The root to look up
     * @return Robot token ID
     */
    function getRobotForRoot(bytes32 merkleRoot) external view returns (uint256) {
        return rootToRobotId[merkleRoot];
    }

    /**
     * @notice Get current nonce for a robot
     * @param robotId The robot's token ID
     * @return Current nonce
     */
    function getNonce(uint256 robotId) external view returns (uint256) {
        return robotNonces[robotId];
    }

    // ============ Admin Functions ============

    /**
     * @notice Set RobotID contract address
     * @param _robotIdContract New address
     */
    function setRobotIdContract(address _robotIdContract) external onlyOwner {
        if (_robotIdContract == address(0)) revert ZeroAddress();
        robotIdContract = IRobotID(_robotIdContract);
    }

    /**
     * @notice Update trust score configuration
     * @param _config New configuration
     */
    function setTrustScoreConfig(TrustScoreConfig calldata _config) external onlyOwner {
        // Validate max bonuses don't exceed remaining score space
        if (_config.maxLongevityBonus + _config.maxActivityBonus + _config.maxStakeBonus >
            MAX_TRUST_SCORE - BASE_TRUST_SCORE) {
            revert InvalidParameter();
        }
        trustScoreConfig = _config;
        emit TrustScoreConfigUpdated(_config);
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Internal Functions ============

    /**
     * @notice Verify batch attestation signature
     */
    function _verifyBatchSignature(
        uint256 robotId,
        bytes32 merkleRoot,
        uint256 attestationCount,
        bytes32 metadataHash,
        uint256 nonce,
        bytes calldata signature
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                BATCH_TYPEHASH,
                robotId,
                merkleRoot,
                attestationCount,
                metadataHash,
                nonce,
                block.chainid
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash)
        );

        address signer = ECDSA.recover(digest, signature);
        address expectedSigner = robotIdContract.getHardwareAddress(robotId);

        if (signer != expectedSigner) revert InvalidSignature();
    }

    /**
     * @notice Verify single attestation signature
     */
    function _verifySingleSignature(
        uint256 robotId,
        bytes32 actionHash,
        bytes32 locationHash,
        bytes32 sensorDataHash,
        uint8 assuranceLevel,
        uint256 nonce,
        bytes calldata signature
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                SINGLE_TYPEHASH,
                robotId,
                actionHash,
                locationHash,
                sensorDataHash,
                assuranceLevel,
                nonce,
                block.chainid
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash)
        );

        address signer = ECDSA.recover(digest, signature);
        address expectedSigner = robotIdContract.getHardwareAddress(robotId);

        if (signer != expectedSigner) revert InvalidSignature();
    }

    /**
     * @notice Compute and update trust score for a robot
     * @dev Score = BASE + longevity_bonus + activity_bonus + stake_bonus
     */
    function _updateTrustScore(uint256 robotId) internal {
        (
            ,  // operator
            ,  // hardwareHash
            ,  // hardwareAddress
            uint256 registeredAt,
            uint256 stakeAmount,
            uint256 attestationCount,
            uint256 currentScore,
            bool active
        ) = robotIdContract.getRobot(robotId);

        if (!active) return;

        TrustScoreConfig memory config = trustScoreConfig;

        // Calculate longevity bonus
        uint256 weeksActive = (block.timestamp - registeredAt) / 1 weeks;
        uint256 longevityBonus = weeksActive * config.longevityWeight;
        if (longevityBonus > config.maxLongevityBonus) {
            longevityBonus = config.maxLongevityBonus;
        }

        // Calculate activity bonus (per 10 attestations)
        uint256 activityBonus = (attestationCount / 10) * config.activityWeight;
        if (activityBonus > config.maxActivityBonus) {
            activityBonus = config.maxActivityBonus;
        }

        // Calculate stake bonus (per 1000 USDC = 1000e6)
        uint256 stakeBonus = (stakeAmount / 1000e6) * config.stakeWeight;
        if (stakeBonus > config.maxStakeBonus) {
            stakeBonus = config.maxStakeBonus;
        }

        // Compute new score
        uint256 newScore = BASE_TRUST_SCORE + longevityBonus + activityBonus + stakeBonus;
        if (newScore > MAX_TRUST_SCORE) {
            newScore = MAX_TRUST_SCORE;
        }

        // Only update if changed
        if (newScore != currentScore) {
            robotIdContract.updateTrustScore(robotId, newScore);

            emit TrustScoreComputed(
                robotId,
                currentScore,
                newScore,
                longevityBonus,
                activityBonus,
                stakeBonus
            );
        }
    }
}
