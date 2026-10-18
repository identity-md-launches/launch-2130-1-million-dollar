// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OneMillionDollarToken} from "../src/OneMillionDollarToken.sol";

/// @notice Edge cases of the allowance and transfer paths not covered by the main suite.
contract OneMillionDollarTokenEdgesTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 ether;

    OneMillionDollarToken internal token;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);

    function setUp() public {
        token = new OneMillionDollarToken();
        token.transfer(ALICE, 1000 ether);
    }

    function test_RevertWhen_transferFromToZeroAddress_allowanceUntouched() public {
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(ALICE, address(0), 1 ether);
        assertEq(token.allowance(ALICE, BOB), 10 ether, "a failed spend consumed allowance");
        assertEq(token.balanceOf(ALICE), 1000 ether);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_RevertWhen_transferFromTheZeroAddress() public {
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(address(0), BOB, 1);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_RevertWhen_ownerSpendsOwnTokensWithoutSelfAllowance() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_RevertWhen_allowanceSpentTwice() public {
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        vm.startPrank(BOB);
        token.transferFrom(ALICE, CAROL, 10 ether);
        assertEq(token.allowance(ALICE, BOB), 0, "exact spend leaves nothing");
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, CAROL, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(CAROL), 10 ether);
    }

    function test_allowanceJustBelowMaxIsDecremented() public {
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max - 1);
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 1);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max - 2, "a finite allowance must be decremented");
    }

    function test_zeroAmountTransferFromWithoutAllowanceSucceeds() public {
        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, CAROL, 0));
        assertEq(token.balanceOf(ALICE), 1000 ether);
        assertEq(token.allowance(ALICE, BOB), 0);
    }

    function test_approvalsAreIndependentPerSpender() public {
        vm.startPrank(ALICE);
        token.approve(BOB, 5 ether);
        token.approve(CAROL, 7 ether);
        vm.stopPrank();
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 5 ether);
        assertEq(token.allowance(ALICE, BOB), 0);
        assertEq(token.allowance(ALICE, CAROL), 7 ether, "spending one allowance touched another");
        assertEq(token.allowance(BOB, ALICE), 0, "allowances are directional");
    }

    function test_RevertWhen_callingWithUnknownSelector() public {
        (bool ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok, "the token has a fallback");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveSetsExactly(address spender, uint256 amount) public {
        spender = address(uint160(bound(uint160(spender), 1, type(uint160).max)));
        vm.prank(ALICE);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(ALICE, spender), amount);
        assertEq(token.balanceOf(ALICE), 1000 ether, "approve moved tokens");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_selfTransferNeverChangesBalance(uint256 amount) public {
        amount = bound(amount, 0, 1000 ether);
        vm.prank(ALICE);
        token.transfer(ALICE, amount);
        assertEq(token.balanceOf(ALICE), 1000 ether);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromAtTheEdgesOfBalanceAndAllowance(uint256 balance, uint256 allowed, uint256 spend)
        public
    {
        balance = bound(balance, 0, EXPECTED_SUPPLY - 1000 ether);
        allowed = bound(allowed, 0, type(uint256).max - 1);
        spend = bound(spend, 0, EXPECTED_SUPPLY);
        token.transfer(BOB, balance);
        vm.prank(BOB);
        token.approve(CAROL, allowed);

        vm.prank(CAROL);
        if (spend > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, CAROL, allowed, spend)
            );
            token.transferFrom(BOB, ALICE, spend);
        } else if (spend > balance) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, balance, spend));
            token.transferFrom(BOB, ALICE, spend);
        } else {
            assertTrue(token.transferFrom(BOB, ALICE, spend));
            assertEq(token.balanceOf(BOB), balance - spend);
            assertEq(token.balanceOf(ALICE), 1000 ether + spend);
            assertEq(token.allowance(BOB, CAROL), allowed - spend);
            return;
        }
        assertEq(token.balanceOf(BOB), balance, "a failed spend moved tokens");
        assertEq(token.allowance(BOB, CAROL), allowed, "a failed spend consumed allowance");
    }
}
