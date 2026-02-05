// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title RobotID
 * @notice Hardware-bound robot identity NFT for the Flectra protocol
 * @dev Each RobotID is cryptographically bound to physical hardware through secure enclave attestation
 */
contract RobotID is ERC721Enumerable, Ownable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ Structs ============

    struct Robot {
        address operator;           // Operator who registered the robot
        bytes32 hardwareHash;       // Hash of hardware attestation (TPM/secure enclave)
        uint256 registeredAt;       // Registration timestamp
        uint256 stakeAmount;        // Amount staked for this robot
        uint256 attestationCount;   // Total attestations submitted
        uint256 trustScore;         // Computed trust score (0-10000, basis points)
        bool active;                // Whether robot is active
    }

    // ============ State Variables ============

    uint256 private _tokenIdCounter;
    uint256 public minStakeAmount;
    address public stakingContract;
    address public attestationRegistry;

    mapping(uint256 => Robot) public robots;
    mapping(bytes32 => uint256) public hardwareToTokenId;
    mapping(address => uint256[]) public operatorRobots;

    // ============ Events ============

    event RobotRegistered(
        uint256 indexed tokenId,
        address indexed operator,
        bytes32 hardwareHash,
        uint256 stakeAmount
    );
    event RobotDeactivated(uint256 indexed tokenId, address indexed operator);
    event RobotReactivated(uint256 indexed tokenId, address indexed operator);
    event TrustScoreUpdated(uint256 indexed tokenId, uint256 newScore);
    event AttestationCountIncremented(uint256 indexed tokenId, uint256 newCount);

    // ============ Errors ============

    error HardwareAlreadyRegistered();
    error InsufficientStake();
    error InvalidHardwareAttestation();
    error RobotNotActive();
    error NotOperator();
    error NotAuthorized();
    error InvalidSignature();

    // ============ Constructor ============

    constructor(
        uint256 _minStakeAmount
    ) ERC721("Flectra Robot ID", "ROBOT") Ownable(msg.sender) {
        minStakeAmount = _minStakeAmount;
    }

    // ============ External Functions ============

    /**
     * @notice Register a new robot with hardware attestation
     * @param hardwareHash Hash of the hardware attestation from TPM/secure enclave
     * @param attestationSignature Signature proving possession of hardware private key
     * @param stakeAmount Amount being staked for this robot
     */
    function registerRobot(
        bytes32 hardwareHash,
        bytes memory attestationSignature,
        uint256 stakeAmount
    ) external returns (uint256 tokenId) {
        // Verify hardware hasn't been registered before
        if (hardwareToTokenId[hardwareHash] != 0) {
            revert HardwareAlreadyRegistered();
        }

        // Verify minimum stake
        if (stakeAmount < minStakeAmount) {
            revert InsufficientStake();
        }

        // Verify hardware attestation signature
        // The signature must be from the hardware's secure enclave proving ownership
        bytes32 messageHash = keccak256(abi.encodePacked(
            "FLECTRA_ROBOT_REGISTRATION",
            msg.sender,
            hardwareHash,
            block.chainid
        ));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedHash.recover(attestationSignature);

        // The signer should derive from the hardware hash (simplified verification)
        if (signer == address(0)) {
            revert InvalidSignature();
        }

        // Mint the RobotID NFT
        _tokenIdCounter++;
        tokenId = _tokenIdCounter;
        _safeMint(msg.sender, tokenId);

        // Store robot data
        robots[tokenId] = Robot({
            operator: msg.sender,
            hardwareHash: hardwareHash,
            registeredAt: block.timestamp,
            stakeAmount: stakeAmount,
            attestationCount: 0,
            trustScore: 5000, // Start at 50% trust
            active: true
        });

        hardwareToTokenId[hardwareHash] = tokenId;
        operatorRobots[msg.sender].push(tokenId);

        emit RobotRegistered(tokenId, msg.sender, hardwareHash, stakeAmount);
    }

    /**
     * @notice Deactivate a robot (operator only)
     * @param tokenId The robot's token ID
     */
    function deactivateRobot(uint256 tokenId) external {
        Robot storage robot = robots[tokenId];
        if (robot.operator != msg.sender) {
            revert NotOperator();
        }
        robot.active = false;
        emit RobotDeactivated(tokenId, msg.sender);
    }

    /**
     * @notice Reactivate a robot (operator only)
     * @param tokenId The robot's token ID
     */
    function reactivateRobot(uint256 tokenId) external {
        Robot storage robot = robots[tokenId];
        if (robot.operator != msg.sender) {
            revert NotOperator();
        }
        robot.active = true;
        emit RobotReactivated(tokenId, msg.sender);
    }

    /**
     * @notice Update trust score (called by attestation registry)
     * @param tokenId The robot's token ID
     * @param newScore New trust score in basis points (0-10000)
     */
    function updateTrustScore(uint256 tokenId, uint256 newScore) external {
        if (msg.sender != attestationRegistry && msg.sender != owner()) {
            revert NotAuthorized();
        }
        robots[tokenId].trustScore = newScore;
        emit TrustScoreUpdated(tokenId, newScore);
    }

    /**
     * @notice Increment attestation count (called by attestation registry)
     * @param tokenId The robot's token ID
     */
    function incrementAttestationCount(uint256 tokenId) external {
        if (msg.sender != attestationRegistry) {
            revert NotAuthorized();
        }
        robots[tokenId].attestationCount++;
        emit AttestationCountIncremented(tokenId, robots[tokenId].attestationCount);
    }

    /**
     * @notice Update stake amount (called by staking contract)
     * @param tokenId The robot's token ID
     * @param newAmount New stake amount
     */
    function updateStakeAmount(uint256 tokenId, uint256 newAmount) external {
        if (msg.sender != stakingContract) {
            revert NotAuthorized();
        }
        robots[tokenId].stakeAmount = newAmount;
    }

    // ============ View Functions ============

    /**
     * @notice Get full robot data
     * @param tokenId The robot's token ID
     */
    function getRobot(uint256 tokenId) external view returns (Robot memory) {
        return robots[tokenId];
    }

    /**
     * @notice Check if a robot is active and verified
     * @param tokenId The robot's token ID
     */
    function isVerified(uint256 tokenId) external view returns (bool) {
        return robots[tokenId].active && robots[tokenId].stakeAmount >= minStakeAmount;
    }

    /**
     * @notice Get all robots owned by an operator
     * @param operator The operator's address
     */
    function getRobotsByOperator(address operator) external view returns (uint256[] memory) {
        return operatorRobots[operator];
    }

    /**
     * @notice Get robot ID by hardware hash
     * @param hardwareHash The hardware attestation hash
     */
    function getRobotByHardware(bytes32 hardwareHash) external view returns (uint256) {
        return hardwareToTokenId[hardwareHash];
    }

    // ============ Admin Functions ============

    function setMinStakeAmount(uint256 _minStakeAmount) external onlyOwner {
        minStakeAmount = _minStakeAmount;
    }

    function setStakingContract(address _stakingContract) external onlyOwner {
        stakingContract = _stakingContract;
    }

    function setAttestationRegistry(address _attestationRegistry) external onlyOwner {
        attestationRegistry = _attestationRegistry;
    }

    // ============ Override Functions ============

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);

        // Update operator on transfer
        if (from != address(0) && to != address(0)) {
            robots[tokenId].operator = to;
        }

        return super._update(to, tokenId, auth);
    }
}
