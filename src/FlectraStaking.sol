// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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

    function updateStakeAmount(uint256 tokenId, uint256 newAmount) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function isVerified(uint256 tokenId) external view returns (bool);
}

/**
 * @title FlectraStaking
 * @author Flectra Protocol
 * @notice Stake management for robot operators with slashing mechanism
 * @dev Operators stake USDC collateral when operating robots. Stakes serve as economic
 *      security and can be slashed for protocol violations.
 *
 * Key features:
 * - Stake locking with configurable time period
 * - Slashing through governance proposals
 * - Timelocked slash execution for dispute resolution
 * - Configurable fee distribution (protocol, reporter, burn)
 *
 * Security considerations:
 * - ReentrancyGuard on all external state-changing functions
 * - Pausable for emergency scenarios
 * - 2-step ownership transfer
 * - Minimum stake thresholds enforced
 */
contract FlectraStaking is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Maximum basis points (100%)
    uint256 public constant MAX_BPS = 10_000;

    /// @notice Minimum slash proposal delay (1 hour)
    uint256 public constant MIN_SLASH_DELAY = 1 hours;

    /// @notice Maximum slash proposal delay (7 days)
    uint256 public constant MAX_SLASH_DELAY = 7 days;

    /// @notice Minimum lock period (1 day)
    uint256 public constant MIN_LOCK_PERIOD = 1 days;

    /// @notice Maximum lock period (365 days)
    uint256 public constant MAX_LOCK_PERIOD = 365 days;

    // ============ Immutables ============

    /// @notice The ERC20 token used for staking (USDC on Base)
    IERC20 public immutable STAKE_TOKEN;

    // ============ Structs ============

    /// @notice Stake data for a robot
    /// @param amount Current staked amount
    /// @param lockedUntil Timestamp when stake can be withdrawn
    /// @param slashedTotal Total amount ever slashed from this stake
    /// @param lastStakeTime Timestamp of last stake/increase operation
    struct Stake {
        uint256 amount;
        uint256 lockedUntil;
        uint256 slashedTotal;
        uint256 lastStakeTime;
    }

    /// @notice Slash proposal data
    /// @param robotId Target robot's token ID
    /// @param amount Amount to slash
    /// @param reason Human-readable reason for slashing
    /// @param proposer Address that created the proposal
    /// @param createdAt Timestamp when proposal was created
    /// @param executeAfter Earliest timestamp for execution
    /// @param executed Whether proposal has been executed
    /// @param cancelled Whether proposal has been cancelled
    struct SlashProposal {
        uint256 robotId;
        uint256 amount;
        string reason;
        address proposer;
        uint256 createdAt;
        uint256 executeAfter;
        bool executed;
        bool cancelled;
    }

    // ============ State Variables ============

    /// @notice RobotID contract reference
    IRobotID public robotIdContract;

    /// @notice Minimum stake amount required
    uint256 public minStakeAmount;

    /// @notice Time period stake must be locked after deposit
    uint256 public lockPeriod;

    /// @notice Delay before slash proposal can be executed
    uint256 public slashProposalDelay;

    /// @notice Counter for slash proposals
    uint256 public slashProposalCounter;

    /// @notice Protocol treasury address (receives slashed funds)
    address public protocolTreasury;

    /// @notice Protocol's share of slashed funds (in basis points)
    uint256 public protocolFeeBps;

    /// @notice Reporter's share of slashed funds (in basis points)
    uint256 public reporterRewardBps;

    /// @notice Addresses authorized to propose slashing
    mapping(address slasher => bool authorized) public authorizedSlashers;

    /// @notice Stakes by robot ID
    mapping(uint256 robotId => Stake stake) private _stakes;

    /// @notice Slash proposals by proposal ID
    mapping(uint256 proposalId => SlashProposal proposal) private _slashProposals;

    // ============ Events ============

    /// @notice Emitted when tokens are staked
    event Staked(
        uint256 indexed robotId,
        address indexed operator,
        uint256 amount,
        uint256 totalStake,
        uint256 lockedUntil
    );

    /// @notice Emitted when stake is increased
    event StakeIncreased(
        uint256 indexed robotId,
        address indexed operator,
        uint256 addedAmount,
        uint256 totalStake
    );

    /// @notice Emitted when tokens are unstaked
    event Unstaked(
        uint256 indexed robotId,
        address indexed operator,
        uint256 amount,
        uint256 remainingStake
    );

    /// @notice Emitted when a slash proposal is created
    event SlashProposed(
        uint256 indexed proposalId,
        uint256 indexed robotId,
        address indexed proposer,
        uint256 amount,
        string reason,
        uint256 executeAfter
    );

    /// @notice Emitted when a slash is executed
    event SlashExecuted(
        uint256 indexed proposalId,
        uint256 indexed robotId,
        uint256 amount,
        uint256 protocolAmount,
        uint256 reporterAmount
    );

    /// @notice Emitted when a slash proposal is cancelled
    event SlashCancelled(uint256 indexed proposalId, address indexed canceller);

    /// @notice Emitted when an authorized slasher is added/removed
    event SlasherAuthorizationChanged(address indexed slasher, bool authorized);

    /// @notice Emitted when configuration is updated
    event ConfigUpdated(string indexed param, uint256 oldValue, uint256 newValue);

    /// @notice Emitted when treasury address is updated
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    // ============ Errors ============

    /// @notice Stake amount is below minimum
    error InsufficientStake();

    /// @notice Cannot unstake during lock period
    error StakeLocked();

    /// @notice Caller is not the robot operator
    error NotOperator();

    /// @notice No stake exists for this robot
    error StakeNotFound();

    /// @notice Slash proposal not found
    error ProposalNotFound();

    /// @notice Proposal already executed or cancelled
    error ProposalFinalized();

    /// @notice Timelock not yet passed
    error TimelockNotPassed();

    /// @notice Amount exceeds available stake
    error AmountExceedsStake();

    /// @notice Invalid parameter value
    error InvalidParameter();

    /// @notice Zero address not allowed
    error ZeroAddress();

    /// @notice Caller not authorized to slash
    error NotAuthorizedSlasher();

    /// @notice Robot does not exist
    error RobotNotFound();

    /// @notice Fee configuration exceeds 100%
    error FeesExceedMax();

    // ============ Modifiers ============

    /// @notice Ensures caller is authorized to propose slashes
    modifier onlySlasher() {
        if (!authorizedSlashers[msg.sender] && msg.sender != owner()) {
            revert NotAuthorizedSlasher();
        }
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Initialize the staking contract
     * @param _stakeToken Address of the ERC20 token for staking (USDC)
     * @param _minStakeAmount Minimum stake required
     * @param _lockPeriod Lock period duration
     * @param _protocolTreasury Treasury address for slashed funds
     */
    constructor(
        address _stakeToken,
        uint256 _minStakeAmount,
        uint256 _lockPeriod,
        address _protocolTreasury
    ) Ownable(msg.sender) {
        if (_stakeToken == address(0)) revert ZeroAddress();
        if (_protocolTreasury == address(0)) revert ZeroAddress();
        if (_lockPeriod < MIN_LOCK_PERIOD || _lockPeriod > MAX_LOCK_PERIOD) {
            revert InvalidParameter();
        }

        STAKE_TOKEN = IERC20(_stakeToken);
        minStakeAmount = _minStakeAmount;
        lockPeriod = _lockPeriod;
        slashProposalDelay = 24 hours;
        protocolTreasury = _protocolTreasury;
        protocolFeeBps = 5000; // 50%
        reporterRewardBps = 3000; // 30%
        // Remaining 20% is burned (sent to dead address)
    }

    // ============ External Functions ============

    /**
     * @notice Stake tokens for a robot
     * @dev Creates new stake or adds to existing. Caller must be robot owner.
     * @param robotId The robot's token ID
     * @param amount Amount to stake
     */
    function stake(uint256 robotId, uint256 amount)
        external
        whenNotPaused
        nonReentrant
    {
        if (amount == 0) revert InvalidParameter();

        // Verify robot exists and caller owns it
        address robotOwner = _getRobotOwner(robotId);
        if (robotOwner != msg.sender) revert NotOperator();

        Stake storage s = _stakes[robotId];
        uint256 newTotal = s.amount + amount;

        // New stakes must meet minimum
        if (s.amount == 0 && newTotal < minStakeAmount) {
            revert InsufficientStake();
        }

        // Transfer tokens
        STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);

        // Update stake
        uint256 newLockTime = block.timestamp + lockPeriod;
        s.amount = newTotal;
        s.lockedUntil = newLockTime;
        s.lastStakeTime = block.timestamp;

        // Sync with RobotID contract
        robotIdContract.updateStakeAmount(robotId, newTotal);

        emit Staked(robotId, msg.sender, amount, newTotal, newLockTime);
    }

    /**
     * @notice Increase stake for a robot
     * @dev Resets lock period. Caller must be robot owner.
     * @param robotId The robot's token ID
     * @param amount Additional amount to stake
     */
    function increaseStake(uint256 robotId, uint256 amount)
        external
        whenNotPaused
        nonReentrant
    {
        if (amount == 0) revert InvalidParameter();

        Stake storage s = _stakes[robotId];
        if (s.amount == 0) revert StakeNotFound();

        address robotOwner = _getRobotOwner(robotId);
        if (robotOwner != msg.sender) revert NotOperator();

        STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);

        uint256 newTotal = s.amount + amount;
        s.amount = newTotal;
        s.lockedUntil = block.timestamp + lockPeriod;
        s.lastStakeTime = block.timestamp;

        robotIdContract.updateStakeAmount(robotId, newTotal);

        emit StakeIncreased(robotId, msg.sender, amount, newTotal);
    }

    /**
     * @notice Withdraw staked tokens (after lock period)
     * @dev Remaining stake must be >= minStakeAmount or zero
     * @param robotId The robot's token ID
     * @param amount Amount to withdraw
     */
    function unstake(uint256 robotId, uint256 amount)
        external
        whenNotPaused
        nonReentrant
    {
        if (amount == 0) revert InvalidParameter();

        Stake storage s = _stakes[robotId];
        if (s.amount == 0) revert StakeNotFound();

        address robotOwner = _getRobotOwner(robotId);
        if (robotOwner != msg.sender) revert NotOperator();

        if (block.timestamp < s.lockedUntil) revert StakeLocked();
        if (amount > s.amount) revert AmountExceedsStake();

        uint256 remaining = s.amount - amount;

        // Must unstake completely or keep minimum
        if (remaining > 0 && remaining < minStakeAmount) {
            revert InsufficientStake();
        }

        s.amount = remaining;

        STAKE_TOKEN.safeTransfer(msg.sender, amount);
        robotIdContract.updateStakeAmount(robotId, remaining);

        emit Unstaked(robotId, msg.sender, amount, remaining);
    }

    /**
     * @notice Propose slashing a robot's stake
     * @dev Only authorized slashers can propose. Creates timelock.
     * @param robotId The robot's token ID
     * @param amount Amount to slash
     * @param reason Human-readable justification
     * @return proposalId The created proposal's ID
     */
    function proposeSlash(
        uint256 robotId,
        uint256 amount,
        string calldata reason
    ) external onlySlasher whenNotPaused returns (uint256 proposalId) {
        Stake storage s = _stakes[robotId];
        if (s.amount == 0) revert StakeNotFound();
        if (amount == 0 || amount > s.amount) revert InvalidParameter();
        if (bytes(reason).length == 0) revert InvalidParameter();

        unchecked {
            proposalId = ++slashProposalCounter;
        }

        uint256 executeAfter = block.timestamp + slashProposalDelay;

        _slashProposals[proposalId] = SlashProposal({
            robotId: robotId,
            amount: amount,
            reason: reason,
            proposer: msg.sender,
            createdAt: block.timestamp,
            executeAfter: executeAfter,
            executed: false,
            cancelled: false
        });

        emit SlashProposed(proposalId, robotId, msg.sender, amount, reason, executeAfter);
    }

    /**
     * @notice Execute a slash proposal after timelock
     * @dev Anyone can execute after timelock passes
     * @param proposalId The proposal ID to execute
     */
    function executeSlash(uint256 proposalId) external nonReentrant {
        SlashProposal storage proposal = _slashProposals[proposalId];

        if (proposal.createdAt == 0) revert ProposalNotFound();
        if (proposal.executed || proposal.cancelled) revert ProposalFinalized();
        if (block.timestamp < proposal.executeAfter) revert TimelockNotPassed();

        proposal.executed = true;

        Stake storage s = _stakes[proposal.robotId];
        uint256 slashAmount = proposal.amount;

        // Cap to available stake
        if (slashAmount > s.amount) {
            slashAmount = s.amount;
        }

        s.amount -= slashAmount;
        s.slashedTotal += slashAmount;

        // Calculate distribution
        uint256 protocolAmount = (slashAmount * protocolFeeBps) / MAX_BPS;
        uint256 reporterAmount = (slashAmount * reporterRewardBps) / MAX_BPS;
        uint256 burnAmount = slashAmount - protocolAmount - reporterAmount;

        // Distribute slashed funds
        if (protocolAmount > 0) {
            STAKE_TOKEN.safeTransfer(protocolTreasury, protocolAmount);
        }
        if (reporterAmount > 0) {
            STAKE_TOKEN.safeTransfer(proposal.proposer, reporterAmount);
        }
        if (burnAmount > 0) {
            // Send to dead address (effective burn for USDC)
            STAKE_TOKEN.safeTransfer(address(0xdead), burnAmount);
        }

        robotIdContract.updateStakeAmount(proposal.robotId, s.amount);

        emit SlashExecuted(
            proposalId,
            proposal.robotId,
            slashAmount,
            protocolAmount,
            reporterAmount
        );
    }

    /**
     * @notice Cancel a slash proposal (owner only, for disputes)
     * @param proposalId The proposal ID to cancel
     */
    function cancelSlash(uint256 proposalId) external onlyOwner {
        SlashProposal storage proposal = _slashProposals[proposalId];

        if (proposal.createdAt == 0) revert ProposalNotFound();
        if (proposal.executed || proposal.cancelled) revert ProposalFinalized();

        proposal.cancelled = true;

        emit SlashCancelled(proposalId, msg.sender);
    }

    // ============ View Functions ============

    /**
     * @notice Get stake data for a robot
     * @param robotId The robot's token ID
     * @return Stake struct
     */
    function getStake(uint256 robotId) external view returns (Stake memory) {
        return _stakes[robotId];
    }

    /**
     * @notice Get slash proposal data
     * @param proposalId The proposal ID
     * @return SlashProposal struct
     */
    function getSlashProposal(uint256 proposalId) external view returns (SlashProposal memory) {
        return _slashProposals[proposalId];
    }

    /**
     * @notice Check if stake can be withdrawn
     * @param robotId The robot's token ID
     * @return canWithdraw True if unlocked and has balance
     * @return availableAt Timestamp when available (0 if already available)
     */
    function canUnstake(uint256 robotId)
        external
        view
        returns (bool canWithdraw, uint256 availableAt)
    {
        Stake memory s = _stakes[robotId];
        if (s.amount == 0) {
            return (false, 0);
        }
        if (block.timestamp >= s.lockedUntil) {
            return (true, 0);
        }
        return (false, s.lockedUntil);
    }

    /**
     * @notice Get effective stake after pending slashes
     * @dev Useful for checking if robot will remain verified after pending slashes
     * @param robotId The robot's token ID
     * @return Current stake amount
     */
    function getEffectiveStake(uint256 robotId) external view returns (uint256) {
        return _stakes[robotId].amount;
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the RobotID contract address
     * @param _robotIdContract New RobotID contract address
     */
    function setRobotIdContract(address _robotIdContract) external onlyOwner {
        if (_robotIdContract == address(0)) revert ZeroAddress();
        robotIdContract = IRobotID(_robotIdContract);
    }

    /**
     * @notice Update minimum stake amount
     * @param _minStakeAmount New minimum
     */
    function setMinStakeAmount(uint256 _minStakeAmount) external onlyOwner {
        uint256 oldValue = minStakeAmount;
        minStakeAmount = _minStakeAmount;
        emit ConfigUpdated("minStakeAmount", oldValue, _minStakeAmount);
    }

    /**
     * @notice Update lock period
     * @param _lockPeriod New lock period
     */
    function setLockPeriod(uint256 _lockPeriod) external onlyOwner {
        if (_lockPeriod < MIN_LOCK_PERIOD || _lockPeriod > MAX_LOCK_PERIOD) {
            revert InvalidParameter();
        }
        uint256 oldValue = lockPeriod;
        lockPeriod = _lockPeriod;
        emit ConfigUpdated("lockPeriod", oldValue, _lockPeriod);
    }

    /**
     * @notice Update slash proposal delay
     * @param _delay New delay in seconds
     */
    function setSlashProposalDelay(uint256 _delay) external onlyOwner {
        if (_delay < MIN_SLASH_DELAY || _delay > MAX_SLASH_DELAY) {
            revert InvalidParameter();
        }
        uint256 oldValue = slashProposalDelay;
        slashProposalDelay = _delay;
        emit ConfigUpdated("slashProposalDelay", oldValue, _delay);
    }

    /**
     * @notice Update protocol treasury address
     * @param _treasury New treasury address
     */
    function setProtocolTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        address oldTreasury = protocolTreasury;
        protocolTreasury = _treasury;
        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    /**
     * @notice Update fee percentages
     * @param _protocolBps Protocol fee in basis points
     * @param _reporterBps Reporter reward in basis points
     */
    function setFeePercentages(uint256 _protocolBps, uint256 _reporterBps)
        external
        onlyOwner
    {
        if (_protocolBps + _reporterBps > MAX_BPS) revert FeesExceedMax();

        uint256 oldProtocol = protocolFeeBps;
        uint256 oldReporter = reporterRewardBps;
        protocolFeeBps = _protocolBps;
        reporterRewardBps = _reporterBps;

        emit ConfigUpdated("protocolFeeBps", oldProtocol, _protocolBps);
        emit ConfigUpdated("reporterRewardBps", oldReporter, _reporterBps);
    }

    /**
     * @notice Add or remove authorized slasher
     * @param slasher Address to authorize/deauthorize
     * @param authorized Whether to authorize
     */
    function setAuthorizedSlasher(address slasher, bool authorized)
        external
        onlyOwner
    {
        if (slasher == address(0)) revert ZeroAddress();
        authorizedSlashers[slasher] = authorized;
        emit SlasherAuthorizationChanged(slasher, authorized);
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
     * @notice Get robot owner with existence check
     * @param robotId The robot's token ID
     * @return owner The robot owner address
     */
    function _getRobotOwner(uint256 robotId) internal view returns (address owner) {
        try robotIdContract.ownerOf(robotId) returns (address _owner) {
            if (_owner == address(0)) revert RobotNotFound();
            return _owner;
        } catch {
            revert RobotNotFound();
        }
    }
}
