// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StreamManager} from "../src/StreamManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {StreamHandler} from "./StreamHandler.sol";

/// @notice Funds-conservation invariants over a bounded fuzz campaign of
///         create/withdraw/cancel/warp across many concurrent streams.
contract StreamManagerInvariant is Test {
    StreamManager internal mgr;
    MockERC20 internal token;
    StreamHandler internal handler;

    address internal owner = address(0xA11CE);
    address internal feeRecipient = address(0xFEE);

    function setUp() public {
        token = new MockERC20("Token", "TKN", 18);
        mgr = new StreamManager(owner, feeRecipient, 300); // 3% fee exercises fee accounting
        handler = new StreamHandler(mgr, token);
        targetContract(address(handler));
    }

    /// @dev Per stream: deposited == withdrawn + remaining + returnedToSender + feeAtCreation.
    ///      Contract balance always covers the sum of outstanding obligations, and every
    ///      fee ever taken has been delivered to the fee recipient — funds are never
    ///      created or lost.
    function invariant_FundsConserved() public view {
        uint256 n = handler.streamCount();
        uint256 sumRemaining;

        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.streamIds(i);
            StreamManager.Stream memory s = mgr.getStream(id);

            uint256 received = handler.gReceived(id);
            uint256 fee = handler.gFee(id);
            uint256 remaining = uint256(s.deposit) - s.withdrawn - s.refunded;

            // principal recorded == received - fee
            assertEq(uint256(s.deposit), received - fee, "deposit != received - fee");
            // conservation identity for the stream
            assertEq(received, uint256(s.withdrawn) + remaining + uint256(s.refunded) + fee, "stream not conserved");
            // nothing over-drawn
            assertLe(uint256(s.withdrawn) + uint256(s.refunded), uint256(s.deposit), "over-drawn");

            sumRemaining += remaining;
        }

        // The contract holds at least what it still owes across all streams.
        assertGe(token.balanceOf(address(mgr)), sumRemaining, "balance below obligations");
        // With a non-fee token, held balance equals outstanding obligations exactly.
        assertEq(token.balanceOf(address(mgr)), sumRemaining, "balance != obligations");
        // Every protocol fee taken has reached the fee recipient.
        assertEq(token.balanceOf(feeRecipient), handler.gTotalFees(), "fees not fully delivered");
    }
}
