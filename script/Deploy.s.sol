// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {StreamManager} from "../src/StreamManager.sol";

/// @notice Deploys StreamManager with owner/feeRecipient/feeBps taken from the environment.
/// @dev Configure via env vars (see DEPLOY.md):
///        OWNER          - protocol owner (fee configuration only; cannot touch stream funds)
///        FEE_RECIPIENT  - receives the creation fee skimmed at stream creation
///        FEE_BPS        - initial protocol fee in basis points, <= MAX_FEE_BPS (1000 = 10%)
///      Streams themselves are created after deploy via createStream(...); this script only
///      deploys the contract.
contract DeployScript is Script {
    function run() external returns (StreamManager streamManager) {
        address owner = vm.envAddress("OWNER");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 feeBps = vm.envUint("FEE_BPS");

        vm.startBroadcast();
        streamManager = new StreamManager(owner, feeRecipient, feeBps);
        vm.stopBroadcast();

        console2.log("StreamManager deployed at:", address(streamManager));
        console2.log("  owner:        ", owner);
        console2.log("  feeRecipient: ", feeRecipient);
        console2.log("  feeBps:       ", feeBps);
    }
}
