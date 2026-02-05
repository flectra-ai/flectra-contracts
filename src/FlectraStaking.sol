// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IRobotID {
    function getRobot(uint256 tokenId) external view returns (
        address operator,
        bytes32 hardwareHash,
        uint256 registeredAt,
        uint256 stakeAmount,
        uint256 attestationCount,
        uint256 trustScore,
        bool active
    );
    function updateStakeAmount(uint256 tokenId, uint256 newAmount) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

/**
 * @title FlectraStaking
 * @notice Stake management for robot operators with slashing mechanism
 * @dev Operators stake collateral when registering robots. Stakes can be slashed for violations.
 */
contract FlectraStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Structs ============

    struct Stake {
        uint256 amount;             // Current staked amount
        uint256 lockedUntil;        // Lock period end timestamp
        uint256 slashedAmount;      // Total amount slashed
        bool exists;
    }

    struct SlashProposal {
        uint256 robotId;
        uint256 amount;
        string reason;
        address proposer;
        uint256 createdAt;
        uint256 votesFor;
        uint256 votesAgainst;
        bool executed;
        bool cancelled;
    }

    // ============ State Variables ============

    IERC20 public immutable stakeToken;  // USDC on Base
    IRobotID public robotIdContract;

    uint256 public minStakeAmount;
    uint256 public lockPeriod;           // Time stake must be locked after deposit
    uint256 public slashProposalDelay;   // Time before slash can be executed
    uint256 public slashProposalCounter;

    // Protocol fee recipients
    address public protocolTreasury;
    address public reporterRewardPool;
    uint256 public protocolFeePercent;   // In basis points (e.g., 1000 = 10%)
    uint256 public reporterRewardPercent;

    mapping(uint256 => Stake) public stakes;              // robotId => Stake
    mapping(uint256 => SlashProposal) public slashProposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // ============ Events ============

    event Staked(uint256 indexed robotId, address indexed operator, uint256 amount);
    event Unstaked(uint256 indexed robotId, address indexed operator, uint256 amount);
    event StakeIncreased(uint256 indexed robotId, uint256 addedAmount, uint256 newTotal);
    event SlashProposed(uint256 indexed proposalId, uint256 indexed robotId, uint256 amount, string reason);
    event SlashExecuted(uint256 indexed proposalId, uint256 indexed robotId, uint256 amount);
    event SlashCancelled(uint256 indexed proposalId);
    event SlashVoted(uint256 indexed proposalId, address indexed voter, bool support);

    // ============ Errors ============

    error InsufficientStake();
    error StakeLocked();
    error NotOperator();
    error StakeNotFound();
    error ProposalNotFound();
    error ProposalAlreadyExecuted();
    error ProposalDelayNotPassed();
    error AlreadyVoted();
    error InvalidAmount();

    // ============ Constructor ============

    constructor(
        address _stakeToken,
        uint256 _minStakeAmount,
        uint256 _lockPeriod,
        address _protocolTreasury
    ) Ownable(msg.sender) {
        stakeToken = IERC20(_stakeToken);
        minStakeAmount = _minStakeAmount;
        lockPeriod = _lockPeriod;
        slashProposalDelay = 24 hours;
        protocolTreasury = _protocolTreasury;
        reporterRewardPool = _protocolTreasury;
        protocolFeePercent = 5000;    // 50% to protocol
        reporterRewardPercent = 3000; // 30% to reporter
        // Remaining 20% burned or sent to harmed parties
    }

    // ============ External Functions ============

    /**
     * @notice Stake tokens for a robot
     * @param robotId The robot's token ID
     * @param amount Amount to stake
     */
    function stake(uint256 robotId, uint256 amount) external nonReentrant {
        if (amount < minStakeAmount) {
            revert InsufficientStake();
        }

        // Verify caller owns the robot
        if (robotIdContract.ownerOf(robotId) != msg.sender) {
            revert NotOperator();
        }

        // Transfer stake tokens
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);

        // Update or create stake
        Stake storage s = stakes[robotId];
        if (s.exists) {
            s.amount += amount;
            s.lockedUntil = block.timestamp + lockPeriod;
        } else {
            stakes[robotId] = Stake({
                amount: amount,
                lockedUntil: block.timestamp + lockPeriod,
                slashedAmount: 0,
                exists: true
            });
        }

        // Update RobotID contract
        robotIdContract.updateStakeAmount(robotId, s.amount);

        emit Staked(robotId, msg.sender, amount);
    }

    /**
     * @notice Increase stake for a robot
     * @param robotId The robot's token ID
     * @param amount Additional amount to stake
     */
    function increaseStake(uint256 robotId, uint256 amount) external nonReentrant {
        Stake storage s = stakes[robotId];
        if (!s.exists) {
            revert StakeNotFound();
        }

        if (robotIdContract.ownerOf(robotId) != msg.sender) {
            revert NotOperator();
        }

        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        s.amount += amount;
        s.lockedUntil = block.timestamp + lockPeriod;

        robotIdContract.updateStakeAmount(robotId, s.amount);

        emit StakeIncreased(robotId, amount, s.amount);
    }

    /**
     * @notice Unstake tokens (after lock period)
     * @param robotId The robot's token ID
     * @param amount Amount to unstake
     */
    function unstake(uint256 robotId, uint256 amount) external nonReentrant {
        Stake storage s = stakes[robotId];
        if (!s.exists) {
            revert StakeNotFound();
        }

        if (robotIdContract.ownerOf(robotId) != msg.sender) {
            revert NotOperator();
        }

        if (block.timestamp < s.lockedUntil) {
            revert StakeLocked();
        }

        if (amount > s.amount) {
            revert InvalidAmount();
        }

        // Ensure remaining stake meets minimum
        uint256 remaining = s.amount - amount;
        if (remaining > 0 && remaining < minStakeAmount) {
            revert InsufficientStake();
        }

        s.amount = remaining;
        stakeToken.safeTransfer(msg.sender, amount);

        robotIdContract.updateStakeAmount(robotId, s.amount);

        emit Unstaked(robotId, msg.sender, amount);
    }

    /**
     * @notice Propose slashing a robot's stake
     * @param robotId The robot's token ID
     * @param amount Amount to slash
     * @param reason Reason for slashing
     */
    function proposeSlash(
        uint256 robotId,
        uint256 amount,
        string calldata reason
    ) external returns (uint256 proposalId) {
        Stake storage s = stakes[robotId];
        if (!s.exists) {
            revert StakeNotFound();
        }

        if (amount > s.amount) {
            revert InvalidAmount();
        }

        slashProposalCounter++;
        proposalId = slashProposalCounter;

        slashProposals[proposalId] = SlashProposal({
            robotId: robotId,
            amount: amount,
            reason: reason,
            proposer: msg.sender,
            createdAt: block.timestamp,
            votesFor: 0,
            votesAgainst: 0,
            executed: false,
            cancelled: false
        });

        emit SlashProposed(proposalId, robotId, amount, reason);
    }

    /**
     * @notice Vote on a slash proposal
     * @param proposalId The proposal ID
     * @param support Whether to support the slash
     */
    function voteOnSlash(uint256 proposalId, bool support) external {
        SlashProposal storage proposal = slashProposals[proposalId];
        if (proposal.createdAt == 0) {
            revert ProposalNotFound();
        }

        if (proposal.executed || proposal.cancelled) {
            revert ProposalAlreadyExecuted();
        }

        if (hasVoted[proposalId][msg.sender]) {
            revert AlreadyVoted();
        }

        hasVoted[proposalId][msg.sender] = true;

        if (support) {
            proposal.votesFor++;
        } else {
            proposal.votesAgainst++;
        }

        emit SlashVoted(proposalId, msg.sender, support);
    }

    /**
     * @notice Execute a slash proposal (after delay)
     * @param proposalId The proposal ID
     */
    function executeSlash(uint256 proposalId) external nonReentrant {
        SlashProposal storage proposal = slashProposals[proposalId];
        if (proposal.createdAt == 0) {
            revert ProposalNotFound();
        }

        if (proposal.executed || proposal.cancelled) {
            revert ProposalAlreadyExecuted();
        }

        if (block.timestamp < proposal.createdAt + slashProposalDelay) {
            revert ProposalDelayNotPassed();
        }

        // Simple majority required (can be made more sophisticated)
        require(proposal.votesFor > proposal.votesAgainst, "Proposal rejected");

        proposal.executed = true;

        Stake storage s = stakes[proposal.robotId];
        uint256 slashAmount = proposal.amount;
        if (slashAmount > s.amount) {
            slashAmount = s.amount;
        }

        s.amount -= slashAmount;
        s.slashedAmount += slashAmount;

        // Distribute slashed funds
        uint256 protocolAmount = (slashAmount * protocolFeePercent) / 10000;
        uint256 reporterAmount = (slashAmount * reporterRewardPercent) / 10000;
        uint256 remaining = slashAmount - protocolAmount - reporterAmount;

        stakeToken.safeTransfer(protocolTreasury, protocolAmount + remaining);
        stakeToken.safeTransfer(proposal.proposer, reporterAmount);

        robotIdContract.updateStakeAmount(proposal.robotId, s.amount);

        emit SlashExecuted(proposalId, proposal.robotId, slashAmount);
    }

    /**
     * @notice Cancel a slash proposal (owner only for disputes)
     * @param proposalId The proposal ID
     */
    function cancelSlash(uint256 proposalId) external onlyOwner {
        SlashProposal storage proposal = slashProposals[proposalId];
        if (proposal.createdAt == 0) {
            revert ProposalNotFound();
        }

        if (proposal.executed) {
            revert ProposalAlreadyExecuted();
        }

        proposal.cancelled = true;
        emit SlashCancelled(proposalId);
    }

    // ============ View Functions ============

    function getStake(uint256 robotId) external view returns (Stake memory) {
        return stakes[robotId];
    }

    function getSlashProposal(uint256 proposalId) external view returns (SlashProposal memory) {
        return slashProposals[proposalId];
    }

    function canUnstake(uint256 robotId) external view returns (bool) {
        Stake memory s = stakes[robotId];
        return s.exists && block.timestamp >= s.lockedUntil;
    }

    // ============ Admin Functions ============

    function setRobotIdContract(address _robotIdContract) external onlyOwner {
        robotIdContract = IRobotID(_robotIdContract);
    }

    function setMinStakeAmount(uint256 _minStakeAmount) external onlyOwner {
        minStakeAmount = _minStakeAmount;
    }

    function setLockPeriod(uint256 _lockPeriod) external onlyOwner {
        lockPeriod = _lockPeriod;
    }

    function setSlashProposalDelay(uint256 _delay) external onlyOwner {
        slashProposalDelay = _delay;
    }

    function setFeeRecipients(address _treasury, address _reporterPool) external onlyOwner {
        protocolTreasury = _treasury;
        reporterRewardPool = _reporterPool;
    }

    function setFeePercentages(uint256 _protocolPercent, uint256 _reporterPercent) external onlyOwner {
        require(_protocolPercent + _reporterPercent <= 10000, "Exceeds 100%");
        protocolFeePercent = _protocolPercent;
        reporterRewardPercent = _reporterPercent;
    }
}
