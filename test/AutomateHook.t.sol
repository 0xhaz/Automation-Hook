// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {AutomateSetup} from "test/AutomateSetup.sol";
import {Automate} from "src/Automate.sol";

import {IAutoMate} from "src/interfaces/IAutomate.sol";

contract TestAutomateHook is AutomateSetup {
    function test_Swap_Without_Execute_Task_With_Empty_Hook_Data() public {
        // Subscribed task will not be executed
        subscribeERC20TransferTaskBy(alice, defaultBounty, defaultTransferAmount);

        vm.warp(block.timestamp + 50 minutes);
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // negative value means exact input swap

        vm.startPrank(cat);
        IERC20(address(token0)).approve(address(swapRouter), defaultTransferAmount);
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        vm.stopPrank();

        // No JIT amount refunded to subscriber
        assertEq(alice.balance, 0);
        // Cat didn't receive bounty , remaining is 1 ether
        assertEq(cat.balance, 1 ether);
        // Bob didn't receive 1000 token0 from scheduled task
        assertEq(token0.balanceOf(bob), 0);
        // Cat's token0 balance reduced by 1 after swap
        assertEq(token0.balanceOf(cat), 9_999 ether);
    }

    function test_Swap_Swap_Normally_When_Empty_Tasks() public {
        swapToken(cat, block.timestamp + 50 minutes, true, -1e18);

        // Didn't execute any task, all user data remain same
        assertEq(alice.balance, 110 ether);
        assertEq(cat.balance, 1 ether);
        assertEq(token0.balanceOf(bob), 0);
        // Cat's toke0 balance reduced by 1 after swap
        assertEq(token0.balanceOf(cat), 9_999 ether);
    }

    function test_Swap_And_Execute_Task_Demo() public {
        uint256 beforeSubETHBalanceAlice = alice.balance;
        uint256 beforeSubTokenBalanceAlice = token0.balanceOf(alice);
        console2.log("### BEFORE SUBSCRIPTION ###");
        console2.log("eth balanceOf(alice): ", _normalize(beforeSubETHBalanceAlice));
        console2.log("token0 balanceOf(alice): ", _normalize(beforeSubTokenBalanceAlice));

        subscribeERC20TransferTaskBy(alice, defaultBounty, defaultTransferAmount);

        uint256 afterSubETHBalanceAlice = alice.balance;
        uint256 afterSubTokenBalanceAlice = token0.balanceOf(alice);
        console2.log("### AFTER SUBSCRIPTION ###");
        console2.log("eth balanceOf(alice): ", _normalize(afterSubETHBalanceAlice));
        console2.log("token0 balanceOf(alice): ", _normalize(afterSubTokenBalanceAlice));
        console2.log("### ------------------ ###");

        assertEq(beforeSubETHBalanceAlice - afterSubETHBalanceAlice, defaultBounty + protocolFee);
        assertEq(beforeSubTokenBalanceAlice - afterSubTokenBalanceAlice, defaultTransferAmount);

        uint256 beforeSwapETHBalanceAlice = alice.balance;
        uint256 beforeSwapETHBalanceCat = cat.balance;
        uint256 beforeSwapTokenBlanceBob = token0.balanceOf(bob);

        console2.log("### BEFORE SWAP ###");
        console2.log("eth balanceOf(alice): ", _normalize(beforeSwapETHBalanceAlice));
        console2.log("eth balanceOf(cat): ", _normalize(beforeSwapETHBalanceCat));
        console2.log("token0 balanceOf(bob): ", _normalize(beforeSwapTokenBlanceBob));
        console2.log("### ------------------ ###");

        // Searcher(Cat) performs a swap and executes task 1 min earlier, results in 1% bounty decay
        vm.warp(block.timestamp + 59 minutes);
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // negative value means exact input swap

        IAutoMate.ClaimBounty memory claimBounty = IAutoMate.ClaimBounty({receiver: address(cat)});
        bytes memory sig = getEIP712Signature(claimBounty, userPrivateKeys[2], automate.DOMAIN_SEPARATOR());
        bytes memory encodedHookData = abi.encode(claimBounty, sig);

        vm.startPrank(cat);
        IERC20(address(token0)).approve(address(swapRouter), defaultTransferAmount);
        vm.expectEmit(address(automate));
        emit IAutoMate.TaskExecuted(cat, 0);
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, encodedHookData);
        vm.stopPrank();

        assertEq(int256(swapDelta.amount0()), amountSpecified);

        uint256 afterSwapETHBalanceAlice = alice.balance;
        uint256 afterSwapETHBalanceCat = cat.balance;
        uint256 afterSwapTokenBalanceBob = token0.balanceOf(bob);

        console2.log("### AFTER SWAP ###");
        console2.log("eth balanceOf(alice): ", _normalize(afterSwapETHBalanceAlice));
        console2.log("eth balanceOf(cat): ", _normalize(afterSwapETHBalanceCat));
        console2.log("token0 balanceOf(bob): ", _normalize(afterSwapTokenBalanceBob));
        console2.log("### ------------------ ###");

        (uint256 remainingBountyAmount, uint256 decayAmount) = calculateRemainingBountyByMin(1);
        assertEq(afterSwapETHBalanceAlice - beforeSwapETHBalanceAlice, decayAmount);
        assertEq(afterSwapETHBalanceCat - beforeSwapETHBalanceCat, remainingBountyAmount);
        assertEq(afterSwapTokenBalanceBob - beforeSwapTokenBlanceBob, defaultTransferAmount);
    }
}
