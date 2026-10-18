// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OneMillionDollarToken} from "../src/OneMillionDollarToken.sol";

/// @notice Drives the token with random sequences of transfers, approvals and spends between a fixed
///         set of actors, including calls that must fail. It keeps an independent model of every
///         balance and allowance, updated only from the ERC-20 rules, never from the token's answers.
contract TokenHandler is Test {
    OneMillionDollarToken public immutable token;
    address[] public actors;

    mapping(address => uint256) public modelBalance;
    mapping(address => mapping(address => uint256)) public modelAllowance;

    uint256 public calls;
    uint256 public successfulMoves;
    uint256 public expectedFailures;
    /// @dev Counts anything that contradicts the ERC-20 rules: a failing call that succeeded, a
    ///      succeeding call that failed or returned false, or a move that arrived short or long.
    uint256 public violations;

    constructor(OneMillionDollarToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
        // actors[0] deployed the token and holds the whole supply.
        modelBalance[actors_[0]] = token_.totalSupply();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        calls++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, modelBalance[from]);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            if (!ok) violations++;
        } catch {
            violations++;
            return;
        }
        if (from != to) {
            modelBalance[from] -= amount;
            modelBalance[to] += amount;
            if (token.balanceOf(to) != toBefore + amount) violations++;
        }
        successfulMoves++;
    }

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 extra) external {
        calls++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = modelBalance[from];
        extra = bound(extra, 1, type(uint256).max - balance);

        vm.prank(from);
        try token.transfer(to, balance + extra) {
            violations++;
        } catch (bytes memory reason) {
            if (
                keccak256(reason)
                    != keccak256(
                        abi.encodeWithSelector(
                            IERC20Errors.ERC20InsufficientBalance.selector, from, balance, balance + extra
                        )
                    )
            ) violations++;
        }
        expectedFailures++;
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        calls++;
        address from = _actor(fromSeed);
        amount = bound(amount, 0, modelBalance[from]);
        vm.prank(from);
        try token.transfer(address(0), amount) {
            violations++;
        } catch {}
        expectedFailures++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        calls++;
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (infinite) amount = type(uint256).max;

        vm.prank(owner);
        try token.approve(spender, amount) returns (bool ok) {
            if (!ok) violations++;
            modelAllowance[owner][spender] = amount;
        } catch {
            violations++;
        }
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        calls++;
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = modelAllowance[owner][spender];
        uint256 cap = allowed < modelBalance[owner] ? allowed : modelBalance[owner];
        amount = bound(amount, 0, cap);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            if (!ok) violations++;
        } catch {
            violations++;
            return;
        }
        if (allowed != type(uint256).max) modelAllowance[owner][spender] = allowed - amount;
        if (owner != to) {
            modelBalance[owner] -= amount;
            modelBalance[to] += amount;
            if (token.balanceOf(to) != toBefore + amount) violations++;
        }
        successfulMoves++;
    }

    function transferFromBeyondAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 extra)
        external
    {
        calls++;
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = modelAllowance[owner][spender];
        if (allowed == type(uint256).max) return; // an infinite allowance cannot be exceeded
        extra = bound(extra, 1, type(uint256).max - allowed);

        vm.prank(spender);
        try token.transferFrom(owner, to, allowed + extra) {
            violations++;
        } catch (bytes memory reason) {
            if (
                keccak256(reason)
                    != keccak256(
                        abi.encodeWithSelector(
                            IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, allowed + extra
                        )
                    )
            ) violations++;
        }
        expectedFailures++;
    }

    function transferFromBeyondBalance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 extra) external {
        calls++;
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 balance = modelBalance[owner];
        extra = bound(extra, 1, 1_000_000 ether);
        uint256 amount = balance + extra;
        // Give the spender enough allowance so that only the balance can be the reason to fail.
        vm.prank(owner);
        token.approve(spender, amount);
        modelAllowance[owner][spender] = amount;

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            violations++;
        } catch (bytes memory reason) {
            if (
                keccak256(reason)
                    != keccak256(
                        abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
                    )
            ) violations++;
        }
        expectedFailures++;
    }

    /// @dev A stranger with no allowance tries to pull from an actor.
    function strangerPulls(uint256 ownerSeed, uint256 amount) external {
        calls++;
        address owner = _actor(ownerSeed);
        address stranger = address(0xBAD);
        amount = bound(amount, 1, type(uint256).max);
        vm.prank(stranger);
        try token.transferFrom(owner, stranger, amount) {
            violations++;
        } catch {}
        expectedFailures++;
    }
}

/// @notice Invariants of a fixed-supply ERC-20 over random call sequences.
contract OneMillionDollarTokenInvariantTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 ether;

    OneMillionDollarToken internal token;
    TokenHandler internal handler;
    address[] internal actors;

    function setUp() public {
        actors.push(address(0xDE9107)); // the deployer, holding the whole supply
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA401));
        actors.push(address(0xD157));

        vm.prank(actors[0]);
        token = new OneMillionDollarToken();
        handler = new TokenHandler(token, actors);

        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyNeverChanges() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "the supply changed");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_actorsHoldTheWholeSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply(), "balances do not add up to the supply");
        assertEq(token.balanceOf(address(0)), 0, "something reached the zero address");
        assertEq(token.balanceOf(address(token)), 0, "the token holds its own supply");
        assertEq(token.balanceOf(address(0xBAD)), 0, "a stranger got tokens");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesMatchTheModel() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            assertEq(token.balanceOf(actors[i]), handler.modelBalance(actors[i]), "balance differs from the model");
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allowancesMatchTheModel() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            for (uint256 j = 0; j < actors.length; j++) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.modelAllowance(actors[i], actors[j]),
                    "allowance differs from the model"
                );
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_noCallBrokeTheErc20Rules() public view {
        assertEq(handler.violations(), 0, "a call broke the ERC-20 rules");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_metadataNeverChanges() public view {
        assertEq(token.name(), "1 Million Dollar");
        assertEq(token.symbol(), "1MD");
        assertEq(uint256(token.decimals()), 18);
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    /// @dev Guards against a vacuous suite: the handler must actually be reachable and move tokens.
    function test_handlerMovesTokens() public {
        handler.transfer(0, 1, 500 ether);
        handler.approve(1, 2, 100 ether, false);
        handler.transferFrom(2, 1, 3, 40 ether);
        handler.transferTooMuch(3, 4, 1);
        handler.transferFromBeyondAllowance(2, 1, 4, 1);
        handler.transferFromBeyondBalance(4, 3, 0, 1);
        handler.strangerPulls(0, 1);
        handler.transferToZero(0, 1);
        assertEq(handler.violations(), 0);
        assertEq(handler.successfulMoves(), 2);
        assertEq(token.balanceOf(actors[3]), 40 ether);
        assertEq(token.allowance(actors[1], actors[2]), 60 ether);
        assertEq(token.balanceOf(actors[1]), handler.modelBalance(actors[1]));
    }
}
