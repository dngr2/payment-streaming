// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StreamManager} from "../src/StreamManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {FeeOnTransferERC20} from "./mocks/FeeOnTransferERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract StreamManagerTest is Test {
    StreamManager internal mgr;
    MockERC20 internal token;

    address internal owner = address(0xA11CE);
    address internal feeRecipient = address(0xFEE);
    address internal sender = address(0x5E11D);
    address internal recipient = address(0xB0B);
    address internal stranger = address(0xDEAD);

    // Absolute time origin; all warps are vm.warp(T0 + n) to dodge via_ir CSE on block.timestamp.
    uint40 internal constant T0 = 1_000_000;
    uint40 internal constant START = T0;
    uint40 internal constant END = T0 + 1000;

    uint256 internal constant AMT = 1000e18;

    function setUp() public {
        vm.warp(T0);
        token = new MockERC20("Token", "TKN", 18);
        mgr = new StreamManager(owner, feeRecipient, 0); // feeBps = 0 for exact arithmetic
        token.mint(sender, 1_000_000e18);
        vm.prank(sender);
        token.approve(address(mgr), type(uint256).max);
    }

    // --------------------------------------------------------------------- //
    // helpers
    // --------------------------------------------------------------------- //

    function _create(uint40 cliff, bool cancelable) internal returns (uint256 id) {
        vm.prank(sender);
        id = mgr.createStream(recipient, address(token), AMT, START, cliff, END, cancelable);
    }

    // --------------------------------------------------------------------- //
    // streamed / withdrawable math
    // --------------------------------------------------------------------- //

    function test_NothingBeforeStart() public {
        uint256 id = _create(0, true);
        vm.warp(uint256(START) - 1);
        assertEq(mgr.streamedAmount(id), 0);
        assertEq(mgr.withdrawableAmount(id), 0);
        assertEq(uint256(mgr.statusOf(id)), uint256(StreamManager.Status.Pending));
    }

    function test_NothingBeforeCliff() public {
        uint40 cliff = T0 + 100;
        uint256 id = _create(cliff, true);
        vm.warp(uint256(T0) + 50);
        assertEq(mgr.streamedAmount(id), 0);
        assertEq(mgr.withdrawableAmount(id), 0);
    }

    function test_LinearAtCliffEdge() public {
        uint40 cliff = T0 + 100;
        uint256 id = _create(cliff, true);
        // exactly at the cliff the release jumps to the linear-from-start value
        vm.warp(uint256(T0) + 100);
        // 1000e18 * 100 / 1000 = 100e18
        assertEq(mgr.streamedAmount(id), 100e18);
    }

    function test_LinearMidpoints() public {
        uint256 id = _create(0, true);

        vm.warp(uint256(T0) + 250);
        assertEq(mgr.streamedAmount(id), 250e18); // 1000e18 * 250 / 1000

        vm.warp(uint256(T0) + 500);
        assertEq(mgr.streamedAmount(id), 500e18);

        vm.warp(uint256(T0) + 750);
        assertEq(mgr.streamedAmount(id), 750e18);

        vm.warp(uint256(T0) + 999);
        assertEq(mgr.streamedAmount(id), 999e18);
    }

    function test_FullAfterEnd() public {
        uint256 id = _create(0, true);
        vm.warp(uint256(END));
        assertEq(mgr.streamedAmount(id), AMT);
        vm.warp(uint256(END) + 100_000);
        assertEq(mgr.streamedAmount(id), AMT);
        assertEq(uint256(mgr.statusOf(id)), uint256(StreamManager.Status.Settled));
    }

    // --------------------------------------------------------------------- //
    // withdraw
    // --------------------------------------------------------------------- //

    function test_WithdrawPartialThenMax() public {
        uint256 id = _create(0, true);

        vm.warp(uint256(T0) + 400); // streamed = 400e18
        vm.prank(recipient);
        mgr.withdraw(id, 150e18);
        assertEq(token.balanceOf(recipient), 150e18);
        assertEq(mgr.withdrawableAmount(id), 250e18);

        vm.warp(uint256(T0) + 600); // streamed = 600e18
        vm.prank(recipient);
        uint256 got = mgr.withdrawMax(id);
        assertEq(got, 450e18); // 600e18 - 150e18 already out
        assertEq(token.balanceOf(recipient), 600e18);
        assertEq(mgr.withdrawableAmount(id), 0);
    }

    function test_WithdrawFullAfterEndDepletes() public {
        uint256 id = _create(0, true);
        vm.warp(uint256(END));
        vm.prank(recipient);
        mgr.withdrawMax(id);
        assertEq(token.balanceOf(recipient), AMT);
        assertEq(uint256(mgr.statusOf(id)), uint256(StreamManager.Status.Depleted));
    }

    function test_OverWithdrawReverts() public {
        uint256 id = _create(0, true);
        vm.warp(uint256(T0) + 300); // withdrawable = 300e18
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.Overdraw.selector, id, 300e18 + 1, 300e18));
        mgr.withdraw(id, 300e18 + 1);
    }

    function test_OnlyRecipientOrApprovedWithdraws() public {
        uint256 id = _create(0, true);
        vm.warp(uint256(T0) + 300);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.Unauthorized.selector, id, stranger));
        mgr.withdraw(id, 100e18);

        // approve stranger
        vm.prank(recipient);
        mgr.approveWithdrawer(id, stranger);
        vm.prank(stranger);
        mgr.withdraw(id, 100e18);
        // funds still go to the recipient, not the caller
        assertEq(token.balanceOf(recipient), 100e18);
        assertEq(token.balanceOf(stranger), 0);
    }

    function test_WithdrawZeroReverts() public {
        uint256 id = _create(0, true);
        vm.warp(uint256(T0) + 300);
        vm.prank(recipient);
        vm.expectRevert(StreamManager.ZeroAmount.selector);
        mgr.withdraw(id, 0);
    }

    // --------------------------------------------------------------------- //
    // cancel
    // --------------------------------------------------------------------- //

    function test_CancelMidStreamSplitsExactly() public {
        uint256 id = _create(0, true);

        vm.warp(uint256(T0) + 300); // streamed = 300e18
        vm.prank(recipient);
        mgr.withdraw(id, 100e18); // recipient already took 100e18

        vm.warp(uint256(T0) + 400); // streamed = 400e18
        vm.prank(sender);
        mgr.cancel(id);

        // recipient: streamed(400) - withdrawn(100) = 300e18 paid now, plus the 100 already out
        assertEq(token.balanceOf(recipient), 400e18);
        // sender: deposit(1000) - streamed(400) = 600e18 refunded
        assertEq(token.balanceOf(sender), 1_000_000e18 - AMT + 600e18);

        assertEq(uint256(mgr.statusOf(id)), uint256(StreamManager.Status.Canceled));
        assertEq(mgr.remainingBalance(id), 0);
        assertEq(mgr.withdrawableAmount(id), 0);
    }

    function test_PostCancelNoFurtherWithdraw() public {
        uint256 id = _create(0, true);
        vm.warp(uint256(T0) + 400);
        vm.prank(sender);
        mgr.cancel(id);

        vm.warp(uint256(T0) + 900); // time marches on, but stream is frozen
        assertEq(mgr.streamedAmount(id), 400e18);
        assertEq(mgr.withdrawableAmount(id), 0);

        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.Overdraw.selector, id, 1, 0));
        mgr.withdraw(id, 1);
    }

    function test_CancelByRecipient() public {
        uint256 id = _create(0, true);
        vm.warp(uint256(T0) + 250);
        vm.prank(recipient);
        mgr.cancel(id);
        assertEq(token.balanceOf(recipient), 250e18);
        assertEq(token.balanceOf(sender), 1_000_000e18 - AMT + 750e18);
    }

    function test_CancelStrangerReverts() public {
        uint256 id = _create(0, true);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.Unauthorized.selector, id, stranger));
        mgr.cancel(id);
    }

    function test_NonCancelableReverts() public {
        uint256 id = _create(0, false);
        vm.warp(uint256(T0) + 400);
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.NotCancelable.selector, id));
        mgr.cancel(id);
    }

    function test_DoubleCancelReverts() public {
        uint256 id = _create(0, true);
        vm.warp(uint256(T0) + 400);
        vm.prank(sender);
        mgr.cancel(id);
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.AlreadyCanceled.selector, id));
        mgr.cancel(id);
    }

    function test_CancelBeforeStartRefundsAll() public {
        uint256 id = _create(0, true);
        vm.warp(uint256(START) - 1);
        vm.prank(sender);
        mgr.cancel(id);
        assertEq(token.balanceOf(sender), 1_000_000e18); // whole principal back
        assertEq(token.balanceOf(recipient), 0);
    }

    // --------------------------------------------------------------------- //
    // fee-on-transfer token
    // --------------------------------------------------------------------- //

    function test_FeeOnTransfer_PrincipalFromActualReceived() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20("FoT", "FOT", 100); // 1% burned per transfer
        fot.mint(sender, 1000e18);
        vm.prank(sender);
        fot.approve(address(mgr), type(uint256).max);

        vm.prank(sender);
        uint256 id = mgr.createStream(recipient, address(fot), 1000e18, START, 0, END, true);

        // 1% burned in transit => manager received 990e18, which becomes the principal.
        StreamManager.Stream memory s = mgr.getStream(id);
        assertEq(s.deposit, 990e18);
        assertEq(fot.balanceOf(address(mgr)), 990e18);
        assertEq(fot.balanceOf(sender), 0);

        // stream the full principal and confirm accounting is conserved (net of transfer burns)
        vm.warp(uint256(END));
        vm.prank(recipient);
        uint256 got = mgr.withdrawMax(id);
        assertEq(got, 990e18);
        // recipient gets 990e18 minus the 1% burned on the withdraw transfer
        assertEq(fot.balanceOf(recipient), 990e18 - 9.9e18);
        assertEq(fot.balanceOf(address(mgr)), 0); // contract fully drained for this stream
    }

    // --------------------------------------------------------------------- //
    // protocol fee at creation
    // --------------------------------------------------------------------- //

    function test_ProtocolFeeSkimmedAtCreation() public {
        vm.prank(owner);
        mgr.setFeeBps(250); // 2.5%

        vm.prank(sender);
        uint256 id = mgr.createStream(recipient, address(token), AMT, START, 0, END, true);

        // fee = 1000e18 * 250 / 10000 = 25e18; principal = 975e18
        assertEq(token.balanceOf(feeRecipient), 25e18);
        StreamManager.Stream memory s = mgr.getStream(id);
        assertEq(s.deposit, 975e18);
        assertEq(token.balanceOf(address(mgr)), 975e18);

        vm.warp(uint256(T0) + 500);
        assertEq(mgr.streamedAmount(id), 487.5e18); // 975e18 * 500 / 1000
    }

    function test_FeeCapEnforced() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.FeeTooHigh.selector, 1001, 1000));
        mgr.setFeeBps(1001);
    }

    function test_ConstructorFeeCapEnforced() public {
        vm.expectRevert(abi.encodeWithSelector(StreamManager.FeeTooHigh.selector, 1001, 1000));
        new StreamManager(owner, feeRecipient, 1001);
    }

    // --------------------------------------------------------------------- //
    // bad params
    // --------------------------------------------------------------------- //

    function test_RevertEndBeforeStart() public {
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.InvalidTimeRange.selector, END, START));
        mgr.createStream(recipient, address(token), AMT, END, 0, START, true);
    }

    function test_RevertEndEqualsStart() public {
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.InvalidTimeRange.selector, START, START));
        mgr.createStream(recipient, address(token), AMT, START, 0, START, true);
    }

    function test_RevertCliffBeforeStart() public {
        uint40 badCliff = START - 1;
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.InvalidCliff.selector, START, badCliff, END));
        mgr.createStream(recipient, address(token), AMT, START, badCliff, END, true);
    }

    function test_RevertCliffAfterEnd() public {
        uint40 badCliff = END + 1;
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.InvalidCliff.selector, START, badCliff, END));
        mgr.createStream(recipient, address(token), AMT, START, badCliff, END, true);
    }

    function test_RevertZeroAmount() public {
        vm.prank(sender);
        vm.expectRevert(StreamManager.ZeroAmount.selector);
        mgr.createStream(recipient, address(token), 0, START, 0, END, true);
    }

    function test_RevertZeroRecipient() public {
        vm.prank(sender);
        vm.expectRevert(StreamManager.ZeroAddress.selector);
        mgr.createStream(address(0), address(token), AMT, START, 0, END, true);
    }

    function test_RevertZeroToken() public {
        vm.prank(sender);
        vm.expectRevert(StreamManager.ZeroAddress.selector);
        mgr.createStream(recipient, address(0), AMT, START, 0, END, true);
    }

    // --------------------------------------------------------------------- //
    // recipient management & access control
    // --------------------------------------------------------------------- //

    function test_TransferRecipient() public {
        uint256 id = _create(0, true);
        vm.warp(uint256(T0) + 300);

        vm.prank(recipient);
        mgr.transferRecipient(id, stranger);

        vm.prank(stranger);
        mgr.withdrawMax(id);
        assertEq(token.balanceOf(stranger), 300e18);

        // old recipient can no longer act
        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(StreamManager.Unauthorized.selector, id, recipient));
        mgr.withdraw(id, 1);
    }

    function test_TransferRecipientClearsApproval() public {
        uint256 id = _create(0, true);
        vm.prank(recipient);
        mgr.approveWithdrawer(id, stranger);
        vm.prank(recipient);
        mgr.transferRecipient(id, address(0xCAFE));
        assertEq(mgr.getApproved(id), address(0));
    }

    function test_OnlyOwnerSetsFee() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mgr.setFeeBps(100);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mgr.setFeeRecipient(stranger);
    }

    function test_SetFeeRecipient() public {
        vm.prank(owner);
        mgr.setFeeRecipient(address(0xBEEF));
        assertEq(mgr.feeRecipient(), address(0xBEEF));

        vm.prank(owner);
        vm.expectRevert(StreamManager.ZeroAddress.selector);
        mgr.setFeeRecipient(address(0));
    }

    function test_NullStreamViewsRevert() public {
        vm.expectRevert(abi.encodeWithSelector(StreamManager.StreamNull.selector, 999));
        mgr.streamedAmount(999);
    }

    // --------------------------------------------------------------------- //
    // conservation on a single stream (deposited == withdrawn + remaining + refunded + fee)
    // --------------------------------------------------------------------- //

    function test_ConservationAcrossLifecycle() public {
        vm.prank(owner);
        mgr.setFeeBps(300); // 3%

        uint256 received = AMT; // MockERC20: no transfer fee
        vm.prank(sender);
        uint256 id = mgr.createStream(recipient, address(token), AMT, START, 0, END, true);

        uint256 fee = (received * 300) / 10_000; // 30e18
        StreamManager.Stream memory s = mgr.getStream(id);
        uint256 principal = s.deposit; // 970e18

        vm.warp(uint256(T0) + 500);
        vm.prank(recipient);
        mgr.withdraw(id, 100e18);

        vm.warp(uint256(T0) + 700);
        vm.prank(sender);
        mgr.cancel(id);

        s = mgr.getStream(id);
        uint256 remaining = uint256(s.deposit) - s.withdrawn - s.refunded;
        // deposited(received) == withdrawn + remaining + refunded + fee
        assertEq(received, uint256(s.withdrawn) + remaining + uint256(s.refunded) + fee);
        assertEq(principal, uint256(s.withdrawn) + remaining + uint256(s.refunded));
    }
}
