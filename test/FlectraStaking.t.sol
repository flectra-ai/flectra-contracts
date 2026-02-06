// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {FlectraStaking} from "../src/FlectraStaking.sol";
import {MockUSDC} from "../script/Deploy.s.sol";

contract MockRobotID {
    mapping(uint256 => address) public owners;
    mapping(uint256 => uint256) public stakeAmounts;

    function setOwner(uint256 tokenId, address owner) external {
        owners[tokenId] = owner;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return owners[tokenId];
    }

    function updateStakeAmount(uint256 tokenId, uint256 amount) external {
        stakeAmounts[tokenId] = amount;
    }

    function isVerified(uint256 tokenId) external view returns (bool) {
        return owners[tokenId] != address(0);
    }
}

contract FlectraStakingTest is Test {
    FlectraStaking public staking;
    MockUSDC public usdc;
    MockRobotID public robotId;

    address public owner;
    address public operator;
    address public attacker;
    address public treasury;
    address public slasher;

    uint256 public constant MIN_STAKE = 100 * 1e6;
    uint256 public constant LOCK_PERIOD = 7 days;
    uint256 public constant ROBOT_ID = 1;

    event Staked(uint256 indexed robotId, address indexed operator, uint256 amount, uint256 totalStake, uint256 lockedUntil);
    event Unstaked(uint256 indexed robotId, address indexed operator, uint256 amount, uint256 remainingStake);
    event SlashProposed(uint256 indexed proposalId, uint256 indexed robotId, address indexed proposer, uint256 amount, string reason, uint256 executeAfter);
    event SlashExecuted(uint256 indexed proposalId, uint256 indexed robotId, uint256 amount, uint256 protocolAmount, uint256 reporterAmount);
    event SlashCancelled(uint256 indexed proposalId, address indexed canceller);

    function setUp() public {
        owner = address(this);
        operator = makeAddr("operator");
        attacker = makeAddr("attacker");
        treasury = makeAddr("treasury");
        slasher = makeAddr("slasher");

        usdc = new MockUSDC();
        robotId = new MockRobotID();

        staking = new FlectraStaking(
            address(usdc),
            MIN_STAKE,
            LOCK_PERIOD,
            treasury
        );

        staking.setRobotIdContract(address(robotId));
        staking.setAuthorizedSlasher(slasher, true);

        // Setup robot ownership
        robotId.setOwner(ROBOT_ID, operator);

        // Fund operator with USDC
        usdc.mint(operator, 1000 * 1e6);

        vm.prank(operator);
        usdc.approve(address(staking), type(uint256).max);
    }

    // ============ Deployment Tests ============

    function test_Deployment() public view {
        assertEq(address(staking.STAKE_TOKEN()), address(usdc));
        assertEq(staking.minStakeAmount(), MIN_STAKE);
        assertEq(staking.lockPeriod(), LOCK_PERIOD);
        assertEq(staking.protocolTreasury(), treasury);
        assertEq(staking.protocolFeeBps(), 5000);
        assertEq(staking.reporterRewardBps(), 3000);
    }

    function test_Constants() public view {
        assertEq(staking.MAX_BPS(), 10_000);
        assertEq(staking.MIN_SLASH_DELAY(), 1 hours);
        assertEq(staking.MAX_SLASH_DELAY(), 7 days);
        assertEq(staking.MIN_LOCK_PERIOD(), 1 days);
        assertEq(staking.MAX_LOCK_PERIOD(), 365 days);
    }

    // ============ Stake Tests ============

    function test_Stake() public {
        uint256 amount = MIN_STAKE;

        vm.prank(operator);
        staking.stake(ROBOT_ID, amount);

        FlectraStaking.Stake memory s = staking.getStake(ROBOT_ID);
        assertEq(s.amount, amount);
        assertEq(s.lockedUntil, block.timestamp + LOCK_PERIOD);
        assertEq(s.slashedTotal, 0);
        assertEq(usdc.balanceOf(address(staking)), amount);
    }

    function test_Stake_EmitsEvent() public {
        uint256 amount = MIN_STAKE;

        vm.expectEmit(true, true, false, true);
        emit Staked(ROBOT_ID, operator, amount, amount, block.timestamp + LOCK_PERIOD);

        vm.prank(operator);
        staking.stake(ROBOT_ID, amount);
    }

    function test_Stake_UpdatesRobotStake() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        assertEq(robotId.stakeAmounts(ROBOT_ID), MIN_STAKE);
    }

    function test_Stake_RevertIfNotOperator() public {
        vm.prank(attacker);
        vm.expectRevert(FlectraStaking.NotOperator.selector);
        staking.stake(ROBOT_ID, MIN_STAKE);
    }

    function test_Stake_RevertIfBelowMinimum() public {
        vm.prank(operator);
        vm.expectRevert(FlectraStaking.InsufficientStake.selector);
        staking.stake(ROBOT_ID, MIN_STAKE - 1);
    }

    function test_Stake_RevertIfZeroAmount() public {
        vm.prank(operator);
        vm.expectRevert(FlectraStaking.InvalidParameter.selector);
        staking.stake(ROBOT_ID, 0);
    }

    function test_Stake_RevertIfRobotNotFound() public {
        vm.prank(operator);
        vm.expectRevert(FlectraStaking.RobotNotFound.selector);
        staking.stake(999, MIN_STAKE); // Non-existent robot
    }

    // ============ Increase Stake Tests ============

    function test_IncreaseStake() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        uint256 additionalAmount = 50 * 1e6;

        vm.prank(operator);
        staking.increaseStake(ROBOT_ID, additionalAmount);

        FlectraStaking.Stake memory s = staking.getStake(ROBOT_ID);
        assertEq(s.amount, MIN_STAKE + additionalAmount);
    }

    function test_IncreaseStake_ResetsLock() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        vm.warp(block.timestamp + 3 days);

        vm.prank(operator);
        staking.increaseStake(ROBOT_ID, 50 * 1e6);

        FlectraStaking.Stake memory s = staking.getStake(ROBOT_ID);
        assertEq(s.lockedUntil, block.timestamp + LOCK_PERIOD);
    }

    function test_IncreaseStake_RevertIfNoExistingStake() public {
        vm.prank(operator);
        vm.expectRevert(FlectraStaking.StakeNotFound.selector);
        staking.increaseStake(ROBOT_ID, 50 * 1e6);
    }

    // ============ Unstake Tests ============

    function test_Unstake() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        // Warp past lock period
        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        uint256 balanceBefore = usdc.balanceOf(operator);

        vm.prank(operator);
        staking.unstake(ROBOT_ID, MIN_STAKE);

        assertEq(usdc.balanceOf(operator), balanceBefore + MIN_STAKE);
        assertEq(staking.getStake(ROBOT_ID).amount, 0);
    }

    function test_Unstake_Partial() public {
        uint256 initialStake = 200 * 1e6;

        vm.prank(operator);
        staking.stake(ROBOT_ID, initialStake);

        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        vm.prank(operator);
        staking.unstake(ROBOT_ID, 50 * 1e6);

        assertEq(staking.getStake(ROBOT_ID).amount, 150 * 1e6);
    }

    function test_Unstake_RevertIfLocked() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        vm.prank(operator);
        vm.expectRevert(FlectraStaking.StakeLocked.selector);
        staking.unstake(ROBOT_ID, MIN_STAKE);
    }

    function test_Unstake_RevertIfPartialBelowMin() public {
        uint256 initialStake = 150 * 1e6;

        vm.prank(operator);
        staking.stake(ROBOT_ID, initialStake);

        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        // Try to unstake leaving less than minimum
        vm.prank(operator);
        vm.expectRevert(FlectraStaking.InsufficientStake.selector);
        staking.unstake(ROBOT_ID, 60 * 1e6); // Would leave 90 USDC
    }

    function test_Unstake_RevertIfExceedsAmount() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        vm.prank(operator);
        vm.expectRevert(FlectraStaking.AmountExceedsStake.selector);
        staking.unstake(ROBOT_ID, MIN_STAKE + 1);
    }

    // ============ Slash Proposal Tests ============

    function test_ProposeSlash() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        vm.prank(slasher);
        uint256 proposalId = staking.proposeSlash(ROBOT_ID, 50 * 1e6, "Malicious behavior");

        FlectraStaking.SlashProposal memory p = staking.getSlashProposal(proposalId);
        assertEq(p.robotId, ROBOT_ID);
        assertEq(p.amount, 50 * 1e6);
        assertEq(p.proposer, slasher);
        assertFalse(p.executed);
        assertFalse(p.cancelled);
    }

    function test_ProposeSlash_ByOwner() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        // Owner can also propose
        uint256 proposalId = staking.proposeSlash(ROBOT_ID, 50 * 1e6, "Owner slash");
        assertEq(staking.getSlashProposal(proposalId).proposer, owner);
    }

    function test_ProposeSlash_RevertIfNotAuthorized() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        vm.prank(attacker);
        vm.expectRevert(FlectraStaking.NotAuthorizedSlasher.selector);
        staking.proposeSlash(ROBOT_ID, 50 * 1e6, "Unauthorized");
    }

    function test_ProposeSlash_RevertIfNoStake() public {
        vm.prank(slasher);
        vm.expectRevert(FlectraStaking.StakeNotFound.selector);
        staking.proposeSlash(ROBOT_ID, 50 * 1e6, "No stake");
    }

    function test_ProposeSlash_RevertIfExceedsStake() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        vm.prank(slasher);
        vm.expectRevert(FlectraStaking.InvalidParameter.selector);
        staking.proposeSlash(ROBOT_ID, MIN_STAKE + 1, "Too much");
    }

    function test_ProposeSlash_RevertIfEmptyReason() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        vm.prank(slasher);
        vm.expectRevert(FlectraStaking.InvalidParameter.selector);
        staking.proposeSlash(ROBOT_ID, 50 * 1e6, "");
    }

    // ============ Execute Slash Tests ============

    function test_ExecuteSlash() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        vm.prank(slasher);
        uint256 proposalId = staking.proposeSlash(ROBOT_ID, 50 * 1e6, "Bad robot");

        // Warp past delay
        vm.warp(block.timestamp + 24 hours + 1);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 slasherBefore = usdc.balanceOf(slasher);

        staking.executeSlash(proposalId);

        // Check distribution: 50% protocol, 30% reporter, 20% burned
        uint256 slashAmount = 50 * 1e6;
        uint256 protocolAmount = (slashAmount * 5000) / 10000; // 25 USDC
        uint256 reporterAmount = (slashAmount * 3000) / 10000; // 15 USDC

        assertEq(usdc.balanceOf(treasury), treasuryBefore + protocolAmount);
        assertEq(usdc.balanceOf(slasher), slasherBefore + reporterAmount);

        // Check stake reduced
        assertEq(staking.getStake(ROBOT_ID).amount, MIN_STAKE - slashAmount);
        assertTrue(staking.getSlashProposal(proposalId).executed);
    }

    function test_ExecuteSlash_RevertIfTimelockNotPassed() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        vm.prank(slasher);
        uint256 proposalId = staking.proposeSlash(ROBOT_ID, 50 * 1e6, "Bad robot");

        vm.expectRevert(FlectraStaking.TimelockNotPassed.selector);
        staking.executeSlash(proposalId);
    }

    function test_ExecuteSlash_RevertIfAlreadyExecuted() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        vm.prank(slasher);
        uint256 proposalId = staking.proposeSlash(ROBOT_ID, 50 * 1e6, "Bad robot");

        vm.warp(block.timestamp + 24 hours + 1);
        staking.executeSlash(proposalId);

        vm.expectRevert(FlectraStaking.ProposalFinalized.selector);
        staking.executeSlash(proposalId);
    }

    // ============ Cancel Slash Tests ============

    function test_CancelSlash() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        vm.prank(slasher);
        uint256 proposalId = staking.proposeSlash(ROBOT_ID, 50 * 1e6, "Bad robot");

        staking.cancelSlash(proposalId);

        assertTrue(staking.getSlashProposal(proposalId).cancelled);
    }

    function test_CancelSlash_RevertIfNotOwner() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        vm.prank(slasher);
        uint256 proposalId = staking.proposeSlash(ROBOT_ID, 50 * 1e6, "Bad robot");

        vm.prank(attacker);
        vm.expectRevert();
        staking.cancelSlash(proposalId);
    }

    function test_CancelSlash_PreventExecution() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        vm.prank(slasher);
        uint256 proposalId = staking.proposeSlash(ROBOT_ID, 50 * 1e6, "Bad robot");

        staking.cancelSlash(proposalId);

        vm.warp(block.timestamp + 24 hours + 1);

        vm.expectRevert(FlectraStaking.ProposalFinalized.selector);
        staking.executeSlash(proposalId);
    }

    // ============ View Function Tests ============

    function test_CanUnstake() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        (bool canWithdraw, uint256 availableAt) = staking.canUnstake(ROBOT_ID);
        assertFalse(canWithdraw);
        assertEq(availableAt, block.timestamp + LOCK_PERIOD);

        vm.warp(block.timestamp + LOCK_PERIOD);

        (canWithdraw, availableAt) = staking.canUnstake(ROBOT_ID);
        assertTrue(canWithdraw);
        assertEq(availableAt, 0);
    }

    function test_GetEffectiveStake() public {
        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        assertEq(staking.getEffectiveStake(ROBOT_ID), MIN_STAKE);
    }

    // ============ Admin Tests ============

    function test_SetMinStakeAmount() public {
        uint256 newMin = 200 * 1e6;
        staking.setMinStakeAmount(newMin);
        assertEq(staking.minStakeAmount(), newMin);
    }

    function test_SetLockPeriod() public {
        uint256 newPeriod = 14 days;
        staking.setLockPeriod(newPeriod);
        assertEq(staking.lockPeriod(), newPeriod);
    }

    function test_SetLockPeriod_RevertIfTooShort() public {
        vm.expectRevert(FlectraStaking.InvalidParameter.selector);
        staking.setLockPeriod(12 hours);
    }

    function test_SetLockPeriod_RevertIfTooLong() public {
        vm.expectRevert(FlectraStaking.InvalidParameter.selector);
        staking.setLockPeriod(400 days);
    }

    function test_SetSlashProposalDelay() public {
        staking.setSlashProposalDelay(48 hours);
        assertEq(staking.slashProposalDelay(), 48 hours);
    }

    function test_SetFeePercentages() public {
        staking.setFeePercentages(6000, 2000);
        assertEq(staking.protocolFeeBps(), 6000);
        assertEq(staking.reporterRewardBps(), 2000);
    }

    function test_SetFeePercentages_RevertIfExceeds100() public {
        vm.expectRevert(FlectraStaking.FeesExceedMax.selector);
        staking.setFeePercentages(6000, 5000);
    }

    function test_SetAuthorizedSlasher() public {
        address newSlasher = makeAddr("newSlasher");

        staking.setAuthorizedSlasher(newSlasher, true);
        assertTrue(staking.authorizedSlashers(newSlasher));

        staking.setAuthorizedSlasher(newSlasher, false);
        assertFalse(staking.authorizedSlashers(newSlasher));
    }

    function test_Pause_Unpause() public {
        staking.pause();
        assertTrue(staking.paused());

        vm.prank(operator);
        vm.expectRevert();
        staking.stake(ROBOT_ID, MIN_STAKE);

        staking.unpause();
        assertFalse(staking.paused());
    }

    // ============ Fuzz Tests ============

    function testFuzz_Stake(uint256 amount) public {
        vm.assume(amount >= MIN_STAKE && amount <= 1000 * 1e6);

        usdc.mint(operator, amount);

        vm.prank(operator);
        staking.stake(ROBOT_ID, amount);

        assertEq(staking.getStake(ROBOT_ID).amount, amount);
    }

    function testFuzz_SlashAmount(uint256 slashAmount) public {
        vm.assume(slashAmount > 0 && slashAmount <= MIN_STAKE);

        vm.prank(operator);
        staking.stake(ROBOT_ID, MIN_STAKE);

        vm.prank(slasher);
        uint256 proposalId = staking.proposeSlash(ROBOT_ID, slashAmount, "Test slash");

        vm.warp(block.timestamp + 24 hours + 1);
        staking.executeSlash(proposalId);

        assertEq(staking.getStake(ROBOT_ID).amount, MIN_STAKE - slashAmount);
    }
}
