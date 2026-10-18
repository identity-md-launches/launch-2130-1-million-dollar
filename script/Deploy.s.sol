// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {OneMillionDollarToken} from "../src/OneMillionDollarToken.sol";

/// @title Deploy 1MD
/// @notice Reviewable deployment helper. The IdentityMD launch deploys the token itself through the
///         factory, so this script is not part of the launch; it exists so a reviewer or a local
///         operator can reproduce a deployment and so the test suite can exercise the deploy path.
/// @dev The token takes no constructor arguments, so there is nothing to configure. `deploy()` is
///      the pure deployment step the tests call directly; `run()` only wraps it in a broadcast.
///      Nothing here reads environment variables.
contract DeployOneMillionDollarToken is Script {
    /// @notice Deploys the token. Whoever calls this receives the entire supply.
    function deploy() public returns (OneMillionDollarToken token) {
        token = new OneMillionDollarToken();
    }

    /// @notice Broadcast entry point for `forge script`. The broadcasting account becomes the deployer
    ///         and therefore the initial holder of the whole supply.
    function run() external returns (OneMillionDollarToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
