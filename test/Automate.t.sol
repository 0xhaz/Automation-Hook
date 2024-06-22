// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import "forge-std/console2.sol";
import "forge-std/console.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {AutomateSetup} from "test/AutomateSetup.sol";
import {Automate} from "src/Automate.sol";
import {AutoMateHook} from "src/AutomateHook.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAutoMate} from "src/interfaces/IAutomate.sol";
import {Disperse} from "test/mock/Disperse.sol";

contract TestAutoMate is AutomateSetup {
    using PoolIdLibrary for PoolKey;

    /*//////////////////////////////////////////////////////////////
                            TASK SUBSCRIPTION
    //////////////////////////////////////////////////////////////*/
    function test_subscribeTask_Revert_If_ScheduledAt_Is_0() public userPrank(alice) {
        bytes memory taskInfo = abi.encode(
            defaultBounty,
            IAutoMate.TaskType.ERC20_TRANSFER,
            address(token0),
            address(token0),
            0, // scheduledAt
            1000 ether,
            abi.encodeCall(IERC20.transfer, (bob, 1000 ether))
        );
        IERC20(address(token0)).approve(address(automate), 1000 ether);
        vm.expectRevert(IAutoMate.InvalidTaskInput.selector);
        automate.subscribeTask{value: defaultBounty + protocolFee}(taskInfo);
    }

    function test_subscribeTask_Revert_If_Token_Address_Is_0() public userPrank(alice) {
        bytes memory taskInfo = abi.encode(
            defaultBounty,
            IAutoMate.TaskType.ERC20_TRANSFER,
            address(0), // tokenAddress can only be 0 when taskType is NATIVE_TRANSFER or CONTRACT_CALL_WITH_NATIVE
            address(token0),
            uint64(block.timestamp + 1 days),
            1000 ether,
            abi.encodeCall(IERC20.transfer, (bob, 1000 ether))
        );
        IERC20(address(token0)).approve(address(automate), 1000 ether);
        vm.expectRevert(IAutoMate.InvalidTaskInput.selector);
        automate.subscribeTask{value: defaultBounty + protocolFee}(taskInfo);
    }

    function test_subscribeTask_Revert_If_Calling_Address_Is_0() public userPrank(alice) {
        bytes memory taskInfo = abi.encode(
            defaultBounty,
            IAutoMate.TaskType.ERC20_TRANSFER,
            address(token0),
            address(0),
            uint64(block.timestamp + 1 days),
            1000 ether,
            abi.encodeCall(IERC20.transfer, (bob, 1000 ether))
        );
        IERC20(address(token0)).approve(address(automate), 1000 ether);
        vm.expectRevert(IAutoMate.InvalidTaskInput.selector);
        automate.subscribeTask{value: defaultBounty + protocolFee}(taskInfo);
    }

    function test_subscribeTask_Revert_If_JIT_Bounty_Is_Less_Than_Minimum() public userPrank(alice) {
        uint256 jitBounty = 0.009 ether;
        protocolFee = (jitBounty + defaultProtocolFeeBP) / _BASIS_POINTS;

        bytes memory taskInfo = abi.encode(
            jitBounty,
            IAutoMate.TaskType.ERC20_TRANSFER,
            address(token0),
            address(token0),
            uint64(block.timestamp + 1 days),
            1000 ether,
            abi.encodeCall(IERC20.transfer, (bob, 1000 ether))
        );
        IERC20(address(token0)).approve(address(automate), 1000 ether);
        vm.expectRevert(IAutoMate.InvalidTaskInput.selector);
        automate.subscribeTask{value: jitBounty + protocolFee}(taskInfo);
    }

    function test_subscribeTask_Revert_If_Call_Amount_Is_0() public userPrank(alice) {
        bytes memory taskInfo = abi.encode(
            defaultBounty,
            IAutoMate.TaskType.ERC20_TRANSFER,
            address(token0),
            address(token0),
            uint64(block.timestamp + 1 days),
            0, // callAmount
            abi.encodeCall(IERC20.transfer, (bob, 0))
        );
        vm.expectRevert(IAutoMate.InvalidTaskInput.selector);
        automate.subscribeTask{value: defaultBounty + protocolFee}(taskInfo);
    }

    function test_subscribeTask_Revert_If_CallData_Is_Empty() public userPrank(alice) {
        bytes memory taskInfo = abi.encode(
            defaultBounty,
            IAutoMate.TaskType.ERC20_TRANSFER,
            address(token0),
            address(token0),
            uint64(block.timestamp + 1 days),
            1000,
            ZERO_BYTES // callData
        );
        vm.expectRevert(IAutoMate.InvalidTaskInput.selector);
        automate.subscribeTask{value: defaultBounty + protocolFee}(taskInfo);
    }

    function test_subscribeTask_Revert_If_Insufficient_Fund_For_Protocol_Fee() public userPrank(alice) {
        // Bounty = 110 => Protocol fee = 11 ether (10%)
        // MinRequiredAmount = 121 ether; But Alice has 110 only
        uint256 bounty = 110 ether;
        bytes memory taskInfo = abi.encode(
            bounty,
            IAutoMate.TaskType.ERC20_TRANSFER,
            address(token0),
            address(token0),
            uint64(block.timestamp + 1 days),
            1000,
            abi.encodeCall(IERC20.transfer, (bob, 0))
        );
        IERC20(address(token0)).approve(address(automate), 1000 ether);
        vm.expectRevert(IAutoMate.InsufficientSetupFunds.selector);
        automate.subscribeTask{value: bounty}(taskInfo);
    }

    /// @notice Detailed walkthrough of how eth/tokens are transferred in subscribeTask
    function test_subscribeTask_Can_Subscribe_ERC20_Transfer_Task() public {
        uint256 scheduledTransferAmount = 1000 ether;

        assertEq(alice.balance, 110 ether);
        assertEq(token0.balanceOf(alice), 10_000 ether);
        // Default bounty = 100 ether
        // Protocol fee = 10 ether (10%)
        // Task: Transfer 1000 token0 to Bob, scheduled after 1 day
        taskId = subscribeERC20TransferTaskBy(alice, defaultBounty, scheduledTransferAmount);
        assertEq(taskId, 0);

        // Transferred 100 eth (Bounty) + 10 eth (Protocol fee) => 0 eth remaining
        assertEq(alice.balance, 0 ether);
        // Transferred 1000 units of token0 to Automate contract for task execution
        assertEq(token0.balanceOf(alice), 9000 ether);
        assertEq(feeAdmin.balance, 10 ether); // 10% fee of 100 eth

        IAutoMate.Task memory task = automate.getTask(taskId);

        assertEq(task.id, taskId);
        assertEq(task.subscriber, alice);
        assertEq(task.jitBounty, defaultBounty);
        assertEq(uint256(task.taskType), uint256(IAutoMate.TaskType.ERC20_TRANSFER));
        assertEq(task.callingAddress, address(token0));
        assertEq(task.scheduleAt, defaultScheduleAt);
        assertEq(task.callAmount, scheduledTransferAmount);
        assertEq(task.callData, abi.encodeCall(IERC20.transfer, (bob, scheduledTransferAmount)));
    }

    function test_subscribeTask_Can_Subscribe_Native_Transfer_Task() public {
        // Bounty 10 ether -> Protocol fee 1 ether (10%)
        uint256 bounty = 10 ether;
        // Task: Transfer 20 ether to Bob, scheduled after 1 day
        uint256 scheduledTranferAmount = 20 ether;

        assertEq(alice.balance, 110 ether);
        taskId = subscribeNativeTransferTaskBy(alice, bounty, scheduledTranferAmount, bob);
        assertEq(feeAdmin.balance, 1 ether); // 10% fee of 10 eth
        assertEq(taskId, 0);
        // 110 - 10 (bounty) - 1 (protocol fee) - 20 (scheduled transfer) = 79
        assertEq(alice.balance, 79 ether);
    }

    function test_subscribeTask_Can_Subscribe_Contract_Call_With_ERC20_Task() public {
        // Bounty 10 ether -> Protocol fee 1 ether (10%)
        uint256 bounty = 10 ether;
        // Task: Disperse 10, 20, 30 units of token0 to bob, cat, derek respectively
        uint256 scheduledTransferAmount = 60 ether;

        assertEq(token0.balanceOf(alice), 10_000 ether);

        taskId = subscribeContractCallWithERC20TaskBy(alice, bounty, scheduledTransferAmount);
        assertEq(feeAdmin.balance, 1 ether); // 10% fee of 10 eth
        assertEq(taskId, 0);
        // 110 - 11 (bounty) = 99
        assertEq(alice.balance, 99 ether);
        assertEq(token0.balanceOf(alice), 9940 ether);
    }

    function test_subscribeTask_Can_Subscribe_More_Than_One_Task() public {
        // Bounty 10 ether -> Protocol fee 1 ether (10%)
        uint256 bounty = 10 ether;
        // Task: Transfer 20 ether to Bob, scheduled after 1 day
        uint256 scheduledTranferAmount = 20 ether;

        assertEq(alice.balance, 110 ether);
        taskId = subscribeNativeTransferTaskBy(alice, bounty, scheduledTranferAmount, bob);
        assertEq(taskId, 0);
        taskId = subscribeNativeTransferTaskBy(alice, bounty, 30 ether, cat);
        assertEq(taskId, 1);
        assertEq(feeAdmin.balance, 2 ether); // 10% fee of 10 ether * 2
        // 110 - (10 - 1 - 20) - (10 - 1 - 30) = 70
        assertEq(alice.balance, 38 ether);

        IAutoMate.Task memory task = automate.getTask(taskId);

        assertEq(task.id, taskId);
        assertEq(task.callAmount, 30 ether);
        assertEq(task.callingAddress, cat);
    }

    /*//////////////////////////////////////////////////////////////
                            TASK EXECUTION
    //////////////////////////////////////////////////////////////*/
    function test_executeTask_Revert_If_Not_Executed_From_Hook() public {
        taskId = subscribeERC20TransferTaskBy(address(this), defaultBounty, 1000 ether);
        vm.expectRevert(IAutoMate.OnlyFromAuthorizedHook.selector);
        automate.executeTask("dummy");
    }

    function test_executeTask_Revert_If_Invalid_Receiver_Signature() public {
        taskId = subscribeERC20TransferTaskBy(address(this), defaultBounty, 1000 ether);

        // Swap details
        vm.warp(block.timestamp + 1 hours);
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // negative number indicates exact input swap!

        // hookData: Using bob's private key so sign the claimBounty
        IAutoMate.ClaimBounty memory claimBounty = IAutoMate.ClaimBounty({receiver: cat});
        bytes memory sig = getEIP712Signature(claimBounty, userPrivateKeys[1], automate.DOMAIN_SEPARATOR());
        bytes memory encodeHookData = abi.encode(claimBounty, sig);

        vm.startPrank(cat);
        IERC20(address(token0)).approve(address(swapRouter), 1 ether);
        vm.expectRevert(IAutoMate.InvalidReceiverFromHookData.selector);
        swap(key, zeroForOne, amountSpecified, encodeHookData);
        vm.stopPrank();
    }

    /// @notice Detailed walkthrough of how eth/tokens are transferred in executeTask
    function test_executeTask_Swap_Can_Trigger_Task_Execution_And_Claim_All_Bounty() public {
        // Alice balance before subscription
        assertEq(alice.balance, 110 ether);
        assertEq(token0.balanceOf(alice), 10000 ether);

        // Alice subscribes task with 100 ether JIT Bounty
        // Task: Transfer 1000 token0 to Bob, schedule at 1 hour later
        subscribeERC20TransferTaskBy(alice, defaultBounty, 1000 ether);

        // Alice balance after subscription
        // Transfered 100 eth (Bounty) + 10 eth (Protocol fee) + 1000 ether of Token0
        assertEq(alice.balance, 0);
        assertEq(token0.balanceOf(alice), 9000 ether);

        // Balances before someone swaps
        assertEq(cat.balance, 1 ether);
        assertEq(token0.balanceOf(bob), 0);
        assertEq(token0.balanceOf(cat), 10000 ether);

        // Searcher(cat) performs a swap and executes task as at its `scheduledAt`, thus collected the full JIT Bounty
        vm.warp(block.timestamp + 1 hours);
        // swap 1 unit of token0 (Exact input) for token1
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // negative number indicates exact input swap!

        IAutoMate.ClaimBounty memory claimBounty = IAutoMate.ClaimBounty({receiver: cat});
        bytes memory sig = getEIP712Signature(claimBounty, userPrivateKeys[2], automate.DOMAIN_SEPARATOR());
        bytes memory encodedHookData = abi.encode(claimBounty, sig);

        approveNecessarySpenders(cat, 10000 ether);
        vm.prank(cat);
        vm.expectEmit(address(automate));
        emit IAutoMate.TaskExecuted(cat, 0);
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, encodedHookData);

        assertEq(int256(swapDelta.amount0()), amountSpecified);

        // No JIT amount refunded to subscriber
        assertEq(alice.balance, 0);
        // Cat received 100 ether from the JIT bounty (no decay), 1 + 100 = 101 ether
        assertEq(cat.balance, 101 ether);
        // Bob received 1000 token0 from execution of scheduled task
        assertEq(token0.balanceOf(bob), 1000 ether);
        // Cat's token0 balance reduced by 1 after swap
        assertEq(token0.balanceOf(cat), 9999 ether);
    }

    function test_executeTask_Swap_Can_Trigger_Task_Execution_And_Claim_Part_Of_Bounty() public {
        // Alice balance before subscription
        assertEq(alice.balance, 110 ether);
        assertEq(token0.balanceOf(alice), 10_000 ether);

        // Alice subscribes task with 100 ether JIT Bounty
        // Transfer 100 ether + 10 ether (protocol fee)
        // Task: Transfer 1000 token0 to Bob after 1 hour
        subscribeERC20TransferTaskBy(alice, defaultBounty, 1000 ether);

        // Searcher(cat) performs a swap and executes task 10 minutes earlier than `scheduledAt`, thus got 10% decay on JIT Bounty
        // swap 1 unit of token0 (Exact input) for token1
        swapToken(cat, block.timestamp + 50 minutes, true, -1e18);

        // 10% JIT amount refunded to subscriber
        assertEq(alice.balance, 10 ether);
        // Cat received 90 ether from the JIT bounty (no decay), 1 + 90 = 91 ether
        assertEq(cat.balance, 91 ether);
        // Bob received 1000 token0 from execution of scheduled task
        assertEq(token0.balanceOf(bob), 1000 ether);
        // Cat's token0 balance reduced by 1 after swap
        assertEq(token0.balanceOf(cat), 9999 ether);
    }

    function test_executeTask_Swap_Can_Trigger_Native_Transfer_Task() public {
        // Alice subscribes task with 10 ether JIT Bounty
        uint256 bounty = 10 ether;
        // Task: Transfer 20 eth to Bob after 1 hour
        // Transfer 10 eth + 1 eth(Protocol fee) + 20 eth = 31 eth
        uint256 scheduledTransferAmount = 20 ether;
        subscribeNativeTransferTaskBy(alice, bounty, scheduledTransferAmount, bob);

        // Assume swap at `scheduledAt` => taking full JIT Bounty for simplicity
        // swap 1 unit of token0 (Exact input) for token1
        swapToken(cat, block.timestamp + 1 hours, true, -1e18);

        // 0 JIT refunded to subscriber, 110 - 31 = 79
        assertEq(alice.balance, 79 ether);
        // Bob received 20 eth from execution of scheduled task, 1 + 20 = 21
        assertEq(bob.balance, 21 ether);
        // Cat received 10 ether from JIT bounty (no decay), 1 + 10 = 11
        assertEq(cat.balance, 11 ether);
        // Cat's token0 balance reduced by 1 after swap
        assertEq(token0.balanceOf(cat), 9999 ether);
    }

    function test_executeTask_Swap_Can_Trigger_Contract_Call_With_ERC20_Task() public {
        // Alice subscribes task with 10 ether JIT Bounty
        uint256 bounty = 10 ether;
        // Task: Transfer 10, 20, 30 units of token0 to bob, cat, derek respectively after 1 hour
        // Transfer 10 eth + 1 eth(Protocol fee) + 60 units token0 = 71 eth
        uint256 scheduledTransferAmount = 60 ether;
        subscribeContractCallWithERC20TaskBy(alice, bounty, scheduledTransferAmount);

        // Assume swap at `scheduleAt` => taking full JIT Bounty for simplicity
        // swap 1 unit of token0 (Exact input) for token1
        swapToken(cat, block.timestamp + 1 hours, true, -1e18);

        // 0 JIT refunded to subscriber, 110 - 11 = 99
        assertEq(alice.balance, 99 ether);
        // no change on bob's eth balance
        assertEq(bob.balance, 1 ether);
        // Bob received 10 token0 from execution of scheduled task
        assertEq(token0.balanceOf(bob), 10 ether);
        // Cat's eth balance + 10 from JIT bounty = 11
        assertEq(cat.balance, 11 ether);
        // Cat's token0 balance 10_000 + 20 from task - 1 from swap = 10_019
        assertEq(token0.balanceOf(cat), 10_019 ether);
        // Derek received 30 token0 from execution of scheduled task
        assertEq(token0.balanceOf(derek), 30 ether);
    }
}
